// LibrePili: a YouTube download's row in the list (stage-2 plan §3.2;
// AC7, AC-O): the saved cover or a placeholder (nothing fetched for the
// list), the YouTube badge, the watch progress from the local history,
// and a tap on a completed one: its exported file played as a local file,
// or, when its merge failed, a toast and nothing opened. 2f: the 720p
// button on a download whose tier is not on offer and whose retries are
// spent (§4.2, AC-Q ③ ④): its tap switches the record to the 720 tier and
// starts it; a record that cannot be saved leaves the entry as it was.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import '../../services/download/download_test_support.dart';
import '../../services/download/yt_download_test_support.dart';

class _Select implements MultiSelectBase<MultiSelectData> {
  @override
  final enableMultiSelect = false.obs;
  @override
  int get checkedCount => 0;
  @override
  void onSelect(MultiSelectData item) {}
  @override
  void handleSelect({bool checked = false, bool disableSelect = true}) {}
  @override
  void onRemove() {}
}

class _Progress extends ChangeNotifier {}

void main() {
  late Directory storage;
  // the service with YouTube's entrances set: a restart (the 720p button)
  // resolves and transfers offline
  final y = YtHarness();
  late DownloadHarness h;
  final opened = <String>[];
  final toasts = <String>[];

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
    LocalHistory.box = await Hive.openBox(
      'localHistory-yt-item',
      bytes: Uint8List(0),
    );
    h = y.base;
    await y.start();
    DetailItem.toastForTest = toasts.add;
    YtDownloadPlatform.openLocalForTest = (p) async {
      opened.add(p);
      return true;
    };
    YtDownloadPlatform.toastForTest = toasts.add;
  });
  tearDownAll(() async {
    DetailItem.toastForTest = null;
    await y.stop();
    await closeDownloadStorage(storage);
  });
  setUp(() async {
    opened.clear();
    toasts.clear();
    await LocalHistory.box.clear();
  });

  /// A completed download in the harness's root; its cover saved when
  /// [cover], its mp4 there unless [merged] is null.
  YtDownloadEntry completed({bool cover = false, bool merged = true}) {
    final e = ytEntry(h.root, completed: true);
    Directory(e.entryDirPath).createSync(recursive: true);
    final coverFile = File(path.join(e.entryDirPath, 'cover.jpg'));
    if (cover) {
      coverFile.writeAsBytesSync(_png);
    } else if (coverFile.existsSync()) {
      coverFile.deleteSync();
    }
    if (merged) {
      final mp4 = File(path.join(h.root.path, 'Never Gonna Give You Up.mp4'))
        ..writeAsBytesSync([0]);
      e.mergedPath = mp4.path;
    }
    return e;
  }

  Future<void> pump(WidgetTester tester, YtDownloadEntry entry) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 110,
            width: 600,
            child: DetailItem(
              entry: entry,
              progress: _Progress(),
              downloadService: h.service,
              onDelete: (_) {},
              showTitle: true,
              controller: _Select(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> watched(WidgetTester tester, int progress) => tester.runAsync(
    () => LocalHistory.record(
      const LocalWatchVisit(
        key: 'yt$ytId',
        platform: LocalHistoryPlatform.yt,
        ytId: ytId,
        title: 'Never Gonna Give You Up',
        partId: LocalHistory.ytPart,
      ),
      progress: progress,
      duration: 213000,
    ),
  );

  testWidgets('no cover.jpg: a placeholder, nothing fetched; the YouTube '
      'badge', (tester) async {
    await pump(tester, completed());
    final images = tester.widgetList<NetworkImgLayer>(
      find.byType(NetworkImgLayer),
    );
    expect(images, hasLength(1));
    expect(images.single.src, '');
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('360p'), findsOneWidget);
  });

  testWidgets('cover.jpg saved: read from the file', (tester) async {
    await pump(tester, completed(cover: true));
    expect(find.byType(NetworkImgLayer), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is ResizeImage &&
            (w.image as ResizeImage).imageProvider is FileImage,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the watch progress: from the local history', (tester) async {
    // 600 ms before the end: finished (within 1000 ms) — not a resume point
    await watched(tester, 213000 - 600);
    await pump(tester, completed());
    expect(find.text('已看完'), findsOneWidget);

    await watched(tester, 106000);
    await pump(tester, completed());
    expect(find.text('01:46/03:33'), findsOneWidget);
    expect(find.text('已看完'), findsNothing);
  });

  // review 2bc (P2-L2 changed): the position is the history's own, not the
  // resume point — which is null under one second (and when finished)
  testWidgets('a start under a second: its own position, not finished', (
    tester,
  ) async {
    await watched(tester, 600);
    final e = completed();
    expect(h.service.platformOf(e).progressOf(e), (
      positionMs: 600,
      finished: false,
    ));
  });

  testWidgets('never watched: no progress badge', (tester) async {
    await pump(tester, completed());
    expect(find.text('已看完'), findsNothing);
    expect(find.textContaining('/03:33'), findsNothing);
  });

  testWidgets('a tap: its exported file, as a local file', (tester) async {
    final e = completed();
    await pump(tester, e);
    await tester.tap(find.byType(DetailItem));
    await tester.pump();
    expect(opened, [e.mergedPath]);
    expect(toasts, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('its merge failed: a toast, nothing opened', (tester) async {
    await pump(tester, completed(merged: false));
    await tester.tap(find.byType(DetailItem));
    await tester.pump();
    expect(opened, isEmpty);
    expect(toasts, ['该视频合并失败，无法播放']);
    expect(Get.currentRoute, '/');
    await tester.pump(const Duration(milliseconds: 500));
  });

  group('「切换为下载 720p」', () {
    /// A download at the 1080 tier, failed as [status] ([gaveUp]: its
    /// retries spent), its record on disk, in the queue.
    YtDownloadEntry failed(DownloadStatus status, {bool gaveUp = true}) {
      final e = ytEntry(h.root, maxHeight: 1080)
        ..streamTag = '137-140'
        ..quality = '1080p';
      writeYtRecord(h.root, e);
      e
        ..status = status
        ..gaveUp = gaveUp;
      h.service.waitDownloadQueue.add(e);
      return e;
    }

    Future<void> remove(WidgetTester tester, YtDownloadEntry e) =>
        tester.runAsync(
          () => h.service.deleteDownload(
            entry: e,
            removeList: true,
            removeQueue: true,
            deleteExported: true,
          ),
        );

    testWidgets('failQuality, retries spent: the button', (tester) async {
      final e = failed(DownloadStatus.failQuality);
      await pump(tester, e);
      expect(find.text('切换为下载 720p'), findsOneWidget);
      await remove(tester, e);
    });

    testWidgets('another failure: no button', (tester) async {
      final e = failed(DownloadStatus.failDownload);
      await pump(tester, e);
      expect(find.text('切换为下载 720p'), findsNothing);
      await remove(tester, e);
    });

    testWidgets('failQuality, retries not spent: no button', (tester) async {
      final e = failed(DownloadStatus.failQuality, gaveUp: false);
      await pump(tester, e);
      expect(find.text('切换为下载 720p'), findsNothing);
      await remove(tester, e);
    });

    testWidgets('it shows once the retries are spent', (tester) async {
      final e = failed(DownloadStatus.failQuality, gaveUp: false);
      await pump(tester, e);
      expect(find.text('切换为下载 720p'), findsNothing);
      e.gaveUp = true;
      e.progress.statusChanged();
      await tester.pump();
      expect(find.text('切换为下载 720p'), findsOneWidget);
      await remove(tester, e);
    });

    testWidgets(
      'the retries spent by the service itself: the button shows (the row '
      'hears it)',
      (tester) async {
        final e = failed(DownloadStatus.wait, gaveUp: false)..streamTag = null;
        // neither source has the 1080 tier
        final keep = y.direct.formats;
        for (final s in [y.direct, y.invidious]) {
          s.formats = [
            for (final f in keep)
              if (f['itag'] != 137) f,
          ];
        }
        DownloadService.retryWaitsForTest = const [
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ];
        try {
          await pump(tester, e);
          expect(find.text('切换为下载 720p'), findsNothing);
          await tester.runAsync(() async {
            unawaited(h.service.startDownload(e));
            await until(
              () => e.gaveUp && e.status == DownloadStatus.failQuality,
              reason: 'its retries spent',
            );
          });
          await tester.pump();
          expect(find.text('切换为下载 720p'), findsOneWidget);
        } finally {
          DownloadService.retryWaitsForTest = null;
          for (final s in [y.direct, y.invidious]) {
            s.formats = keep;
          }
        }
        await remove(tester, e);
      },
    );

    testWidgets(
      'a tap: the record at the 720 tier, no stream folder, then started',
      (tester) async {
        final e = failed(DownloadStatus.failQuality);
        await pump(tester, e);
        await tester.runAsync(() async {
          await tester.tap(find.text('切换为下载 720p'));
          await y.untilStatus(e);
        });
        expect(e.maxHeight, 720);
        expect(toasts, isEmpty);
        final record = await tester.runAsync(() => y.record(e));
        expect(record!['max_height'], 720);
        // the 720 tier's pair (§4.5), in a new folder
        expect(record['stream_tag'], '136-140');
        await remove(tester, e);
      },
    );

    testWidgets(
      'a record that cannot be saved: the entry as it was, a toast, not '
      'started',
      (tester) async {
        final e = failed(DownloadStatus.failQuality);
        await pump(tester, e);
        await tester.runAsync(() async {
          await IOOverrides.runWithIOOverrides(
            () => tester.tap(find.text('切换为下载 720p')),
            _NoSave(),
          );
          await until(() => toasts.isNotEmpty, reason: 'its toast');
        });
        expect(toasts, ['下载记录保存失败，未重新开始']);
        expect(
          (e.maxHeight, e.streamTag, e.quality),
          (
            1080,
            '137-140',
            '1080p',
          ),
        );
        expect(e.status, DownloadStatus.failQuality);
        final record = await tester.runAsync(() => y.record(e));
        expect(record!['max_height'], 1080);
        await remove(tester, e);
      },
    );
  });
}

/// Every record written in its zone fails.
final class _NoSave extends IOOverrides {
  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return file.endsWith('${YtDownloadEntry.recordFile}.tmp')
        ? _FailingFile(made)
        : made;
  }
}

class _FailingFile implements File {
  _FailingFile(this._file);

  final File _file;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async => throw FileSystemException('no room', _file.path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A 1x1 PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
