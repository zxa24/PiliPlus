// LibrePili: the YouTube record (stage-2 plan §3.2, design §2.2):
// `yt_<id>/main/entry.librepili.json`, its fields, what is refused when
// read, and how the list takes it — complete ones listed, others queued,
// a platform this build does not know skipped with its own lastError, the
// list sorted by the update time in seconds like bilibili's (AC2).
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

void main() {
  group('the record', () {
    final root = Directory(path.join('r', 'download'));

    test('made for the panel: folders, tier, label, seconds', () {
      final now = DateTime.utc(2026, 11, 1, 12);
      final e = YtDownloadPlatform.newEntry(ytDetail(), 1080, now, root.path);
      expect(e.pageDirPath, path.join(root.path, 'yt_$ytId'));
      expect(e.entryDirPath, path.join(root.path, 'yt_$ytId', 'main'));
      expect(e.maxHeight, 1080);
      expect(e.quality, '1080p');
      expect(e.cover, ytThumb(ytId));
      expect(e.durationMs, 213000);
      expect(e.timeCreateStamp, now.millisecondsSinceEpoch ~/ 1000);
      expect(e.timeUpdateStamp, now.millisecondsSinceEpoch ~/ 1000);
      expect(e.streamTag, isNull);
      expect(e.streamTypeTag, '0');
      expect(e.key, 'yt:$ytId');
      expect(e.logLabel, 'yt:$ytId');
      expect(e.groupId, 'yt_$ytId');
      expect(e.platform, 'youtube');
      expect(e.ownerName, 'Rick Astley');
      expect(e.mergedParts, isNull);
    });

    test('every field written and read back', () {
      final e = ytEntry(root, maxHeight: 720)
        ..streamTag = '136-140'
        ..streamSource = 'direct'
        ..quality = '720p60'
        ..totalBytes = 30
        ..downloadedBytes = 20
        ..isCompleted = true
        ..mergedPath = 'C:/v.mp4'
        ..extrasPending = true
        ..transcriptPending = true;
      final json = e.toJson();
      expect(json.keys, [
        'format',
        'platform',
        'video_id',
        'title',
        'channel',
        'channel_id',
        'cover',
        'duration_ms',
        'max_height',
        'stream_tag',
        'stream_source',
        'quality_label',
        'total_bytes',
        'downloaded_bytes',
        'is_completed',
        'merged_path',
        'extras_pending',
        'transcript_pending',
        'time_create_stamp',
        'time_update_stamp',
      ]);
      expect(json['format'], 'librepili-entry-1');
      final back = YtDownloadEntry.fromJson(jsonDecode(jsonEncode(json)));
      expect(back.toJson(), json);
      expect(back.streamTypeTag, '136-140');
    });

    test('not one of these: refused', () {
      final good = ytEntry(root).toJson();
      for (final (field, value) in [
        ('format', 'librepili-entry-2'),
        ('format', null),
        ('platform', 'bilibili'),
        ('video_id', 'dQw4w9WgXc'),
        ('video_id', '../dQw4w9WgX'),
        ('video_id', 7),
      ]) {
        expect(
          () => YtDownloadEntry.fromJson({...good, field: value}),
          throwsFormatException,
          reason: '$field $value',
        );
      }
    });
  });

  group('the list', () {
    late Directory storage;
    final h = DownloadHarness();
    setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
    tearDownAll(() => closeDownloadStorage(storage));
    tearDown(h.stop);

    test('complete: listed; not: queued; with bilibili, newest first by '
        'seconds', () async {
      await h.start(
        before: (root) {
          // before every bilibili fixture (1761000100 and later)
          writeYtRecord(
            root,
            ytEntry(root, completed: true, stamp: 1735689600),
          );
          writeYtRecord(root, ytEntry(root, id: 'jNQXAC9IVRw'));
        },
      );
      final listed = h.service.downloadList;
      expect(listed.last.key, 'yt:$ytId');
      expect(
        listed.where((e) => e.key.startsWith('yt:')).single.timeUpdateStamp,
        1735689600,
      );
      expect(
        h.service.waitDownloadQueue.map((e) => e.key),
        contains('yt:jNQXAC9IVRw'),
      );
      final queued = h.service.waitDownloadQueue.firstWhere(
        (e) => e.key == 'yt:jNQXAC9IVRw',
      );
      expect(
        queued.entryDirPath,
        endsWith(path.join('yt_jNQXAC9IVRw', 'main')),
      );
    });

    test('a platform this build does not know: skipped, its lastError '
        'says so', () async {
      late Directory dir;
      await h.start(
        entries: const [],
        before: (root) {
          final e = ytEntry(root);
          final json = e.toJson()..['platform'] = 'foo';
          final file = writeYtRecord(root, e, raw: jsonEncode(json));
          dir = file.parent;
        },
      );
      expect(h.service.downloadList, isEmpty);
      expect(h.service.waitDownloadQueue, isEmpty);
      expect(h.service.lastError, 'unknown platform foo (${dir.path})');
    });

    test('a record that is not one: skipped, named in lastError', () async {
      late Directory dir;
      await h.start(
        entries: const [],
        before: (root) {
          final e = ytEntry(root);
          final json = e.toJson()..['video_id'] = 'short';
          dir = writeYtRecord(root, e, raw: jsonEncode(json)).parent;
        },
      );
      expect(h.service.waitDownloadQueue, isEmpty);
      expect(
        h.service.lastError,
        startsWith('entry.librepili.json (${dir.path}): FormatException'),
      );
    });
  });
}
