import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/asr/segment_cap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // as the transcriber: 0.2 s stretches every 10 ms at 16 kHz
  int quietest(Float32List s) => SegmentCap.quietest(
    s,
    frameLength: (SegmentCap.frame * 16000).round(),
    hopLength: (SegmentCap.hop * 16000).round(),
  );

  /// [seconds] of a 200 Hz tone at half scale, at a [level] of that in
  /// each of [gaps] (from, to, level).
  Float32List tone(
    double seconds, {
    List<(double, double, double)> gaps = const [],
  }) {
    final out = Float32List((seconds * 16000).round());
    for (var i = 0; i < out.length; i++) {
      final t = i / 16000;
      var level = 1.0;
      for (final g in gaps) {
        if (t >= g.$1 && t < g.$2) level = g.$3;
      }
      out[i] = 0.5 * level * math.sin(2 * math.pi * 200 * t);
    }
    return out;
  }

  test('the cut lands in the middle of a pause between words', () {
    final at = quietest(tone(6, gaps: [(3.20, 3.40, 0)]));
    expect(at / 16000, closeTo(3.30, 0.02));
  });

  test('a 0.2 s stretch: a longer lull under music beats a brief drop '
      'inside a word', () {
    // 0.05 s of silence still leaves 0.15 s of full speech in any 0.2 s
    // around it; 0.3 s at a fifth of the level is quieter over 0.2 s
    final at = quietest(
      tone(6, gaps: [(1.00, 1.05, 0), (4.00, 4.30, 0.2)]),
    );
    expect(at / 16000, inInclusiveRange(4.10, 4.20));
  });

  test('of equally quiet stretches, the earliest', () {
    expect(quietest(Float32List(16000)), 1600);
  });

  test('too little audio for one stretch: the end', () {
    expect(quietest(Float32List(1000)), 1000);
  });

  group('zeros at a cut', () {
    final audio = Float32List.fromList([0.1, 0.2, 0.3]);
    Matcher samples(List<double> v) => pairwiseCompare<double, double>(
      v,
      (a, b) => (a - b).abs() < 1e-6,
      'close to',
    );

    test('none where neither side is a cut: the audio itself', () {
      final r = SegmentCap.withZeros(
        audio,
        from: 1000,
        before: false,
        after: false,
        count: 2,
      );
      expect(r.samples, same(audio));
      expect(r.from, 1000);
    });

    test('before a cut start: the decoded audio, and the token times with '
        'it, begin that much earlier', () {
      final r = SegmentCap.withZeros(
        audio,
        from: 1000,
        before: true,
        after: false,
        count: 2,
      );
      expect(r.samples, samples([0, 0, 0.1, 0.2, 0.3]));
      expect(r.from, 998);
      // a token the recogniser puts at the first real sample is where that
      // sample is in the run
      expect(r.from + 2, 1000);
    });

    test('after a cut end: the start is unchanged', () {
      final r = SegmentCap.withZeros(
        audio,
        from: 1000,
        before: false,
        after: true,
        count: 2,
      );
      expect(r.samples, samples([0.1, 0.2, 0.3, 0, 0]));
      expect(r.from, 1000);
    });

    test('both sides, 0.4 s each', () {
      final zeros = (SegmentCap.zeros * 16000).round();
      final r = SegmentCap.withZeros(
        audio,
        from: 100000,
        before: true,
        after: true,
        count: zeros,
      );
      expect(zeros, 6400);
      expect(r.samples.length, 3 + 2 * zeros);
      expect(r.from, 100000 - zeros);
      expect(r.samples.sublist(zeros, zeros + 3), samples([0.1, 0.2, 0.3]));
      expect(r.samples.take(zeros).every((s) => s == 0), isTrue);
      expect(r.samples.skip(zeros + 3).every((s) => s == 0), isTrue);
    });
  });
}
