import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/widgets/spaced_subtitle_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Red along row [y] of [child] as drawn, from x 0 on.
Future<List<int>> row(WidgetTester tester, Widget child, int y) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(color: Colors.white, child: child),
        ),
      ),
    ),
  );
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late List<int> out;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    out = [
      for (var x = 0; x < image.width; x++)
        data.getUint8((y * image.width + x) * 4),
    ];
  });
  return out;
}

void main() {
  // runs meeting at fractions of a pixel; the glyphs white on white, so
  // only the background shows
  const glyphs = TextStyle(fontSize: 20, height: 1.5, color: Colors.white);
  TextSpan runs(TextStyle style) => TextSpan(
    style: style,
    children: const [
      TextSpan(text: '中', style: TextStyle(letterSpacing: 1.3)),
      TextSpan(text: '文', style: TextStyle(letterSpacing: 0.7)),
      TextSpan(text: 'AB'),
    ],
  );
  const grey = Color(0x80000000);

  testWidgets('one even band behind the line, end to end', (tester) async {
    // row 2: above the glyphs, inside the line
    final band = await row(
      tester,
      LineBands(color: grey, child: Text.rich(runs(glyphs))),
      2,
    );
    final inked = [
      for (var x = 0; x < band.length; x++)
        if (band[x] < 250) x,
    ];
    // 中 21.3 + 文 20.7 + AB 40 wide
    expect(inked.first, 0);
    expect(inked.last, 81);
    expect(
      {for (final x in inked.skip(1).take(inked.length - 2)) band[x]},
      hasLength(1),
    );
  });

  testWidgets('as the style would draw it: a seam where runs meet', (
    tester,
  ) async {
    final boxes = await row(
      tester,
      Text.rich(runs(glyphs.copyWith(backgroundColor: grey))),
      2,
    );
    final inside = boxes.sublist(1, 81);
    expect(inside.toSet().length, greaterThan(1));
  });
}
