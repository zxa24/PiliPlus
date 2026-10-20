/// LibrePili — Invidious streams through the app, not straight to mpv.
///
/// An Invidious instance names the stream URLs. Each was checked when it was
/// listed ([YtInvidiousSource.publicAddresses]: https, a public address),
/// but mpv follows a redirect wherever it leads — a public instance could
/// send it on to a service on the local network — and looks the name up
/// again itself, so a second DNS answer could do the same (audit 2026-10-19,
/// round 2's G9 and round 4's D11; user: route them through the app).
///
/// So mpv is handed `http://127.0.0.1:<port>/<token>/<host>` and this
/// fetches the stream:
///
///  * every hop, the first one included, is checked as the listed URL was;
///    redirects are followed here, one hop at a time, never by the client;
///  * the connection goes to an address that check found ([YtCheckedHops]),
///    with TLS for the URL's own host name (SNI and the certificate), so a
///    second lookup cannot change where it goes;
///  * with the 设置代理 setting on ([proxyFor]), the proxy looks the names
///    up and connects: only the scheme and the host (not this machine, not
///    a local address written as one) are checked then;
///  * GET and HEAD, with the Range mpv asks for; the status and the headers
///    a player reads (Content-Range, Content-Length, Content-Type,
///    Accept-Ranges) go back as they came.
///
/// The token is 128 random bits, as the parallel fetch's: anything else on
/// this machine able to reach 127.0.0.1 cannot guess its way to a stream.
/// googlevideo's own URLs from the direct source do not come here.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/youtube/invidious_source.dart';

/// A hop refused: not https, or not to a public address.
class YtHopRefused implements Exception {
  const YtHopRefused(this.uri, this.why);

  final Uri uri;
  final String why;

  @override
  String toString() => 'YtHopRefused($why: ${uri.host})';
}

/// An [HttpClient] that only reaches checked hops, at the addresses checked.
///
/// The relay's and the downloader's: [send] follows redirects itself,
/// checking each hop with [check], and the client's connections go to the
/// address [check] pinned for the host (see the library doc).
class YtCheckedHops {
  YtCheckedHops(this.client) {
    client
      ..findProxy = proxyOf
      ..connectionFactory = _connect;
  }

  final HttpClient client;

  /// The addresses each host was last checked at.
  final _pins = <String, List<InternetAddress>>{};

  /// How [uri] is reached (`DIRECT` / `PROXY host:port`): the listing's
  /// check ([YtInvidiousSource.isPublicUrl]) follows the same rule.
  static String proxyOf(Uri uri) =>
      YtStreamRelay.proxyFor?.call(uri) ??
      HttpClient.findProxyFromEnvironment(uri);

  /// How many redirects are followed.
  static const maxHops = 5;

