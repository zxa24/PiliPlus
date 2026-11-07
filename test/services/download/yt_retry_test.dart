// LibrePili: a YouTube download's retries (stage-2 plan §2.4, §3.5; AC4's
// unit part). Nothing to download (failNoFormat): no retry, the queue goes
// on. A refusal of an Invidious address: the instance set aside
// (`playbackFailed`) before the timer, once — a failure later that wrote
// no kind of its own (a damaged merge) does not set it aside again.
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

  Future<void> one() =>
      h.start(records: [(root) => ytEntry(root, maxHeight: 1080)]);

  Future<void> start() => h.start(
    records: [
      (root) => ytEntry(root, maxHeight: 1080, stamp: 2),
      (root) => ytEntry(root, id: _otherId, maxHeight: 1080, stamp: 1),
    ],
  );

  test(
    'nothing to download: failNoFormat, no retry, the next one starts',
    () async {
      await start();
      h.direct.streamFailures.add(
        const YtVerdict(YtCause.contentUnavailable, 'no-playable-pair'),
      );
      final e = h.entry();
      await h.run(e, status: DownloadStatus.failNoFormat);
      await h.untilStatus(h.entry(_otherId));
      expect(
        h.log.where((l) => l.contains('yt:$ytId') && l.contains('again in')),
        isEmpty,
      );
      expect(
        h.log,
        contains(
          contains(
            'yt:$ytId: failNoFormat (contentUnavailable<no-playable-pair>), no more retries (no format)',
          ),
        ),
      );
      expect(e.status, DownloadStatus.failNoFormat);
      expect(e.gaveUp, isTrue);
    },
  );

  test(
    'an Invidious address refused: set aside before the retry, then done',
    () async {
      await one();
      YtSourceStore.debugMode = YtSourceMode.fallbackOnly;
      h.server.script = (s, n, _) =>
          s == 'audio' && n == 0 ? const FakeAnswer.status(403) : null;
      final e = h.entry();
      await h.run(e);
      expect(h.playbackFailed, [ytId]);
      expect(h.log, contains(contains('yt:$ytId: failDownloadAudio')));
      expect(h.log, contains(contains('again in')));
      // the retry asked for the streams again
      expect(h.invidious.streamCalls, 2);
    },
  );

  test('a direct address refused: nothing set aside', () async {
    await one();
    h.server.script = (s, n, _) =>
        s == 'video' && n == 0 ? const FakeAnswer.status(403) : null;
    final e = h.entry();
    await h.run(e);
    expect(h.playbackFailed, isEmpty);
    expect(h.direct.streamCalls, 2);
  });

  test(
    'refused, retried, then a damaged merge retried: set aside once',
    () async {
      await start();
      YtSourceStore.debugMode = YtSourceMode.fallbackOnly;
      h.server.script = (s, n, _) =>
          s == 'audio' && n == 0 ? const FakeAnswer.status(403) : null;
      h.remuxError = const FormatException('bad box');
      final e = h.entry();
      await h.run(e);
      expect(h.log, contains(contains('yt:$ytId: damaged streams removed')));
      expect(h.remuxed, hasLength(2));
      expect(h.playbackFailed, [ytId]);
    },
  );
}
