// LibrePili: the download state kept per entry (by cid now, by a platform
// key after the download-platforms refactor), each place checked on the
// real service with fake transfers before that refactor touches it (design
// feature-logs/download-platforms/design.md, AC1 「以 cid 为键的各处」).
//
// Three entries: P1 and P2, two parts of one video (same avid, same page
// folder, only their cids differ), and S, a bangumi episode whose cid comes
// from `source`. A key taken from the wrong field makes P1 and P2 collide;
// every check also says the others were left alone.
//
// Not here (they need a running AsrService, which is not faked): the
// transcripts' `running`, `_failures` and the running branch of `forget`;
// `--download-transcribe` checks those (design AC1, p7#7).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

/// Waiting in the queue, nothing downloaded yet.
Map<String, Object?> queued(String entry, Map<String, dynamic> json) => {
  ...json,
  'is_completed': false,
  'downloaded_bytes': 0,
};

/// [seconds] of media transcribed, as the subtitle cache keeps it.
TranscriptStore transcribed(double seconds) {
  final store = TranscriptStore();
  final run = store.startRun(0);
  store.advance(run, seconds);
  run.finish();
  return store;
}

/// A video file of [entry]'s own, as a merge leaves it.
String exportOf(DownloadHarness h, String name) {
  final file = File(path.join(h.root.path, name, '$name.mp4'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('merged');
  return file.path;
}

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(() async {
    await h.stop();
    await GStorage.setting.put(SettingBoxKey.dlTranscribe, false);
  });

  late BiliDownloadEntryInfo p1;
  late BiliDownloadEntryInfo p2;
  late BiliDownloadEntryInfo s;

  /// [h] started, P1 / P2 / S picked out of it, the queue in that order.
  Future<void> start({
    Map<String, Object?> Function(String entry, Map<String, dynamic> json)?
    patch,
  }) async {
    await h.start(patch: patch);
    p1 = h.entry(fixtureP1);
    p2 = h.entry(fixtureP2);
    s = h.entry(fixtureS);
    final queue = h.service.waitDownloadQueue;
    final order = <Object>[p1, p2, s];
    queue.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
  }

  int count(String text) => h.log.where((l) => l.contains(text)).length;

  group('DownloadTranscripts', () {
    test('finished, stateOf, forget and kept act on one entry', () async {
      await GStorage.setting.put(SettingBoxKey.dlTranscribe, true);
      await start();
      final transcripts = h.service.transcripts;

      await transcripts.finished(p1);
      expect(transcripts.progress[keyOf(p1)], 0);
      expect(transcripts.stateOf(keyArg(p1))?.fraction, 0);
      expect(transcripts.stateOf(keyArg(p1))?.running, isFalse);
      expect(transcripts.stateOf(keyArg(p2)), isNull);
      expect(transcripts.stateOf(keyArg(s)), isNull);
      expect(p1.transcriptPending, isTrue);
      expect(
        readEntryJson(h.root.path, fixtureP1)['transcript_pending'],
        isTrue,
      );

      await transcripts.finished(s);
      expect(transcripts.stateOf(keyArg(s))?.fraction, 0);

      await transcripts.forget(keyArg(p1));
      expect(transcripts.stateOf(keyArg(p1)), isNull);
      expect(transcripts.stateOf(keyArg(s)), isNotNull);

      // what the cache kept of P2: 30 s of its 98
      final kept = SubtitleCacheEntry(
        SubtitleCacheKey.bilibili(p2.cid),
        AsrService.recogniserId,
      )..captureTranscript(transcribed(30));
      transcripts.kept(kept, p2);
      expect(transcripts.stateOf(keyArg(p2))?.fraction, closeTo(30 / 98, 1e-9));
      expect(transcripts.stateOf(keyArg(p1)), isNull);
      expect(transcripts.stateOf(keyArg(s))?.fraction, 0);
    });
  });

  group('the queue', () {
    test('the current entry, and how many the notification says wait '
        'behind it', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p1).isNotEmpty);
      h.transportsOf(p1).single.receive(1 << 20, 4 << 20);

      expect(h.service.curCid, keyOf(p1));
      expect(identical(h.service.curDownload.value, p1), isTrue);
      expect(p1.status, DownloadStatus.downloading);
      expect(p2.status, DownloadStatus.wait);
      // P2 and S: not the running one itself
      expect(h.service.keepAliveStateForTest?.text, endsWith(' · 还有 2 个'));
    });

    test('retries are counted per entry, and the queue goes on in its '
        'order after the last one', () async {
      h.onTransport = (t) => scheduleMicrotask(t.fail);
      await start(patch: queued);
      h.service.startDownload(p1);
      // all three give up (a queue that stalls instead is told below)
      await until(() => count('no more retries') == 3, quiet: true);

      // a start and three retries each
      expect(h.transportsOf(p1), hasLength(4));
      expect(h.transportsOf(p2), hasLength(4));
      expect(h.transportsOf(s), hasLength(4));
      expect(count('again in'), 9);
      // P2, the same video's other part, right after P1; then S
      final firstOf = [
        for (final e in [p1, p2, s]) h.transports.indexOf(h.transportsOf(e)[0]),
      ];
      expect(firstOf, orderedEquals([...firstOf]..sort()));
      expect(p1.status, DownloadStatus.failDownload);
      expect(p2.status, DownloadStatus.failDownload);
      expect(s.status, DownloadStatus.failDownload);
    });

    test('a retry that failed after receiving bytes starts its count over; '
        'the other part counts its own', () async {
      await start(patch: queued);
      var p1Starts = 0;
      h.onTransport = (t) {
        // P1's third start gets somewhere before it fails: bytes on disk
        if (path.isWithin(p1.entryDirPath, t.path) && ++p1Starts == 3) {
          File(t.path)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(List.filled(100, 1));
        }
        scheduleMicrotask(t.fail);
      };
      h.service.startDownload(p1);
      await until(() => count('no more retries') == 3, quiet: true);

      // P1: two retries, then the one with bytes counts as the first again
      // and three more follow; P2, the same video's other part, has its own
      // three, as S does
      expect(h.transportsOf(p1), hasLength(6));
      expect(h.transportsOf(p2), hasLength(4));
      expect(h.transportsOf(s), hasLength(4));
      expect(count('again in'), 11);
      expect(p1.status, DownloadStatus.failDownload);
      expect(p2.status, DownloadStatus.failDownload);
    });

    test('a retry waiting for its timer does not start once another entry '
        'is the current one', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      DownloadService.retryWaitsForTest = const [
        Duration(milliseconds: 60),
        Duration(milliseconds: 60),
        Duration(milliseconds: 60),
      ];
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p1).isNotEmpty);
      h.transportsOf(p1).single.fail();
      expect(p1.status, DownloadStatus.retryWait);

      // the other part became the current entry with no start of its own
      // (no new generation): P1's timer finds it and leaves it
      h.service.curDownload.value = p2;
      await settle(200);
      expect(h.transportsOf(p1), hasLength(1));
      expect(p1.status, DownloadStatus.retryWait);
    });

    test('the queue passes over a failed entry', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      h.onTransport = (t) {
        if (path.isWithin(p1.entryDirPath, t.path)) scheduleMicrotask(t.fail);
      };
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p2).isNotEmpty, quiet: true);
      expect(p1.status, DownloadStatus.failDownload);
      expect(h.transportsOf(p1), hasLength(4));
      expect(h.transportsOf(p2), hasLength(1));

      h.transportsOf(p2).single.complete();
      await until(() => h.transportsOf(s).isNotEmpty, quiet: true);
      expect(h.transportsOf(s), isNotEmpty);
      expect(h.transportsOf(p1), hasLength(4));
      expect(hasKey(h.service.downloadList, keyOf(p2)), isTrue);
    });

    test('a download failed off screen is started again when the app is '
        'back', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p1).isNotEmpty);

      h.service.didChangeAppLifecycleState(AppLifecycleState.paused);
      // the network's failure: no retry while away
      h.transportsOf(p1).single.fail(const SocketException('offline'));
      await settle();
      expect(p1.status, DownloadStatus.failDownload);
      expect(h.transportsOf(p1), hasLength(1));
      expect(h.transportsOf(p2), isEmpty);

      h.service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await until(() => h.transportsOf(p1).length == 2);
      expect(identical(h.service.curDownload.value, p1), isTrue);
      expect(h.transportsOf(p2), isEmpty);
    });

    test('pausing stops the current entry only, and saves what it '
        'downloaded', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p1).isNotEmpty);
      final transfer = h.transportsOf(p1).single..receive(4096, 1 << 20);

      await h.service.cancelDownload(isDelete: false, downloadNext: false);
      expect(transfer.cancels, [false]);
      expect(p1.status, DownloadStatus.pause);
      expect(p2.status, DownloadStatus.wait);
      expect(identical(h.service.curDownload.value, p1), isTrue);
      expect(readEntryJson(h.root.path, fixtureP1)['downloaded_bytes'], 4096);
      expect(readEntryJson(h.root.path, fixtureP2)['downloaded_bytes'], 0);
    });
  });

  group('merging', () {
    test('an entry being merged is not started or paused again; the queue '
        'goes on with the other part after it', () async {
      final gate = Completer<void>();
      h.mergeGate = (_) => h.merged.length == 1 ? gate.future : null;
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.merged.length == 1);
      expect(p1.status, DownloadStatus.merging);

      await h.service.startDownload(p1);
      expect(h.transportsOf(p1), hasLength(1));
      await h.service.cancelDownload(isDelete: false);
      expect(p1.status, DownloadStatus.merging);
      expect(h.transportsOf(p2), isEmpty);

      gate.complete();
      await until(() => hasKey(h.service.downloadList, keyOf(p1)));
      await until(() => h.transportsOf(p2).isNotEmpty);
      expect(h.transportsOf(p1), hasLength(1));
    });

    test('an entry deleted while it is merged is removed once the merge '
        'ends; the other part stays', () async {
      final gate = Completer<void>();
      h.mergeGate = (e) async {
        if (h.merged.length != 1) return;
        await gate.future;
        // the merge kept its files open: the delete could not remove the
        // folder (Windows), as it may
        Directory(e.entryDirPath).createSync(recursive: true);
      };
      h.onTransport = (t) {
        if (h.transports.length == 1) scheduleMicrotask(t.complete);
      };
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.merged.length == 1);

      // the start's own saves of entry.json done (they are not awaited; one
      // still writing would keep the folder from being deleted, Windows)
      await h.service.saveEntryForTest(p1);
      await h.service.deleteDownload(entry: p1, removeQueue: true);
      expect(hasKey(h.service.waitDownloadQueue, keyOf(p2)), isTrue);
      gate.complete();
      // the merge's end dealt with: P1 removed, or (wrongly) listed
      await until(
        () =>
            p1.mergedPath != null &&
            (hasKey(h.service.downloadList, keyOf(p1)) ||
                !Directory(p1.entryDirPath).existsSync()),
      );
      await settle();

      expect(hasKey(h.service.downloadList, keyOf(p1)), isFalse);
      expect(hasKey(h.service.waitDownloadQueue, keyOf(p1)), isFalse);
      expect(Directory(p1.entryDirPath).existsSync(), isFalse);
      expect(File(p1.mergedPath!).existsSync(), isFalse);
      expect(
        File(path.join(p2.entryDirPath, 'entry.json')).existsSync(),
        isTrue,
      );
      expect(hasKey(h.service.waitDownloadQueue, keyOf(p2)), isTrue);
    });

    test('re-reading the list while an entry is merged keeps it current; '
        'it joins the list when done', () async {
      final gate = Completer<void>();
      h.mergeGate = (_) => h.merged.length == 1 ? gate.future : null;
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.merged.length == 1);

      h.service.reloadDownloadList();
      await h.service.waitForInitialization;
      expect(identical(h.service.curDownload.value, p1), isTrue);
      expect(h.transportsOf(p1), hasLength(1));

      gate.complete();
      await until(() => hasKey(h.service.downloadList, keyOf(p1)));
      expect(identical(entryIn(h.service.downloadList, keyOf(p1)), p1), isTrue);
    });

    test('re-reading the list while an entry downloads lets it go; the '
        're-read queue starts again', () async {
      h.onTransport = (_) {};
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.transportsOf(p1).isNotEmpty);

      h.service.reloadDownloadList();
      await h.service.waitForInitialization;
      await until(() => h.transports.length == 2);
      final current = h.service.curDownload.value!;
      expect(identical(current, p1), isFalse);
      expect(keyOf(current), keyOf(p1));
      expect(h.transports.first.cancels, [false]);
    });

    test('「暂停」 tapped while an entry merges: the queue does not go on '
        'after it', () async {
      final first = Completer<void>();
      final second = Completer<void>();
      h.mergeGate = (_) => switch (h.merged.length) {
        1 => first.future,
        2 => second.future,
        _ => null,
      };
      await start(patch: queued);
      h.service.startDownload(p1);
      await until(() => h.merged.length == 1);

      h.service.keepAlive.onPause!();
      first.complete();
      await until(() => hasKey(h.service.downloadList, keyOf(p1)));
      await settle();
      expect(h.service.curDownload.value, isNull);
      expect(p2.status, DownloadStatus.wait);
      expect(h.transportsOf(p2), isEmpty);

      // P2 merged with no 「暂停」: the queue goes on to S
      h.service.startDownload(p2);
      await until(() => h.merged.length == 2);
      second.complete();
      await until(() => h.transportsOf(s).isNotEmpty);
    });

    test('damaged streams are downloaded again once per start, for each '
        'entry on its own', () async {
      final damaged = <Object>{};
      h.mergeAnswer = (e) => damaged.contains(keyOf(e))
          ? (
              output: null,
              inputs: [path.join(e.entryDirPath, e.streamTypeTag, 'video.m4s')],
              damaged: true,
              corrupt: true,
            )
          : null;
      await start(patch: queued);
      damaged.addAll([keyOf(p1), keyOf(p2)]);
      const first = '音视频文件已损坏，将重新下载';
      const again = '音视频文件再次损坏，已删除，可稍后重新开始该下载';

      h.service.startDownload(p1);
      await until(() => count('no more retries') == 1, quiet: true);
      expect(count('no more retries'), 1);
      expect(
        h.log.lastWhere((l) => l.contains('no more retries')),
        endsWith('no more retries (merge)'),
      );
      expect(h.transportsOf(p1), hasLength(2));
      expect(h.toasts, [first, again]);
      expect(count('damaged streams removed'), 2);
      expect(count('again in'), 1);
      expect(p1.status, DownloadStatus.failMerge);

      // the queue goes on: P2's first damage is its own first
      await until(() => count('no more retries') == 2, quiet: true);
      expect(h.toasts, [first, again, first, again]);
      expect(h.transportsOf(p2), hasLength(2));
      await until(() => hasKey(h.service.downloadList, keyOf(s)));

      // started again by the user: one more download of P1's streams
      h.service.startDownload(p1);
      await until(() => count('no more retries') == 3, quiet: true);
      expect(h.toasts.sublist(4), [first, again]);
      expect(h.transportsOf(p1), hasLength(4));
    });
  });

  group('extras', () {
    test('an extras job, the saving mark and its cancel belong to one '
        'entry', () async {
      final gates = <Object, Completer<void>>{};
      h.exportGate = (e) => (gates[keyOf(e)] = Completer<void>()).future;
      await start(
        patch: (entry, json) => entry == fixtureS ? json : queued(entry, json),
      );
      h.service.startDownload(p1);
      await until(() => h.exported.length == 1);
      expect(identical(h.exported.single, p1), isTrue);
      expect(h.service.isSavingExtras(p1), isTrue);
      expect(h.service.isSavingExtras(p2), isFalse);
      expect(h.service.extrasDone(keyArg(p1)), isNotNull);
      expect(h.service.extrasDone(keyArg(p2)), isNull);

      // the queue does not wait for extras: P2 completes, its extras wait
      // behind P1's
      await until(() => h.service.extrasDone(keyArg(p2)) != null);
      expect(h.service.isSavingExtras(p2), isTrue);
      expect(h.exported, hasLength(1));

      // P1 deleted while its extras run: its job stops, P2's goes on
      final deleting = h.service.deleteDownload(entry: p1, removeList: true);
      await settle();
      gates[keyOf(p1)]!.complete();
      await deleting;
      expect(h.service.isSavingExtras(p1), isFalse);
      await until(() => h.exported.length == 2);
      expect(identical(h.exported.last, p2), isTrue);
      expect(h.service.extrasDone(keyArg(p2)), isNotNull);

      gates[keyOf(p2)]!.complete();
      await until(() => h.service.extrasDone(keyArg(p2)) == null);
      expect(h.service.isSavingExtras(p2), isFalse);
      expect(p2.status, DownloadStatus.completed);
      expect(readEntryJson(h.root.path, fixtureP2)['extras_pending'], isNull);
    });

    test('re-reading the list does not queue a second extras job for one '
        'still saving; one marked with none is queued', () async {
      final gate = Completer<void>();
      h.exportGate = (_) => h.exported.length == 1 ? gate.future : null;
      await start(
        patch: (entry, json) => entry == fixtureP1 ? queued(entry, json) : json,
      );
      h.service.startDownload(p1);
      await until(() => h.exported.length == 1);
      expect(readEntryJson(h.root.path, fixtureP1)['extras_pending'], isTrue);

      // P2 complete, its extras marked unsaved, no job for it
      File(path.join(p2.entryDirPath, 'entry.json')).writeAsStringSync(
        jsonEncode({
          ...readEntryJson(h.root.path, fixtureP2),
          'extras_pending': true,
          'merged_path': exportOf(h, 'p2 export'),
        }),
      );
      h.service.reloadDownloadList();
      await h.service.waitForInitialization;

      gate.complete();
      await until(() => h.exported.length >= 2);
      await settle(60);
      expect(h.exported.map(keyOf), [keyOf(p1), keyOf(p2)]);
    });
  });

  group('deleting', () {
    test('deleting the page stops and deletes both parts of the video; the '
        'bangumi stays', () async {
      h.onTransport = (_) {};
      await start(
        patch: (entry, json) => entry == fixtureP2 ? queued(entry, json) : json,
      );
      p1.mergedPath = exportOf(h, 'p1 export');
      s.mergedPath = exportOf(h, 's export');
      final transcripts = h.service.transcripts;
      transcripts.progress[keyArg(p1)] = 0.5;
      transcripts.progress[keyArg(p2)] = 0.25;
      transcripts.progress[keyArg(s)] = 1.0;
      h.service.startDownload(p2);
      await until(() => h.transportsOf(p2).isNotEmpty);
      // the start's own saves of entry.json done (see above)
      await h.service.saveEntryForTest(p2);

      await h.service.deletePage(
        pageDirPath: p1.pageDirPath,
        deleteExported: true,
      );
      expect(h.transportsOf(p2).single.cancels, [true]);
      expect(h.service.curDownload.value, isNull);
      expect(File(p1.mergedPath!).existsSync(), isFalse);
      expect(transcripts.progress[keyOf(p1)], isNull);
      expect(transcripts.progress[keyOf(p2)], isNull);
      expect(Directory(p1.pageDirPath).existsSync(), isFalse);
      expect(hasKey(h.service.downloadList, keyOf(p1)), isFalse);
      expect(hasKey(h.service.waitDownloadQueue, keyOf(p2)), isFalse);

      expect(transcripts.progress[keyOf(s)], 1.0);
      expect(File(s.mergedPath!).existsSync(), isTrue);
      expect(hasKey(h.service.downloadList, keyOf(s)), isTrue);
      expect(Directory(s.entryDirPath).existsSync(), isTrue);
    });

    test('deleting one part leaves the other and its files', () async {
      await start();
      await h.service.deleteDownload(entry: p1, removeList: true);
      expect(hasKey(h.service.downloadList, keyOf(p1)), isFalse);
      expect(hasKey(h.service.downloadList, keyOf(p2)), isTrue);
      expect(Directory(p1.entryDirPath).existsSync(), isFalse);
      expect(
        File(path.join(p2.entryDirPath, 'entry.json')).existsSync(),
        isTrue,
      );
      expect(
        File(path.join(s.entryDirPath, 'entry.json')).existsSync(),
        isTrue,
      );
    });
  });

  group('a transcript kept while watching', () {
    Future<void> keep(SubtitleCacheKey key) async {
      final cache = SubtitleCache.instance;
      final kept = await cache.open(key, AsrService.recogniserId);
      kept.captureTranscript(transcribed(30));
      await cache.save(kept);
      await TranscriptFiles.flush();
    }

    Future<void> startWithExports() async {
      await start();
      p1.mergedPath = exportOf(h, 'p1 export');
      p2.mergedPath = exportOf(h, 'p2 export');
      s.mergedPath = exportOf(h, 's export');
    }

    test('counts for its own part only (P1)', () async {
      await startWithExports();
      await keep(SubtitleCacheKey.bilibili(p1.cid));
      final progress = h.service.transcripts.progress;
      expect(progress[keyOf(p1)], closeTo(30 / 125, 1e-9));
      expect(progress[keyOf(p2)], isNull);
      expect(progress[keyOf(s)], isNull);
    });

    test("counts for the bangumi episode by its source's cid (S)", () async {
      await startWithExports();
      await keep(SubtitleCacheKey.bilibili(s.source!.cid));
      final progress = h.service.transcripts.progress;
      expect(progress[keyOf(s)], closeTo(30 / 1420, 1e-9));
      expect(progress[keyOf(p1)], isNull);
      expect(progress[keyOf(p2)], isNull);
    });
  });
}
