import 'package:PiliPlus/plugin/pl_player/widgets/spaced_subtitle_view.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// The subtitle outline scales with the text (oct-pass2-D3): the 描边粗细
/// setting is its width at 16 px, as it was before subtitles were sized by
/// the area they are drawn in.
void main() {
  TextStyle outline(double width) => TextStyle(
    fontSize: 16,
    foreground: Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width,
  );

  double widthAt(double width, double em) =>
      SpacedSubtitleView.strokeFor(outline(width), em).foreground!.strokeWidth;

  test('the setting at 16 px, in proportion above and below', () {
    expect(widthAt(2, 16), 2);
    expect(widthAt(2, 40), closeTo(5, 1e-9));
    expect(widthAt(3, 14), closeTo(2.625, 1e-9));
    expect(widthAt(0, 64), 0);
  });

  test('the outline stays an outline, in its colour', () {
    final paint = SpacedSubtitleView.strokeFor(outline(2), 32).foreground!;
    expect(paint.style, PaintingStyle.stroke);
    expect(paint.color, const Color(0xFF000000));
  });

  test('a style that is no outline is left as it is', () {
    const plain = TextStyle(fontSize: 16, color: Color(0xFFFFFFFF));
    expect(identical(SpacedSubtitleView.strokeFor(plain, 40), plain), true);
  });
}
