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
///
/// With a [store], pieces are kept on disk as well (user 2026-10-17): each
/// is read from there before the network is asked, and a stream whose size
/// the store knows is answered without waiting for the upstream's first
/// answer. What a download reads ([wrap] `keep: false`) is not kept: the
/// download is a copy of its own.
///
/// ## Start-up (user 2026-10-20, 6A and 7C)
///
/// mpv opens the video, probes it, then opens the audio: two first answers
/// one after the other (0.63 s and 0.50 s of a 1.4 s start, 16A). The player
/// asks for the start of both at once as it opens them ([prefetch]), so mpv
/// finds them here. And while a stream's size is not known — every open of
/// it waits on that — a request upstream with no answer after [hedgeAfter]
/// is sent again, the first answer taken and the other dropped: one slow
/// answer had mpv give up on the open (17A).
library;

import 'dart:async';
import 'dart:io';
import 'dart:collection' show SplayTreeMap;
import 'dart:math' show Random, max, min;
import 'dart:typed_data';

import 'package:PiliPlus/services/piece_store.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

class ParallelFetch {
  ParallelFetch({
    this.connections = 4,
    this.chunkBytes = 512 * 1024,
    this.aheadChunks = 12,
    this.cachedBytes = 64 << 20,
    this.hedgeAfter = const Duration(milliseconds: 1500),
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

  /// How long a request is given to answer before a second, alike, is sent
  /// beside it, while the stream's size is not known (see the library's
  /// doc). First answers come in 0.5-0.6 s (16A): 1.5 s, the time a refusal
  /// is given to show in [_serve], is well past that, so a normal start
  /// sends one request, and well inside mpv's 5 s.
  final Duration hedgeAfter;

  /// Requests sent again by [hedgeAfter]; for tests.
  @visibleForTesting
  var hedges = 0;

  final Map<String, String> Function(Uri upstream) _headers;

  /// Where each piece's trouble is written (the event log, from the
  /// player): this file stays free of the app.
  static void Function(String line)? log;

  /// Told of each answer that was an HTTP error, with the stream's own
  /// address (not the self-test's proxy) and the status — for playback's
  /// streams only (`keep`), not a download's.
  static void Function(Uri upstream, int status)? onRefused;

  /// Told of a copy cut short — a piece given up on where the host ended
  /// it (the body short of its range, the connection closed, a server
  /// error) below the size the host gave for the file — with the stream's
  /// address and the byte (see [isCut]); playback's streams only. The
  /// player hands over to another host at the same quality, rather than
  /// taking the stall behind the cut for a slow host (user 2026-10-19, 15A).
  static void Function(Uri upstream, int at)? onCut;

  /// Whether a piece given up on at byte [at] of a file of [size] bytes is
  /// a copy cut short: some of the tries that brought nothing were ended by
  /// the host ([shortEnds]), not timed out, and the file goes on past it.
  /// Timeouts alone are a slow host (audit F27).
  @visibleForTesting
  static bool isCut({
    required int shortEnds,
    required int at,
    required int? size,
  }) => shortEnds > 0 && size != null && at < size;

  /// Pieces kept on disk (see the library's doc); none when null.
  PieceStore? store;

  /// Bytes answered from [store] and from the network, all streams: for the
  /// self-test.
  var bytesFromStore = 0;
  var bytesFromNetwork = 0;

  /// How a connection upstream goes (`DIRECT` / `PROXY host:port`), as
  /// the app's own requests do: a download through this went round the
  /// 设置代理 setting (audit 2026-10-19). Unset, the environment's.
  static String Function(Uri uri)? proxyFor;

  HttpServer? _server;
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15)
    ..autoUncompress = false
    ..findProxy = (uri) =>
        proxyFor?.call(uri) ?? HttpClient.findProxyFromEnvironment(uri);

  final _byId = <String, _Remote>{};

  /// By URL and `keep`: a download's wrap (not kept) took playback's remote
  /// (kept), and its pieces went into the store, or the other way round.
  final _idOf = <(String, bool), String>{};

  /// Pieces held, oldest use first, for [cachedBytes].
  final _held = <_Chunk>{};
  var _heldBytes = 0;

  /// Pieces [prefetch] started that the player has not come for yet.
  final _prefetched = <_Remote, _Chunk>{};

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
      (request) =>
          unawaited(_serve(request).catchError((Object _) => _end(request))),
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
        // bilibili's caches known by address only (`<ip>:<port>/upgcxcode/…`):
        // by its path alone, a stream on any named host was sent
        // bilibili's headers
        (uri.path.contains('/upgcxcode/') && _isAddress(host));
  }

