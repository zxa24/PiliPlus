import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// When an early step down may go by what came in: only with the buffer
/// actually going down.
void main() {
  List<({double cacheSeconds, bool stalled})> seconds(List<double> cache) => [
    for (final c in cache) (cacheSeconds: c, stalled: false),
  ];

  test('going down by more than a second, most of the time', () {
    expect(
      PlPlayerController.bufferDraining(seconds([24, 23.6, 23.1, 22.9, 22.4, 22])),
      isTrue,
    );
  });

  test('held at its byte limit, topped up a trickle at a time', () {
    // 2026-10-09: 22.3-22.8 s for minutes on a healthy stream
    expect(
      PlPlayerController.bufferDraining(seconds([22.5, 22.3, 22.6, 22.4, 22.7, 22.5])),
      isFalse,
    );
  });

  test('refilling', () {
    expect(
      PlPlayerController.bufferDraining(seconds([20, 22, 24, 26, 28, 30])),
      isFalse,
    );
  });

  test('too few seconds to say', () {
    expect(PlPlayerController.bufferDraining(seconds([24, 22, 20])), isFalse);
  });

  group('the buffer falling a long way, whatever came in', () {
    bool fell(List<double> cache, [double target = 30]) =>
        PlPlayerController.bufferFell(seconds(cache), target);

    test('the user copy, 2026-10-10: 29 s to 15 s in 17 s', () {
      expect(
        fell([29, 28, 27, 27, 26, 24, 22, 22, 21, 20, 20, 19, 18, 17, 16, 15]),
        isTrue,
      );
    });

    test('a healthy stream swinging from full to where it refills', () {
      // demuxer-hysteresis-secs: reading again at two thirds of 30 s
      expect(fell([30, 28, 26, 24, 22, 20, 19.5, 21, 24, 27, 30]), isFalse);
    });

    test('low, but not fallen there: the start of a video filling', () {
      expect(fell([2, 4, 6, 8, 10, 12]), isFalse);
    });

    test('fallen, but still above half of the target', () {
      expect(fell([30, 25, 20, 16]), isFalse);
    });

    test('a smaller target, the phone default', () {
      expect(fell([16, 14, 12, 10, 8], 16), isTrue);
      expect(fell([16, 14, 12, 11, 12], 16), isFalse);
    });
  });

  group('the rest of the video all in the buffer', () {
    bool toEnd(double? position, double cache, double? duration) =>
        PlPlayerController.bufferedToEnd(
          position: position,
          cacheSeconds: cache,
          duration: duration,
        );

    test('the user copy, 2026-10-12: 14.1 s left at 788.9 s of 802 s', () {
      expect(toEnd(788.9, 14.1, 802), isTrue);
      expect(toEnd(138.2, 14.8, 151.5), isTrue);
    });

    test('the end not reached yet', () {
      expect(toEnd(700, 14.1, 802), isFalse);
    });

    test('nothing known of where or how long', () {
      expect(toEnd(null, 14.1, 802), isFalse);
      expect(toEnd(788.9, 14.1, null), isFalse);
      expect(toEnd(788.9, 14.1, 0), isFalse);
    });
  });
}
