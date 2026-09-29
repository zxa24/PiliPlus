/// LibrePili: what the user is asked before transcription can first run:
/// whether to download the recogniser.
///
/// The models are a 240 MB download, so nothing is fetched until this asks
/// (and on mobile data it says what that costs). Whether transcription runs
/// at all is the subtitle menu's switch, remembered for every video — there
/// is no second question about doing it by itself (design 2026-09-26, 甲).
/// The same sheet offers importing files the user fetched themselves, checked
/// against the same hashes — for a flaky connection, or for a device that is
/// simply offline.
library;

import 'dart:io';

import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_download_copy.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

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
    await start();
  }

  static Future<bool?> _askForModels(
    BuildContext context,
    AsrService service,
  ) async {
    final mobileData = await ConnectivityUtils.isMobileData;
    if (!context.mounted) return null;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要先下载识别模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              modelDownloadNote(
                bytes: service.downloadSize,
                mobileData: mobileData,
              ),
            ),
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

  /// Asks before the English model is downloaded: its size (and on mobile
  /// data what that costs), what it is for, and the licence it comes under
  /// — NVIDIA's agreement has to reach whoever gets a copy. True to go
  /// ahead.
  static Future<bool> confirmEnglishModel(BuildContext context) async {
    final model = AsrModelCatalog.parakeet;
    final mobileData = await ConnectivityUtils.isMobileData;
    if (!context.mounted) return false;
    final outline = ColorScheme.of(context).outline;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载英语识别模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              modelDownloadNote(
                what: model.label,
                bytes: model.totalSize,
                mobileData: mobileData,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '英语为主的视频在确认语种后改用它识别，比默认模型更准确；'
              '识别时计算约为默认模型的 2–3 倍，多占约 0.8 GB 内存。'
              '可在设置中关闭。',
            ),
            const SizedBox(height: 8),
            Text(
              '${model.licence!.notice}。下载即表示接受该许可协议。',
              style: TextStyle(fontSize: 13, color: outline),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => showLicence(context, model),
            child: const Text('许可协议'),
          ),
          TextButton(
            onPressed: Get.back,
            child: Text('取消', style: TextStyle(color: outline)),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    return go == true;
  }

  /// The full licence [model] comes under, as shipped with the app, with
  /// the notice it requires on top.
  static Future<void> showLicence(BuildContext context, AsrModel model) async {
    final licence = model.licence;
    if (licence == null) return;
    String text;
    try {
      text = await rootBundle.loadString(licence.asset);
    } catch (_) {
      text = licence.url;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(licence.name),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText('${licence.notice}\n\n$text'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => PageUtils.launchURL(licence.url),
            child: const Text('在网页中查看'),
          ),
          TextButton(onPressed: Get.back, child: const Text('关闭')),
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