  static bool _isAddress(String host) => InternetAddress.tryParse(host) != null;

  /// The loopback URL that stands in for [url]; null while not running.
  /// The upstream's host is in the path, for a log line to name.
  ///
  /// [keep]: what is fetched of it goes into [store] (not for a download).
  String? wrap(String url, {bool keep = true}) {
    final server = _server;
    if (server == null) return null;
    final known = _idOf[(url, keep)];
    // a new URL (a renewal, another host): what the others left half
    // fetched is let go
    if (known == null) _releaseIdle();
    final id = known ?? (_idOf[(url, keep)] = _newId());
    _byId[id] ??= _remote(Uri.parse(url), keep);
    final host = Uri.parse(url).host;
    return 'http://127.0.0.1:${server.port}/$id/$host';
  }

  /// 128 random bits: anything else able to reach 127.0.0.1 could read the
  /// playing stream at `/0/…`, `/1/…`.
  static String _newId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static final _random = Random.secure();

  _Remote _remote(Uri uri, bool keep) {
    final remote = _Remote(uri)..keep = keep;
    if (store case final store?) {
      final key = remote.key = PieceStore.keyOf(uri);
      if (store.meta(key) case final meta?) {
        remote
          ..size = meta.size
          ..contentType = meta.type
          ..checked = _check(remote, store, meta.size);
      }
    }
    return remote;
  }

  /// Asks the upstream the size of [remote] once, before what [store]
  /// kept of it is read: another file at the same path (one encoded again)
  /// is another size, and what was kept of the old one must not be played
  /// (a test caught it handed over whole, the network never asked). Without
  /// an answer (offline) what was kept is read.
  Future<void> _check(_Remote remote, PieceStore store, int kept) async {
    try {
      final request = await _client
          .getUrl(debugUpstream?.call(remote.uri) ?? remote.uri)
          .timeout(const Duration(seconds: 5));
      _headers(remote.uri).forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>().catchError((_) {});
      final total = int.tryParse(
        RegExp(r'/(\d+)$')
                .firstMatch(
                  response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
                )
                ?.group(1) ??
            '',
      );
      if (total == null || total == kept) return;
      log?.call(
        '${remote.uri.host}: ${remote.uri.pathSegments.last} is $total '
        'bytes, not $kept: kept pieces dropped',
      );
      remote
        ..size = total
        ..key = null;
      _dropStored(remote);
      await store.sized(PieceStore.keyOf(remote.uri), remote.uri, total, null);
      if (remote.keep) remote.key = PieceStore.keyOf(remote.uri);
    } catch (_) {
      // offline, or the host slow: what was kept stands
    }
  }

  /// The upstream [local] stands in for, or [local] itself.
  String upstreamOf(String local) {
    final uri = Uri.tryParse(local);
    if (uri == null || uri.host != '127.0.0.1' || uri.pathSegments.isEmpty) {
      return local;
    }
    return _byId[uri.pathSegments.first]?.uri.toString() ?? local;
  }

  _Remote? _remoteOf(String local) {
    final uri = Uri.tryParse(local);
    if (uri == null ||
        uri.host != '127.0.0.1' ||
        uri.port != _server?.port ||
        uri.pathSegments.isEmpty) {
      return null;
    }
    return _byId[uri.pathSegments.first];
  }

