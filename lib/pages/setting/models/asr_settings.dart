import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/pages/local_models.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
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
      return service.modelsReady
          ? '已就绪，占用 ${CacheManager.formatSize(used)}'
          : '未下载，需 ${CacheManager.formatSize(service.downloadSize)}';
    },
    // one place manages the models; this is a shortcut to it
    onTap: (context, setState) =>
        Get.to(() => const LocalModelsPage())?.whenComplete(setState),
  ),
];

