// LibrePili: the service's extras queue (YouTube extras review 1; the
// service code is shared with bilibili): a job whose record cannot be saved
// does not stop the jobs behind it, and its record stays marked
// `extras_pending` for the next launch (c1); each queued job has its own
// cancel mark, so a key queued again after a delete does not bring the
// deleted entry's job back (l5). Driven through a fake platform
// (fake_platform.dart) on the real service.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'fake_platform.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();
  late FakePlatform fake;

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  Future<void> start() async {
    await h.start(entries: const []);
    fake = FakePlatform(h.service.hostForTest);
    h.service.addPlatformForTest(fake);
  }

  /// A completed entry of [fake] whose extras are to be saved, its video
  /// in its folder.
  FakeEntry done(String id) {
    final page = Directory(path.join(h.root.path, 'fake_$id'));
    final dir = Directory(path.join(page.path, 'main'))
      ..createSync(recursive: true);
    final mp4 = File(path.join(dir.path, 'v.mp4'))..writeAsBytesSync([0]);
    return FakeEntry(id)
      ..pageDirPath = page.path
      ..entryDirPath = dir.path
      ..isCompleted = true
      ..mergedPath = mp4.path
      ..extrasPending = true
      ..status = DownloadStatus.extrasWait;
  }

  test('a job whose record save fails: the job behind it still runs; the '
      'failed one stays marked, and leaves the queue', () async {
    await start();
    final a = done('a');
    final b = done('b');
    final releaseA = Completer<void>();
    var failSaves = false;
    fake
      ..saveGate = () {
        if (failSaves) throw const FileSystemException('disk full (test)');
        return null;
      }
      ..extrasGate = (e, _) async {
        if (e.key == a.key) {
          await releaseA.future;
        } else {
          // a's job is over, its save included
          failSaves = false;
        }
      };
    h.service
      ..extrasQueue.addAll([a, b])
      ..queueExtrasForTest(a)
      ..queueExtrasForTest(b);
    await until(() => fake.extrasKeys.length == 1, reason: "a's export");
    failSaves = true;
    releaseA.complete();
    await until(() => fake.extrasKeys.length == 2, reason: "b's export");
    await until(() => !b.extrasPending, reason: "b's record");
    await settle();
    expect(a.extrasPending, isTrue, reason: 'its record still says so');
    expect(b.extrasPending, isFalse);
    expect(h.service.extrasQueue, isEmpty);
    expect(h.service.extrasDone(a.key), isNull);
    expect(h.service.extrasDone(b.key), isNull);
  });

  test('a deleted entry downloaded again: its old job stays cancelled, the '
      'new one runs once', () async {
    await start();
    final x = done('x');
    final a = done('a');
    final releaseX = Completer<void>();
    fake.extrasGate = (e, _) async {
      if (e.key == x.key) await releaseX.future;
    };
    // x holds the queue; a waits behind it
    h.service.queueExtrasForTest(x);
    await until(() => fake.extrasKeys.length == 1, reason: "x's export");
    h.service.queueExtrasForTest(a);
    // deleted while it waits, then downloaded again and completed
    await h.service.cancelExtrasForTest(a.key);
    h.service.queueExtrasForTest(a);
    releaseX.complete();
    await until(() => fake.extrasKeys.length >= 2, reason: "a's export");
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await settle();
    expect(fake.extrasKeys, [x.key, a.key]);
  });

  test('a running job is told it is cancelled once its entry is deleted',
      () async {
    await start();
    final a = done('a');
    final seen = <bool>[];
    final inside = Completer<void>();
    final release = Completer<void>();
    fake.extrasGate = (e, cancelled) async {
      seen.add(cancelled!());
      inside.complete();
      await release.future;
      seen.add(cancelled());
    };
    h.service.queueExtrasForTest(a);
    await inside.future;
    final cancel = h.service.cancelExtrasForTest(a.key);
    release.complete();
    await cancel;
    expect(seen, [false, true]);
    // cancelled: the record is left as it was
    expect(a.extrasPending, isTrue);
  });
}
