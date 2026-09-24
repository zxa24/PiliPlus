/// LibrePili: the subtitle menu's on-device part, shared by the bilibili
/// and YouTube pages. It names subtitles by language — 原文（端侧）,
/// 中文（端侧）, the languages kept in the menu, 其他语言… — rather than
/// offering to transcribe or translate: picking one shows it, making it
/// first if need be.
library;

import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/pages/setting/common_setting.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class OnDeviceMenu {
  /// Popup values no subtitle index can take.
  static const original = -100;
  static const other = -98;
  static const stop = -97;

  static const _languageBase = -1000;

  /// Every language that can be translated into, the app's first.
  static List<String> get _languages => [
    AsrService.appLanguage,
    ...translationLanguageNames.keys.where(
      (code) => !AsrService.isSameMajorLanguage(code, AsrService.appLanguage),
    ),
  ];

  static int valueOf(String code) =>
      _languageBase - _languages.indexOf(code).clamp(0, 999);

  /// The menu value of the on-device subtitle [picked] (`asr` or a
  /// language), for the popup's selection.
  static int? valueOfPicked(String? picked) => switch (picked) {
    null => null,
    'asr' => original,
    final code => valueOf(code),
  };

  /// The languages listed by name: the app's, those kept in the menu, and
  /// [current] — the one picked or being made — when it is neither.
  static List<String> listed(String? current) => [
    AsrService.appLanguage,
    ...pinnedTranslationLanguages,
    if (current != null &&
        current != 'asr' &&
        current != AsrService.appLanguage &&
        !pinnedTranslationLanguages.contains(current))
      current,
  ];

  /// [label] with [status] after it, as the menu shows it.
  static String itemLabel(String label, String? status) =>
      status == null ? label : '$label · $status';

  /// Asks which of the other languages to show; the last entry opens the
  /// settings where languages are kept in the menu. Null when dismissed or
  /// sent to the settings.
  static Future<String?> pickOther(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('其他语言'),
        children: [
          for (final code in otherTranslationLanguages)
            SimpleDialogOption(
              onPressed: () => Get.back(result: code),
              child: Text(onDeviceLabel(code)),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Get.back(result: _settings),
            child: const Text('设置常驻语言…'),
          ),
        ],
      ),
    );
    if (picked == _settings) {
      await Get.to(
        () => const CommonSetting(settingType: SettingType.asrSetting),
      );
      return null;
    }
    return picked;
  }

  static const _settings = '#settings';
}
