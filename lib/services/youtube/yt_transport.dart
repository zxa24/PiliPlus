/// The HTTP transport this folder owns, and the reason it is its own.
///
/// ## Why the app's shared request stack is deliberately NOT used
///
/// `Request.dio` (lib/http/init.dart) is built for bilibili and carries, on
/// every request that goes through it:
///
///   * [AccountManager] (lib/utils/accounts/account_manager/account_mgr.dart),
///     a dio `Interceptor` that resolves an [Account] for the request, attaches
///     `account.headers`, loads that account's `cookieJar` into the `Cookie`
///     header, **persists every `Set-Cookie` back into that jar**, adds
///     `access_key` + an app signature to app-API calls, and defaults
///     `referer` to `https://www.bilibili.com`;
///   * the `buvid` / `buvid3` / `buvid4` device identifiers those cookie jars
///     hold, plus `LoginUtils.setAnonymousWebCookie()`'s anonymous-session
///     cookies — stable per install, i.e. a durable device fingerprint;
///   * [LoginPolicy] (lib/utils/accounts/login_policy.dart), whose whole job is
///     to decide *which bilibili account* a request goes out as;
///   * a bilibili `baseUrl`, a bilibili user-agent, `br,gzip` encodings decoded
///     by a bilibili-specific `responseDecoder`, and a retry interceptor tuned
///     to bilibili's error envelope.
///
/// Every one of those is wrong here, and two of them are actively harmful:
/// sending a bilibili `buvid`/session cookie to Google would join the two
/// identities, and persisting Google's `Set-Cookie` into an account's jar would
/// then leak back the other way. Routing YouTube through that stack could not
/// be made safe by configuration — the interceptor is registered on the shared
/// `dio` instance, so it applies to everything that instance sends.
///
/// So this layer owns a bare `dart:io` [HttpClient]:
///
///   * **no cookie jar.** `HttpClient` does not persist cookies on its own and
///     we never read `Set-Cookie`. The only `Cookie` we ever send is the fixed
///     literal `SOCS=CAISAiAD`, a consent flag with no user state, without
///     which EU egress IPs are 302'd to `consent.youtube.com`;
///   * **no account binding, no `LoginPolicy`, no bilibili headers or referer**
///     — the only headers sent are the ones in [YtClientIdentity.headers];
///   * the only per-session identity is `visitorData`, an anonymous blob minted
///     by YouTube itself, held in memory, never written to disk, and dropped
///     when the client is closed. See `innertube_client.dart`.
///
/// The one user-derived value that leaves this layer is the bare 11-character
/// video id (see `yt_video_id.dart`).
///
/// ## Testability
///
/// [YtTransport] is an interface so tests can drive the classifier and the
/// parsers from recorded fixtures without touching the network. [IoYtTransport]
/// is the only production implementation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/yt_identity.dart';

/// One HTTP response, already read into memory.
class YtResponse {
  YtResponse({
    required this.status,
    required this.headers,
    required this.body,
    this.json,
    this.took = Duration.zero,
    this.transportError = '',
  });

  /// A transport-level failure (DNS, TCP, TLS, timeout): status 0.
  factory YtResponse.transportFailure(
    String error, [
    Duration took = Duration.zero,
  ]) => YtResponse(
    status: 0,
    headers: const {},
    body: const [],
    took: took,
    transportError: error,
  );

  /// For tests: a JSON body that was recorded rather than fetched.
  factory YtResponse.recorded(
    Object? json, {
    int status = 200,
    Map<String, String> headers = const {
      'content-type': 'application/json; charset=UTF-8',
    },
  }) {
    final bytes = utf8.encode(jsonEncode(json));
    return YtResponse(
      status: status,
      headers: headers,
      body: bytes,
      json: json,
    );
  }

  final int status;
  final Map<String, String> headers;

  /// The raw bytes. [text] is a lossy UTF-8 decode and MUST NOT be used to
  /// write media back out — the spike lost 5% of a 262 144-byte fragment that
  /// way and still produced a plausible-looking file.
  final List<int> body;

  final Object? json;
  final Duration took;
  final String transportError;

  int get byteCount => body.length;

  String? _text;
  String get text => _text ??= utf8.decode(body, allowMalformed: true);

  String get contentType => (headers['content-type'] ?? '').toLowerCase();

  Map<String, dynamic> get obj =>
      json is Map ? (json! as Map).cast<String, dynamic>() : const {};

  /// A short, log-safe excerpt of the body.
  String get snippet {
    final t = text;
    return (t.length > 300 ? t.substring(0, 300) : t)
        .replaceAll('\n', ' ')
        .trim();
  }
}

/// How this layer talks to the network. One implementation in production
/// ([IoYtTransport]); tests substitute a recorder.
abstract class YtTransport {
  Future<YtResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers,
    List<int>? body,
    String? contentType,
    bool parseJson,
    bool followRedirects,
  });

  void close();
}

/// A `dart:io` [HttpClient] with no cookie jar and no shared state.
class IoYtTransport implements YtTransport {
  IoYtTransport({
    this.timeout = const Duration(seconds: 25),
    Duration connectTimeout = const Duration(seconds: 12),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = connectTimeout
      // Never let dart:io add its own default UA: the identity's UA is the
      // whole point, and a second one would be a fingerprint of its own.
      ..userAgent = null
      ..autoUncompress = true;
  }

  final HttpClient _client;
  final Duration timeout;

  /// Bytes and requests seen, for the diagnostics line. Not persisted.
  int requests = 0;
  int bytesIn = 0;

  /// Hard ceiling on a single response. A player response is 60–270 KiB; this
  /// is generous enough for a search page (~1 MiB) and still bounded.
  static const int maxBytes = 12 << 20;

  @override
  Future<YtResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    String? contentType,
    bool parseJson = true,
    bool followRedirects = false,
  }) async {
    requests++;
    final sw = Stopwatch()..start();
    try {
      final req = await _client.openUrl(method, url).timeout(timeout);
      req
        ..followRedirects = followRedirects
        ..maxRedirects = 5;
      // Drop dart:io's default, then set exactly what the identity asked for.
      req.headers.removeAll(HttpHeaders.userAgentHeader);
      headers.forEach(req.headers.set);
      req.headers
        ..set(
          HttpHeaders.acceptHeader,
          parseJson ? 'application/json, text/plain, */*' : '*/*',
        )
        ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      if (body != null) {
        req.headers
          ..set(
            HttpHeaders.contentTypeHeader,
            contentType ?? 'application/json',
          )
          ..set(HttpHeaders.contentLengthHeader, '${body.length}');
        req.add(body);
      }
      final res = await req.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) break;
      }
      sw.stop();
      bytesIn += bytes.length;
      final hm = <String, String>{};
      res.headers.forEach((k, v) => hm[k.toLowerCase()] = v.join(', '));
      Object? decoded;
      if (parseJson) {
        try {
          decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        } catch (_) {
          // Left null on purpose: the classifier reads "JSON expected but
          // unparseable" as (d), which is what it is.
        }
      }
      return YtResponse(
        status: res.statusCode,
        headers: hm,
        body: bytes,
        json: decoded,
        took: sw.elapsed,
      );
    } on TimeoutException {
      sw.stop();
      return YtResponse.transportFailure('timeout', sw.elapsed);
    } catch (e) {
      sw.stop();
      final m = e.toString();
      return YtResponse.transportFailure(
        m.length > 160 ? m.substring(0, 160) : m,
        sw.elapsed,
      );
    }
  }

  @override
  void close() => _client.close(force: true);
}
