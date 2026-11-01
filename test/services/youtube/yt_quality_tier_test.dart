// LibrePili: the downloads' quality tier (stage-2 plan §4.5): the table of
// §4.5, each format with its tier and whether the 720p button's pick (tier
// 720) takes it; the wide family that a short-side reading would list as
// "800, 534, 356"; the ends of the ladder.
import 'package:PiliPlus/services/youtube/yt_quality_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the §4.5 table', () {
    const table = [
      // width, height, tier
      (1920, 1080, 1080),
      (1280, 720, 720),
      (1920, 800, 1080), // 1920 × 9 / 16 = 1080
      (2048, 858, 1080), // 1152, floored to 1080
      (1280, 534, 720), // 720
      (854, 356, 480), // 480
      (1080, 1920, 1080), // portrait: 1920 × 9 / 16
      (960, 720, 720), // 4:3: the short side
      (1440, 1080, 1080),
    ];
    for (final (w, h, tier) in table) {
      expect(ytQualityTier(w, h), tier, reason: '${w}x$h');
      expect(ytQualityTier(w, h) == 720, tier == 720, reason: '${w}x$h');
    }
  });

  test('a wide family lists 1080, 720, 480 — not its short sides', () {
    expect(
      [
        (1920, 800),
        (1280, 534),
        (854, 356),
      ].map((s) => ytQualityTier(s.$1, s.$2)),
      [1080, 720, 480],
    );
  });

  test('the ladder: tops and floors', () {
    expect(ytQualityTier(3840, 2160), 2160);
    expect(ytQualityTier(7680, 4320), 2160);
    expect(ytQualityTier(2560, 1440), 1440);
    expect(ytQualityTier(640, 360), 360);
    expect(ytQualityTier(426, 240), 240);
    expect(ytQualityTier(256, 144), 144);
    expect(ytQualityTier(100, 50), 144);
    expect(ytQualityTier(0, 0), 144);
    // just under a step: the one below
    expect(ytQualityTier(1279, 719), 480);
  });
}
