import 'dart:ui' as ui;

import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> spaced(String text) => [
  for (final (s, e) in CjkAutospace.gaps(text)) text.substring(s, e),
];

/// The x ranges inked along the middle row of [span] as drawn (the test
/// font draws every character as a box). Carets would not do: with letter
/// spacing they sit inside it. With [column], the y ranges down that
/// column instead.
Future<List<(int, int)>> inked(
  WidgetTester tester,
  InlineSpan span, {
  int? column,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          // room below: a lowered word is drawn past the paragraph
          child: ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text.rich(span),
            ),
          ),
        ),
      ),
    ),
  );
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final runs = <(int, int)>[];
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final length = column == null ? image.width : image.height;
    bool dark(int i) {
      final (x, y) = column == null ? (i, image.height ~/ 2) : (column, i);
      return data.getUint8((y * image.width + x) * 4) < 128;
    }

    int? start;
    for (var i = 0; i < length; i++) {
      if (dark(i) && start == null) start = i;
      if (!dark(i) && start != null) {
        runs.add((start, i));
        start = null;
      }
    }
    if (start != null) runs.add((start, length));
  });
  return runs;
}

void main() {
  group('where the gaps go', () {
    test('between Chinese and letters or digits, both ways', () {
      expect(spaced('用iPhone拍了3张'), ['用', 'e', '了', '3']);
      expect(spaced('第2集'), ['第', '2']);
    });

    test('kana too; Hangul and full-width letters not', () {
      expect(spaced('これはTest'), ['は']);
      expect(spaced('カードA'), ['ド']);
      expect(spaced('한국어A'), isEmpty);
      expect(spaced('中ＡＢ'), isEmpty);
    });

    test('none where a space or punctuation is there already', () {
      expect(spaced('中文 English'), isEmpty);
      expect(spaced('涨了100%，'), ['了']);
      expect(spaced('“OK”好'), isEmpty);
      expect(spaced('（A）'), isEmpty);
    });

    test('accented, Greek and Cyrillic letters count; × does not', () {
      expect(spaced('去Café'), ['去']);
      expect(spaced('α粒子'), ['α']);
      expect(spaced('Привет你'), ['т']);
      expect(spaced('3×中'), isEmpty);
    });

    test('characters outside the BMP are one character', () {
      // U+20BB7 𠮷
      expect(spaced('𠮷A'), ['𠮷']);
      expect(spaced('A𠮷'), ['A']);
    });
  });

  group('a span tree', () {
    const base = TextStyle(fontSize: 20);

    /// (text, letterSpacing, recognizer) of each leaf, in order.
    List<(String, double?, GestureRecognizer?)> leaves(
      InlineSpan span, [
      TextStyle style = base,
    ]) {
      final out = <(String, double?, GestureRecognizer?)>[];
      void walk(InlineSpan s, TextStyle inherited) {
        if (s is! TextSpan) {
          out.add(('[w]', null, null));
          return;
        }
        final own = s.style == null ? inherited : inherited.merge(s.style);
        if (s.text case final t?) out.add((t, own.letterSpacing, s.recognizer));
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c, own);
        }
      }

      walk(span, style);
      return out;
    }

    test('across spans, and a link split keeps its recognizer', () {
      final tap = TapGestureRecognizer();
      addTearDown(tap.dispose);
      final spaced = CjkAutospace.spaceTree(
        TextSpan(
          children: [
            const TextSpan(text: '我用'),
            TextSpan(text: 'iPhone', recognizer: tap),
            const TextSpan(text: '拍'),
          ],
        ),
        base,
      );
      expect(spaced.toPlainText(), '我用iPhone拍');
      expect(leaves(spaced), [
        ('我', null, null),
        ('用', 2.5, null),
        ('iPhon', null, tap),
        ('e', 2.5, tap),
        ('拍', null, null),
      ]);
    });

    test('an emote between parts them', () {
      final root = TextSpan(
        children: [
          const TextSpan(text: '中'),
          const WidgetSpan(child: SizedBox()),
          const TextSpan(text: 'A'),
        ],
      );
      expect(identical(CjkAutospace.spaceTree(root, base), root), isTrue);
    });

    test('a const span used twice is spaced at each place', () {
      const han = TextSpan(text: '中');
      final spaced = CjkAutospace.spaceTree(
        const TextSpan(
          children: [
            han,
            TextSpan(text: 'A'),
            han,
          ],
        ),
        base,
      );
      expect(leaves(spaced), [
        ('中', 2.5, null),
        ('A', 2.5, null),
        ('中', null, null),
      ]);
    });

    test('measured in the size each span is drawn at', () {
      final spaced = CjkAutospace.spaceTree(
        const TextSpan(
          children: [
            TextSpan(
              text: '中A',
              style: TextStyle(fontSize: 10, letterSpacing: 0.5),
            ),
          ],
        ),
        base,
      );
      expect(leaves(spaced), [('中', 0.5 + 1.25, null), ('A', 0.5, null)]);
    });

    test('no gap: the same span back', () {
      const root = TextSpan(text: '中文 English，100%');
      expect(identical(CjkAutospace.spaceTree(root, base), root), isTrue);
    });
  });

  group('the span', () {
    const style = TextStyle(fontSize: 20, letterSpacing: 0.5);

    test('no gap: one plain span', () {
      final s = CjkAutospace.span('中文', style);
      expect(s.text, '中文');
      expect(s.children, isNull);
    });

    test('tracking: between two CJK characters only, not after the last '
        'of them', () {
      final s = CjkAutospace.span(
        '中文。ab中',
        style,
        autospace: false,
        tracking: 0.1,
      );
      expect(s.toPlainText(), '中文。ab中');
      final pieces = [
        for (final c in s.children!.cast<TextSpan>())
          (c.text, c.style?.letterSpacing),
      ];
      // 中 文 。 apart (。 then a: none), ab and the last 中 as they were
      expect(pieces, [('中文', 0.5 + 2), ('。ab中', null)]);
    });

    test('tracking and the gap together', () {
      final s = CjkAutospace.span('中文A', style, tracking: 0.1);
      final pieces = [
        for (final c in s.children!.cast<TextSpan>())
          (c.text, c.style?.letterSpacing),
      ];
      expect(pieces, [('中', 0.5 + 2), ('文', 0.5 + 2.5), ('A', null)]);
    });

    test('latinScale: letters and digits on a line with CJK, not spaces '
        'or a line of English', () {
      final s = CjkAutospace.span(
        '中 Ab 1',
        style,
        autospace: false,
        latinScale: 1.1,
      );
      final pieces = [
        for (final c in s.children!.cast<TextSpan>())
          (c.text, c.style?.fontSize?.toStringAsFixed(3)),
      ];
      expect(pieces, [
        ('中 ', null),
        ('Ab', '22.000'),
        (' ', null),
        ('1', '22.000'),
      ]);
      final english = CjkAutospace.span('Ab 1', style, latinScale: 1.1);
      expect(english.children, isNull);
      expect(english.text, 'Ab 1');
    });

    test('the text is kept as it was', () {
      final s = CjkAutospace.span('用iPhone拍', style);
      expect(s.toPlainText(), '用iPhone拍');
    });

    test('a gap of another width where given (the subtitles\' 0.2 em)', () {
      const style = TextStyle(fontSize: 40);
      final s = CjkAutospace.span('用i拍', style, gap: 0.2);
      final spacing = [
        for (final c in s.children!.cast<TextSpan>()) c.style?.letterSpacing,
      ];
      // 用 and i each with the gap after them, 拍 with none
      expect(spacing, [closeTo(8, 1e-9), null]);
      expect(s.children!.cast<TextSpan>().first.text, '用i');
    });

    testWidgets('the whole gap lands at the boundary, after the character', (
      tester,
    ) async {
      // a gap after x (yx|中); the space and B show where the rest went
      const style = TextStyle(fontSize: 40, color: Colors.black);
      const gap = CjkAutospace.em * 40;
      final plain = await inked(
        tester,
        const TextSpan(text: 'yx中 B', style: style),
      );
      final spaced = await inked(tester, CjkAutospace.span('yx中 B', style));
      expect(plain, [(0, 120), (160, 200)]);
      expect(spaced, hasLength(3));
      // y and x where they were, then the gap, then 中
      expect(spaced[0], (0, 80));
      expect(spaced[1].$1 - 80, closeTo(gap, 1));
      // everything after moved by just the gap
      expect(spaced[2].$1 - 160, closeTo(gap, 1));
    });

    testWidgets('latinDrop: the word drawn that much lower, nothing moved '
        'along the line', (tester) async {
      const style = TextStyle(fontSize: 40, color: Colors.black);
      // 中 0-40, gap 5, A 45-85, b 85-125, gap 5, 中 130-170
      final level = CjkAutospace.span('中Ab中', style);
      final low = CjkAutospace.span('中Ab中', style, latinDrop: 0.1);
      expect(low.children!.whereType<WidgetSpan>(), hasLength(1));
      expect(await inked(tester, low), await inked(tester, level));
      final cjk = await inked(tester, low, column: 20);
      final word = await inked(tester, low, column: 65);
      final word0 = await inked(tester, level, column: 65);
      expect(word.single.$1 - word0.single.$1, 4);
      expect(word.single.$2 - word0.single.$2, 4);
      expect(word0.single, cjk.single);
    });

    testWidgets('first in a line: drawn half a gap in as well (SkParagraph)', (
      tester,
    ) async {
      const style = TextStyle(fontSize: 40, color: Colors.black);
      final spaced = await inked(tester, CjkAutospace.span('x中', style));
      expect(spaced.first.$1, closeTo(CjkAutospace.em * 40 / 2, 1));
    });
  });
}
