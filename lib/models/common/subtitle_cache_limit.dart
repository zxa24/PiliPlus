import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: how much disk the on-device subtitle cache may take (字幕缓存
/// 上限; research/subtitle-switch-design-2026-09-26.md, 9B). An entry is
/// tens of KB per video — even 128 MB is thousands of videos — so a few
/// fixed sizes are all the choice needed.
enum SubtitleCacheLimit implements EnumWithLabel {
  mb128(128, '128 MB'),
  mb256(256, '256 MB'),
  mb512(512, '512 MB'),
  gb1(1024, '1 GB'),
  gb2(2048, '2 GB');

  const SubtitleCacheLimit(this.mb, this.label);

  final int mb;

  @override
  final String label;

  /// The one for [mb], or the nearest below it (the default, 512 MB, when
  /// none is).
  static SubtitleCacheLimit of(int mb) =>
      values.lastWhere((v) => v.mb <= mb, orElse: () => mb512);
}
