// LibrePili: a YouTube download's merge and completion (stage-2 plan
// §3.5, §2.5; AC12's unit part, and the completion half of AC-E: the half
// that reads the list back is yt_extras_deferred_test). Only after both
// streams are whole; the two streams of the current folder into one mp4 in
// the export folder; a merge that fails keeps the streams apart (complete,
// no export to play), damaged streams are removed and downloaded again; a
// completion marks the extras for stage 4 and does not queue them.
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
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

  Future<void> start() =>
      h.start(records: [(root) => ytEntry(root, maxHeight: 1080)]);

  test(
    'a merge: after both streams are whole; the export, extras marked, '
    'not queued',
    () async {
      await start();
      final e = h.entry();
      final atMerge = <(int, int)>[];
      final queued = <int>[];
      h.service.extrasQueue.listen((q) => queued.add(q.length));
      h.mergeGate = (_) async {
        final dir = h.streamDir(e);
        atMerge.add((
          File(path.join(dir, 'video.m4s')).lengthSync(),
          File(path.join(dir, 'audio.m4s')).lengthSync(),
        ));
      };
      await h.run(e);
      expect(atMerge.single, (
        h.server.bodies['video']!.length,
        h.server.bodies['audio']!.length,
      ));
      expect(e.isCompleted, isTrue);
      expect(e.extrasPending, isTrue);
      expect((await h.record(e))['extras_pending'], isTrue);
      expect(h.service.extrasQueue, isEmpty);
      expect(queued.where((n) => n > 0), isEmpty);
      expect(e.progress.value, 1);
      expect(path.basename(e.mergedPath!), endsWith('.mp4'));
      // the stream files go once completion is saved
      expect(
        File(path.join(h.streamDir(e), 'video.m4s')).existsSync(),
        isFalse,
      );
      expect(
        h.log.where((l) => l.contains('damaged streams removed')),
        isEmpty,
      );
    },
  );

  test(
    'a merge that fails (not damaged bytes): complete, no export, the '
    'streams kept, nothing marked',
    () async {
      await start();
      h.remuxError = StateError('the remuxer gave up');
      final e = h.entry();
      await h.run(e);
      expect(h.toasts, contains('合并音视频失败，已保留分离的音视频文件'));
      expect(e.isCompleted, isTrue);
      expect(e.mergedPath, isNull);
      expect(e.extrasPending, isFalse);
      expect(e.transcriptPending, isFalse);
      final saved = await h.record(e);
      expect(saved['is_completed'], isTrue);
      expect(saved['merged_path'], isNull);
      expect(saved['extras_pending'], isFalse);
      expect(File(path.join(h.streamDir(e), 'video.m4s')).existsSync(), isTrue);
      expect(File(path.join(h.streamDir(e), 'audio.m4s')).existsSync(), isTrue);
      // no export folder left behind
      expect(
        h.root.listSync().whereType<Directory>().map(
          (d) => path.basename(d.path),
        ),
        ['yt_$ytId'],
      );
      // opened from the list: told it cannot play
      await h.service.platformOf(e).openOffline(e);
      expect(h.toasts.last, '该视频合并失败，无法播放');
    },
  );

  test(
    'damaged bytes: the streams removed and downloaded again, then done',
    () async {
      await start();
      h.remuxError = const FormatException('a box cut short');
      final e = h.entry();
      await h.run(e);
      expect(h.log, contains(contains('yt:$ytId: damaged streams removed')));
      expect(h.toasts, contains('音视频文件已损坏，将重新下载'));
      expect(h.remuxed, hasLength(2));
      expect(e.isCompleted, isTrue);
      expect(e.mergedPath, isNotNull);
      expect(
        h.log.where((l) => l.contains('yt:$ytId: video restarted from 0')),
        hasLength(1),
      );
    },
  );

  test(
    'a stream file gone at the merge: failMerge, nothing removed',
    () async {
      await start();
      h.remuxError = const FileSystemException('gone', 'audio.m4s');
      final e = h.entry();
      await h.run(e, status: DownloadStatus.failMerge);
      expect(h.toasts, contains('音视频文件丢失或无法读取，可稍后重新开始该下载'));
      expect(e.isCompleted, isFalse);
      expect(File(path.join(h.streamDir(e), 'video.m4s')).existsSync(), isTrue);
    },
  );
}
