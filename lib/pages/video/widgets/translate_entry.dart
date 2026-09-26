/// LibrePili: the subtitle-menu entry for translating a video's own captions
/// or a transcript, and what it asks the first time.
///
/// The model is a 1–3 GB download, so nothing is fetched until this asks.
/// The download itself runs inside the translation, with its progress in
/// the menu, rather than behind a dialog the user would have to wait out.
library;

import 'dart:io';

import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class TranslateEntry {
  /// Whether the menus offer translation at all (see
  /// [TranslationService.supported]).
  static bool get available => TranslationService.supported;

  /// Asks what still needs asking, then [start]s. [needsTranscript] is true
  /// when no transcript exists yet, in which case the transcription's own
  /// questions come after these.
  ///
  /// [start] is handed a way to ask whether it may transcribe after all:
  /// captions to translate need no transcript — unless they cannot be
  /// fetched and the page falls back to transcribing, which then asks what
  /// any start of transcription asks before it downloads anything. Scoped to
  /// this one start, so an overlapping one cannot take it away.
  static Future<void> startFor(
    BuildContext context,
    Future<void> Function({Future<bool> Function()? mayTranscribe}) start, {
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
      // asked just now, by the transcription's own questions
      return AsrEntry.startFor(
        context,
        () => start(mayTranscribe: () async => true),
      );
    }
    await start(
      mayTranscribe: () async {
        if (!context.mounted) return false;
        var proceed = false;
        await AsrEntry.startFor(context, () async => proceed = true);
        return proceed;
      },
    );
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

  /// Asks before the model is downloaded, if it is not there: for what
  /// translates without a subtitle menu (the comments). Whether to go on.
  static Future<bool> ensureModel(BuildContext context) async {
    final service = TranslationService.to;
    if (service.modelReady) return true;
    return await _askForModel(context, service) == true;
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
      final AsrModelFile file;
      try {
        file = await service.store.importFile(
          File(path),
          models: TranslationModelCatalog.all,
        );
      } finally {
        SmartDialog.dismiss();
      }
      // another model than the one selected: imported on purpose, so it is
      // the one to use — the dialog asking for the selected one would
      // otherwise just stay open
      final imported = TranslationModelCatalog.all
          .where((model) => model.files.contains(file))
          .firstOrNull;
      if (imported != null &&
          imported.id != service.model.id &&
          service.store.isInstalled(imported)) {
        await GStorage.setting.put(SettingBoxKey.translateModel, imported.id);
      }
      SmartDialog.showToast('已导入');
      return true;
    } catch (e) {
      SmartDialog.showToast('$e');
      return false;
    }
  }
}
