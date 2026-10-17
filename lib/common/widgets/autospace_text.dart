/// LibrePili: a little space between Chinese or Japanese and Latin letters
/// or digits (中英文间距, [CjkAutospace.spaceTree]) in the text of titles,
/// descriptions and comments (user 2026-10-17, the second of 「a 123」:
/// 「再加评论、视频标题、简介」), when the setting subtitles share is on
/// ([Pref.cjkAutospace]). The text itself is not changed: what is copied
/// or selected is what was there.
library;

import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';

/// [Text] / [Text.rich], spaced.
class AutospaceText extends StatelessWidget {
  const AutospaceText(
    String this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  }) : span = null;

  const AutospaceText.rich(
    InlineSpan this.span, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  }) : data = null;

  final String? data;
  final InlineSpan? span;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// [span] spaced, drawn in [style] over what [context] inherits: for the
  /// widgets that take a span of their own (an expandable comment, a
  /// selectable title).
  static InlineSpan apply(
    BuildContext context,
    InlineSpan span, {
    TextStyle? style,
  }) {
    if (!Pref.cjkAutospace) return span;
    return CjkAutospace.spaceTree(
      span,
      DefaultTextStyle.of(context).style.merge(style),
    );
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    apply(context, span ?? TextSpan(text: data), style: style),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
  );
}
