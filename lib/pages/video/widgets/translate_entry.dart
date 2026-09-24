/// LibrePili: the subtitle-menu entry for translating a transcript, and what
/// it asks the first time.
///
/// The model is a 1–3 GB download, so nothing is fetched until this asks.
/// The download itself runs inside the translation, with its progress in
/// the menu, rather than behind a dialog the user would have to wait out.
library;

import 'dart:io';

import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// See [AsrMenuTile]: its own widget, reading only observables.
class TranslateMenuTile extends StatelessWidget {
  const TranslateMenuTile({
    super.key,
    required this.session,
    required this.onStart,
    required this.onStop,
    this.titleStyle,
  });

  final Rxn<TranslationSession> session;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => Obx(() {
    final state = session.value?.state.value;
    final running = state?.isBusy ?? false;
    final failed = state?.stage == TranslationStage.failed;
    return ListTile(
      dense: true,
      onTap: running ? onStop : onStart,
      leading: Icon(
        running
            ? Icons.stop_circle_outlined
            : (failed ? Icons.error_outline : Icons.translate),
        size: 20,
      ),
      title: Text(TranslateEntry.menuLabel(session.value), style: titleStyle),
      subtitle: switch (true) {
        _ when running && state!.message != null => Text(
          state.message!,
          style: const TextStyle(fontSize: 11),
        ),
        _ when failed && state!.message != null => Text(
          state.message!,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        _ => null,
      },
    );
  });
}

abstract final class TranslateEntry {
  /// A one-line label, for the popup where the tile does not fit.
  static String menuLabel(TranslationSession? session) {
    final state = session?.state.value;
    return switch (state?.stage) {
      TranslationStage.loading => '停止翻译（${state!.message ?? '准备模型'}）',
      TranslationStage.translating || TranslationStage.waiting => '停止翻译',
      TranslationStage.failed => '翻译失败，点击重试',
      TranslationStage.done => '重新翻译',
      _ => '翻译字幕',
    };
  }

  /// Asks what still needs asking, then [start]s. [needsTranscript] is true
  /// when no transcript exists yet, in which case the transcription's own
  /// questions come after these.
  static Future<void> startFor(
    BuildContext context,
    Future<void> Function() start, {
    required bool needsTranscript,
  }) async {
    final service = TranslationService.to;
    if (!service.modelReady) {
      final proceed = await _askForModel(context, service);
      if (proceed != true || !context.mounted) return;
    }
    if (!Pref.translateAsked) {
      await _askForMode(context);
      if (!context.mounted) return;
    }
    if (needsTranscript && !AsrService.to.modelsReady) {
      return AsrEntry.startFor(context, start);
    }
    await start();
  }

  static Future<void> _askForMode(BuildContext context) async {
    final mode = await showDialog<TranslateMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('以后自动翻译吗？'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              '翻译在本机进行，不上传任何内容；只翻译不是界面语言的字幕和语音，耗电。',
              style: TextStyle(
                fontSize: 13,
                color: ColorScheme.of(context).outline,
              ),
            ),
          ),
          for (final option in TranslateMode.values)
            SimpleDialogOption(
              onPressed: () => Get.back(result: option),
              child: Text(option.label),
            ),
        ],
      ),
    );
    GStorage.setting
      ..put(SettingBoxKey.translateAsked, true)
      ..put(SettingBoxKey.translateMode, (mode ?? TranslateMode.manual).index);
  }

  static Future<bool?> _askForModel(
    BuildContext context,
    TranslationService service,
  ) {
    final model = service.model;
    final size = CacheManager.formatSize(service.downloadSize);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要先下载翻译模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${model.label}，共 $size，只需下载一次，存在应用数据目录，可随时删除。'),
            const SizedBox(height: 8),
            Text(
              '下载在后台进行，进度显示在字幕菜单里；带 SHA-256 校验，'
              '也可以自己下载后手动导入。模型可在设置里换成体积更小的。',
              style: TextStyle(
                fontSize: 13,
                color: ColorScheme.of(context).outline,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              final imported = await _import(service);
              if (imported && service.modelReady) Get.back(result: true);
            },
            child: const Text('手动导入'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  /// See AsrEntry's import: checked against the same pinned hash.
  static Future<bool> _import(TranslationService service) async {
    try {
      final picked = await FilePicker.pickFiles();
      final path = picked.firstOrNull?.path;
      if (path == null) return false;
      SmartDialog.showLoading(msg: '校验中');
      try {
        await service.store.importFile(
          File(path),
          models: TranslationModelCatalog.all,
        );
      } finally {
        SmartDialog.dismiss();
      }
      SmartDialog.showToast('已导入');
      return true;
    } catch (e) {
      SmartDialog.showToast('$e');
      return false;
    }
  }
}
