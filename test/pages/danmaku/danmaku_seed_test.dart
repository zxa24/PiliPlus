import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_seed.dart';
import 'package:flutter_test/flutter_test.dart';

/// Buckets as PlDanmakuController stores them: by progress ~/ 100.
List<DanmakuElem>? Function(int) bucketsOf(List<DanmakuElem> elems) {
  final map = <int, List<DanmakuElem>>{};
  for (final e in elems) {
    (map[e.progress ~/ danmakuBucketMs] ??= []).add(e);
  }
  return (bucket) => map[bucket];
}

DanmakuElem dm(String content, int progress, {int mode = 1, int weight = 5}) =>
    DanmakuElem(
      content: content,
      progress: progress,
      mode: mode,
      weight: weight,
    );

Map<String, int> alive(
  List<DanmakuElem> elems,
  int position, {
  int scroll = 8000,
  int fixed = 4000,
  int minWeight = 0,
}) => {
  for (final a in aliveDanmakuAt(
    position,
    bucketAt: bucketsOf(elems),
    scrollLifetime: scroll,
    staticLifetime: fixed,
    minWeight: minWeight,
  ))
    a.elem.content: a.elapsed,
};

void main() {
  group('aliveDanmakuAt', () {
    test('a scrolling one is on screen for its lifetime, from its bucket', () {
      final elems = [dm('a', 50_050)]; // bucket 500, shown at 50 000
      expect(alive(elems, 49_999), isEmpty); // not yet
      expect(alive(elems, 50_000), {'a': 0});
      expect(alive(elems, 50_099), {'a': 99});
      expect(alive(elems, 57_999), {'a': 7999});
      expect(alive(elems, 58_000), isEmpty); // gone
    });

    test('top and bottom ones live by the static lifetime', () {
      final elems = [
        dm('top', 10_000, mode: 5),
        dm('bottom', 10_000, mode: 4),
        dm('scroll', 10_000),
      ];
      expect(alive(elems, 13_999).keys, {'top', 'bottom', 'scroll'});
      expect(alive(elems, 14_000).keys, {'scroll'});
      // the lifetimes are the settings, not constants
      expect(alive(elems, 14_000, fixed: 6000).keys, {
        'top',
        'bottom',
        'scroll',
      });
      expect(alive(elems, 12_000, scroll: 2000).keys, {'top', 'bottom'});
    });

    test(
      'a static lifetime longer than the scrolling one is looked back over',
      () {
        final elems = [dm('top', 1000, mode: 5), dm('scroll', 1000)];
        expect(alive(elems, 9000, scroll: 5000, fixed: 10_000).keys, {'top'});
      },
    );

    test('advanced danmaku and those under the weight are left out', () {
      final elems = [
        dm('special', 5000, mode: 7),
        dm('light', 5000, weight: 1),
        dm('heavy', 5000, weight: 8),
      ];
      expect(alive(elems, 6000, minWeight: 3).keys, {'heavy'});
    });

    test('the longest showing come first', () {
      final elems = [dm('new', 20_000), dm('old', 14_000), dm('mid', 17_500)];
      expect(alive(elems, 20_000).keys.toList(), ['old', 'mid', 'new']);
    });

    test('near the start nothing is looked for before 0', () {
      final seen = <int>[];
      aliveDanmakuAt(
        300,
        bucketAt: (b) {
          seen.add(b);
          return null;
        },
        scrollLifetime: 8000,
        staticLifetime: 4000,
      );
      expect(seen, [0, 1, 2, 3]);
      expect(
        aliveDanmakuAt(
          -1,
          bucketAt: (_) => fail('nothing to look up'),
          scrollLifetime: 8000,
          staticLifetime: 4000,
        ),
        isEmpty,
      );
    });

    test('looks at exactly the buckets that can hold one still showing', () {
      final seen = <int>[];
      aliveDanmakuAt(
        100_050,
        bucketAt: (b) {
          seen.add(b);
          return null;
        },
        scrollLifetime: 8000,
        staticLifetime: 4000,
      );
      // bucket 920 was shown at 92 000: 8050 ms ago, gone; 921: 7950 ms ago
      expect(seen.first, 921);
      expect(seen.last, 1000);
      expect(seen.length, 80);
    });
  });

  group('scrollOffsetAfter', () {
    test('crosses the view plus its own width in the duration', () {
      double at(num elapsed) => scrollOffsetAfter(
        elapsed,
        duration: 8000,
        viewWidth: 1000,
        itemWidth: 200,
        fixedVelocity: false,
      );
      expect(at(0), 0);
      expect(at(4000), 600);
      expect(at(8000), 1200); // off the left edge
    });

    test('with a fixed velocity, the view width in the duration', () {
      double at(num elapsed, double width) => scrollOffsetAfter(
        elapsed,
        duration: 8000,
        viewWidth: 1000,
        itemWidth: width,
        fixedVelocity: true,
      );
      expect(at(4000, 200), 500);
      expect(at(4000, 50), 500);
    });

    test('same answer in wall time as in video time', () {
      // at 2x the renderer's duration is halved and so is the wall time
      const video = 3000;
      final byVideo = scrollOffsetAfter(
        video,
        duration: 8000,
        viewWidth: 800,
        itemWidth: 120,
        fixedVelocity: false,
      );
      final byWall = scrollOffsetAfter(
        video / 2,
        duration: 4000,
        viewWidth: 800,
        itemWidth: 120,
        fixedVelocity: false,
      );
      expect(byWall, byVideo);
    });
  });
}