  /// Starts fetching, for each of [locals] (stand-ins from [wrap]; anything
  /// else is passed by), the piece the player asks for first: the one at
  /// byte 0, where the file's header is, which mpv reads first even when it
  /// opens further on. The same piece a request from the player would
  /// start, so its request is answered from it, not fetched again (6A). It
  /// is kept as any piece is: within [cachedBytes], and in [store].
  ///
  /// What an earlier call started that the player has not come for is let
  /// go: a source replaced.
  void prefetch(Iterable<String> locals) {
    final remotes = <_Remote>{for (final local in locals) ?_remoteOf(local)};
    _cancelPrefetch(except: remotes);
    for (final remote in remotes) {
      // a download's, or one the player reads already
      if (!remote.keep || remote.readers.isNotEmpty) continue;
      if (_prefetched.containsKey(remote)) continue;
      final piece = _pieceAt(remote, 0);
      if (piece.done || piece.fetching || piece.failure != null) continue;
      _prefetched[remote] = piece;
      unawaited(_fetch(remote, piece));
    }
  }

  /// Lets go of what [prefetch] started that the player has not come for:
  /// the player closed.
  void cancelPrefetch() => _cancelPrefetch();

  void _cancelPrefetch({Set<_Remote> except = const {}}) {
    _prefetched.removeWhere((remote, piece) {
      if (except.contains(remote)) return false;
      // a piece already whole stays, as any piece fetched does
      if (remote.readers.isEmpty && piece.fetching && !piece.done) {
        piece.cancel();
      }
      return true;
    });
  }

  @visibleForTesting
  int get prefetching => _prefetched.length;

  // ---------------------------------------------------------------- serving

  /// A request [_serve] threw on (a header sent twice, say) is answered and
  /// closed, not left open with the error in the zone's handler.
  static Future<void> _end(HttpRequest request) async {
    try {
      request.response.statusCode = HttpStatus.badRequest;
    } catch (_) {
      // the answer had begun
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  Future<void> _serve(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    // only as this address itself: a page that rebinds a name of its own to
    // 127.0.0.1 sends that name
    final host = request.headers.value(HttpHeaders.hostHeader);
    final remote = segments.isEmpty || host != '127.0.0.1:${_server?.port}'
        ? null
        : _byId[segments.first];
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
    final ({int from, int? to})? asked;
    try {
      asked = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    } on FormatException {
      // a byte position past what an int holds
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }
    final from = asked?.from ?? 0;

    final reader = _Reader(from);
    remote.readers.add(reader);
    // what was prefetched of it is the player's now: not let go with a
    // source replaced
    _prefetched.remove(remote);
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
    // one): what it read here is no longer wanted, at once. Heard on the
    // socket's input: `done` alone did not complete in 4 s after the client
    // closed, its input's end came 2 ms after (probed)
    var hungUp = false;
    void hangUp() {
      if (hungUp) return;
      hungUp = true;
      reader.gone = true;
      remote.readers.remove(reader);
      reader.waitingOn?.notify();
      _pump(remote);
    }

    socket.listen(
      (_) {},
      onDone: hangUp,
      onError: (Object _) => hangUp(),
      cancelOnError: true,
    );
    unawaited(socket.done.catchError((_) {}).whenComplete(hangUp));
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
      await _fromStore(remote, chunk);
      final kept = chunk.received;
      // tries that bring nothing count; one that brings bytes does not (akam
      // closes connections every few seconds, measured 2026-10-12)
      var fruitless = 0;
      // of those, the ones the host ended (see [isCut])
      var shortEnds = 0;
      var tries = 0;
      while (!chunk.done && !chunk.cancelled && fruitless < 3 && tries < 30) {
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
          shortEnds = 0;
        } else {
          fruitless++;
          if (chunk.lastError?.short ?? false) shortEnds++;
          if (fruitless < 3) {
            await Future<void>.delayed(Duration(milliseconds: 300 * fruitless));
          }
        }
      }
      chunk.attempts = tries;
      if (chunk.cancelled && !chunk.done) {
        // a prefetch let go (see [prefetch]): not given up on, nor a cut —
        // emptied, and fetched anew if the player does come for it
        bytesFromNetwork += chunk.received - (chunk.fromStore ? kept : 0);
        chunk
          ..cancelled = false
          ..lastError = null
          ..release();
        return;
      }
      chunk.cancelled = false;
      if (!chunk.done) {
        chunk.failure = chunk.lastError ?? const _Failure(null, 'gave up');
        final at = chunk.start + chunk.received;
        // closed meanwhile: its own client cut the pieces under way short
        if (running &&
            remote.keep &&
            isCut(shortEnds: shortEnds, at: at, size: remote.size)) {
          log?.call(
            '${remote.uri.host}: ${remote.uri.pathSegments.last} cut at $at '
            'of ${remote.size}',
          );
          onCut?.call(remote.uri, at);
        }
      }
      // what the store gave, unless it was dropped as another file's
      final fromStore = chunk.fromStore ? kept : 0;
      bytesFromNetwork += chunk.received - fromStore;
      // whole and partly from the network: kept for next time
      if (chunk.done &&
          chunk.received > fromStore &&
          remote.keep &&
          remote.key != null) {
        unawaited(
          store?.write(
            remote.key!,
            chunk.start,
            Uint8List.fromList(chunk.bytes(0, chunk.received)),
          ),
        );
      }
    } finally {
      chunk.fetching = false;
      remote.fetching--;
      // given up on, with nobody reading it: its buffer goes (it stays
      // given up on — a reader's own request tries it anew)
      if (chunk.failure != null && chunk.readers == 0) chunk.release();
      chunk.notify();
      _hold(chunk);
      _pump(remote);
    }
  }

