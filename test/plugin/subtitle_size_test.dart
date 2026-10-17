import 'package:PiliPlus/plugin/pl_player/widgets/spaced_subtitle_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// Subtitles sized by the area they are drawn in: the square root of its
/// height, within limits, times the 字体大小 setting.
void main() {
  double size(double height, [double scale = 1]) =>
      SpacedSubtitleView.sizeFor(height, scale);

  test('40 at 1080, as the square root of the height', () {
    expect(size(1080), closeTo(40, 0.01));
    // a quarter of the height, half the size
    expect(size(270), closeTo(20, 0.01));
    expect(size(720), closeTo(32.66, 0.01));
    // 4K at 125 %
    expect(size(1728), closeTo(50.6, 0.05));
  });

  test('within 14 and 64', () {
    expect(size(100), 14);
    expect(size(0), 14);
    expect(size(4000), 64);
  });

  test('the setting multiplies, the limits before it', () {
    expect(size(1080, 1.5), closeTo(60, 0.01));
    expect(size(100, 0.5), 7);
  });
}
