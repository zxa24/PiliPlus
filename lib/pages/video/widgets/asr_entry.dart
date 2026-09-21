/// LibrePili: what the user sees the first time they ask for transcription.
///
/// The models are a 240 MB download, so nothing is fetched until this asks.
/// The same sheet offers importing files the user fetched themselves, checked
/// against the same hashes — for a flaky connection, or for a device that is
/// simply offline.
library;

import 'dart:io';

import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// The subtitle-menu entry. Its own widget so it can be pumped in a test:
/// the first version was an inline `Obx` that read nothing observable when no
/// transcription was running, which GetX turns into an exception — on a phone
/// it rendered as a grey error box and took the rest of the menu with it.
class AsrMenuTile extends StatelessWidget {
  const AsrMenuTile({
    super.key,
    required this.session,
    required this.onStart,
    required this.onStop,
    this.titleStyle,
  });

  final Rxn<AsrSession> session;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => Obx(() {
    final current = session.value;
    final state = current?.state.value;
    final running = state?.isBusy ?? false;
    final failed = state?.stage == AsrStage.failed;
    // a finished run used to look exactly like one that never started, which
    // is no use to the user and was no use debugging it either
    final done = state?.stage == AsrStage.done;
    final cues = done ? current!.cues.length : 0;
    return ListTile(
      dense: true,
      onTap: running ? onStop : onStart,
      leading: Icon(
        running
            ? Icons.stop_circle_outlined
            : (failed
                  ? Icons.error_outline
                  : Icons.record_voice_over_outlined),
        size: 20,
      ),
      title: Text(
        running
            ? '停止转录（${state!.label}）'
            : (failed ? '转录失败，点击重试' : '自动转录字幕'),
        style: titleStyle,
      ),
      // the reason stays on screen: a toast that has come and gone leaves the
      // user (and anyone debugging) with nothing at all
      subtitle: switch (true) {
        _ when running && state!.progress != null => LinearProgressIndicator(
          value: state.progress,
        ),
        _ when failed && state!.message != null => Text(
          state.message!,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        _ when done => Text(
          cues == 0 ? '没有识别到语音' : '已生成 $cues 条字幕，点击可重新转录',
          style: const TextStyle(fontSize: 11),
        ),
        _ => null,
      },
    );
  });
}

abstract final class AsrEntry {
  /// Asks whatever still needs asking, then starts transcription.
  static Future<void> start(
    BuildContext context,
    VideoDetailController controller,
  ) => startFor(context, controller.startAsr);

  /// The same prompts for any page that can transcribe — the bilibili video
  /// page and the YouTube one ask the user exactly the same things.
  static Future<void> startFor(
    BuildContext context,
    Future<void> Function() start,
  ) async {
    final service = AsrService.to;
    if (!service.modelsReady) {
      final proceed = await _askForModels(context, service);
      if (proceed != true || !context.mounted) return;
    }
    if (!Pref.asrAsked) {
      await _askForMode(context);
    }
    await start();
  }

  /// One-time question: should future videos without subtitles do this by
  /// themselves?
  static Future<void> _askForMode(BuildContext context) async {
    final mode = await showDialog<AsrMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('以后自动转录吗？'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              '转录在本机进行，不上传音频；耗电，联网播放时会额外下载一份音频流。',
              style: TextStyle(
                fontSize: 13,
                color: ColorScheme.of(context).outline,
              ),
            ),
          ),
          for (final option in AsrMode.values)
            SimpleDialogOption(
              onPressed: () => Get.back(result: option),
              child: Text(option.label),
            ),
        ],
      ),
    );
    GStorage.setting
      ..put(SettingBoxKey.asrAsked, true)
      ..put(SettingBoxKey.asrMode, (mode ?? AsrMode.manual).index);
  }

  static Future<bool?> _askForModels(
    BuildContext context,
    AsrService service,
  ) {
    final size = CacheManager.formatSize(service.downloadSize);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要先下载识别模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共 $size，只需下载一次，存在应用数据目录，可随时删除。'),
            const SizedBox(height: 8),
            Text(
              '${AsrModelCatalog.required.length} 个模型文件，带 SHA-256 校验；'
              '也可以自己下载后手动导入。',
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
              if (imported && service.modelsReady) Get.back(result: true);
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

  /// Takes files the user fetched elsewhere. Each is checked against the same
  /// pinned hash a download would be, so a wrong or truncated file is refused
  /// here rather than failing at model load.
  static Future<bool> _import(AsrService service) async {
    try {
      final picked = await FilePicker.pickFiles();
      final paths = [for (final file in picked) ?file.path];
      if (paths.isEmpty) return false;
      SmartDialog.showLoading(msg: '校验中');
      var count = 0;
      for (final path in paths) {
        try {
          await service.store.importFile(File(path));
          count++;
        } catch (e) {
          SmartDialog.showToast('$e');
        }
      }
      SmartDialog.dismiss();
      if (count > 0) SmartDialog.showToast('已导入 $count 个文件');
      return count > 0;
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('导入失败: $e');
      return false;
    }
  }
}
