// LibrePili: a YouTube download's extras wait for stage 4 (stage-2 plan
// §2.5, §10-7 Q2 c; AC-E, the YouTube part). The service side with a
// platform whose extras are off is extras_deferred_test.dart (P2-E1..E3);
// here the YouTube adapter itself: a completed record marked
// `extras_pending` is listed as cached, never queued for its extras, its
// mark kept; once the switch is on (what stage 4 does), the next read of
// the list queues it and the mark is cleared when done — or, its video
// gone, the mark alone is cleared.
//
// The completion that writes the mark is YouTube's start (2e): its test is
// yt_merge_test there.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  late File record;

  /// A completed download marked for its extras, its mp4 in the root
  /// unless [videoGone].
  Future<void> start({bool videoGone = false}) => h.start(
    entries: const [],
    before: (root) {
      final mp4 = File(path.join(root.path, 'Never Gonna Give You Up.mp4'));
      if (!videoGone) mp4.writeAsBytesSync([0]);
      record = writeYtRecord(
        root,
        ytEntry(root, completed: true, merged: mp4.path, extrasPending: true),
      );
    },
  );

  /// The record's mark; while the service renames a new record into place
  /// (Windows refuses a read then), still pending.
  bool pendingOnDisk() {
    try {
      return (jsonDecode(record.readAsStringSync()) as Map)['extras_pending'] ==
          true;
    } on FileSystemException {
      return true;
    }
  }

  YtDownloadEntry listed() => h.service.downloadList.single as YtDownloadEntry;

  test(
    'stage 2: listed as cached, not queued for extras, the mark kept',
    () async {
      await start();
      final e = listed();
      expect(e.extrasPending, isTrue);
      expect(h.service.extrasQueue, isEmpty);
      expect(h.service.isSavingExtras(e), isFalse);
      // what a later use of the service does with an entry it holds
      h.service.resumeExtrasForTest(e);
      expect(h.service.extrasQueue, isEmpty);
      await settle();
      expect(e.extrasPending, isTrue);
      expect(e.status, isNot(DownloadStatus.extrasWait));
      expect(pendingOnDisk(), isTrue);
      expect(h.exported, isEmpty);
    },
  );

  test('stage 2, the video gone: the mark is left too', () async {
    await start(videoGone: true);
    await settle();
    expect(listed().extrasPending, isTrue);
    expect(pendingOnDisk(), isTrue);
  });

  test('the switch on (stage 4): the list read queues it, done then', () async {
    YtDownloadPlatform.extrasEnabledForTest = true;
    await start();
    final e = listed();
    await until(() => !e.extrasPending);
    expect(e.status, DownloadStatus.completed);
    await until(() => !pendingOnDisk());
  });

  test('the switch on, the video gone: only the mark cleared', () async {
    YtDownloadPlatform.extrasEnabledForTest = true;
    await start(videoGone: true);
    final e = listed();
    await until(() => !pendingOnDisk());
    expect(e.extrasPending, isFalse);
    expect(h.service.extrasQueue, isEmpty);
  });
}
