// LibrePili: a platform whose extras are not saved yet (`extrasEnabled`
// false, stage-2 plan §2.5 — YouTube's in stage 2): its completed download
// keeps `extras_pending` for a later build, is never listed as saving
// extras, and a read of the list does not queue them; once the platform
// saves extras, the same entry gets its job once. Driven through a fake
// platform (fake_platform.dart) on the real service.
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';
import 'fake_platform.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();
  late FakePlatform fake;

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  /// [fake] (extras off) with one entry downloaded to its end.
  Future<FakeEntry> completed() async {
    await h.start(entries: const []);
    fake = FakePlatform(h.service.hostForTest)..extrasOn = false;
    h.service.addPlatformForTest(fake);
    final entry = queueFakeEntry(h.service, h.root.path, 'a');
    var listedSaving = false;
    h.service.extrasQueue.listen((list) {
      if (list.any((e) => e.key == entry.key)) listedSaving = true;
    });
    h.service.startDownload(entry);
    await until(() => fake.transfers.isNotEmpty, reason: 'the transfer');
    fake.reports.single.video(100, 100);
    fake.reports.single.videoDone();
    fake.reports.single.audio(10, 10);
    fake.transfers.single.status = DownloadStatus.completed;
    fake.reports.single.done();
    await until(
      () => h.service.downloadList.contains(entry),
      reason: 'the completion',
    );
    await settle();
    expect(listedSaving, isFalse, reason: 'never listed as saving extras');
    return entry;
  }

  test('completed: extras pending kept, never queued nor listed as saving '
      'them', () async {
    final entry = await completed();
    expect(entry.isCompleted, isTrue);
    expect(entry.extrasPending, isTrue);
    expect(fake.extrasCalls, 0);
    expect(h.service.extrasQueue, isEmpty);
    expect(h.service.isSavingExtras(entry), isFalse);
    expect(h.service.extrasDone(entry.key), isNull);
  });

  test('the record says its extras are pending; once the platform saves '
      'extras, a read of the list queues them once', () async {
    final entry = await completed();
    expect(fake.savedExtrasPending.last, isTrue);
    expect(File(entry.mergedPath!).existsSync(), isTrue);

    // a read of the list while extras are off: nothing
    h.service.resumeExtrasForTest(entry);
    await settle();
    expect(fake.extrasCalls, 0);
    expect(h.service.extrasQueue, isEmpty);

    // a later build (extras on): the same entry gets its job, once
    fake.extrasOn = true;
    h.service.resumeExtrasForTest(entry);
    await until(() => fake.extrasCalls == 1, reason: 'the extras job');
    await settle();
    expect(fake.extrasCalls, 1);
    expect(entry.extrasPending, isFalse);
  });

  test('a read of the list while extras are off holds nothing for later '
      'either', () async {
    final entry = await completed();
    h.service.resumeExtrasForTest(entry);
    await settle();
    expect(fake.extrasCalls, 0);
    expect(h.service.extrasQueue, isEmpty);
    expect(fake.savedExtrasPending.last, isTrue);
  });
}
