import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: whether the multi-select 「更新」 (the danmaku fetched again)
/// is shown for [checked]. It updates bilibili's entries only, so it is
/// hidden while something is selected and none of it is bilibili's; with
/// nothing selected it is shown, as before (stage-2 plan §3.2, p1w#4).
bool showDanmakuUpdate(Iterable<DownloadEntry> checked) =>
    checked.isEmpty || checked.any((e) => e is BiliDownloadEntryInfo);

/// [child] (the 「更新」 button) while [showDanmakuUpdate] holds for
/// [checked], rebuilt as [ctr]'s selection changes.
class DanmakuUpdateAction extends StatelessWidget {
  const DanmakuUpdateAction({
    super.key,
    required this.ctr,
    required this.checked,
    required this.child,
  });

  final MultiSelectBase ctr;
  final Iterable<DownloadEntry> Function() checked;
  final Widget child;

  @override
  Widget build(BuildContext context) => Obx(() {
    // read for Obx: the selection count changes with every check
    ctr.checkedCount;
    return showDanmakuUpdate(checked()) ? child : const SizedBox.shrink();
  });
}
