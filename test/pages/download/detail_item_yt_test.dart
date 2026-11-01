// LibrePili: a YouTube download's row in the list (stage-2 plan §3.2;
// AC7, AC-O): the saved cover or a placeholder (nothing fetched for the
// list), the YouTube badge, the watch progress from the local history,
// and a tap on a completed one: its exported file played as a local file,
// or, when its merge failed, a toast and nothing opened.
//
// The 720p button (the failQuality case) is 2f's: its cases join this file
// then.
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
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
  final h = DownloadHarness();
  final opened = <String>[];
  final toasts = <String>[];

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
    LocalHistory.box = await Hive.openBox(
      'localHistory-yt-item',
      bytes: Uint8List(0),
    );
    await h.start(entries: const []);
    YtDownloadPlatform.openLocalForTest = (p) async {
      opened.add(p);
      return true;
    };
    YtDownloadPlatform.toastForTest = toasts.add;
  });
  tearDownAll(() async {
    await h.stop();
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
