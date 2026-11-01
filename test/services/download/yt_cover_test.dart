// LibrePili: a YouTube download's cover (stage-2 plan §3.6; AC8): fetched
// over a bare HttpClient with every hop checked, never through the app's
// Dio (whose interceptors add bilibili's headers and cookies); only from a
// YouTube thumbnail host; written through `cover.jpg.part`; a failure
// does not stop the video.
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'yt_download_test_support.dart';

/// Counts what goes through the app's Dio; answers nothing.
class _Dio implements HttpClientAdapter {
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri.toString());
    return ResponseBody.fromBytes([9, 9], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final dio = _Dio();
  late Directory root;
  late YtDownloadPlatform platform;
  late FakeYtHttp http;

  setUpAll(() {
    Request.dio = Dio()..httpClientAdapter = dio;
    // through a "proxy": the hop check looks at the name only, no lookup
    YtStreamRelay.proxyFor = (_) => 'PROXY 127.0.0.1:9';
  });
  tearDownAll(() => YtStreamRelay.proxyFor = null);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yt-cover-');
    // the adapter does not use its handle for the cover
    platform = YtDownloadPlatform(_NoHost());
    http = FakeYtHttp();
    YtDownloadPlatform.httpClientForTest = () => http;
    dio.asked.clear();
  });
  tearDown(() async {
    YtDownloadPlatform.httpClientForTest = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  File coverOf(String dir) => File(path.join(dir, 'cover.jpg'));

  test('fetched over its own client, not the app\'s Dio', () async {
    final e = ytEntry(root);
    Directory(e.entryDirPath).createSync(recursive: true);
    expect(await platform.cover(e), isTrue);
    expect(coverOf(e.entryDirPath).readAsStringSync(), 'jpeg of ${e.cover}');
    expect(File('${coverOf(e.entryDirPath).path}.part').existsSync(), isFalse);
    expect(http.requests, [('GET', Uri.parse(e.cover))]);
    expect(http.closed, isTrue);
    expect(dio.asked, isEmpty);
  });

  test('already there: nothing fetched', () async {
    final e = ytEntry(root);
    Directory(e.entryDirPath).createSync(recursive: true);
    coverOf(e.entryDirPath).writeAsStringSync('mine');
    expect(await platform.cover(e), isTrue);
    expect(coverOf(e.entryDirPath).readAsStringSync(), 'mine');
    expect(http.requests, isEmpty);
  });

  test('not a YouTube thumbnail host: refused, nothing asked', () async {
    for (final url in [
      'https://i0.hdslb.com/bfs/archive/x.jpg',
      'http://i.ytimg.com/vi/$ytId/hqdefault.jpg',
      'https://ytimg.com.example.org/x.jpg',
      '',
    ]) {
      final odd = _withCover(ytEntry(root), url);
      Directory(odd.entryDirPath).createSync(recursive: true);
      expect(await platform.cover(odd), isFalse, reason: url);
      expect(coverOf(odd.entryDirPath).existsSync(), isFalse, reason: url);
    }
    expect(http.requests, isEmpty);
    expect(dio.asked, isEmpty);
  });

  test('a failed fetch: false, no file left', () async {
    http.answer = (_, _) => (status: 404, body: const []);
    final e = ytEntry(root);
    Directory(e.entryDirPath).createSync(recursive: true);
    expect(await platform.cover(e), isFalse);
    expect(coverOf(e.entryDirPath).existsSync(), isFalse);
    expect(dio.asked, isEmpty);
  });

  // review 2bc: the host rule on every hop, the cover's bounds, whole files
  group('redirects, bounds and whole files', () {
    tearDown(() {
      YtDownloadPlatform.coverMaxBytes = 4 << 20;
      YtDownloadPlatform.coverDeadline = const Duration(seconds: 60);
      YtDownloadPlatform.coverCacheForTest = null;
    });

    YtDownloadEntry entryIn() {
      final e = ytEntry(root);
      Directory(e.entryDirPath).createSync(recursive: true);
      return e;
    }

    File partOf(YtDownloadEntry e) =>
        File('${coverOf(e.entryDirPath).path}.part');

    test(
      'a redirect off ytimg.com: refused before it is opened, no cover',
      () async {
        final e = entryIn();
        final away = Uri.parse('https://images.example.org/x.jpg');
        http.redirects[Uri.parse(e.cover)] = away;
        expect(await platform.cover(e), isFalse);
        expect(http.requests.map((r) => r.$2), [Uri.parse(e.cover)]);
        expect(coverOf(e.entryDirPath).existsSync(), isFalse);
        expect(partOf(e).existsSync(), isFalse);
      },
    );

    test('a redirect within ytimg.com: followed', () async {
      final e = entryIn();
      final next = Uri.parse('https://i9.ytimg.com/vi/$ytId/hqdefault.jpg');
      http.redirects[Uri.parse(e.cover)] = next;
      expect(await platform.cover(e), isTrue);
      expect(coverOf(e.entryDirPath).readAsStringSync(), 'jpeg of $next');
    });

    test('a body over the byte cap: no cover, no .part', () async {
      YtDownloadPlatform.coverMaxBytes = 10;
      http.answer = (_, _) => (status: 200, body: List.filled(64, 1));
      final e = entryIn();
      expect(await platform.cover(e), isFalse);
      expect(coverOf(e.entryDirPath).existsSync(), isFalse);
      expect(partOf(e).existsSync(), isFalse);
    });

    Stream<List<int>> endless(Uri _) =>
        Stream.periodic(const Duration(milliseconds: 5), (_) => [1, 2, 3]);

    test(
      'a body that never ends: let go at the deadline, no cover, no .part',
      () async {
        YtDownloadPlatform.coverDeadline = const Duration(milliseconds: 300);
        http.stream = endless;
        final e = entryIn();
        final watch = Stopwatch()..start();
        expect(await platform.cover(e), isFalse);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(http.closed, isTrue);
        expect(coverOf(e.entryDirPath).existsSync(), isFalse);
        expect(partOf(e).existsSync(), isFalse);
      },
    );

    test(
      'a failed answer whose body never ends: let go at the deadline',
      () async {
        YtDownloadPlatform.coverDeadline = const Duration(milliseconds: 300);
        http
          ..answer = ((_, _) => (status: 404, body: const []))
          ..stream = endless;
        final e = entryIn();
        final watch = Stopwatch()..start();
        expect(await platform.cover(e), isFalse);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(coverOf(e.entryDirPath).existsSync(), isFalse);
      },
    );

    test(
      'from the image cache: through .part, whole, nothing fetched',
      () async {
        final cached = File(path.join(root.path, 'cached.jpg'))
          ..writeAsBytesSync([7, 7, 7]);
        YtDownloadPlatform.coverCacheForTest = (_) async => cached;
        final e = entryIn();
        expect(await platform.cover(e), isTrue);
        expect(coverOf(e.entryDirPath).readAsBytesSync(), [7, 7, 7]);
        expect(partOf(e).existsSync(), isFalse);
        expect(http.requests, isEmpty);
      },
    );

    test('a cache copy that fails: no cover.jpg, no .part', () async {
      // listed by the cache, gone from the disk when copied
      YtDownloadPlatform.coverCacheForTest = (_) async =>
          File(path.join(root.path, 'gone.jpg'));
      final e = entryIn();
      expect(await platform.cover(e), isFalse);
      expect(coverOf(e.entryDirPath).existsSync(), isFalse);
      expect(partOf(e).existsSync(), isFalse);
    });

    test(
      'a .part an earlier run left: removed when this one fails too',
      () async {
        http.answer = (_, _) => (status: 404, body: const []);
        final e = entryIn();
        partOf(e).writeAsBytesSync([0, 0]);
        expect(await platform.cover(e), isFalse);
        expect(partOf(e).existsSync(), isFalse);
      },
    );
  });
}

/// The adapter's handle: not used by the cover.
class _NoHost extends Fake implements DownloadHost {}

/// [e] with another cover (the field is final on the entry).
YtDownloadEntry _withCover(YtDownloadEntry e, String cover) =>
    YtDownloadEntry.fromJson(e.toJson()..['cover'] = cover)
      ..pageDirPath = e.pageDirPath
      ..entryDirPath = e.entryDirPath;
