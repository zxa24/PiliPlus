import 'dart:ui' as ui;

import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> spaced(String text) => [
  for (final (s, e) in CjkAutospace.gaps(text)) text.substring(s, e),
];

/// The x ranges inked along the middle row of [span] as drawn (the test
/// font draws every character as a box). Carets would not do: with letter
/// spacing they sit inside it.
Future<List<(int, int)>> inked(WidgetTester tester, InlineSpan span) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(color: Colors.white, child: Text.rich(span)),
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
    final y = image.height ~/ 2;
    int? start;
    for (var x = 0; x < image.width; x++) {
      final dark = data.getUint8((y * image.width + x) * 4) < 128;
      if (dark && start == null) start = x;
      if (!dark && start != null) {
        runs.add((start, x));
        start = null;
      }
    }
    if (start != null) runs.add((start, image.width));
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

    test('the text is kept as it was', () {
      final s = CjkAutospace.span('用iPhone拍', style);
      expect(s.toPlainText(), '用iPhone拍');
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

    testWidgets('first in a line: drawn half a gap in as well (SkParagraph)', (
      tester,
    ) async {
      const style = TextStyle(fontSize: 40, color: Colors.black);
      final spaced = await inked(tester, CjkAutospace.span('x中', style));
      expect(spaced.first.$1, closeTo(CjkAutospace.em * 40 / 2, 1));
    });
  });
}
