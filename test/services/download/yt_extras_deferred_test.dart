// LibrePili: a YouTube download's extras, stage 4 (design §6, §11 stage 4;
// AC-E as stage 4 flips it, the YouTube part; the service with a platform
// whose extras are off is extras_deferred_test.dart, P2-E1..E3). Stage 2
// left completed records marked `extras_pending`; with the switch on (the
// default now) the first read of the list queues each one's extras once
// and the mark is cleared when they are done — or, its video gone, the
// mark alone is cleared. A build with the switch off (stage 2's, kept as
// `YtDownloadPlatform.extrasEnabledForTest`) leaves the mark and queues
// nothing.
//
// The completion that writes the mark is YouTube's start (2e): its test is
// yt_merge_test there. The export itself is yt_extras_test.dart's.
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

  /// A completed download marked for its extras (as stage 2 left it), its
  /// mp4 in the root unless [videoGone].
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

  test('stage 4 (the default): the list read queues a stage-2 record\'s '
      'extras once, the mark cleared when done', () async {
    expect(YtDownloadPlatform.extrasEnabledForTest, isTrue);
    await start();
    final e = listed();
    await until(() => !e.extrasPending);
    expect(e.status, DownloadStatus.completed);
    expect(h.exported, [same(e)]);
    await until(() => !pendingOnDisk());
    await settle();
    expect(h.exported, hasLength(1));
    expect(h.service.extrasQueue, isEmpty);
  });

  test('stage 4, the video gone: only the mark cleared, no export', () async {
    await start(videoGone: true);
    final e = listed();
    await until(() => !pendingOnDisk());
    expect(e.extrasPending, isFalse);
    expect(h.service.extrasQueue, isEmpty);
    expect(h.exported, isEmpty);
  });

  test('the switch off (a stage-2 build): listed as cached, not queued, the '
      'mark kept', () async {
    YtDownloadPlatform.extrasEnabledForTest = false;
    await start();
    final e = listed();
    expect(e.extrasPending, isTrue);
    expect(h.service.extrasQueue, isEmpty);
    expect(h.service.isSavingExtras(e), isFalse);
    h.service.resumeExtrasForTest(e);
    expect(h.service.extrasQueue, isEmpty);
    await settle();
    expect(e.extrasPending, isTrue);
    expect(e.status, isNot(DownloadStatus.extrasWait));
    expect(pendingOnDisk(), isTrue);
    expect(h.exported, isEmpty);
  });
}
