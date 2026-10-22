/// LibrePili: a little space between Chinese or Japanese and Latin letters
/// or digits, as CSS `text-autospace` puts it (user 2026-10-17:
/// 「中英数字间隔」): 0.2 em, without a character put in the text — the one
/// before the boundary is drawn with that much more letter spacing, so the
/// width does not hang on whether a font has a thin space, and what is
/// copied or searched is the text as it was. Flutter draws a character's
/// letter spacing after it, except the first of a line, which it also moves
/// in by half (0.1 em: not worth undoing).
///
/// Only where they touch: a space already there, punctuation (，。%…) and
/// full-width letters get none. Hangul is left out (Korean is written with
/// spaces).
///
/// The same way, two CJK characters side by side can be set a little apart
/// ([span]'s `tracking`; user 2026-10-17: 「cjk之间的调宽」) — Latin words
/// keep their own spacing.
library;

import 'package:flutter/widgets.dart';

abstract final class CjkAutospace {
  /// The gap, in em: in subtitles, titles and danmaku alike (user
  /// 2026-10-22 「改成0.2em」, then 「标题和弹幕的中英文间隔 同步」; it was
  /// CSS's, 1/8 of the ideographic width).
  static const em = 0.2;

  /// Han ideographs and kana.
  static bool ideograph(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x20000 && c <= 0x3134F) ||
      c == 0x3007 ||
      // hiragana, katakana (not ・), and the long vowel mark ー
      (c >= 0x3041 && c <= 0x3096) ||
      (c >= 0x30A1 && c <= 0x30FA) ||
      c == 0x30FC ||
      (c >= 0x31F0 && c <= 0x31FF);

  /// Latin (with its accented letters), Greek and Cyrillic letters, and
  /// ASCII digits.
  static bool alphanumeric(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
      (c >= 0x370 && c <= 0x3FF) ||
      (c >= 0x400 && c <= 0x4FF);

  /// Ideographs, kana, CJK punctuation and full-width forms: what
  /// `tracking` sets apart.
  static bool wide(int c) =>
      ideograph(c) ||
      (c >= 0x3000 && c <= 0x303F) ||
      (c >= 0x3099 && c <= 0x30FF) ||
      (c >= 0xFF00 && c <= 0xFF60) ||
      (c >= 0xFFE0 && c <= 0xFFE6);

  /// Where the gaps go: for each, the UTF-16 range of the character it
  /// follows.
  static List<(int, int)> gaps(String text) {
    final out = <(int, int)>[];
    var prev = -1;
    var prevStart = 0;
    var i = 0;
    for (final c in text.runes) {
      final width = c > 0xFFFF ? 2 : 1;
      if (prev >= 0 &&
          ((ideograph(prev) && alphanumeric(c)) ||
              (alphanumeric(prev) && ideograph(c)))) {
        out.add((prevStart, i));
      }
      prev = c;
      prevStart = i;
      i += width;
    }
    return out;
  }

  /// [root] with [em] between CJK and Latin letters or digits wherever they
  /// meet, across its spans too (`用` in one, `iPhone` in a link after it):
  /// the character before each boundary in a span of its own with that much
  /// more letter spacing. All else of each span — style, link, cursor — is
  /// kept, and its pieces carry its recognizer. A [WidgetSpan] (an emote)
  /// parts what is either side of it. [inherited]: the style the tree is
  /// drawn in (the [DefaultTextStyle] with the widget's own), for the size
  /// the gap is measured in. [root] itself when there is no gap.
  static InlineSpan spaceTree(InlineSpan root, TextStyle inherited) {
    // the text as drawn, a widget as U+FFFC (no gap either side)
    final buffer = StringBuffer();
    void collect(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text case final text?) buffer.write(text);
        span.children?.forEach(collect);
      } else {
        buffer.writeCharCode(0xFFFC);
      }
    }

    collect(root);
    final at = [for (final (start, _) in gaps(buffer.toString())) start];
    if (at.isEmpty) return root;
    // walked in the order collected: a span used twice (a const one) is at
    // two places
    var pos = 0;
    InlineSpan rebuild(InlineSpan span, TextStyle style) {
      if (span is! TextSpan) {
        pos++;
        return span;
      }
      final own = span.style == null ? style : style.merge(span.style);
      final text = span.text;
      List<InlineSpan>? pieces;
      if (text != null) {
        final start = pos;
        pos += text.length;
        final inside = [
          for (final g in at)
            if (g >= start && g < pos) g - start,
        ];
        if (inside.isNotEmpty) {
          final spaced = TextStyle(
            letterSpacing: (own.letterSpacing ?? 0) + em * (own.fontSize ?? 14),
          );
          TextSpan piece(String text, [TextStyle? style]) => TextSpan(
            text: text,
            style: style,
            recognizer: span.recognizer,
            mouseCursor: span.mouseCursor,
            onEnter: span.onEnter,
            onExit: span.onExit,
          );
          pieces = [];
          var from = 0;
          for (final g in inside) {
            final width = (text.codeUnitAt(g) & 0xFC00) == 0xD800 ? 2 : 1;
            if (g > from) pieces.add(piece(text.substring(from, g)));
            pieces.add(piece(text.substring(g, g + width), spaced));
            from = g + width;
          }
          if (from < text.length) pieces.add(piece(text.substring(from)));
        }
      }
      final children = span.children;
      final rebuilt = children?.map((c) => rebuild(c, own)).toList();
      var changed = false;
      if (children != null) {
        for (var i = 0; i < children.length; i++) {
          if (!identical(children[i], rebuilt![i])) changed = true;
        }
      }
      if (pieces == null && !changed) return span;
      return TextSpan(
        text: pieces == null ? text : null,
        children: [...?pieces, ...?rebuilt],
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        onEnter: span.onEnter,
        onExit: span.onExit,
        semanticsLabel: span.semanticsLabel,
        locale: span.locale,
        spellOut: span.spellOut,
      );
    }

