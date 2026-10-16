/// LibrePili: a bilibili stream fetched over several connections at once,
/// for a player that asks for it over one (user 2026-10-12, 1A).
///
/// ## Why
///
/// A CDN edge serves what it holds fast and fetches the rest from the
/// origin as it is asked for — measured 2026-10-12: the same megabyte, never
/// asked for before, came at 0.3–0.6 Mbps from cosov and at 4.4–5.9 Mbps the
/// next two times; akam 2.7–2.9, then 6–8. mpv reads a stream with one
/// request from where it is, so a video few have watched plays at the edge's
/// pace from the origin, below its bitrate on cosov (0.5–0.8 Mbps for 1.6
/// Mbps streams). Asked for in pieces at once, those fetches run side by
/// side: 1, 2 and 4 at a time gave 0.80, 1.51 and 2.76 Mbps there.
///
/// ## How
///
/// A server on the loopback stands in for each upstream URL
/// ([ParallelFetch.wrap]). A request from the player at byte N is answered
/// from [chunkBytes]-sized pieces of the upstream, [connections] of them
/// fetched at once from where the player reads on; each piece is handed
/// over as it arrives, so the first bytes after a seek do not wait for the
/// whole piece. A piece that breaks off is asked for again from where it
/// stopped, three times. What the upstream does is what the player sees: a
/// refusal is answered with the same status, and a copy that ends early
/// ends the answer at the same byte — the player's own recovery (a CDN
/// switch, a cut copy, expired URLs) reads the same signals as before.
///
/// Only bilibili's own hosts, with bilibili's headers ([isBilibili]); off
/// with the 多线程加载 setting.
library;

import 'dart:async';
import 'dart:io';
import 'dart:collection' show SplayTreeMap;
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

class ParallelFetch {
  ParallelFetch({
    this.connections = 4,
    this.chunkBytes = 512 * 1024,
    this.aheadChunks = 12,
    this.cachedBytes = 64 << 20,
    Map<String, String> Function(Uri upstream)? headers,
  }) : _headers = headers ?? ((_) => const {});

  /// The app's: started with the first player (see [start]).
  static final instance = ParallelFetch();

  /// Pieces fetched at once, per stream.
  final int connections;

  /// The size of one piece. Small, because a cold piece comes at the
  /// origin's pace (0.5 Mbps): the first one after a seek is waited for.
  final int chunkBytes;

  /// How far ahead of where the player reads pieces are fetched.
  final int aheadChunks;

  /// What is kept of pieces fetched, all streams together.
  final int cachedBytes;

  final Map<String, String> Function(Uri upstream) _headers;

  /// Where each piece's trouble is written (the event log, from the
  /// player): this file stays free of the app.
  static void Function(String line)? log;

  HttpServer? _server;
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  final _byId = <String, _Remote>{};
  final _idOf = <String, String>{};
  var _nextId = 0;

  /// Pieces held, oldest use first, for [cachedBytes].
  final _held = <_Chunk>{};
  var _heldBytes = 0;

  bool get running => _server != null;

  /// Self-test: the first request from the player is answered this much
  /// later (an upstream slow to give its first answer).
  static Duration? debugStallFirst;

