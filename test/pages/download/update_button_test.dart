// LibrePili: the multi-select 「更新」 (bilibili's danmaku fetched again) on
// the cache, search and group pages (stage-2 plan §3.2, p1w#4): hidden
// while what is selected holds no bilibili entry, shown when one is in it
// and — as before stage 2 — when nothing is selected yet. The three pages
// put their button in DanmakuUpdateAction; this follows it as the
// selection changes.
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/update_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/download/download_test_support.dart';
import '../../services/download/yt_download_test_support.dart';

class _Select implements MultiSelectBase<MultiSelectData> {
  @override
  final enableMultiSelect = true.obs;
  final count = 0.obs;
  @override
  int get checkedCount => count.value;
  @override
  void onSelect(MultiSelectData item) {}
  @override
  void handleSelect({bool checked = false, bool disableSelect = true}) {}
  @override
  void onRemove() {}
}

void main() {
  final bili = fixtureEntry(recordFixtures, recordUgc);
  final yt = ytEntry(Directory('download'));

  test('the rule', () {
    expect(showDanmakuUpdate(const []), isTrue);
    expect(showDanmakuUpdate([bili]), isTrue);
    expect(showDanmakuUpdate([yt, bili]), isTrue);
    expect(showDanmakuUpdate([yt]), isFalse);
  });

  testWidgets('follows the selection', (tester) async {
    final select = _Select();
    var checked = <DownloadEntry>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              DanmakuUpdateAction(
                ctr: select,
                checked: () => checked,
                child: TextButton(onPressed: () {}, child: const Text('更新')),
              ),
            ],
          ),
        ),
      ),
    );
    final button = find.text('更新');
    // nothing selected yet: as before
    expect(button, findsOneWidget);

    checked = [yt];
    select.count.value = 1;
    await tester.pump();
    expect(button, findsNothing);

    checked = [yt, bili];
    select.count.value = 2;
    await tester.pump();
    expect(button, findsOneWidget);

    checked = [];
    select.count.value = 0;
    await tester.pump();
    expect(button, findsOneWidget);
  });
}
