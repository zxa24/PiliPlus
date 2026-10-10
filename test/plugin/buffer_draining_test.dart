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
}