  /// Throws [YtHopRefused] unless [uri] may be asked for; pins the
  /// addresses it found for [_connect].
  Future<void> check(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw YtHopRefused(uri, 'not https');
    }
    if (proxyOf(uri) != 'DIRECT') {
      // the proxy looks the name up and connects: what is left to check is
      // the name, and an address written as one
      final literal = InternetAddress.tryParse(uri.host);
      if (uri.host.toLowerCase() == 'localhost' ||
          (literal != null && YtInvidiousSource.isLocal(literal))) {
        throw YtHopRefused(uri, 'a local host');
      }
      return;
    }
    final addresses = await YtInvidiousSource.publicAddresses(uri);
    if (addresses == null) throw YtHopRefused(uri, 'no address');
    if (addresses.isEmpty) throw YtHopRefused(uri, 'not a public address');
    _pins[uri.host] = addresses;
  }

  /// [method] on [uri] with [headers], its redirects followed here, every
  /// hop checked. The response is the first that is not a redirect.
  /// [timeout] bounds each hop's wait for its headers, the request aborted
  /// when it runs out; [onRequest] is given each hop's request as it opens,
  /// so a caller can abort one still waiting.
  Future<(HttpClientRequest, HttpClientResponse)> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Duration? timeout,
    void Function(HttpClientRequest request)? onRequest,
  }) async {
    for (var hop = 0; hop <= maxHops; hop++) {
      await check(uri);
      final request = await client.openUrl(method, uri);
      onRequest?.call(request);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      var future = request.close();
      if (timeout != null) {
        future = future.timeout(
          timeout,
          onTimeout: () {
            // the connection let go, not left waiting upstream
            final e = TimeoutException('no response headers', timeout);
            request.abort(e);
            throw e;
          },
        );
      }
      final response = await future;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.statusCode ~/ 100 != 3 || location == null) {
        return (request, response);
      }
      await response.drain<void>().catchError((_) {});
      uri = uri.resolve(location);
    }
    throw HttpException('too many redirects', uri: uri);
  }

  /// A direct connection goes to an address [check] pinned, never to a
  /// fresh lookup; one through the proxy, to the proxy.
  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    final pinned = _pins[uri.host];
    if (pinned == null || pinned.isEmpty) {
      throw YtHopRefused(uri, 'not checked');
    }
    var cancelled = false;
    // every socket opened and not handed on, closed when it is not needed
    final opened = <Socket>{};
    Socket? connected;
    final won = Completer<Socket>();
    var next = 0;
    var live = 0;
    Object? lastError;

    // Staggered, as dart:io's own connect: the next address once the last
    // has failed — in TLS too — or 250 ms on while none has won, TCP or
    // TLS still pending (a TLS that stalls is no better than a dead
    // address); the first through TLS wins and the rest are closed. One at a time, a dead
    // first address used up the client's whole timeout (10 s) and the
    // second was never tried. The client's timeout bounds it all.
    void startNext() {
      if (cancelled || won.isCompleted) return;
      if (next >= pinned.length) {
        if (live == 0) {
          won.completeError(
            lastError ?? const SocketException('connection failed'),
          );
        }
        return;
      }
      final address = pinned[next++];
      live++;
      var handedOn = false;
      void handOn() {
        if (handedOn) return;
        handedOn = true;
        startNext();
      }

      final stagger = Timer(const Duration(milliseconds: 250), () {
        if (!won.isCompleted) handOn();
      });
      () async {
        Socket? raw;
        try {
          raw = await Socket.connect(
            address,
            uri.port,
            timeout: const Duration(seconds: 10),
          );
          opened.add(raw);
          if (cancelled || won.isCompleted) {
            throw const SocketException('connection not needed');
          }
          // TLS for the URL's host: its name is what the certificate must
          // carry, whatever address the connection went to
          final socket = uri.scheme == 'https'
              ? await SecureSocket.secure(raw, host: uri.host)
              : raw;
          if (cancelled || won.isCompleted) {
            socket.destroy();
            throw const SocketException('connection not needed');
          }
          opened.remove(raw);
          live--;
          stagger.cancel();
          won.complete(socket);
          // the race is won: a loser still in TLS (which has no timeout of
          // its own) is closed now, not left open until the peer ends it
          for (final loser in [...opened]) {
            loser.destroy();
          }
          opened.clear();
        } catch (e) {
          if (raw != null) {
            raw.destroy();
            opened.remove(raw);
          }
          lastError = e;
          live--;
          stagger.cancel();
          if (handedOn) {
            // the next address at once; the failure once all have failed
            startNext();
          } else {
            handOn();
          }
        }
      }();
    }

    Future<Socket> open() async {
      startNext();
      final socket = await won.future;
      connected = socket;
      if (cancelled) {
        socket.destroy();
        throw const SocketException('connection cancelled');
      }
      return socket;
    }

    return ConnectionTask.fromSocket(open(), () {
      cancelled = true;
      connected?.destroy();
      for (final socket in [...opened]) {
        socket.destroy();
      }
      opened.clear();
      if (!won.isCompleted) {
        won.completeError(const SocketException('connection cancelled'));
      }
    });
  }

  void close() => client.close(force: true);
}

/// The loopback relay for one page's Invidious streams.
class YtStreamRelay {
  YtStreamRelay();

  /// How a connection upstream goes (`DIRECT` / `PROXY host:port`), as
  /// every client of the app's does (AppProxy, set in main). Unset, the
  /// environment's.
  static String Function(Uri uri)? proxyFor;

  /// Where each stream's trouble is written (the event log, from the
  /// page): this file stays free of the app.
  static void Function(String line)? log;

  HttpServer? _server;
  Future<HttpServer>? _starting;

  /// Counts the [close]s: a bind that finishes after one is closed again.
  var _generation = 0;
  YtCheckedHops _hops = _newHops();

