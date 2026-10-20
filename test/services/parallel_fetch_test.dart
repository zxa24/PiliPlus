import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/parallel_fetch.dart';
import 'package:PiliPlus/services/piece_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parallel fetch against an upstream on the loopback whose behaviour
/// the test sets: the bytes, ranges, and the ways a CDN fails. No network.
void main() {
  final data = Uint8List.fromList(
    List.generate(3 * 1024 * 1024 + 12345, (i) => (i * 31 + (i >> 9)) & 0xff),
  );

  late _Upstream upstream;
  late ParallelFetch fetch;
  late List<(Uri, int)> cuts;

  setUp(() async {
    cuts = [];
    ParallelFetch.onCut = (uri, at) => cuts.add((uri, at));
    upstream = _Upstream(data);
    await upstream.start();
    fetch = ParallelFetch(chunkBytes: 256 * 1024, aheadChunks: 8);
    await fetch.start();
  });

  tearDown(() async {
    ParallelFetch.onCut = null;
    await fetch.close();
    await upstream.close();
  });

  Future<({int status, List<int> body, HttpHeaders headers, bool whole})> get(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      final body = <int>[];
      var whole = true;
      try {
        await for (final b in response) {
          body.addAll(b);
        }
      } catch (_) {
        whole = false;
      }
      return (
        status: response.statusCode,
        body: body,
        headers: response.headers,
        whole: whole,
      );
    } finally {
      client.close(force: true);
    }
  }

  test('the whole stream, byte for byte, from several requests at once', () async {
    upstream.delay = const Duration(milliseconds: 60);
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.status, HttpStatus.partialContent);
    expect(r.body.length, data.length);
    expect(r.body, data);
    expect(r.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${data.length - 1}/${data.length}');
    expect(upstream.mostAtOnce, greaterThanOrEqualTo(3));
    expect(upstream.mostAtOnce, lessThanOrEqualTo(4));
  });

  test('from the middle, as after a seek, and a closed range', () async {
    final local = fetch.wrap(upstream.url)!;
    final r = await get(local, range: 'bytes=1000000-');
    expect(r.body, data.sublist(1000000));
    final part = await get(local, range: 'bytes=300000-300099');
    expect(part.body, data.sublist(300000, 300100));
    expect(part.headers.contentLength, 100);
  });

  test('a piece that breaks off is asked for again from where it stopped', () async {
    upstream.breakOnceAt = {600000, 2000000};
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.body, data);
    expect(r.whole, isTrue);
  });

  test('broken off again and again, each time further on: still whole', () async {
    // akam closed connections every few seconds (2026-10-12)
    upstream.breakOnceAt = {300000, 350000, 400000, 450000, 500000};
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.body, data);
  });

  test('a seek starts where it asks, not at the piece boundary before', () async {
    await get(fetch.wrap(upstream.url)!, range: 'bytes=300000-300099');
    expect(upstream.ranges.first, startsWith('bytes=300000-'));
  });

  test('a seek is not queued behind the pieces of where playback was', () async {
    upstream.delay = const Duration(seconds: 2);
    final local = fetch.wrap(upstream.url)!;
    final client = HttpClient();
    // a reader at the start: four slow pieces under way
    final playing = await client.getUrl(Uri.parse(local));
    playing.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final playingAnswer = playing.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final watch = Stopwatch()..start();
    final seek = await get(local, range: 'bytes=2500000-2500999');
    expect(seek.body, data.sublist(2500000, 2501000));
    // its own request at once: one delay, not one after the others
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 3500)));
    (await playingAnswer).listen((_) {}, onError: (_) {});
    client.close(force: true);
  });

  test('inside a piece still coming in: its own piece, at once', () async {
    // the bytes before it come at the origin's pace (17 s, 2026-10-12)
    upstream.bytesPerSecond = 100 * 1024;
    final local = fetch.wrap(upstream.url)!;
    final client = HttpClient();
    final playing = await client.getUrl(Uri.parse(local));
    playing.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final playingAnswer = playing.close();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final watch = Stopwatch()..start();
    final seek = await get(local, range: 'bytes=200000-200999');
    expect(seek.body, data.sublist(200000, 201000));
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 1200)));
    expect(upstream.ranges, contains(startsWith('bytes=200000-')));
    (await playingAnswer).listen((_) {}, onError: (_) {});
    client.close(force: true);
  });

  test('a copy that ends early ends the answer at the same byte', () async {
    // a cut copy on a CDN (akam, 2026-10-12): the player's own recovery
    // reads "Stream ends prematurely at N"
    upstream.cutAt = 1500000;
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.body.length, 1500000);
    expect(r.body, data.sublist(0, 1500000));
    expect(r.whole, isFalse, reason: 'the content length promised more');
    // and the player is told the copy is cut there (15A): the pieces past
    // it too, each where it starts
    expect(cuts, isNotEmpty);
    expect(cuts.map((c) => c.$2).reduce(min), 1500000);
    expect(cuts.every((c) => c.$1.path == Uri.parse(upstream.url).path), isTrue);
  });

  test('connections refused (the network gone): not a cut copy', () async {
    // a network drop or handover: three refused connections read as a cut
    // and switched host (audit 2026-10-20)
    final local = fetch.wrap(upstream.url)!;
    final first = await get(local, range: 'bytes=0-99');
    expect(first.body, data.sublist(0, 100));
    // the pieces fetched ahead of it whole first: one closed mid-body is
    // a cut (the host ended it), not what this asks
    while (upstream._atOnce > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await upstream.close();
    await get(
      local,
      range: 'bytes=2000000-2000099',
    ).timeout(const Duration(seconds: 30));
    expect(cuts, isEmpty);
  });

  test('cut: the host ended it below the size; timeouts alone are slow', () {
    expect(ParallelFetch.isCut(shortEnds: 1, at: 100, size: 1000), isTrue);
    expect(ParallelFetch.isCut(shortEnds: 0, at: 100, size: 1000), isFalse);
    // at the end of the file: nothing more to have
    expect(ParallelFetch.isCut(shortEnds: 3, at: 1000, size: 1000), isFalse);
    // no size known: nothing to measure it by
    expect(ParallelFetch.isCut(shortEnds: 3, at: 100, size: null), isFalse);
  });

  test('a refusal is passed on as it was: expired URLs answer 403', () async {
    upstream.status = HttpStatus.forbidden;
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.status, HttpStatus.forbidden);
    // a URL refused, not a copy cut short
    expect(cuts, isEmpty);
  });

  test('HEAD: the size, no body', () async {
    final r = await get(
      fetch.wrap(upstream.url)!,
      range: 'bytes=0-',
      method: 'HEAD',
    );
    expect(r.status, HttpStatus.partialContent);
    expect(r.body, isEmpty);
    expect(r.headers.value(HttpHeaders.contentRangeHeader), endsWith('/${data.length}'));
  });

  test('past the end: 416', () async {
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=${data.length}-');
    expect(r.status, HttpStatus.requestedRangeNotSatisfiable);
  });

  test('what is kept stays within its bound', () async {
    await fetch.close();
    fetch = ParallelFetch(
      chunkBytes: 256 * 1024,
      aheadChunks: 4,
      cachedBytes: 1024 * 1024,
    );
    await fetch.start();
    final r = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
    expect(r.body, data);
    expect(fetch.heldBytes, lessThanOrEqualTo(1024 * 1024 + 256 * 1024));
  });

  test('the same URL, the same stand-in; the upstream read back', () {
    final a = fetch.wrap(upstream.url)!;
    expect(fetch.wrap(upstream.url), a);
    expect(fetch.upstreamOf(a), upstream.url);
    expect(fetch.upstreamOf('https://x.example/y'), 'https://x.example/y');
    expect(Uri.parse(a).pathSegments.last, '127.0.0.1');
  });

  test("bilibili's stream hosts only", () {
    expect(
      ParallelFetch.isBilibili(
        'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1/2/3-1-30080.m4s?e=x',
      ),
      isTrue,
    );
    expect(
      ParallelFetch.isBilibili('https://upos-hz-mirrorakam.akamaized.net/upgcxcode/x.m4s'),
      isTrue,
    );
    expect(
      ParallelFetch.isBilibili('https://rr1---sn-x.googlevideo.com/videoplayback?id=1'),
      isFalse,
    );
    expect(ParallelFetch.isBilibili('C:/videos/a.mp4'), isFalse);
  });
  group('pieces kept on disk', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pieces');
    });

    tearDown(() async {
      await dir.delete(recursive: true).catchError((_) => dir);
    });

    Future<PieceStore> store() async {
      final store = PieceStore(dir, maxBytes: 64 << 20);
      await store.open();
      return store;
    }

    test('played again, from another host, in another session: only the '
        'size asked upstream', () async {
      fetch.store = await store();
      final first = await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
      expect(first.body, data);
      // the writes are not awaited by the answer
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fetch.store!.bytes, data.length);

      // a new session (the app started again), the same file on another
      // host: same path, another address
      final other = _Upstream(data);
      await other.start();
      final again = ParallelFetch(chunkBytes: 256 * 1024, aheadChunks: 8)
        ..store = await store();
      await again.start();
      try {
        final r = await get(again.wrap(other.url)!, range: 'bytes=0-');
        expect(r.body, data);
        // the size asked once, nothing else
        expect(other.ranges, ['bytes=0-0']);
        expect(again.bytesFromStore, data.length);
        final part = await get(
          again.wrap(other.url)!,
          range: 'bytes=1500000-1500099',
        );
        expect(part.body, data.sublist(1500000, 1500100));
      } finally {
        await again.close();
        await other.close();
      }
    });

    test('part kept, part not: the rest from the network', () async {
      fetch.store = await store();
      final local = fetch.wrap(upstream.url)!;
      await get(local, range: 'bytes=0-999999');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final again = ParallelFetch(chunkBytes: 256 * 1024, aheadChunks: 8)
        ..store = await store();
      await again.start();
      try {
        upstream.ranges.clear();
        final r = await get(again.wrap(upstream.url)!, range: 'bytes=0-');
        expect(r.body, data);
        expect(again.bytesFromStore, greaterThanOrEqualTo(1000000));
        expect(again.bytesFromNetwork, lessThan(data.length - 900000));
      } finally {
        await again.close();
      }
    });

    test('what a download reads is not kept', () async {
      fetch.store = await store();
      final r = await get(
        fetch.wrap(upstream.url, keep: false)!,
        range: 'bytes=0-',
      );
      expect(r.body, data);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fetch.store!.bytes, 0);
    });

    test('another size at the same path: what was kept goes', () async {
      fetch.store = await store();
      await get(fetch.wrap(upstream.url)!, range: 'bytes=0-');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final changed = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 7) & 0xff),
      );
      final other = _Upstream(changed);
      await other.start();
      final again = ParallelFetch(chunkBytes: 256 * 1024, aheadChunks: 8)
        ..store = await store();
      await again.start();
      try {
        // the first piece may come from what was kept, before the answer
        // says the size: asked again, the rest is the new file's
        final r = await get(again.wrap(other.url)!, range: 'bytes=600000-');
        expect(r.body, changed.sublist(600000));
      } finally {
        await again.close();
        await other.close();
      }
    });
  });

}

