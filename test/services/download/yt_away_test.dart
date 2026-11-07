// LibrePili: a YouTube download that fails while the app is off screen
// (stage-2 plan §2.4, design §4.3 p2#2; AC11's unit part). No retry is
// scheduled away; a refusal (an address bound to the network left behind)
// and a quality not on offer are started again once the app is back — an
// Invidious refusal sets its instance aside first; a server busy on every
// request (its budget spent: `other`) and a client broken are not. Nothing
// to download goes on with the queue at once, away too.
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
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

  Future<void> start({int maxHeight = 1080, bool two = false}) => h.start(
    records: [
      (root) => ytEntry(root, maxHeight: maxHeight, stamp: 2),
      if (two) (root) => ytEntry(root, id: _otherId, maxHeight: 1080, stamp: 1),
    ],
  );

  void away() => h.service.didChangeAppLifecycleState(AppLifecycleState.paused);
  void back() =>
      h.service.didChangeAppLifecycleState(AppLifecycleState.resumed);

  Iterable<String> startedAgain() =>
      h.log.where((l) => l.contains('yt:$ytId: failed off screen'));

  test('refused away: no retry away; back, started again and done', () async {
    await start();
    h.server.script = (s, n, _) =>
        s == 'video' && n == 0 ? const FakeAnswer.status(403) : null;
    final e = h.entry();
    away();
    await h.run(e, status: DownloadStatus.failDownload);
    await settle(50);
    expect(e.status, DownloadStatus.failDownload);
    expect(h.log.where((l) => l.contains('again in')), isEmpty);
    back();
    await h.untilStatus(e);
    expect(startedAgain().single, contains('(failDownload), started again'));
  });

  test(
    'an Invidious address refused away: set aside before the start again',
    () async {
      await start();
      YtSourceStore.debugMode = YtSourceMode.fallbackOnly;
      h.server.script = (s, n, _) =>
          s == 'audio' && n == 0 ? const FakeAnswer.status(403) : null;
      final e = h.entry();
      away();
      await h.run(e, status: DownloadStatus.failDownloadAudio);
      await settle(50);
      expect(h.playbackFailed, isEmpty);
      back();
      expect(h.playbackFailed, [ytId]);
      await h.untilStatus(e);
    },
  );

  test(
    'busy on every request away (429): failed, not started again',
    () async {
      await start();
      h.server.script = (s, n, _) => const FakeAnswer.status(429);
      final e = h.entry();
      // either stream may spend its budget first
      const failed = {
        DownloadStatus.failDownload,
        DownloadStatus.failDownloadAudio,
      };
      away();
      await h.run(e, any: failed);
      back();
      await settle(100);
      expect(startedAgain(), isEmpty);
      expect(failed, contains(e.status));
    },
  );

  test('nothing to download away: the next one starts at once', () async {
    await start(two: true);
    h.direct.streamFailures.add(
      const YtVerdict(YtCause.contentUnavailable, 'no-playable-pair'),
    );
    final e = h.entry();
    away();
    await h.run(e, status: DownloadStatus.failNoFormat);
    // still away
    await h.untilStatus(h.entry(_otherId));
  });

  test(
    'a quality not on offer away: back, started again (and retried)',
    () async {
      // tier 2160: neither source has it
      await start(maxHeight: 2160);
      final e = h.entry();
      away();
      await h.run(e, status: DownloadStatus.failQuality);
      await settle(50);
      expect(h.log.where((l) => l.contains('again in')), isEmpty);
      back();
      expect(startedAgain().single, contains('(failQuality), started again'));
      await until(() => e.gaveUp, reason: 'its three retries on screen');
      expect(e.status, DownloadStatus.failQuality);
    },
  );

  test('a client broken away: not started again', () async {
    await start();
    h.direct.streamFailures.add(
      const YtVerdict(YtCause.clientBroken, 'needs-javascript'),
    );
    final e = h.entry();
    away();
    await h.run(e, status: DownloadStatus.failPlayUrl);
    back();
    await settle(100);
    expect(startedAgain(), isEmpty);
    expect(e.status, DownloadStatus.failPlayUrl);
  });
}