  static YtCheckedHops _newHops() => YtCheckedHops(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15)
      // the bytes as they came: mpv is told their encoding, if any
      ..autoUncompress = false,
  );

  /// Token → upstream URL, and the way back.
  final _upstream = <String, Uri>{};
  final _tokenOf = <String, String>{};

  /// What is being relayed now, by token: each one's stop, called when its
  /// stream is let go ([retain]) or the page closes ([close]). Not
  /// [HttpClientRequest.abort], which does nothing once the response has
  /// begun: the body's subscription is cancelled, which closes the
  /// connection upstream.
  final _active = <String, Set<void Function()>>{};

  bool get running => _server != null;

  /// The loopback URL that stands in for [url], the relay started first if
  /// it is not running.
  Future<String> wrap(String url) async {
    final server = _server ?? await (_starting ??= _start());
    // closed meanwhile: a URL that leads nowhere, the page being gone
    if (!identical(server, _server)) return 'http://127.0.0.1:0/';
    return _urlFor(server, url);
  }

  /// [wrap] without starting it: null while it is not running.
  String? wrapNow(String url) {
    final server = _server;
    return server == null ? null : _urlFor(server, url);
  }

  String _urlFor(HttpServer server, String url) {
    final uri = Uri.parse(url);
    final token = _tokenOf[url] ??= _newToken();
    _upstream[token] = uri;
    // the upstream's expiry, which the player reads to ask for new URLs
    // before a long pause outlives them (PlPlayerController.sourceExpiry);
    // the relay itself reads only the token
    final expire = _expire.firstMatch(url)?.group(1);
    return 'http://127.0.0.1:${server.port}/$token/${uri.host}'
        '${expire == null ? '' : '?expire=$expire'}';
  }

  static final _expire = RegExp(r'(?:[?&]expire=|/expire/)(\d{9,11})');

  /// The streams now played are [urls]: what is still being fetched for
  /// any other is stopped (a quality change, new URLs). Their tokens stay
  /// valid, so something still reading one (a transcription of the old
  /// audio) can ask again.
  void retain(Iterable<String> urls) {
    final keep = {for (final url in urls) ?_tokenOf[url]};
    for (final MapEntry(key: token, value: stops) in _active.entries) {
      if (keep.contains(token)) continue;
      for (final stop in [...stops]) {
        stop();
      }
    }
  }

  Future<HttpServer> _start() async {
    final generation = _generation;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (generation != _generation) {
      // the page closed while binding: nothing is to listen
      await server.close(force: true);
      return server;
    }
    server.listen(_serve, onError: (_) {});
    return _server = server;
  }

  /// Every stream let go and the server closed: the page is gone.
  Future<void> close() async {
    _generation++;
    final server = _server;
    _server = null;
    _starting = null;
    for (final stops in [..._active.values]) {
      for (final stop in [...stops]) {
        stop();
      }
    }
    _active.clear();
    _upstream.clear();
    _tokenOf.clear();
    _hops.close();
    _hops = _newHops();
    await server?.close(force: true);
  }

  /// The response headers a player reads, passed on as they came.
  static const _passed = [
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.contentEncodingHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
  ];

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final token = segments.isEmpty ? '' : segments.first;
    final upstream = _upstream[token];
    if (upstream == null ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      await response.close().catchError((_) {});
      return;
    }
    // nothing more is read from the player's request
    unawaited(request.drain<void>().catchError((_) {}));

    // stoppable from the start: a request still waiting for its headers is
    // let go too (a quality change), not only one already streaming
    HttpClientRequest? pending;
    StreamSubscription<List<int>>? body;
    StreamController<List<int>>? out;
    var stopped = false;
    void stop() {
      stopped = true;
      pending?.abort(const HttpException('let go'));
      body?.cancel();
      final sink = out;
      if (sink != null && !sink.isClosed) {
        sink
          ..addError(const HttpException('let go'))
          ..close();
      }
    }

    (_active[token] ??= {}).add(stop);
    try {
      final (_, answer) = await _hops.send(
        request.method,
        upstream,
        // the client's idle timeout: an upstream that answers nothing in
        // that long is let go, as one that goes quiet mid-body is
        timeout: const Duration(seconds: 15),
        onRequest: (r) {
          pending = r;
          if (stopped) r.abort(const HttpException('let go'));
        },
        headers: {
          HttpHeaders.userAgentHeader: ?request.headers.value(
            HttpHeaders.userAgentHeader,
          ),
          HttpHeaders.rangeHeader: ?request.headers.value(
            HttpHeaders.rangeHeader,
          ),
          HttpHeaders.acceptEncodingHeader: 'identity',
        },
      );
      if (stopped) {
        await answer.drain<void>().catchError((_) {});
        throw const HttpException('let go');
      }
      response.statusCode = answer.statusCode;
      for (final name in _passed) {
        final value = answer.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      if (answer.contentLength >= 0) {
        response.contentLength = answer.contentLength;
      }
      if (answer.statusCode ~/ 100 != 2) {
        log?.call('${upstream.host}: ${answer.statusCode}');
      }
      if (request.method == 'HEAD') {
        await answer.drain<void>().catchError((_) {});
        await response.close();
        return;
      }
      // the body as it comes, at the player's pace (a paused player pauses
      // the read upstream), and stoppable
      final upstreamBody = body = answer.listen(null);
      final sink = out = StreamController<List<int>>(
        onPause: upstreamBody.pause,
        onResume: upstreamBody.resume,
        onCancel: upstreamBody.cancel,
      );
      upstreamBody
        ..onData(sink.add)
        ..onError(sink.addError)
        ..onDone(sink.close);
      await response.addStream(sink.stream);
      await response.close();
    } on YtHopRefused catch (e) {
      log?.call('refused: $e');
      await _fail(response, HttpStatus.forbidden);
    } catch (e) {
      log?.call('${upstream.host}: $e');
      await _fail(response, HttpStatus.badGateway);
    } finally {
      _active[token]?.remove(stop);
    }
  }

  /// [status] when nothing was sent yet. Otherwise the response is closed
  /// short of its length, which cuts the connection: the player sees a
  /// short read and asks again.
  static Future<void> _fail(HttpResponse response, int status) async {
    try {
      response.statusCode = status;
    } catch (_) {
      // the headers went out already
    }
    await response.close().catchError((_) {});
  }

  static String _newToken() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static final _random = Random.secure();
}
