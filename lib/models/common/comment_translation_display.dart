import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: how a comment translated on the device is shown (评论翻译显示;
/// user 2026-10-01). Bilingual by default: a small model's translation is
/// often close but not exact, and the original under it is what lets the
/// viewer tell.
enum CommentTranslationDisplay implements EnumWithLabel {
  bilingual('双语（译文在前）'),
  translationOnly('仅译文');

  @override
  final String label;
  const CommentTranslationDisplay(this.label);
}
