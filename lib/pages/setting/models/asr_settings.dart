import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/pages/local_models.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: on-device transcription and translation — when each runs, and
/// the models they run with.
List<SettingsModel> get asrSettings => [
  PopupModel<AsrMode>(
    title: '自动转录',
    leading: const Icon(Icons.record_voice_over_outlined),
    value: () => Pref.asrMode,
    items: AsrMode.values,
    // a choice made here is the answer the first-use prompt would ask for
    onSelected: (value, setState) => GStorage.setting
        .putAll({
          SettingBoxKey.asrMode: value.index,
          SettingBoxKey.asrAsked: true,
        })
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
  // nothing to offer where it cannot run (see [TranslationService.supported])
  if (TranslationService.supported) ...[
    PopupModel<TranslateMode>(
      title: '自动翻译',
      leading: const Icon(Icons.translate),
      value: () => Pref.translateMode,
      items: TranslateMode.values,
      // a choice made here is the answer the first-use prompt would ask for
      onSelected: (value, setState) => GStorage.setting
          .putAll({
            SettingBoxKey.translateMode: value.index,
            SettingBoxKey.translateAsked: true,
          })
          .whenComplete(setState),
    ),
    const SwitchModel(
      title: '双语字幕',
      subtitle: '译文下方同时显示原文',
      leading: Icon(Icons.subtitles_outlined),
      setKey: SettingBoxKey.translateDual,
    ),
    NormalModel(
      title: '常驻语言',
      leading: const Icon(Icons.language),
      getSubtitle: () {
        final pinned = pinnedTranslationLanguages;
        return pinned.isEmpty
            ? '字幕菜单里除${translationLanguageLabel(AsrService.appLanguage)}外直接列出的语言：无'
            : pinned.map(translationLanguageLabel).join('、');
      },
      onTap: (context, setState) async {
        final chosen = await showDialog<List<String>>(
          context: context,
          builder: (context) => const _PinnedLanguagesDialog(),
        );
        if (chosen == null) return;
        await GStorage.setting.put(
          SettingBoxKey.translatePinnedLanguages,
          chosen,
        );
        setState();
      },
    ),
    PopupModel<TranslationModelChoice>(
      title: '翻译模型',
      leading: const Icon(Icons.model_training_outlined),
      value: () => TranslationModelChoice.of(TranslationService.to.model),
      items: TranslationModelChoice.values,
      onSelected: (value, setState) => GStorage.setting
          .put(SettingBoxKey.translateModel, value.model.id)
          .whenComplete(setState),
    ),
    NormalModel(
      title: '已下载的翻译模型',
      leading: const Icon(Icons.storage_outlined),
      getSubtitle: () {
        final used = TranslationService.to.store.installedBytes();
        return used == 0 ? '无' : '占用 ${CacheManager.formatSize(used)}，点击删除';
      },
      onTap: (context, setState) async {
        final service = TranslationService.to;
        if (service.store.installedBytes() == 0) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除已下载的翻译模型？'),
            content: const Text('需要时会重新下载。'),
            actions: [
              TextButton(onPressed: Get.back, child: const Text('取消')),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        // a running translation has the file mapped; its page hears why it ended
        await service.stop(reason: '翻译模型已删除', paused: true);
        await service.store.removeAll();
        setState();
      },
    ),
  ],
];

/// Which languages the subtitle menu lists by name, besides the app's; the
/// rest are under 其他语言.
class _PinnedLanguagesDialog extends StatefulWidget {
  const _PinnedLanguagesDialog();

  @override
  State<_PinnedLanguagesDialog> createState() => _PinnedLanguagesDialogState();
}

class _PinnedLanguagesDialogState extends State<_PinnedLanguagesDialog> {
  late final _chosen = pinnedTranslationLanguages.toSet();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('常驻语言'),
    contentPadding: const EdgeInsets.only(top: 12),
    content: SizedBox(
      width: 320,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final code in otherTranslationLanguages)
            CheckboxListTile(
              dense: true,
              value: _chosen.contains(code),
              title: Text(translationLanguageLabel(code)),
              onChanged: (value) => setState(
                () => value == true ? _chosen.add(code) : _chosen.remove(code),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: Get.back, child: const Text('取消')),
      TextButton(
        // in the order the languages are listed, not the order ticked
        onPressed: () => Get.back(
          result: [
            for (final code in otherTranslationLanguages)
              if (_chosen.contains(code)) code,
          ],
        ),
        child: const Text('确定'),
      ),
    ],
  );
}
