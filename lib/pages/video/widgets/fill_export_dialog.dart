/// LibrePili: the dialog of a save that waits for an on-device subtitle to
/// be whole (research/chunked-transcription-design-2026-09-25.md, 13) —
/// 正在补全字幕 x%, with 放到后台继续 and 取消. The flow is [FillExport].
library;

import 'dart:async';

import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/services/asr/fill_export.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class FillExportDialog {
  static const tag = 'fill-export';

  /// Saves with [save] at once when [target] has nothing missing (or there
  /// is no session to fill it); otherwise fills it first, with the dialog
  /// up, and returns the flow — the page cancels it when it goes.
  static FillExport? saveWhenWhole({
    required FillTarget? target,
    required Future<void> Function({required bool background}) save,
  }) {
    if (!FillExport.needed(target)) {
      unawaited(save(background: false));
      return null;
    }
    final flow = FillExport(target!, save: save);
    late final Worker worker;
    worker = ever<FillPhase>(flow.phase, (phase) {
      if (phase == FillPhase.filling) return;
      SmartDialog.dismiss(tag: tag);
      switch (phase) {
        case FillPhase.background:
          SmartDialog.showToast('补全后将自动保存');
          return;
        case FillPhase.failed:
          FailureReport.show(
            '字幕保存失败',
            '补全字幕时出错（${flow.failure}），字幕未保存',
          );
        case _:
          break;
      }
      worker.dispose();
    });
    flow.start();
    if (flow.phase.value == FillPhase.filling) _show(flow);
    return flow;
  }

  static void _show(FillExport flow) {
    SmartDialog.show(
      tag: tag,
      clickMaskDismiss: false,
      backType: SmartBackType.block,
      builder: (context) => AlertDialog(
        title: Obx(
          () => Text(
            '正在补全字幕 ${(flow.progress.value * 100).floor()}%',
          ),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Obx(() => LinearProgressIndicator(value: flow.progress.value)),
              const SizedBox(height: 12),
              const Text('字幕还有未生成的部分，补全后保存。'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: flow.cancel, child: const Text('取消')),
          TextButton(
            onPressed: flow.toBackground,
            child: const Text('放到后台继续'),
          ),
        ],
      ),
    );
  }
}
