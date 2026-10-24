// LibrePili: the local watch progress (`watchProgress`, by cid) dropped
// with a deleted download, at each of the seven places that delete from
// the list, and kept by the 「正在缓存」 page's delete, which never dropped
// it (design feature-logs/download-platforms/design.md, §2.1 观看进度 and
// AC1 删除路径); and the search page's filter. Each deletes through the
// pages and the real service on a temporary download folder.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/controller.dart';
import 'package:PiliPlus/pages/download/detail/view.dart';
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/pages/download/downloading/view.dart';
import 'package:PiliPlus/pages/download/search/controller.dart';
import 'package:PiliPlus/pages/download/search/view.dart';
import 'package:PiliPlus/pages/download/view.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import '../../services/download/download_test_support.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));

  late BiliDownloadEntryInfo p1;
  late BiliDownloadEntryInfo p2;
  late BiliDownloadEntryInfo s;

  /// The watch progress kept for [entry] (bilibili: by cid).
  String progressKey(BiliDownloadEntryInfo entry) => '${entry.cid}';
  bool watched(BiliDownloadEntryInfo entry) =>
      GStorage.watchProgress.containsKey(progressKey(entry));

  Future<void> start({
    Map<String, Object?> Function(String entry, Map<String, dynamic> json)?
    patch,
  }) async {
    await h.start(patch: patch);
    p1 = h.entry(fixtureP1);
    p2 = h.entry(fixtureP2);
    s = h.entry(fixtureS);
    // no saved covers: a row's image still being read (its I/O waits on
    // the test's clock) would hold the file the delete removes (Windows)
    for (final e in [p1, p2, s]) {
      File(path.join(e.entryDirPath, 'cover.jpg')).deleteSync();
    }
    await GStorage.watchProgress.clear();
    await GStorage.watchProgress.putAll({
      progressKey(p1): 30000,
      progressKey(p2): 40000,
      progressKey(s): 50000,
    });
  }

  tearDown(() async {
    Get
      ..delete<DownloadSearchController>(force: true)
      ..delete<DownloadPageController>(force: true);
    await h.stop();
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: page,
        builder: FlutterSmartDialog.init(),
        navigatorObservers: [FlutterSmartDialog.observer],
      ),
    );
    // the list is read once the service's own reading is done (a future of
    // the real clock)
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  /// Lets the files and the boxes do their work (real I/O) while the
  /// widgets' clock is pumped, until [done].
  Future<void> untilDone(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'the delete to finish');
    // the loading overlay's and the dialogs' closing animations
    await tester.pump(const Duration(seconds: 1));
  }

  Finder itemOf(BiliDownloadEntryInfo entry) => find.byWidgetPredicate(
    (w) => w is DetailItem && identical(w.entry, entry),
  );

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The long-press menu's 「删除」, then 「确认」 with the exported video
  /// kept.
  Future<void> deleteByMenu(WidgetTester tester, Finder target) async {
    await tester.longPress(target);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await confirm(tester);
  }

  bool gone(BiliDownloadEntryInfo entry) =>
      !Directory(entry.entryDirPath).existsSync() &&
      !hasKey(h.service.downloadList, keyOf(entry));

  group('the cached videos page', () {
    setUp(start);

    testWidgets('1. a group of one, its row deleted', (tester) async {
      await pumpPage(tester, const DownloadPage());
      await deleteByMenu(tester, itemOf(s));
      await untilDone(tester, () => gone(s));
      expect(watched(s), isFalse);
      expect(watched(p1), isTrue);
      expect(watched(p2), isTrue);
    });

    testWidgets("2. a group's long-press 「删除」", (tester) async {
      await pumpPage(tester, const DownloadPage());
      await deleteByMenu(tester, find.text(p1.title));
      await untilDone(tester, () => gone(p1) && gone(p2));
      expect(watched(p1), isFalse);
      expect(watched(p2), isFalse);
      expect(watched(s), isTrue);
    });

    testWidgets('3. groups deleted by multi-select', (tester) async {
      await pumpPage(tester, const DownloadPage());
      final controller = Get.find<DownloadPageController>();
      final group = controller.pages.firstWhere(
        (page) => page.entries.any((e) => identical(e, p1)),
      );
      controller
        ..enableMultiSelect.value = true
        ..onSelect(group);
      await tester.pump();
      unawaited(controller.onRemove());
      await tester.pumpAndSettle();
      await confirm(tester);
      await untilDone(tester, () => gone(p1) && gone(p2));
      expect(watched(p1), isFalse);
      expect(watched(p2), isFalse);
      expect(watched(s), isTrue);
    });
  });

  group("a group's page", () {
    setUp(start);

    Future<void> pumpGroup(WidgetTester tester) async {
      Get.put(DownloadPageController());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pumpPage(
        tester,
        DownloadDetailPage(
          pageId: p1.pageId,
          title: p1.title,
          progress: ChangeNotifier(),
        ),
      );
    }

    testWidgets('4. one of its entries deleted', (tester) async {
      await pumpGroup(tester);
      await deleteByMenu(tester, itemOf(p1));
      await untilDone(tester, () => gone(p1));
      expect(watched(p1), isFalse);
      expect(watched(p2), isTrue);
      expect(watched(s), isTrue);
    });

    testWidgets('5. entries deleted by multi-select', (tester) async {
      await pumpGroup(tester);
      (tester.state(find.byType(DownloadDetailPage)) as BaseMultiSelectMixin)
        ..enableMultiSelect.value = true
        ..onSelect(p1)
        ..onRemove();
      await tester.pumpAndSettle();
      await confirm(tester);
      await untilDone(tester, () => gone(p1));
      expect(watched(p1), isFalse);
      expect(watched(p2), isTrue);
      expect(watched(s), isTrue);
    });
  });

  group('the search page', () {
    setUp(start);

    Future<DownloadSearchController> pumpSearch(WidgetTester tester) async {
      await pumpPage(tester, DownloadSearchPage(progress: ChangeNotifier()));
      final controller = Get.find<DownloadSearchController>();
      controller.editController.text = '夹具';
      unawaited(controller.onRefresh());
      await tester.pump();
      await tester.pump();
      expect(itemOf(p1), findsOneWidget);
      return controller;
    }

    testWidgets('6. one result deleted', (tester) async {
      await pumpSearch(tester);
      await deleteByMenu(tester, itemOf(p1));
      await untilDone(tester, () => gone(p1));
      expect(watched(p1), isFalse);
      expect(watched(p2), isTrue);
      expect(watched(s), isTrue);
    });

    testWidgets('7. results deleted by multi-select', (tester) async {
      final controller = await pumpSearch(tester);
      controller
        ..enableMultiSelect.value = true
        ..onSelect(p1);
      await tester.pump();
      unawaited(controller.onRemove());
      await tester.pumpAndSettle();
      await confirm(tester);
      await untilDone(tester, () => gone(p1));
      expect(watched(p1), isFalse);
      expect(watched(p2), isTrue);
      expect(watched(s), isTrue);
    });
  });

  group('the downloading page', () {
    setUp(
      () => start(
        patch: (entry, json) => {
          ...json,
          'is_completed': false,
          'downloaded_bytes': 0,
        },
      ),
    );

    testWidgets('its multi-select delete leaves the watch progress alone', (
      tester,
    ) async {
      await pumpPage(tester, const DownloadingPage());
      (tester.state(find.byType(DownloadingPage)) as BaseMultiSelectMixin)
        ..enableMultiSelect.value = true
        ..onSelect(p1)
        ..onRemove();
      await tester.pumpAndSettle();
      await confirm(tester);
      await untilDone(
        tester,
        () =>
            !Directory(p1.entryDirPath).existsSync() &&
            !hasKey(h.service.waitDownloadQueue, keyOf(p1)),
      );
      expect(watched(p1), isTrue);
      expect(hasKey(h.service.waitDownloadQueue, keyOf(p2)), isTrue);
    });
  });

  group('the search filter', () {
    // one field each holds the word, in another case than asked
    setUp(
      () => h.start(
        entries: const [fixtureP1, fixtureP2, fixtureS, fixtureOfficial],
        patch: (entry, json) => switch (entry) {
          fixtureP1 => {...json, 'title': 'In the TITLE: KEYWORD'},
          fixtureP2 => {
            ...json,
            'title': 'second',
            'page_data': {
              ...json['page_data'] as Map,
              'part': 'part with keyword',
            },
          },
          fixtureS => {...json, 'owner_name': 'KeyWord 的频道'},
          _ => json,
        },
      ),
    );

    testWidgets('title, shown title and uploader, in the list order', (
      tester,
    ) async {
      final controller = Get.put(DownloadSearchController());
      final list = h.service.downloadList;
      final matching = [
        for (final e in list)
          if (!identical(e, h.entry(fixtureOfficial))) e,
      ];
      expect(matching, hasLength(3));

      controller.editController.text = 'kEYword';
      final found = (await controller.customGetData()).data;
      expect(found.length, 3);
      for (final (i, e) in found.indexed) {
        expect(identical(e, matching[i]), isTrue);
      }

      controller.editController.text = '';
      final all = (await controller.customGetData()).data;
      expect(all.length, list.length);
    });
  });
}