  /// What [store] holds of [chunk], put in it; the piece done when that is
  /// all of it.
  Future<void> _fromStore(_Remote remote, _Chunk chunk) async {
    final store = this.store;
    if (store == null || remote.key == null) return;
    // made while the store was still being read (see [_remote]): what it
    // found of this one is checked the same way before it is read; nothing
    // compared it, and another encode's pieces were played (audit 2026-10-19)
    if (remote.checked == null) {
      if (store.meta(remote.key!) case final meta?) {
        if (remote.size == meta.size) {
          // the size the network gave (its own meta, as like as not)
          remote.checked = Future<void>.value();
        } else {
          if (remote.size == null) {
            remote
              ..size = meta.size
              ..contentType ??= meta.type;
          }
          remote.checked = _check(remote, store, meta.size);
        }
      }
    }
    // the size the upstream gives first (see [_check]): as long as its two
    // 5 s timeouts, or a slow answer came after the old file was read
    await remote.checked?.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    final key = remote.key;
    if (key == null) return;
    while (chunk.received < chunk.length) {
      // as it was before the read: one that found another file meanwhile
      // (see [_dropStored]) may have read the old file's bytes
      final epoch = remote.epoch;
      final data = await store.read(
        key,
        chunk.start + chunk.received,
        chunk.length - chunk.received,
      );
      if (data == null || data.isEmpty || remote.epoch != epoch) break;
      // shortened meanwhile (a reader started inside it)
      final take = min(data.length, chunk.length - chunk.received);
      if (take <= 0) break;
      chunk
        ..add(data, take)
        ..fromStore = true
        ..storeEpoch = epoch;
      bytesFromStore += take;
    }
    final size = remote.size;
    if (chunk.received > 0 &&
        (chunk.received >= chunk.length ||
            (size != null && chunk.start + chunk.received >= size))) {
      chunk.finish(chunk.received);
    }
  }

