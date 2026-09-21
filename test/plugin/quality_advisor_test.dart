import 'package:PiliPlus/plugin/pl_player/quality_advisor.dart';
import 'package:flutter_test/flutter_test.dart';

List<PlaybackHealth> _series(List<double> cache, {bool stalled = false}) => [
  for (final seconds in cache) (cacheSeconds: seconds, stalled: stalled),
];

/// The thresholds are relative to the player's own `cache-secs`, so these use
/// 16 s — what the app configures.
QualityAdvice _advise(
  List<PlaybackHealth> samples, {
  int currentIndex = 0,
  int qualityCount = 4,
  bool allowStepUp = true,
}) => QualityAdvisor.advise(
  samples: samples,
  currentIndex: currentIndex,
  qualityCount: qualityCount,
  targetSeconds: 16,
  allowStepUp: allowStepUp,
);

void main() {
  group('not enough evidence', () {
    test('a short window advises nothing', () {
      expect(_advise(_series([16, 15, 14])), QualityAdvice.keep);
    });

    test('a single quality has nowhere to go', () {
      expect(
        _advise(_series([1, 1, 1, 1, 1, 1]), qualityCount: 1),
        QualityAdvice.keep,
      );
    });
  });

  group('step down', () {
    test('a steady decline into the low water mark', () {
      // the shape measured on a real stream falling behind
      expect(
        _advise(_series([12.0, 10.5, 9.0, 7.5, 6.0, 4.5])),
        QualityAdvice.stepDown,
      );
    });

    test('a stall is acted on immediately', () {
      final samples = _series([16, 16, 16, 16, 16])
        ..add((cacheSeconds: 2, stalled: true));
      expect(_advise(samples), QualityAdvice.stepDown);
    });

    test('already at the lowest quality, nothing to do', () {
      expect(
        _advise(
          _series([12.0, 10.5, 9.0, 7.5, 6.0, 4.5]),
          currentIndex: 3,
        ),
        QualityAdvice.keep,
      );
    });

    test('a low but stable buffer is not a decline', () {
      // a small buffer that holds is fine: the stream is keeping up
      expect(
        _advise(_series([5.0, 5.1, 5.0, 4.9, 5.0, 5.0])),
        QualityAdvice.keep,
      );
    });

    test('one dip inside a healthy window is ignored', () {
      expect(
        _advise(_series([16, 15.5, 9.0, 15.0, 15.5, 16])),
        QualityAdvice.keep,
      );
    });
  });

  group('step up', () {
    test('a full buffer throughout, with room above', () {
      expect(
        _advise(_series([15.5, 16, 16, 15.8, 16, 16]), currentIndex: 2),
        QualityAdvice.stepUp,
      );
    });

    test('never past the best quality', () {
      expect(
        _advise(_series([16, 16, 16, 16, 16, 16])),
        QualityAdvice.keep,
      );
    });

    test('not while the user has stepping up switched off', () {
      expect(
        _advise(
          _series([16, 16, 16, 16, 16, 16]),
          currentIndex: 2,
          allowStepUp: false,
        ),
        QualityAdvice.keep,
      );
    });

    test('a merely adequate buffer is not an invitation to go up', () {
      expect(
        _advise(_series([10, 11, 10, 11, 10, 11]), currentIndex: 2),
        QualityAdvice.keep,
      );
    });
  });

  test('thresholds follow the configured buffer, not a fixed number', () {
    // 5 s of buffer is plenty when only 6 s were asked for
    expect(
      QualityAdvisor.advise(
        samples: _series([6, 5.8, 5.6, 5.5, 5.4, 5.3]),
        currentIndex: 0,
        qualityCount: 4,
        targetSeconds: 6,
      ),
      QualityAdvice.keep,
    );
    // the same numbers are a problem when 60 s were asked for
    expect(
      QualityAdvisor.advise(
        samples: _series([6, 5.8, 5.6, 5.5, 5.4, 5.3]),
        currentIndex: 0,
        qualityCount: 4,
        targetSeconds: 60,
      ),
      QualityAdvice.stepDown,
    );
  });
}
