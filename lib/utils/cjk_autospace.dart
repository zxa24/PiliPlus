/// LibrePili: a little space between Chinese or Japanese and Latin letters
/// or digits, as CSS `text-autospace` puts it (user 2026-10-17:
/// 「中英数字间隔」): 1/8 em, without a character put in the text — the one
/// before the boundary is drawn with that much more letter spacing, so the
/// width does not hang on whether a font has a thin space, and what is
/// copied or searched is the text as it was. Flutter draws a character's
/// letter spacing after it, except the first of a line, which it also moves
/// in by half (1/16 em: not worth undoing).
///
/// Only where they touch: a space already there, punctuation (，。%…) and
/// full-width letters get none. Hangul is left out (Korean is written with
/// spaces).
///
/// The same way, two CJK characters side by side can be set a little apart
/// ([span]'s `tracking`; user 2026-10-17: 「cjk之间的调宽」) — Latin words
/// keep their own spacing.
library;

import 'package:flutter/painting.dart';

abstract final class CjkAutospace {
  /// The gap, in em (CSS: 1/8 of the ideographic width).
  static const em = 0.125;

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

  /// [text] in [style]: [em] between CJK and Latin letters or digits when
  /// [autospace], [tracking] em between two CJK characters. Characters with
  /// the same spacing after them are one span.
  static TextSpan span(
    String text,
    TextStyle style, {
    bool autospace = true,
    double tracking = 0,
  }) {
    final size = style.fontSize ?? 14;
    final base = style.letterSpacing ?? 0;
    final children = <TextSpan>[];
    var runStart = 0;
    var runExtra = 0.0;
    void close(int end) {
      if (end <= runStart) return;
      final piece = text.substring(runStart, end);
      children.add(
        runExtra == 0
            ? TextSpan(text: piece)
            : TextSpan(
                text: piece,
                style: TextStyle(letterSpacing: base + runExtra * size),
              ),
      );
    }

    // the spacing after each character hangs on the one after it
    var prev = -1;
    var prevStart = 0;
    var i = 0;
    for (final c in text.runes) {
      if (prev >= 0) {
        final extra =
            autospace &&
                ((ideograph(prev) && alphanumeric(c)) ||
                    (alphanumeric(prev) && ideograph(c)))
            ? em
            : wide(prev) && wide(c)
            ? tracking
            : 0.0;
        if (extra != runExtra) {
          close(prevStart);
          runStart = prevStart;
          runExtra = extra;
        }
      }
      prev = c;
      prevStart = i;
      i += c > 0xFFFF ? 2 : 1;
    }
    // the last character: nothing after it
    if (runExtra != 0) {
      close(prevStart);
      runStart = prevStart;
      runExtra = 0;
    }
    close(text.length);
    if (children.length == 1 && children.single.style == null) {
      return TextSpan(text: text, style: style);
    }
    return TextSpan(style: style, children: children);
  }
}
