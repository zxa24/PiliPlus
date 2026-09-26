/// LibrePili: which danmaku are still on screen at a playback position.
///
/// The renderer is fed one 100 ms bucket at a time, as playback reaches it,
/// and it animates what it was given by the wall clock. So whenever the
/// screen is emptied — a seek, a reload of the source, recovery from a stall —
/// everything that appeared shortly before the new position, and would still
/// be on its way across, was lost: after a seek the screen stayed empty until
/// new danmaku came along. This finds those again: the ones whose bucket lies
/// within their type's on-screen lifetime before the position, and how long
/// each has been showing, so a scrolling one can be put where it would be by
/// now.
library;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';

/// A danmaku still on screen, and for how long it has been (ms of video).
typedef AliveDanmaku = ({DanmakuElem elem, int elapsed});

/// Danmaku are stored by 100 ms of progress (see PlDanmakuController).
const int danmakuBucketMs = 100;

/// Those of the danmaku stored in [bucketAt] that are on screen at
/// [position] (ms of video), the longest-showing first.
///
/// A bucket is shown when playback reaches its start (the page rounds the
/// position down to 100 ms), so that is what the elapsed time counts from;
/// the bucket [position] is in counts, at 0 or more.
///
/// [scrollLifetime] and [staticLifetime] are how long a scrolling and a
/// top/bottom danmaku stay on screen, in ms of video: the user's duration
/// settings. Advanced (mode 7) danmaku carry their own duration inside their
/// content and are left out; so is anything under [minWeight], as the page
/// leaves it out when playing.
List<AliveDanmaku> aliveDanmakuAt(
  int position, {
  required List<DanmakuElem>? Function(int bucket) bucketAt,
  required int scrollLifetime,
  required int staticLifetime,
  int minWeight = 0,
}) {
  if (position < 0) return const [];
  final current = position ~/ danmakuBucketMs;
  final longest = scrollLifetime > staticLifetime
      ? scrollLifetime
      : staticLifetime;
  // the oldest bucket that can hold anything still showing
  final first = ((position - longest) / danmakuBucketMs).floor() + 1;
  final alive = <AliveDanmaku>[];
  for (var bucket = first < 0 ? 0 : first; bucket <= current; bucket++) {
    final list = bucketAt(bucket);
    if (list == null) continue;
    final elapsed = position - bucket * danmakuBucketMs;
    for (final e in list) {
      if (e.weight < minWeight) continue;
      final lifetime = switch (DmUtils.getPosition(e.mode)) {
        DanmakuItemType.scroll => scrollLifetime,
        DanmakuItemType.top || DanmakuItemType.bottom => staticLifetime,
        DanmakuItemType.special => null,
      };
      if (lifetime != null && elapsed < lifetime) {
        alive.add((elem: e, elapsed: elapsed));
      }
    }
  }
  return alive;
}

/// How far left of the right edge a scrolling danmaku is after [elapsed] ms
/// on screen, the way canvas_danmaku moves it: across the view plus its own
/// width in [duration] ms, or, with a fixed velocity, the view's width in
/// [duration] ms whatever its own width. [elapsed] and [duration] are in the
/// same clock (both of video, or both of the wall).
double scrollOffsetAfter(
  num elapsed, {
  required double duration,
  required double viewWidth,
  required double itemWidth,
  required bool fixedVelocity,
}) {
  if (duration <= 0) return 0;
  final distance = fixedVelocity ? viewWidth : viewWidth + itemWidth;
  return elapsed / duration * distance;
}