  /// Self-test: where a request upstream really goes (the self-test's
  /// proxy, standing between this and the host).
  static Uri Function(Uri uri)? debugUpstream;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _client.maxConnectionsPerHost = connections * 3;
    _server = server;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (_) {},
    );
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
  }

  /// Whether [url] is one of bilibili's stream hosts (the only ones this
  /// is for: their headers are bilibili's).
  static bool isBilibili(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
      return false;
    }
    final host = uri.host;
    return host.endsWith('.bilivideo.com') ||
        host.endsWith('.bilivideo.cn') ||
        host.endsWith('.akamaized.net') ||
        host.endsWith('.hdslb.com') ||
        uri.path.contains('/upgcxcode/');
  }

  /// The loopback URL that stands in for [url]; null while not running.
  /// The upstream's host is in the path, for a log line to name.
  String? wrap(String url) {
    final server = _server;
    if (server == null) return null;
    final id = _idOf[url] ??= '${_nextId++}';
    _byId[id] ??= _Remote(Uri.parse(url));
    final host = Uri.parse(url).host;
    return 'http://127.0.0.1:${server.port}/$id/$host';
  }

  /// The upstream [local] stands in for, or [local] itself.
  String upstreamOf(String local) {
    final uri = Uri.tryParse(local);
    if (uri == null || uri.host != '127.0.0.1' || uri.pathSegments.isEmpty) {
      return local;
    }
    return _byId[uri.pathSegments.first]?.uri.toString() ?? local;
  }

  // ---------------------------------------------------------------- serving

  Future<void> _serve(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final remote = segments.isEmpty ? null : _byId[segments.first];
    final response = request.response;
    if (remote == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (debugStallFirst case final stall?) {
      debugStallFirst = null;
      await Future<void>.delayed(stall);
    }
    final asked = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    final from = asked?.from ?? 0;

    final reader = _Reader(from);
    remote.readers.add(reader);
    // the player asking again is its own retry of a piece given up on
    final first = _pieceAt(remote, from, again: true);
    _pump(remote);

    // Answered once the size is known — at once after the first answer, so a
    // seek is not left waiting for its first bytes (mpv gave up on one after
    // 5 s, 2026-10-12) — but a moment is given for a refusal to show: a 403
    // for expired URLs is passed on as the status the player knows.
    final patience = Stopwatch()..start();
    first.readers++;
    try {
      while (first.received <= from - first.start &&
          first.failure == null &&
          !first.done &&
          (remote.size == null ||
              patience.elapsed < const Duration(milliseconds: 1500))) {
        await Future.any([
          first.changed,
          Future<void>.delayed(const Duration(milliseconds: 250)),
        ]);
        if (patience.elapsed > const Duration(seconds: 30)) break;
      }
    } finally {
      first.readers--;
    }
    final size = remote.size;
    if (size == null ||
        (first.failure != null && first.received <= from - first.start)) {
      remote.readers.remove(reader);
      response.statusCode = first.failure?.status ?? HttpStatus.badGateway;
      await response.close();
      return;
    }
    if (from >= size) {
      remote.readers.remove(reader);
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
      await response.close();
      return;
    }
    final to = min(asked?.to ?? size - 1, size - 1);
    response
      ..statusCode = asked == null ? HttpStatus.ok : HttpStatus.partialContent
      ..contentLength = to - from + 1
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (asked != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $from-$to/$size',
      );
    }
    if (remote.contentType case final type?) {
      response.headers.set(HttpHeaders.contentTypeHeader, type);
    }
    if (request.method == 'HEAD') {
      remote.readers.remove(reader);
      await response.close();
      return;
    }

    final Socket socket;
    try {
      socket = await response.detachSocket(writeHeaders: true);
    } catch (_) {
      remote.readers.remove(reader);
      return;
    }
    // the player hanging up (a seek opens a new request and drops this
    // one): what it read here is no longer wanted, at once
    unawaited(
      socket.done.catchError((_) {}).whenComplete(() {
        reader.gone = true;
        remote.readers.remove(reader);
        reader.waitingOn?.notify();
        _pump(remote);
      }),
    );
    try {
      while (reader.pos <= to && !reader.gone) {
        final pos = reader.pos;
        final chunk = _pieceAt(remote, pos);
        _pump(remote);
        final offset = pos - chunk.start;
        chunk.readers++;
        reader.waitingOn = chunk;
        try {
          while (chunk.received <= offset &&
              !chunk.done &&
              chunk.failure == null &&
              !reader.gone) {
            await chunk.changed;
          }
        } finally {
          chunk.readers--;
          reader.waitingOn = null;
        }
        if (reader.gone) break;
        if (chunk.received <= offset) {
          // the piece broke off here for good: the answer ends here too, as
          // the upstream's would have (a cut copy ends at its byte)
          log?.call(
            '${remote.uri.host}: piece at ${chunk.start} ended at '
            '${chunk.start + chunk.received}'
            '${chunk.failure == null ? '' : ' (${chunk.failure})'}',
          );
          break;
        }
        final end = min(chunk.received, to - chunk.start + 1);
        socket.add(chunk.bytes(offset, end));
        reader.pos = chunk.start + end;
        _touch(chunk);
        // only as fast as the player reads
        await socket.flush();
      }
    } catch (_) {
      // the player hung up: a seek, a close
    } finally {
      reader.gone = true;
      remote.readers.remove(reader);
      socket.destroy();
      _pump(remote);
    }
  }

  static ({int from, int? to})? _parseRange(String? header) {
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header ?? '');
    if (m == null) return null;
    return (
      from: int.parse(m.group(1)!),
      to: m.group(2)!.isEmpty ? null : int.parse(m.group(2)!),
    );
  }

  // ---------------------------------------------------------------- pieces

  /// The piece holding byte [pos]. A new one starts at [pos] itself, not at
  /// a boundary before it: after a seek, the bytes before it would be waited
  /// for at the origin's pace for nothing. It ends at the next boundary (a
  /// multiple of [chunkBytes]) or the next piece, so the ones after line up.
  ///
  /// With [again], one given up on is tried anew — for a new request from
  /// the player only: the player asking again is its own retry, and anything
  /// else retrying a piece that fails for good never lets the answer end
  /// (expired URLs excepted: the player renews those).
  _Chunk _pieceAt(_Remote remote, int pos, {bool again = false}) {
    final key = remote.chunks.lastKeyBefore(pos + 1);
    final holding = key == null ? null : remote.chunks[key];
    if (holding != null && pos < holding.start + holding.length) {
      final arrived = holding.start + holding.received;
      // a piece under way whose bytes are still far before [pos]: it stops
      // at [pos], and the rest is a piece of its own, fetched at once —
      // else the reader waits for the bytes before it to come in at the
      // origin's pace (17 s at the start of a seek, 2026-10-12)
      if (holding.fetching && !holding.done && pos - arrived > 64 * 1024) {
        final end = holding.start + holding.length;
        holding.length = pos - holding.start;
        final rest = _Chunk(pos, end - pos);
        remote.chunks[pos] = rest;
        return rest;
      }
      // an idle piece that has nothing yet and starts well before: started
      // here instead
      final idle = holding.received == 0 && !holding.fetching && !holding.done;
      if (!idle || pos - holding.start < 16 * 1024) {
        if (again &&
            holding.failure != null &&
            !holding.fetching &&
            !holding.done) {
          final status = holding.failure!.status;
          if (status != HttpStatus.forbidden && status != HttpStatus.notFound) {
            holding
              ..failure = null
              ..lastError = null
              ..attempts = 0;
          }
        }
        return holding;
      }
      if (holding.readers == 0) remote.chunks.remove(holding.start);
    }
    var end = (pos ~/ chunkBytes + 1) * chunkBytes;
    final next = remote.chunks.firstKeyAfter(pos);
    if (next != null && next < end) end = next;
    if (remote.size case final size?) end = min(end, size);
    final piece = _Chunk(pos, max(1, end - pos));
    remote.chunks[pos] = piece;
    return piece;
  }

  /// Starts the pieces the readers need next: the one each reader waits on
  /// at once, whatever else is under way (a seek is not queued behind the
  /// pieces of where playback was), and the ones after it [connections] at
  /// a time, the nearest first.
  void _pump(_Remote remote) {
    if (remote.readers.isEmpty) return;
    final size = remote.size;
    final ahead = <_Chunk>[];
    for (final reader in remote.readers.toList()) {
      if (reader.gone) continue;
      var pos = reader.pos;
      for (var d = 0; d < aheadChunks; d++) {
        if (size != null && pos >= size) break;
        final piece = _pieceAt(remote, pos);
        if (d == 0) {
          if (!piece.done && !piece.fetching && piece.failure == null) {
            unawaited(_fetch(remote, piece));
          }
        } else if (!ahead.contains(piece)) {
          ahead.add(piece);
        }
        // before the size is known, only the piece each reader is at
        if (size == null) break;
        pos = piece.start + piece.length;
      }
    }
    ahead.sort((a, b) => a.start.compareTo(b.start));
    for (final piece in ahead) {
      if (remote.fetching >= connections) return;
      if (piece.done || piece.fetching || piece.failure != null) continue;
      unawaited(_fetch(remote, piece));
    }
  }

  Future<void> _fetch(_Remote remote, _Chunk chunk) async {
    chunk.fetching = true;
    remote.fetching++;
    try {
      // tries that bring nothing count; one that brings bytes does not (akam
      // closes connections every few seconds, measured 2026-10-12)
      var fruitless = 0;
      var tries = 0;
      while (!chunk.done && fruitless < 3 && tries < 30) {
        tries++;
        final from = chunk.start + chunk.received;
        final size = remote.size;
        final to = size == null
            ? chunk.start + chunk.length - 1
            : min(chunk.start + chunk.length - 1, size - 1);
        if (from > to) {
          chunk.finish(chunk.received);
          break;
        }
        final before = chunk.received;
        final status = await _get(remote, chunk, from, to);
        if (status == null) continue;
        if (status == HttpStatus.forbidden || status == HttpStatus.notFound) {
          break;
        }
        if (chunk.received > before) {
          fruitless = 0;
        } else {
          fruitless++;
          if (fruitless < 3) {
            await Future<void>.delayed(Duration(milliseconds: 300 * fruitless));
          }
        }
      }
      chunk.attempts = tries;
      if (!chunk.done) {
        chunk.failure = chunk.lastError ?? const _Failure(null, 'gave up');
      }
    } finally {
      chunk.fetching = false;
      remote.fetching--;
      chunk.notify();
      _hold(chunk);
      _pump(remote);
    }
  }

  /// One request for bytes [from]-[to] of [chunk]: null when the piece is
  /// whole, the status (or 0) when it is not.
  Future<int?> _get(_Remote remote, _Chunk chunk, int from, int to) async {
    try {
      final request = await _client
          .getUrl(debugUpstream?.call(remote.uri) ?? remote.uri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = true;
      _headers(remote.uri).forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final status = response.statusCode;
      if (status != HttpStatus.partialContent && status != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        chunk.lastError = _Failure(status, 'HTTP $status');
        return status;
      }
      if (status == HttpStatus.partialContent) {
        final total = RegExp(r'/(\d+)$')
            .firstMatch(
              response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
            )
            ?.group(1);
        if (total != null && remote.size == null) {
          remote.size = int.parse(total);
          // the rest need not wait for this piece to finish
          scheduleMicrotask(() => _pump(remote));
        }
      } else {
        // the whole file, ranges ignored: usable only from its start
        if (from != 0) {
          await response.drain<void>().catchError((_) {});
          chunk.lastError = const _Failure(null, 'range ignored');
          return HttpStatus.ok;
        }
        if (response.contentLength >= 0) remote.size ??= response.contentLength;
      }
      remote.contentType ??= response.headers.value(
        HttpHeaders.contentTypeHeader,
      );
      var got = 0;
      // a piece that stops coming in is asked for again; one shortened
      // meanwhile stops where it now ends
      await for (final data in response.timeout(const Duration(seconds: 12))) {
        final room = chunk.length - chunk.received;
        if (room <= 0) break;
        final take = min(data.length, room);
        chunk.add(data, take);
        got += take;
        if (chunk.received >= chunk.length) break;
      }
      if (chunk.received >= chunk.length ||
          chunk.start + chunk.received >= (remote.size ?? 0)) {
        chunk.finish(chunk.received);
        return null;
      }
      chunk.lastError = _Failure(null, 'ended at ${from + got}');
      return 0;
    } catch (e) {
      chunk.lastError = _Failure(null, e.runtimeType.toString());
      return 0;
    } finally {
      chunk.notify();
    }
  }

  // ---------------------------------------------------------------- memory

  void _touch(_Chunk chunk) {
    if (_held.remove(chunk)) _held.add(chunk);
  }

  void _hold(_Chunk chunk) {
    if (!chunk.done || !_held.add(chunk)) return;
    _heldBytes += chunk.received;
    while (_heldBytes > cachedBytes) {
      final old = _held.firstWhere(
        (c) => c.readers == 0 && !c.fetching,
        orElse: () => chunk,
      );
      if (identical(old, chunk)) break;
      _held.remove(old);
      _heldBytes -= old.received;
      old.drop();
    }
  }

  @visibleForTesting
  int get heldBytes => _heldBytes;
}

