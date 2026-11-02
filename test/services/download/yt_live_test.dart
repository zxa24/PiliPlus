// LibrePili: a live or upcoming YouTube video is not downloaded (stage-2
// plan §3.3, design §10-5 items 3 and 4; AC15's unit part). The direct
// source's detail says `liveNow`: failNoFormat, no retry, no transfer,
// the queue goes on. An upcoming one the direct source refuses as
// `live_stream_offline`: the same. Invidious does not tell: its answer is
// downloaded as it is (§10-5 4 b).
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

const _otherId = 'jNQXAC9IVRw';

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  Future<void> start() => h.start(
    records: [
      (root) => ytEntry(root, maxHeight: 1080, stamp: 2),
      (root) => ytEntry(root, id: _otherId, maxHeight: 1080, stamp: 1),
    ],
  );

  void expectNoTransfer() {
    expect(h.server.requests.where((r) => r.$1 != 'hqdefault.jpg'), isEmpty);
    expect(h.log.where((l) => l.contains('yt:$ytId: video')), isEmpty);
  }

  test(
    'live now (the direct source): failNoFormat, no retry, the next one',
    () async {
      await start();
      h.direct.liveIds.add(ytId);
      final e = h.entry();
      await h.run(e, status: DownloadStatus.failNoFormat);
      expect(h.service.lastError, contains('live or upcoming'));
      expect(h.log.where((l) => l.contains('again in')), isEmpty);
      expect(h.log, contains(contains('yt:$ytId: failNoFormat')));
      expectNoTransfer();
      // the queue goes on with the other video
      await h.untilStatus(h.entry(_otherId));
      expect(e.status, DownloadStatus.failNoFormat);
    },
  );

  test(
    'upcoming (live_stream_offline): failNoFormat, no retry',
    () async {
      await start();
      h.direct.detailFailures.add(
        const YtVerdict(
          YtCause.contentUnavailable,
          'playability:live_stream_offline',
        ),
      );
      final e = h.entry();
      await h.run(e, status: DownloadStatus.failNoFormat);
      expect(h.log.where((l) => l.contains('again in')), isEmpty);
      expectNoTransfer();
    },
  );

  test("Invidious's answer: not judged live, downloaded", () async {
    await start();
    YtSourceStore.debugMode = YtSourceMode.fallbackOnly;
    h.invidious.liveIds.add(ytId);
    final e = h.entry();
    await h.run(e);
    expect(e.isCompleted, isTrue);
    expect(e.streamSource, 'invidious');
  });
}
