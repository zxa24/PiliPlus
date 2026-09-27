import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: where a subtitle in the language picked comes from when both
/// could supply it — the video platform's own tracks, or this device's
/// transcription and translation (默认来源; research/subtitle-switch-design-
/// 2026-09-26.md, 9①).
///
/// A platform's machine-translated track (英语（自动翻译）) counts as the
/// platform's: it is a subtitle in that language, and it costs nothing.
/// Whoever finds those poor picks 本机优先.
enum SubtitleSourcePreference implements EnumWithLabel {
  platform('平台优先'),
  device('本机优先');

  @override
  final String label;
  const SubtitleSourcePreference(this.label);
}
