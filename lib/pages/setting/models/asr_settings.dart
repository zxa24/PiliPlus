import 'dart:io';

import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: on-device transcription — when it runs, and the models it runs
/// with.
List<SettingsModel> get asrSettings => [
  PopupModel<AsrMode>(
    title: '自动转录',
    leading: const Icon(Icons.record_voice_over_outlined),
    value: () => Pref.asrMode,
    items: AsrMode.values,
    onSelected: (value, setState) => GStorage.setting
        .put(SettingBoxKey.asrMode, value.index)
        .whenComplete(setState),
  ),
  NormalModel(
    title: '识别模型',
    leading: const Icon(Icons.storage_outlined),
    getSubtitle: () {
      final service = AsrService.to;
      final used = service.store.installedBytes();
      if (service.modelsReady) {
        return '已就绪，占用 ${CacheManager.formatSize(used)}';
      }
      final missing = service.downloadSize;
      return '未下载，需 ${CacheManager.formatSize(missing)}'
          '${used > 0 ? '（已下载 ${CacheManager.formatSize(used)}）' : ''}';
    },
    onTap: _manageModels,
  ),
];

Future<void> _manageModels(BuildContext context, VoidCallback setState) async {
  final service = AsrService.to;
  await showDialog<void>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('识别模型'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            '存放在应用数据目录，删除后需要重新下载。'
            '两个下载源都在 github.com，下不动时可以自己下载后手动导入，'
            '导入同样要通过 SHA-256 校验。',
            style: TextStyle(
              fontSize: 13,
              color: ColorScheme.of(context).outline,
            ),
          ),
        ),
        for (final model in AsrModelCatalog.required)
          ListTile(
            dense: true,
            title: Text(model.label),
            subtitle: Text(
              '${CacheManager.formatSize(model.totalSize)} · '
              '${service.store.isInstalled(model) ? "已安装" : "未安装"}',
            ),
            trailing: service.store.isInstalled(model)
                ? IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await service.store.remove(model);
                      setState();
                      Get.back();
                    },
                  )
                : null,
          ),
        const Divider(height: 1),
        SimpleDialogOption(
          onPressed: () async {
            Get.back();
            await _import(service);
            setState();
          },
          child: const Text('手动导入模型文件'),
        ),
        SimpleDialogOption(
          onPressed: () async {
            Get.back();
            await _copyUrls();
          },
          child: const Text('复制下载地址'),
        ),
      ],
    ),
  );
  setState();
}

Future<void> _copyUrls() async {
  final urls = [
    for (final model in AsrModelCatalog.required)
      for (final file in model.files) file.sources.first.url,
  ];
  await Utils.copyText(
    urls.join('\n'),
    toastText: '已复制 ${urls.length} 个地址',
  );
}

Future<void> _import(AsrService service) async {
  try {
    final picked = await FilePicker.pickFiles();
    final paths = [for (final file in picked) ?file.path];
    if (paths.isEmpty) return;
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
    SmartDialog.showToast(count > 0 ? '已导入 $count 个文件' : '没有可用的文件');
  } catch (e) {
    SmartDialog.dismiss();
    SmartDialog.showToast('导入失败: $e');
  }
}