/// A CDN in miniature: ranges, a delay per request, and its failures.
class _Upstream {
  _Upstream(this.data);

  final Uint8List data;
  late HttpServer _server;

  Duration delay = Duration.zero;

  /// Each of these bytes breaks the first request that reaches it.
  Set<int> breakOnceAt = {};

  /// The copy ends here, and asked for past it answers 503.
  int? cutAt;

  /// Every request answered with this.
  int? status;

  /// Each answer trickles out no faster than this.
  int? bytesPerSecond;

  /// The Range of every request, in order.
  final ranges = <String>[];

  var _atOnce = 0;
  var mostAtOnce = 0;

  String get url =>
      'http://127.0.0.1:${_server.port}/upgcxcode/1/2/3-1-30080.m4s?e=x';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    _atOnce++;
    mostAtOnce = max(mostAtOnce, _atOnce);
    try {
      await Future<void>.delayed(delay);
      final response = request.response;
      if (status case final s?) {
        response.statusCode = s;
        await response.close();
        return;
      }
      ranges.add(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(
        request.headers.value(HttpHeaders.rangeHeader) ?? '',
      );
      final from = m == null ? 0 : int.parse(m.group(1)!);
      final to = m == null || m.group(2)!.isEmpty
          ? data.length - 1
          : min(int.parse(m.group(2)!), data.length - 1);
      final cut = cutAt;
      if (cut != null && from >= cut) {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = to - from + 1
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/${data.length}')
        ..headers.contentType = ContentType('video', 'mp4');
      final socket = await response.detachSocket(writeHeaders: true);
      var end = to + 1;
      if (cut != null && cut < end) end = cut;
      for (final b in breakOnceAt.toList()) {
        if (b > from && b < end) {
          breakOnceAt.remove(b);
          end = b;
          break;
        }
      }
      try {
        if (bytesPerSecond case final rate?) {
          const step = 8192;
          for (var at = from; at < end; at += step) {
            socket.add(Uint8List.sublistView(data, at, min(at + step, end)));
            await socket.flush();
            await Future<void>.delayed(
              Duration(microseconds: step * 1000000 ~/ rate),
            );
          }
        } else {
          socket.add(Uint8List.sublistView(data, from, end));
          await socket.flush();
        }
      } catch (_) {
        // the fetch hung up first (a HEAD, a close)
      }
      socket.destroy();
    } catch (_) {
      // the fetch closed first (a test's end)
    } finally {
      _atOnce--;
    }
  }
}
