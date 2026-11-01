/// LibrePili: the quality tier of a YouTube format, as the downloads name it
/// (feature-logs/download-platforms stage-2 plan §4.5, design §10-8 ⑦ A).
///
/// The download panel's tiers and greyed tiers, the start's `exactHeight`
/// and the 720p button all go through [ytQualityTier]; the online page's
/// quality menu and pick still go by the short side (`ytShortSide`).
///
/// A tier is what a 16:9 frame of that size would be called: a wide film
/// at 1920x800 is "1080", not "800". So the tier is the larger of the short
/// side and the long side × 9 ÷ 16, floored to the ladder.
library;

import 'dart:math' as math;

/// The tiers, highest first.
const ytQualityLadder = [2160, 1440, 1080, 720, 480, 360, 240, 144];

/// The tier of a [width] x [height] frame: `max(short side, long side × 9 ÷
/// 16)` (integer division) floored to [ytQualityLadder]; below 144, 144.
/// Only the size counts, never the format's `qualityLabel` (two sources
/// write it differently).
int ytQualityTier(int width, int height) {
  final short = math.min(width, height);
  final long = math.max(width, height);
  final size = math.max(short, long * 9 ~/ 16);
  for (final tier in ytQualityLadder) {
    if (tier <= size) return tier;
  }
  return ytQualityLadder.last;
}
