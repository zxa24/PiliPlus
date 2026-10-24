// LibrePili: one row of the download list as the user sees it (design
// feature-logs/download-platforms/design.md, AC1 列表界面): the watch
// progress badge, the quality badge, the saved or the network cover and
// how it is decoded, the title lines, the long-press menu, the 「更多」
// button, and the badge redrawn after the offline page is left. The self
// tests do not look at any of it.
//
// Values sit near the edges the code draws: 「已看完」 from 400 ms before
// the end (one at 200 ms before, one at 1000 ms before); the quality
// downloaded differs from the one asked for.
import 'dart:io';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/download/download_test_support.dart';

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

class _Progress extends ChangeNotifier {
  void tell() => notifyListeners();
}

/// The offline page: gone again as soon as it is shown.
class _BackAtOnce extends StatefulWidget {
  const _BackAtOnce();

  static var shown = 0;

  @override
  State<_BackAtOnce> createState() => _BackAtOnceState();
}

class _BackAtOnceState extends State<_BackAtOnce> {
  @override
  void initState() {
    super.initState();
    _BackAtOnce.shown++;
    WidgetsBinding.instance.addPostFrameCallback((_) => Get.back());
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
    await h.start(entries: const []);
  });
  tearDownAll(() async {
    await h.stop();
    await closeDownloadStorage(storage);
  });

  // the ugc one has no cover.jpg beside it, the bangumi one has
  final ugc = fixtureEntry(recordFixtures, recordUgc);
  final pgc = fixtureEntry(recordFixtures, recordPgc);

  Future<void> watched(WidgetTester tester, Map<String, int> positions) =>
      tester.runAsync(() async {
        await GStorage.watchProgress.clear();
        await GStorage.watchProgress.putAll(positions);
      });

  Future<_Progress> pumpItems(
    WidgetTester tester, {
    bool showTitle = true,
  }) async {
    final progress = _Progress();
    final select = _Select();
    await tester.pumpWidget(
      GetMaterialApp(
        getPages: [GetPage(name: '/videoV', page: () => const _BackAtOnce())],
        home: Scaffold(
          body: Column(
            children: [
              for (final entry in [ugc, pgc])
                SizedBox(
                  height: 110,
                  width: 600,
                  child: DetailItem(
                    entry: entry,
                    progress: progress,
                    downloadService: h.service,
                    onDelete: (_) {},
                    showTitle: showTitle,
                    controller: select,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return progress;
  }

  /// An image read from a `cover.jpg` file.
  final savedCover = find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is ResizeImage &&
        (w.image as ResizeImage).imageProvider is FileImage,
  );

  Finder inItem(BiliDownloadEntryInfo entry, Finder finder) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is DetailItem && identical(w.entry, entry),
    ),
    matching: finder,
  );

  Text textOf(WidgetTester tester, BiliDownloadEntryInfo entry, String text) =>
      tester.widget<Text>(inItem(entry, find.text(text)));

  testWidgets('the watch progress: 「已看完」 near the end, the position '
      'otherwise; redrawn when told', (tester) async {
    await watched(tester, {
      '${ugc.cid}': ugc.totalTimeMilli - 200,
      '${pgc.cid}': pgc.totalTimeMilli - 1000,
    });
    final progress = await pumpItems(tester);
    expect(inItem(ugc, find.text('已看完')), findsOneWidget);
    // 1419 s of 1420 s
    expect(inItem(pgc, find.text('23:39/23:40')), findsOneWidget);
    expect(inItem(pgc, find.text('已看完')), findsNothing);

    await watched(tester, {'${ugc.cid}': 60000});
    progress.tell();
    await tester.pump();
    expect(inItem(ugc, find.text('01:00/02:05')), findsOneWidget);
    expect(inItem(ugc, find.text('已看完')), findsNothing);
    // none kept: the length alone
    expect(inItem(pgc, find.text('23:40')), findsOneWidget);
  });

  testWidgets('the quality badge is the one downloaded', (tester) async {
    await watched(tester, {});
    await pumpItems(tester);
    // video_quality 80, prefered_video_quality 112
    expect(inItem(ugc, find.text('1080P')), findsOneWidget);
    expect(inItem(ugc, find.text('1080P+')), findsNothing);
    expect(inItem(pgc, find.text('720P')), findsOneWidget);
  });

  testWidgets('the saved cover from the disk, else the network one; '
      'decoded by height for a landscape video', (tester) async {
    await watched(tester, {});
    await pumpItems(tester);
    // ugc: no cover.jpg
    final network = tester.widget<NetworkImgLayer>(
      inItem(ugc, find.byType(NetworkImgLayer)),
    );
    expect(network.src, ugc.cover);
    expect(network.cacheWidth, isFalse);
    expect(inItem(ugc, savedCover), findsNothing);
    // pgc: its cover.jpg
    expect(inItem(pgc, find.byType(NetworkImgLayer)), findsNothing);
    final image = tester.widget<Image>(inItem(pgc, savedCover));
    final resize = image.image as ResizeImage;
    expect(
      (resize.imageProvider as FileImage).file.path,
      endsWith('cover.jpg'),
    );
    expect(resize.width, isNull);
    expect(resize.height, isNotNull);
  });

  testWidgets('the title lines', (tester) async {
    await watched(tester, {});
    await pumpItems(tester);
    // ugc: the video's title, then its part on a line of its own
    expect(textOf(tester, ugc, ugc.title).maxLines, 2);
    expect(textOf(tester, ugc, ugc.pageData!.part!).maxLines, 1);
    // bangumi: the series on one line, then the episode
    expect(textOf(tester, pgc, pgc.title).maxLines, 1);
    expect(textOf(tester, pgc, pgc.ep!.showTitle!).maxLines, 2);

    // in a group's page: the part alone, on two lines
    await pumpItems(tester, showTitle: false);
    expect(textOf(tester, ugc, ugc.pageData!.part!).maxLines, 2);
    expect(inItem(ugc, find.text(ugc.title)), findsNothing);
  });

  testWidgets('the long-press menu and the 「更多」 button', (tester) async {
    await watched(tester, {});
    await pumpItems(tester);
    expect(inItem(ugc, find.byIcon(Icons.more_vert_outlined)), findsOneWidget);
    expect(inItem(pgc, find.byIcon(Icons.more_vert_outlined)), findsOneWidget);

    await tester.longPress(
      find.byWidgetPredicate(
        (w) => w is DetailItem && identical(w.entry, ugc),
      ),
    );
    await tester.pumpAndSettle();
    final menu = find.byType(SimpleDialog);
    expect(menu, findsOneWidget);
    expect(
      tester
          .widgetList<Text>(
            find.descendant(of: menu, matching: find.byType(Text)),
          )
          .map((t) => t.data),
      ['删除', '更新弹幕'],
    );
  });

  testWidgets('back from the offline page, the badge is redrawn 400 ms '
      'later', (tester) async {
    await watched(tester, {});
    final progress = await pumpItems(tester);
    var told = 0;
    progress.addListener(() => told++);
    final shown = _BackAtOnce.shown;

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is DetailItem && identical(w.entry, ugc),
      ),
    );
    // until the offline page has come and gone
    for (var i = 0; i < 100 && Get.currentRoute != '/'; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    for (var i = 0; i < 100 && _BackAtOnce.shown == shown; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(_BackAtOnce.shown, shown + 1);
    for (var i = 0; i < 100 && Get.currentRoute != '/'; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(told, 0);
    await tester.pump(const Duration(milliseconds: 390));
    expect(told, 0);
    await tester.pump(const Duration(milliseconds: 20));
    expect(told, 1);
    await tester.pumpAndSettle();
  });
}
