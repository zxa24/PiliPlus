// LibrePili: the service's handle for platforms outside its library
// (`DownloadHost`, stage-2 plan §2.2, review of 2a): a save only for the
// start under way, one live transfer per start, nothing after a
// transfer's own `done`. Driven through a fake platform (fake_platform.dart)
// on the real service.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/download/download_service.dart';
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

  /// The service with no bilibili entries and [fake] registered; [entry]
  /// started and its transfer attached.
  Future<FakeEntry> started() async {
    await h.start(entries: const []);
    fake = FakePlatform(h.service.hostForTest);
    h.service.addPlatformForTest(fake);
    final entry = queueFakeEntry(h.service, h.root.path, 'a');
    h.service.startDownload(entry);
    await until(() => fake.transfers.isNotEmpty, reason: 'the transfer');
    return entry;
  }

  test('a save of a start that is over, of another object of the key, or '
      'of a folder gone: dropped', () async {
    final entry = await started();
    final gen = fake.gens.single;
    final host = h.service.hostForTest;

    await host.save(gen, entry);
    expect(fake.saves, 1);
    // another object of the same key (one read again, say)
    await host.save(gen, FakeEntry('a')..entryDirPath = entry.entryDirPath);
    expect(fake.saves, 1);

    // the folder gone (deleted under it)
    Directory(entry.entryDirPath).deleteSync(recursive: true);
    await host.save(gen, entry);
    expect(fake.saves, 1);
    Directory(entry.entryDirPath).createSync(recursive: true);

    // the start over: paused (the pause saves the record itself)
    await h.service.cancelDownload(isDelete: false, downloadNext: false);
    final afterPause = fake.saves;
    await host.save(gen, entry);
    await settle();
    expect(fake.saves, afterPause);
  });

  test('a save queued behind another is dropped when, by its turn, the '
      'folder is gone', () async {
    final entry = await started();
    final gen = fake.gens.single;
    final host = h.service.hostForTest;
    final gate = Completer<void>();
    fake.saveGate = () => gate.future;

    final first = host.save(gen, entry);
    final second = host.save(gen, entry);
    await settle();
    expect(fake.saves, 1);
    // deleted while the first is still writing
    Directory(entry.entryDirPath).deleteSync(recursive: true);
    gate.complete();
    await first.catchError((_) {});
    await second.catchError((_) {});
    await settle();
    expect(fake.saves, 1);
  });

  test('a second transfer while the first runs is refused; the first goes '
      'on', () async {
    final entry = await started();
    final gen = fake.gens.single;
    var built = 0;
    expect(
      () => h.service.hostForTest.attach(gen, entry, (_) {
        built++;
        return FakeTransfer();
      }),
      throwsA(isA<AssertionError>()),
    );
    expect(built, 0);
    // the first one's callbacks still reach the entry
    fake.reports.single.video(5, 10);
    expect(entry.downloadedBytes, 5);
    expect(
      h.log.where((l) => l.contains('a second transfer refused')),
      hasLength(1),
    );
  });

  test('after its own failed done, a transfer\'s late callbacks are dropped: '
      'the retry still comes', () async {
    DownloadService.retryWaitsForTest = const [
      Duration(milliseconds: 150),
      Duration(milliseconds: 150),
      Duration(milliseconds: 150),
    ];
    final entry = await started();
    final transfer = fake.transfers.single;
    final report = fake.reports.single;

    transfer.status = DownloadStatus.failDownload;
    report.done('broken');
    expect(entry.status, DownloadStatus.retryWait);
    // late: bytes, and a second done
    report.video(10, 100);
    report.done();
    expect(entry.status, DownloadStatus.retryWait);
    expect(entry.downloadedBytes, 0);

    await until(() => fake.resolves == 2, reason: 'the retry');
    expect(fake.transfers, hasLength(2));
  });
}