    return rebuild(root, inherited);
  }

  /// [text] in [style]: [em] between CJK and Latin letters or digits when
  /// [autospace], [tracking] em between two CJK characters, and Latin
  /// letters and digits at [latinScale] times the size — on a line with CJK
  /// in it only: a line of English keeps the size it was set to. On such a
  /// line they also sit [latinDrop] em below the baseline: Flutter has no
  /// baseline shift, so each word is then a [WidgetSpan] drawn lower (one
  /// word to a span, as a word is not broken anyway). Characters alike in
  /// all that are one span.
  static TextSpan span(
    String text,
    TextStyle style, {
    bool autospace = true,
    double tracking = 0,
    double latinScale = 1,
    double latinDrop = 0,
  }) {
    final size = style.fontSize ?? 14;
    final base = style.letterSpacing ?? 0;
    final scaling =
        (latinScale != 1 || latinDrop != 0) && text.runes.any(ideograph);
    // per character: the spacing after it (em) and whether it is scaled
    final chars = <(int, int, double, bool)>[];
    var i = 0;
    int? prev;
    for (final c in text.runes) {
      final width = c > 0xFFFF ? 2 : 1;
      if (prev != null) {
        final extra =
            autospace &&
                ((ideograph(prev) && alphanumeric(c)) ||
                    (alphanumeric(prev) && ideograph(c)))
            ? em
            : wide(prev) && wide(c)
            ? tracking
            : 0.0;
        final (s0, e0, _, k0) = chars.last;
        chars.last = (s0, e0, extra, k0);
      }
      chars.add((i, i + width, 0.0, scaling && alphanumeric(c)));
      prev = c;
      i += width;
    }
    final children = <InlineSpan>[];
    var run = 0;
    for (var k = 1; k <= chars.length; k++) {
      final (from, _, extra, scaled) = chars[run];
      final lowered = scaled && latinDrop != 0;
      // a lowered word is one span whatever its spacing: only its last
      // character can have more (before CJK)
      if (k < chars.length &&
          chars[k].$4 == scaled &&
          (lowered || chars[k].$3 == extra)) {
        continue;
      }
      final piece = text.substring(from, chars[k - 1].$2);
      if (lowered) {
        children.add(
          _lowered(
            piece,
            style,
            size * latinScale,
            latinDrop * size,
            chars[k - 1].$3 * size,
          ),
        );
        run = k;
        continue;
      }
      children.add(
        extra == 0 && !scaled
            ? TextSpan(text: piece)
            : TextSpan(
                text: piece,
                style: TextStyle(
                  fontSize: scaled ? size * latinScale : null,
                  letterSpacing: extra == 0 ? null : base + extra * size,
                ),
              ),
      );
      run = k;
    }
    if (children.length <= 1 && (children.firstOrNull?.style == null)) {
      return TextSpan(text: text, style: style);
    }
    return TextSpan(style: style, children: children);
  }

  /// [word] in the line's [style] (all of it, as a widget does not take
  /// the line's) at [fontSize], drawn [drop] lower, then [gap] of space.
  /// The gap is padding, not letter spacing, which Flutter would also put
  /// half of before the word, the first in its own paragraph. Its line is
  /// as tall as the others and its baseline where theirs is, and the line
  /// paints the background behind it: one even band, not a taller or darker
  /// box behind each word.
  static WidgetSpan _lowered(
    String word,
    TextStyle style,
    double fontSize,
    double drop,
    double gap,
  ) => WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: Padding(
      padding: EdgeInsets.only(right: gap),
      // laid out where it was, so on the line's baseline; drawn lower
      child: Transform.translate(
        offset: Offset(0, drop),
        child: Text(
          word,
          style: style.copyWith(
            fontSize: fontSize,
            backgroundColor: style.background == null
                ? const Color(0x00000000)
                : null,
            background: style.background == null
                ? null
                : (Paint()..color = const Color(0x00000000)),
          ),
          strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
        ),
      ),
    ),
  );
}
