/// LibrePili: which region and language the app asks YouTube for.
///
/// These are two different questions and the app keeps them apart, because
/// mixing them up costs something either way:
///
/// * `hl` decides the *language of the text YouTube sends back* — the
///   subscriber count, the publish date, 「共 N 条回复」. Nothing on this
///   side can translate those; the server picks the words.
/// * `gl` decides the *content region*, which is what availability rules are
///   applied against. Pointing it at a country can make a video refuse to
///   play that would otherwise have played.
///
/// Both are also a (weak) fingerprint. One value for every user of this app
/// is the least distinguishing thing to send, which is why the defaults are
/// fixed rather than taken from the device.
library;

import 'package:PiliPlus/models/common/enum_with_label.dart';

enum YtRegion implements EnumWithLabel {
  gb('英国 (GB)', 'GB'),
  us('美国 (US)', 'US'),
  jp('日本 (JP)', 'JP'),
  kr('韩国 (KR)', 'KR'),
  hk('香港 (HK)', 'HK'),
  tw('台湾 (TW)', 'TW'),
  sg('新加坡 (SG)', 'SG'),
  de('德国 (DE)', 'DE'),
  ca('加拿大 (CA)', 'CA'),
  au('澳大利亚 (AU)', 'AU'),
  cn('中国大陆 (CN)', 'CN');

  @override
  final String label;

  /// The two-letter code sent as `gl`.
  final String code;

  const YtRegion(this.label, this.code);

  static YtRegion fromCode(String code) => values.firstWhere(
    (e) => e.code == code,
    orElse: () => gb,
  );
}

enum YtLanguage implements EnumWithLabel {
  zhCn('简体中文', 'zh-CN'),
  zhTw('繁體中文', 'zh-TW'),
  enGb('English (UK)', 'en-GB'),
  enUs('English (US)', 'en-US'),
  ja('日本語', 'ja'),
  ko('한국어', 'ko');

  @override
  final String label;

  /// The tag sent as `hl`.
  final String code;

  const YtLanguage(this.label, this.code);

  static YtLanguage fromCode(String code) => values.firstWhere(
    (e) => e.code == code,
    orElse: () => zhCn,
  );
}
