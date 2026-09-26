/// LibrePili: read-only access to a running app from the command line
/// (`lib/scripts/librepili_ctl.py`), so the user or an agent can ask the
/// instance actually in use what it is doing — which video, where its
/// transcription and translation stand, what the event log says.
///
/// A plain HTTP server on the loopback address only, on a port the system
/// picks, started only while 设置 → 其它设置 → 允许命令行读取状态 is on. Every
/// request but `/health` must carry the token written, with the port, to
/// `ctl.json` in the app's own data folder: whoever can read that folder
/// (the same user, or `adb` on a debuggable Android build) can read the
/// state; nothing else on the machine can.
///
/// Only GET, only JSON, and nothing that changes the app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

/// Answers one endpoint: the JSON-encodable value to send.
typedef CtlEndpoint = FutureOr<Object?> Function(Uri uri);

/// Anything JSON cannot hold is sent as its `toString`, rather than failing
/// the whole answer.
const _encoder = JsonEncoder.withIndent('  ', _asText);
Object? _asText(Object? value) => '$value';

final class CtlServer {
  CtlServer({
    required this.dir,
    required this.endpoints,
    required this.identity,
    this.mirrorDir,
    String? token,
  }) : token = token ?? newToken();

  /// Where `ctl.json` is written: the app's support folder.
  final String dir;

  /// A second place `ctl.json` is written, for a reader that cannot reach
  /// [dir] (Android's app-specific external folder, which `adb shell` can
  /// read on a release build). Null: none.
  final String? mirrorDir;

  /// By path (`/status`…). Every one needs the token.
  final Map<String, CtlEndpoint> endpoints;

  /// Written into `ctl.json` and answered by `/health`: version, profile.
  final Map<String, Object?> identity;

  final String token;

  HttpServer? _server;
  DateTime? _startedAt;

  /// The one serving, for the way out (`appExit`), which must remove its
  /// file and can reach nothing else.
  static CtlServer? current;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  static const fileName = 'ctl.json';

  String get filePath => path.join(dir, fileName);
  String? get mirrorPath =>
      mirrorDir == null ? null : path.join(mirrorDir!, fileName);

  /// 32 random bytes, as hex.
  static String newToken() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Whether an `Authorization` header carries [token], compared in time
  /// that does not depend on where the first difference is.
  static bool tokenMatches(String? header, String token) {
    if (header == null) return false;
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    final given = utf8.encode(header.substring(prefix.length).trim());
    final expected = utf8.encode(token);
    var diff = given.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ (i < given.length ? given[i] : 0);
    }
    return diff == 0;
  }

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    current = this;
    _startedAt = DateTime.now();
    server.listen(_serve, onError: (_) {});
    try {
      await _writeFile();
    } catch (_) {
      // a server no one can find the token of serves no one
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (identical(current, this)) current = null;
    removeFileSync();
    await server?.close(force: true);
  }

  Map<String, Object?> get fileContents => {
    'port': port,
    'token': token,
    'pid': pid,
    'startedAt': _startedAt?.toIso8601String(),
    ...identity,
  };

  Future<void> _writeFile() async {
    final json = _encoder.convert(fileContents);
    for (final target in [filePath, ?mirrorPath]) {
      try {
        await Directory(path.dirname(target)).create(recursive: true);
        // whole or not at all: a reader never sees half a file
        final part = File('$target.part');
        await part.writeAsString(json, flush: true);
        await part.rename(target);
      } catch (_) {
        if (target == filePath) rethrow;
      }
    }
  }

  /// Best effort, and synchronous: it is also called on the way out, where
  /// nothing asynchronous gets to run (see `appExit`).
  void removeFileSync() {
    for (final target in [filePath, ?mirrorPath]) {
      try {
        final file = File(target);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  /// Removes a `ctl.json` left in [dir] (and [mirrorDir]) by a run that did
  /// not get to — a crash, a kill — so the setting being off means there
  /// is none.
  static void removeStale(String dir, {String? mirrorDir}) {
    for (final d in [dir, ?mirrorDir]) {
      try {
        final file = File(path.join(d, fileName));
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    Future<void> send(int status, Object? body) async {
      try {
        response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..write(_encoder.convert(body));
        await response.close();
      } catch (_) {}
    }

    // a browser's page on another origin: never, token or not (a page can
    // reach the loopback address; it has no business here)
    if (request.headers.value('origin') != null) {
      return send(HttpStatus.forbidden, {'error': 'browser requests refused'});
    }
    if (request.method != 'GET') {
      return send(HttpStatus.methodNotAllowed, {'error': 'read-only: GET'});
    }
    final route = request.uri.path;
    if (route == '/health') {
      return send(HttpStatus.ok, {'ok': true, ...identity});
    }
    if (!tokenMatches(
      request.headers.value(HttpHeaders.authorizationHeader),
      token,
    )) {
      return send(HttpStatus.unauthorized, {
        'error': 'missing or wrong token (see ctl.json)',
      });
    }
    final endpoint = endpoints[route];
    if (endpoint == null) {
      return send(HttpStatus.notFound, {
        'error': 'no such endpoint',
        'endpoints': ['/health', ...endpoints.keys],
      });
    }
    Object? body;
    try {
      body = await endpoint(request.uri);
    } catch (e) {
      return send(HttpStatus.internalServerError, {'error': '$e'});
    }
    return send(HttpStatus.ok, body);
  }
}
