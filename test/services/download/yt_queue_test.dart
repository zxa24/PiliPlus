// LibrePili: YouTube and bilibili downloads in one queue (stage-2 plan
// §5 AC7, the stage-2 part). They take turns; a YouTube download that
// fails for good (nothing to download) is skipped and the queue goes on;
// a YouTube one retried for the network finishes, the bilibili one after
// it too; a YouTube download deleted takes its `yt_<id>` folder with it
// and keeps the export unless asked.
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

Map<String, Object?> _queued(String entry, Map<String, dynamic> json) => {
  ...json,
  'is_completed': false,
  'downloaded_bytes': 0,
};

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  Future<void> start() => h.start(
    records: [(root) => ytEntry(root, maxHeight: 1080)],
    bili: const [fixtureP1],
    patch: _queued,
  );

  bool done(Object e) => h.service.downloadList.contains(e);

  test('a YouTube download, then the bilibili one: both done', () async {
    await start();
    final yt = h.entry();
    final bili = h.base.entry(fixtureP1);
    await h.run(yt);
    await until(() => done(bili), reason: 'the bilibili download');
    expect(yt.isCompleted, isTrue);
  });

  test('the bilibili download, then the YouTube one: both done', () async {
    await start();
    final yt = h.entry();
    final bili = h.base.entry(fixtureP1);
    await h.service.startDownload(bili);
    await until(() => done(bili), reason: 'the bilibili download');
    await h.untilStatus(yt);
  });

  test('a YouTube download with nothing to download: skipped', () async {
    await start();
    h.direct.streamFailures.add(
      const YtVerdict(YtCause.contentUnavailable, 'no-playable-pair'),
    );
    final yt = h.entry();
    final bili = h.base.entry(fixtureP1);
    await h.run(yt, status: DownloadStatus.failNoFormat);
    await until(() => done(bili), reason: 'the bilibili download');
    expect(yt.status, DownloadStatus.failNoFormat);
  });

  test(
    'a YouTube download retried for the network: done, then the next',
    () async {
      await start();
      // six drops in a row that save nothing: the transfer's budget spent
      h.server.script = (s, n, _) =>
          s == 'video' && n < 6 ? const FakeAnswer.range(cutAfter: 0) : null;
      final yt = h.entry();
      final bili = h.base.entry(fixtureP1);
      await h.run(yt);
      expect(h.log, contains(contains('yt:$ytId: failDownload')));
      expect(h.log, contains(contains('again in')));
      await until(() => done(bili), reason: 'the bilibili download');
    },
  );

  for (final deleteExported in [false, true]) {
    test(
      'a YouTube download deleted: its folder gone, the export '
      '${deleteExported ? 'deleted too' : 'kept'}',
      () async {
        await h.start(records: [(root) => ytEntry(root, maxHeight: 1080)]);
        final yt = h.entry();
        await h.run(yt);
        final export = yt.mergedPath!;
        await h.service.deleteDownload(
          entry: yt,
          removeList: true,
          deleteExported: deleteExported,
        );
        expect(
          Directory(path.join(h.root.path, 'yt_$ytId')).existsSync(),
          isFalse,
        );
        expect(File(export).existsSync(), !deleteExported);
      },
    );
  }
}
