/// LibrePili: what the app asks YouTube for.
library;

import 'package:PiliPlus/models/common/yt_locale.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/services/youtube/yt_identity.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Reads both back out of storage into the values the data layer sends.
/// Called once at launch and again whenever either is changed, so a change
/// takes effect on the next request rather than the next restart.
void applyYtLocale() {
  ytGl = Pref.ytRegion.code;
  ytHl = Pref.ytLanguage.code;
}

List<SettingsModel> get youtubeSettings => [
  PopupModel<YtRegion>(
    title: '内容地区',
    leading: const Icon(Icons.public_outlined),
    value: () => Pref.ytRegion,
    items: YtRegion.values,
    onSelected: (value, setState) => GStorage.setting
        .put(SettingBoxKey.ytRegion, value.code)
        .whenComplete(() {
          applyYtLocale();
          setState();
          // the pages already open were built from the old region
          SmartDialog.showToast('已切换到${value.label}，重新打开页面后生效');
        }),
  ),
  PopupModel<YtLanguage>(
    title: '内容语言',
    leading: const Icon(Icons.translate_outlined),
    value: () => Pref.ytLanguage,
    items: YtLanguage.values,
    onSelected: (value, setState) => GStorage.setting
        .put(SettingBoxKey.ytLanguage, value.code)
        .whenComplete(() {
          applyYtLocale();
          setState();
          SmartDialog.showToast('已切换到${value.label}，重新打开页面后生效');
        }),
  ),
  const NormalModel(
    title: '关于这两项',
    leading: Icon(Icons.info_outline),
    subtitle:
        '「地区」决定按哪个国家的规则判断视频能否播放，改错可能让原本能播的视频被拦下。\n'
        '「语言」决定 YouTube 返回的文字用哪种语言 —— 订阅数、发布时间、'
        '「共 N 条回复」都由服务端决定，应用这边无法翻译。\n'
        '两者都会构成一点点指纹特征；所有人用同一个值是最不可区分的。',
  ),
];
