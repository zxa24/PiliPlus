import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/utils/utils.dart' as danmaku;
import 'package:flutter_test/flutter_test.dart';

/// A danmaku drawn with the gap between Chinese and Latin letters or digits
/// (中英文间距): its line is wider by the gaps, and only by them.
void main() {
  tearDown(() => danmaku.DmUtils.gapsOf = null);

  double width(String text) => danmaku.DmUtils.generateParagraph(
    content: DanmakuContentItem(text),
    fontSize: 20,
    fontWeight: 4,
  ).maxIntrinsicWidth;

  test('one gap of 1/8 em at each boundary', () {
    final plain = width('用iPhone拍了3张');
    danmaku.DmUtils.gapsOf = CjkAutospace.gaps;
    final spaced = width('用iPhone拍了3张');
    // 用|i, e|拍, 了|3, 3|张
    expect(spaced - plain, closeTo(4 * 0.125 * 20, 0.01));
  });

  test('none where there is no boundary, or the setting is off', () {
    final unset = width('用iPhone');
    final noBoundary = width('中文 English');
    danmaku.DmUtils.gapsOf = CjkAutospace.gaps;
    expect(width('中文 English'), noBoundary);
    // what the app gives with the setting off
    danmaku.DmUtils.gapsOf = (_) => const [];
    expect(width('用iPhone'), unset);
  });
}
