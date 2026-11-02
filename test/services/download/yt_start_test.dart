// LibrePili: a YouTube download's start through the service (stage-2 plan
// §2.3, §3.3, §3.4; the service-level part of AC3). The resolve picks the
// pair (the shared router built at each start, so a source mode set after
// launch holds) and changes nothing of the entry; the service makes the
// plan's stream folder; the pair transfer writes stream.json (the
// adapter's writeStreamKey does not); what the resolve found is written
// into the record once the transfer is taken. Streams already whole: no
// resolve, no cover. A start paused during the cover leaves the record.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  YtDownloadEntry record(Directory root) => ytEntry(root, maxHeight: 1080);

  /// The current stream folder's identities as `stream.json` would hold
  /// them, the video's [videoLmt] its version.
  void plantStreams(
    Directory root, {
    int? video,
    int? audio,
    String videoLmt = 'v1',
  }) {
    final dir = Directory(
      path.join(root.path, 'yt_$ytId', 'main', '137-140'),
    )..createSync(recursive: true);
    final v = h.server.bodies['video']!;
    final a = h.server.bodies['audio']!;
    File(path.join(dir.path, 'video.m4s')).writeAsBytesSync(
      v.sublist(0, video ?? v.length),
    );
    File(path.join(dir.path, 'audio.m4s')).writeAsBytesSync(
      a.sublist(0, audio ?? a.length),
    );
    File(path.join(dir.path, 'stream.json')).writeAsStringSync(
      PairFixture.jsonText(
        YtStreamId(itag: 137, bytes: v.length, lmt: videoLmt),
        YtStreamId(itag: 140, isDefault: true, bytes: a.length, lmt: 'a1'),
      ),
    );
  }

  /// A record whose stream folder is `137-140`.
  YtDownloadEntry withTag(Directory root) =>
      record(root)..streamTag = '137-140';

  test(
    'a first start: the plan\'s folder, both streams, the merge, the record',
    () async {
      await h.start(records: [record]);
      final e = h.entry();
      final foldersAtMerge = <String>[];
      h.mergeGate = (entry) async {
        foldersAtMerge.addAll(
          Directory(entry.entryDirPath).listSync().whereType<Directory>().map(
            (d) => path.basename(d.path),
          ),
        );
      };
      await h.run(e);
      expect(foldersAtMerge, ['137-140']);
      expect(e.streamTag, '137-140');
      expect(e.streamSource, 'direct');
      expect(e.qualityLabel, '1080p');
      expect(e.isCompleted, isTrue);
      expect(e.mergedPath, isNotNull);
      expect(
        File(e.mergedPath!).readAsBytesSync(),
        [...h.server.bodies['video']!, ...h.server.bodies['audio']!],
      );
      expect(h.remuxed.single.map(path.basename), ['video.m4s', 'audio.m4s']);
      final saved = await h.record(e);
      expect(saved['stream_tag'], '137-140');
      expect(saved['stream_source'], 'direct');
      expect(saved['is_completed'], isTrue);
      expect(saved['extras_pending'], isTrue);
      expect(h.log, contains(contains('yt:$ytId: video start from 0')));
      expect(h.log, contains(contains('yt:$ytId: audio start from 0')));
      expect(h.routers.first, (
        mode: YtSourceMode.auto,
        own: false,
        shared: true,
      ));
    },
  );

  test('the merge is not in the start\'s lock', () async {
    await h.start(records: [record]);
    final e = h.entry();
    bool? locked;
    h.mergeGate = (_) async => locked = h.service.lockedForTest;
    await h.run(e);
    expect(locked, isFalse);
  });

  test(
    'the source mode set after launch: the router is built with it',
    () async {
      await h.start(records: [record]);
      YtSourceStore.debugMode = YtSourceMode.fallbackOnly;
      final e = h.entry();
      await h.run(e);
      expect(h.routers.first.mode, YtSourceMode.fallbackOnly);
      expect(e.streamSource, 'invidious');
      expect(h.direct.detailCalls, 0);
    },
  );

  test(
    'both streams already whole: no resolve, no cover, merged',
    () async {
      await h.start(
        records: [withTag],
        before: plantStreams,
      );
      final e = h.entry();
      await h.run(e);
      expect(h.routers, isEmpty);
      expect(h.direct.detailCalls, 0);
      expect(h.server.requests, isEmpty);
      expect(h.log, contains(contains('video already complete')));
      expect(h.log, contains(contains('audio already complete')));
      expect(h.remuxed, hasLength(1));
    },
  );

  test(
    'a resume: the first progress is each stream\'s own (p4#4)',
    () async {
      await h.start(
        records: [withTag],
        before: (root) => plantStreams(root, video: 200000, audio: 50000),
      );
      final e = h.entry();
      // a sum of both streams a run before would have left
      e.progress.video(999999, 999999);
      final atFirstRequest = <(int, int, int, int)>[];
      YtPairTransfer.selfTestOnRequest = (stream, range) {
        if (atFirstRequest.isEmpty) {
          final p = e.progress;
          atFirstRequest.add((
            p.videoReceived,
            p.videoTotal,
            p.audioReceived,
            p.audioTotal,
          ));
        }
      };
      await h.run(e);
      expect(atFirstRequest.single, (
        200000,
        h.server.bodies['video']!.length,
        50000,
        h.server.bodies['audio']!.length,
      ));
      expect(h.log, contains(contains('video resume at 200000 (overlap ok)')));
    },
  );

  test(
    'stream.json is the transfer\'s: another lmt → from 0 (lmt)',
    () async {
      await h.start(
        records: [withTag],
        before: (root) => plantStreams(root, video: 200000, videoLmt: 'v0'),
      );
      final e = h.entry();
      await h.run(e);
      expect(
        h.log,
        contains(contains('yt:$ytId: video restarted from 0 (lmt)')),
      );
    },
  );

  test(
    'paused during the resolve: the record not changed, nothing saved',
    () async {
      await h.start(records: [record]);
      final e = h.entry();
      final held = Completer<void>();
      final release = Completer<void>();
      h.direct.holdStreams = () {
        if (!held.isCompleted) held.complete();
        return release.future;
      };
      unawaited(h.service.startDownload(e));
      await held.future;
      await h.service.cancelDownload(isDelete: false);
      await h.service.saveEntryForTest(e);
      final before = await h.record(e);
      release.complete();
      await until(() => h.direct.streamCalls == 1);
      await settle(100);
      expect(e.streamTag, isNull);
      expect(await h.record(e), before);
      expect(before['stream_tag'], isNull);
      expect(h.server.requests, isEmpty);
    },
  );

  test(
    'paused during the cover: the entry folder and its record stay',
    () async {
      await h.start(records: [record]);
      final e = h.entry();
      final held = Completer<void>();
      final release = Completer<File?>();
      YtDownloadPlatform.coverCacheForTest = (_) {
        if (!held.isCompleted) held.complete();
        return release.future;
      };
      addTearDown(() => YtDownloadPlatform.coverCacheForTest = null);
      unawaited(h.service.startDownload(e));
      await held.future;
      await h.service.cancelDownload(isDelete: false);
      release.complete(null);
      await settle(100);
      expect(Directory(e.entryDirPath).existsSync(), isTrue);
      expect(
        File(
          path.join(e.entryDirPath, YtDownloadEntry.recordFile),
        ).existsSync(),
        isTrue,
      );
      expect(e.status, DownloadStatus.pause);
    },
  );

  test('a resolve that finds nothing to download: failNoFormat', () async {
    await h.start(
      records: [record],
      formats: [
        ytVideoFormat(248, codec: 'vp9'),
        ytAudioFormat(251).map(
          (k, v) =>
              MapEntry(k, k == 'mimeType' ? 'audio/webm; codecs="opus"' : v),
        ),
      ],
    );
    final e = h.entry();
    await h.run(e, status: DownloadStatus.failNoFormat);
    expect(h.service.lastError, 'contentUnavailable<no-playable-pair>');
  });

  test(
    "a DRC stream's bytes on disk: the pin asks for the DRC 140 (review 2d)",
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140.drc'],
        formats: [
          ytVideoFormat(137, bytes: 300 * 1024 + 5),
          ytAudioFormat(140, bytes: 120 * 1024 + 3),
          ytAudioFormat(140, bytes: 120 * 1024 + 3, drc: true),
        ],
        before: (root) {
          final dir = Directory(
            path.join(root.path, 'yt_$ytId', 'main', '137-140.drc'),
          )..createSync(recursive: true);
          File(path.join(dir.path, 'audio.m4s')).writeAsBytesSync([1, 2, 3]);
          File(path.join(dir.path, 'stream.json')).writeAsStringSync(
            PairFixture.jsonText(
              const YtStreamId(itag: 137, bytes: 300 * 1024 + 5, lmt: 'v1'),
              const YtStreamId(
                itag: 140,
                isDefault: true,
                drc: true,
                bytes: 120 * 1024 + 3,
                lmt: 'a1',
              ),
            ),
          );
        },
      );
      final e = h.entry();
      await h.run(e);
      expect(h.direct.preferences.first.pin?.drc, isTrue);
      expect(e.streamTag, '137-140.drc');
    },
  );

  test(
    "a transfer's failure in lastError: no stream URL, no query (review 2d)",
    () async {
      await h.start(
        records: [record],
        formats: [
          {
            ...ytVideoFormat(137, bytes: 300 * 1024 + 5),
            'url':
                '${FakeStreamServer.url('video')}?sig=SECRET2&ip=203.0.113.7',
          },
          ytAudioFormat(140, bytes: 120 * 1024 + 3),
        ],
      );
      // every range of the video dropped: the transfer's budget spent
      h.server.script = (s, n, _) =>
          s == 'video' ? const FakeAnswer.range(cutAfter: 0) : null;
      final e = h.entry();
      await h.run(
        e,
        any: {DownloadStatus.failDownload, DownloadStatus.retryWait},
      );
      final error = h.service.lastError!;
      expect(error, contains('HttpException'));
      expect(error, isNot(contains('SECRET2')));
      expect(error, isNot(contains('203.0.113.7')));
    },
  );

  test('a record that differs from the plan is saved once taken', () async {
    await h.start(records: [record]);
    final e = h.entry();
    final saved = <Map<String, dynamic>>[];
    h.mergeGate = (entry) async => saved.add(await h.record(e));
    await h.run(e);
    expect(saved.single['stream_tag'], '137-140');
    expect(saved.single['quality_label'], '1080p');
    expect(jsonEncode(saved.single['stream_source']), '"direct"');
  });
}
