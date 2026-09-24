/// LibrePili: the languages on-device translation offers, as the subtitle
/// menu and the settings name them.
library;

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// What each language is called in the menus.
const translationLanguageLabels = {
  'zh': '中文',
  'zh-Hant': '繁体中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
  'pt': '葡萄牙语',
  'it': '意大利语',
  'ru': '俄语',
  'ar': '阿拉伯语',
  'hi': '印地语',
  'id': '印尼语',
  'vi': '越南语',
  'th': '泰语',
  'tr': '土耳其语',
  'pl': '波兰语',
  'nl': '荷兰语',
  'uk': '乌克兰语',
  'ms': '马来语',
  'fil': '菲律宾语',
};

String translationLanguageLabel(String code) =>
    translationLanguageLabels[code] ?? code;

/// The label of a subtitle made on the device in [code], or of the
/// transcript with null: `中文（端侧）`, `原文（端侧）`.
String onDeviceLabel(String? code) =>
    '${code == null ? '原文' : translationLanguageLabel(code)}（端侧）';

/// Every language that can be picked under 其他语言: those the model was
/// measured on, besides the app's own, and Traditional Chinese (made by
/// conversion, see TranslationService.traditionalChinese).
List<String> get otherTranslationLanguages => [
  if (AsrService.appLanguage != 'zh-Hant') 'zh-Hant',
  for (final code in translationLanguageNames.keys)
    if (!AsrService.isSameMajorLanguage(code, AsrService.appLanguage)) code,
];

/// The languages the user keeps in the subtitle menu, besides the app's.
List<String> get pinnedTranslationLanguages => [
  for (final code in Pref.translatePinnedLanguages)
    if (otherTranslationLanguages.contains(code)) code,
];