class _Remote {
  _Remote(this.uri);

  final Uri uri;
  int? size;
  String? contentType;

  /// Pieces by where they start.
  final chunks = SplayTreeMap<int, _Chunk>();
  final readers = <_Reader>{};
  var fetching = 0;
}

class _Reader {
  _Reader(this.pos);

  /// The byte it hands over next.
  int pos;

  /// The player hung up.
  var gone = false;

  /// The piece it waits on, to be woken when the player hangs up.
  _Chunk? waitingOn;
}

class _Failure {
  const _Failure(this.status, this.why);

  final int? status;
  final String why;

  @override
  String toString() => why;
}

class _Chunk {
  _Chunk(this.start, this.length);

  final int start;

  /// Shortened when a reader starts further on inside it (see _pieceAt).
  int length;

  Uint8List? _data;
  var received = 0;
  var done = false;
  var fetching = false;
  var attempts = 0;

  /// Given up on, and why: set only once the attempts are spent, so a
  /// reader waits through the retries.
  _Failure? failure;

  /// The last attempt's trouble, while there are attempts left.
  _Failure? lastError;

  /// Readers reading it now: not evicted under them.
  var readers = 0;

  var _waiter = Completer<void>();

  /// Completes the next time bytes arrive or the piece ends.
  Future<void> get changed => _waiter.future;

  void notify() {
    final w = _waiter;
    _waiter = Completer<void>();
    w.complete();
  }

  void add(List<int> data, int count) {
    (_data ??= Uint8List(length)).setRange(received, received + count, data);
    received += count;
    notify();
  }

  void finish(int bytes) {
    done = true;
    failure = null;
    notify();
  }

  List<int> bytes(int from, int to) => Uint8List.sublistView(_data!, from, to);

  /// Evicted: asked for again if it is read again.
  void drop() {
    _data = null;
    received = 0;
    done = false;
    attempts = 0;
    failure = null;
    lastError = null;
  }
}