  /// One request for bytes [from]-[to] of [chunk]: null when the piece is
  /// whole, the status (or 0) when it is not.
  Future<int?> _get(_Remote remote, _Chunk chunk, int from, int to) async {
    // the answer's headers came: a socket error after that is the host
    // closing the body, one before it the network (no route, refused)
    var answered = false;
    HttpClientRequest? sent;
    try {
      final (request, response) = await _send(remote, chunk, from, to);
      sent = request;
      answered = true;
      final status = response.statusCode;
      if (status != HttpStatus.partialContent && status != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        // a server error inside the file: akamai answered 502 at the byte a
        // cut copy ended at (2026-10-17)
        chunk.lastError = _Failure(
          status,
          'HTTP $status',
          short: status >= 500,
        );
        // playback's own (a download's are not kept): a download's refusal
        // put the host among the playing part's cut ones
        if (remote.keep) onRefused?.call(remote.uri, status);
        return status;
      }
      if (status == HttpStatus.partialContent) {
        final total = RegExp(r'/(\d+)$')
            .firstMatch(
              response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
            )
            ?.group(1);
        if (total != null && remote.size != int.parse(total)) {
          // a size the store had for it that is not this file's: what it
          // kept is another file's, and goes — on disk, and the pieces
          // filled from it (this one too), which mixed two encodes
          final stale = remote.size != null;
          if (stale) {
            log?.call(
              '${remote.uri.host}: ${remote.uri.pathSegments.last} is '
              '$total bytes, not ${remote.size}: kept pieces dropped',
            );
          }
          remote.size = int.parse(total);
          if (stale) {
            final store = this.store;
            remote.key = null;
            _dropStored(remote);
            if (store != null) {
              final key = PieceStore.keyOf(remote.uri);
              await store.sized(key, remote.uri, remote.size!, null);
              if (remote.keep) remote.key = key;
            }
          }
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
      if (_stale(remote, chunk)) {
        await response.drain<void>().catchError((_) {});
        return 0;
      }
      remote.contentType ??= response.headers.value(
        HttpHeaders.contentTypeHeader,
      );
      if (remote.key case final key? when remote.keep) {
        if (remote.size case final size?) {
          await store?.sized(key, remote.uri, size, remote.contentType);
        }
      }
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
      // found another file's meanwhile (see [_check])
      if (_stale(remote, chunk)) return 0;
      if (chunk.received >= chunk.length ||
          chunk.start + chunk.received >= (remote.size ?? 0)) {
        chunk.finish(chunk.received);
        return null;
      }
      chunk.lastError = _Failure(null, 'ended at ${from + got}', short: true);
      return 0;
    } catch (e) {
      chunk.lastError = _Failure(
        null,
        e.runtimeType.toString(),
        // the host closed it (a cut copy); not a timeout (a slow one), nor
        // a connection that never came (a network drop or handover: three
        // of those read as a cut copy and switched host, audit 2026-10-20)
        short: e is HttpException || (e is SocketException && answered),
      );
      return 0;
    } finally {
      if (sent != null) chunk.requests.remove(sent);
      chunk.notify();
    }
  }

  /// The request for bytes [from]-[to] of [chunk], sent, with its answer's
  /// headers. While [remote]'s size is not known (playback's streams), a
  /// second goes out beside it when it has not answered in [hedgeAfter],
  /// and the first to answer is taken, the other dropped (7C). To the same
  /// URL: this has no other host for it — the player picks those — but a
  /// new connection, which a host's name may send to another server. A
  /// failure before the second is sent is the answer, as without it; after,
  /// the other is waited for.
  Future<(HttpClientRequest, HttpClientResponse)> _send(
    _Remote remote,
    _Chunk chunk,
    int from,
    int to,
  ) {
    if (!remote.keep || remote.size != null) {
      return _attempt(remote, chunk, from, to, () => false);
    }
    final won = Completer<(HttpClientRequest, HttpClientResponse)>();
    var pending = 0;
    Timer? hedge;

    void run() {
      pending++;
      _attempt(remote, chunk, from, to, () => won.isCompleted).then(
        (answer) {
          pending--;
          if (won.isCompleted) {
            // the other answered first
            _drop(chunk, answer.$1, answer.$2);
            return;
          }
          hedge?.cancel();
          // the one still waiting, dropped
          for (final other in chunk.requests.toList()) {
            if (identical(other, answer.$1)) continue;
            chunk.requests.remove(other);
            other.abort();
          }
          won.complete(answer);
        },
        onError: (Object e, StackTrace s) {
          pending--;
          if (won.isCompleted || pending > 0) return;
          hedge?.cancel();
          won.completeError(e, s);
        },
      );
    }

    run();
    hedge = Timer(hedgeAfter, () {
      if (won.isCompleted || chunk.cancelled) return;
      hedges++;
      log?.call(
        '${remote.uri.host}: no answer in ${hedgeAfter.inMilliseconds} ms '
        'at $from: asked again',
      );
      run();
    });
    return won.future;
  }

  /// One request of [_send]'s; [lost] says another answered first, or the
  /// piece was let go, while it was being connected.
  Future<(HttpClientRequest, HttpClientResponse)> _attempt(
    _Remote remote,
    _Chunk chunk,
    int from,
    int to,
    bool Function() lost,
  ) async {
    final request = await _client
        .getUrl(debugUpstream?.call(remote.uri) ?? remote.uri)
        .timeout(const Duration(seconds: 10));
    if (lost() || chunk.cancelled) {
      request.abort();
      throw const HttpException('no longer wanted');
    }
    chunk.requests.add(request);
    try {
      request.followRedirects = true;
      _headers(remote.uri).forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      return (request, response);
    } catch (_) {
      // timed out: not left open, to answer to nobody
      chunk.requests.remove(request);
      request.abort();
      rethrow;
    }
  }

  /// An answer that came second: its connection closed, its body unread.
  static void _drop(
    _Chunk chunk,
    HttpClientRequest request,
    HttpClientResponse response,
  ) {
    chunk.requests.remove(request);
    response.listen(null, onError: (Object _) {}, cancelOnError: true);
    request.abort();
  }

  /// The buffers of pieces nobody is reading or fetching that are not
  /// whole: outside [cachedBytes], which counts whole pieces only, they
  /// were kept for good (the URLs before a renewal, a host left). The
  /// stand-in itself stays: mpv may come back to it (a paused stream).
  void _releaseIdle() {
    for (final remote in _byId.values) {
      if (remote.readers.isNotEmpty || remote.fetching > 0) continue;
      for (final chunk in remote.chunks.values) {
        if (chunk.done || chunk.fetching || chunk.readers > 0) continue;
        chunk.release();
      }
    }
  }

  /// What [remote]'s pieces took from the store, dropped: another file's
  /// (its size changed), fetched anew when read. Not a piece under way:
  /// that one finds out itself (see [_get]).
  void _dropStored(_Remote remote) {
    remote.epoch++;
    for (final chunk in remote.chunks.values) {
      if (!chunk.fromStore || chunk.fetching) continue;
      if (_held.remove(chunk)) _heldBytes -= chunk.received;
      chunk.drop();
    }
  }

  /// Whether [chunk], under way, began with bytes the store had of another
  /// file (see [_dropStored]): emptied, to be fetched from its start.
  bool _stale(_Remote remote, _Chunk chunk) {
    if (!chunk.fromStore || chunk.storeEpoch == remote.epoch) return false;
    chunk
      ..drop()
      ..lastError = const _Failure(null, 'encoded again');
    return true;
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

  /// Its folder in the store, when there is one.
  String? key;

  /// What is fetched of it is kept in the store.
  var keep = true;

  /// The upstream asked its size, before what the store kept is read.
  Future<void>? checked;

  /// Counts the times what the store had of it turned out another file's.
  var epoch = 0;

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
  const _Failure(this.status, this.why, {this.short = false});

  final int? status;
  final String why;

  /// The host ended it — the body short, the connection closed, a server
  /// error — rather than it timing out (see [ParallelFetch.isCut]).
  final bool short;

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

  /// Some of it came from the store (see [ParallelFetch._dropStored]), as
  /// it was at [_Remote.epoch] [storeEpoch].
  var fromStore = false;
  var storeEpoch = 0;
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

  /// The requests upstream under way for it (two while one is hedged).
  final requests = <HttpClientRequest>{};

  /// A prefetch let go (see [ParallelFetch.prefetch]): its fetch stops.
  var cancelled = false;

  void cancel() {
    cancelled = true;
    for (final request in requests.toList()) {
      request.abort();
    }
    requests.clear();
  }

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

  /// Its bytes let go, not whole: fetched from its start if it is read
  /// again. Unlike [drop], a piece given up on stays so (see
  /// [ParallelFetch._pieceAt]).
  void release() {
    _data = null;
    received = 0;
    fromStore = false;
  }

  /// Evicted: asked for again if it is read again.
  void drop() {
    _data = null;
    received = 0;
    fromStore = false;
    done = false;
    attempts = 0;
    failure = null;
    lastError = null;
  }
}
