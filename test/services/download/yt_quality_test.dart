// LibrePili: the quality a YouTube download was asked for (stage-2 plan
// §3.3, §4.1–§4.3; AC-Q's unit part, numbered as AC-Q). The pick keeps to
// the tier (and to the pair whose bytes are on disk); when the source
// does not have it, the download's own router asks the other source —
// with its own health table, not the direct source in a cooldown; when
// neither has it: failQuality, three retries, then the 720p switch, which
// restarts the download at tier 720 in a new stream folder. Never a quiet
// step down.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

const _otherId = 'jNQXAC9IVRw';

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  /// Tier 1080's bytes on disk in `137-140`, half of the video.
  void plant137(Directory root) {
    final dir = Directory(path.join(root.path, 'yt_$ytId', 'main', '137-140'))
      ..createSync(recursive: true);
    File(path.join(dir.path, 'video.m4s')).writeAsBytesSync(
      List.filled(150000, 7),
    );
    File(path.join(dir.path, 'stream.json')).writeAsStringSync(
      PairFixture.jsonText(
        const YtStreamId(itag: 137, bytes: 300000, lmt: 'v1'),
        const YtStreamId(itag: 140, isDefault: true, bytes: 1000, lmt: 'a1'),
      ),
    );
  }

  List<Map<String, dynamic>> without137() => [
    ytVideoFormat(
      399,
      codec: 'av01.0.08M.08',
      bytes: h.server.bodies['video']!.length,
    ),
    ytVideoFormat(
      136,
      width: 1280,
      height: 720,
      label: '720p60',
      bytes: h.server.bodies['video']!.length,
    ),
    ytAudioFormat(140, bytes: h.server.bodies['audio']!.length),
  ];

  Future<void> start({
    bool pinned = true,
    int maxHeight = 1080,
    bool two = false,
  }) => h.start(
    records: [
      (root) =>
          ytEntry(root, maxHeight: maxHeight, stamp: 2)
            ..streamTag = pinned ? '137-140' : null,
      if (two) (root) => ytEntry(root, id: _otherId, maxHeight: 1080, stamp: 1),
    ],
    before: pinned ? plant137 : null,
  );

  Iterable<String> transferLines() =>
      h.log.where((l) => l.contains('yt:$ytId: video'));

  test(
    '① the pinned 137 on neither source: three retries, failQuality, '
    'no transfer, the next one',
    () async {
      await start(two: true);
      h.direct.formats = without137();
      h.invidious.formats = without137();
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await until(() => e.gaveUp, reason: 'its retries spent');
      expect(e.status, DownloadStatus.failQuality);
      // what was not on offer: the pair whose bytes are on disk (review 2e)
      expect(h.service.lastError, startsWith('the pair on disk ('));
      expect(
        h.log.where((l) => l.contains('yt:$ytId') && l.contains('again in')),
        hasLength(3),
      );
      expect(transferLines(), isEmpty);
      // its pin and tier asked of the other source each time
      expect(h.invidious.streamCalls, 4);
      expect(h.direct.preferences.first.pin?.videoItag, 137);
      expect(h.direct.preferences.first.exactHeight, 1080);
      await h.untilStatus(h.entry(_otherId));
    },
  );

  test(
    '⑤ a new download of 1080, both sources only 720: failQuality, '
    'not a quiet 720',
    () async {
      await start(pinned: false);
      h.direct.formats = [without137()[1], without137()[2]];
      h.invidious.formats = h.direct.formats;
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await until(() => e.gaveUp, reason: 'its retries spent');
      expect(e.status, DownloadStatus.failQuality);
      expect(e.streamTag, isNull);
      expect(h.service.lastError, startsWith('tier 1080 not offered'));
      expect(transferLines(), isEmpty);
    },
  );

  test(
    '② not on the current source, on the other: asked through its own '
    'router, the shared health untouched',
    () async {
      await start();
      h.direct.formats = without137();
      final e = h.entry();
      await h.run(e);
      expect(e.streamSource, 'invidious');
      expect(e.streamTag, '137-140');
      expect(h.routers.last, (
        mode: YtSourceMode.fallbackOnly,
        own: true,
        shared: false,
      ));
      expect(YtSourceRouter.sharedHealth.containsKey('invidious'), isFalse);
      expect(h.playbackFailed, isEmpty);
    },
  );

  test(
    'one source only (--yt-source direct): the other source not asked',
    () async {
      await start();
      YtSourceStore.debugMode = YtSourceMode.directOnly;
      h.direct.formats = without137();
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await h.untilStatus(
        e,
        any: {DownloadStatus.retryWait, DownloadStatus.failQuality},
      );
      expect(h.invidious.streamCalls, 0);
      expect(h.invidious.detailCalls, 0);
      expect(h.routers.where((r) => r.own), isEmpty);
    },
  );

  test(
    '② the other source is the direct one, in a cooldown: not asked',
    () async {
      await start();
      YtSourceRouter.sharedHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = DateTime.now().add(const Duration(minutes: 5));
      h.invidious.formats = without137();
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await h.untilStatus(
        e,
        any: {DownloadStatus.retryWait, DownloadStatus.failQuality},
      );
      expect(h.direct.detailCalls, 0);
      expect(h.direct.streamCalls, 0);
      expect(h.invidious.streamCalls, greaterThan(0));
    },
  );

  test(
    '④ the 720p switch: tier 720 in a new folder, the old one kept until '
    'done, the bar from 0',
    () async {
      await start();
      h.direct.formats = without137();
      h.invidious.formats = without137();
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await until(() => e.gaveUp, reason: 'its retries spent');
      final action = h.service.platformOf(e).failureAction(e);
      expect(action?.label, '切换为下载 720p');
      final old = File(path.join(e.entryDirPath, '137-140', 'video.m4s'));
      final oldBytes = old.readAsBytesSync();
      action!.apply(e);
      expect((e.maxHeight, e.streamTag, e.qualityLabel), (720, null, '720p'));
      int? videoTotalAtResolve;
      double? shownAtResolve;
      // the bar before the switch: what the 1080 bytes on disk made it
      final shownBefore = e.progress.value;
      h.direct.holdDetail = () async {
        videoTotalAtResolve ??= e.progress.videoTotal;
        shownAtResolve ??= e.progress.value;
      };
      final saved = <Map<String, dynamic>>[];
      h.mergeGate = (_) async {
        saved.add(await h.record(e));
        expect(old.readAsBytesSync(), oldBytes);
      };
      unawaited(h.service.restartWith(e));
      await h.untilStatus(e);
      expect(videoTotalAtResolve, 0);
      // the bar starts over with the counters (review 2e)
      expect(shownBefore, greaterThan(0));
      expect(shownAtResolve, 0);
      expect(e.maxHeight, 720);
      expect(e.streamTag, '136-140');
      expect(e.qualityLabel, '720p60');
      expect(saved.single['max_height'], 720);
      expect(saved.single['stream_tag'], '136-140');
      expect(saved.single['quality_label'], '720p60');
      expect(h.direct.preferences.last.exactHeight, 720);
      expect(h.direct.preferences.last.pin, isNull);
      // the old folder goes once the download is done
      expect(old.parent.existsSync(), isFalse);
    },
  );

  test('the switch: not on a failure that is not the quality', () async {
    await start(pinned: false);
    final e = h.entry()
      ..status = DownloadStatus.failDownload
      ..gaveUp = true;
    expect(h.service.platformOf(e).failureAction(e), isNull);
    e
      ..status = DownloadStatus.failQuality
      ..gaveUp = false;
    expect(h.service.platformOf(e).failureAction(e), isNull);
  });

  test(
    'the picked format\'s own label is written, once the transfer is taken',
    () async {
      await start(pinned: false, maxHeight: 720);
      h.direct.formats = without137();
      final e = h.entry();
      await h.run(e);
      expect(e.qualityLabel, '720p60');
      expect(e.maxHeight, 720);
    },
  );

  test('a restart asks the record\'s tier, not the old one', () async {
    await start(pinned: false, maxHeight: 720);
    final e = h.entry();
    await h.run(e);
    expect(h.direct.preferences.single.exactHeight, 720);
    expect(h.direct.preferences.single.maxHeight, 720);
    expect(DownloadService.beforeMergeForTest, isNotNull);
    expect(e, isA<YtDownloadEntry>());
  });
}
