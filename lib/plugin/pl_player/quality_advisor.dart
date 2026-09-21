/// LibrePili: when the picture should step down, and when it may step back up.
///
/// The signal is `demuxer-cache-duration` — how many seconds of media are
/// buffered ahead — sampled once a second. It was picked by measurement, not
/// assumption: a probe against the real player showed `cache-speed` is bursty
/// and reads 0 whenever the cache is full, so a "slow connection" test built
/// on it would fire constantly on a healthy stream. The cache *duration*
/// falling steadily is what "arriving slower than it is consumed" actually
/// looks like:
///
/// ```
/// demuxer-cache-duration: 12.01 → 11.01 → 9.98 → 8.98 → 8.00
/// cache-speed:            1.25M → 1.97M →    0 →    0 →    0
/// ```
///
/// This decides nothing about CDNs: a stall is answered by moving to another
/// host first (see [TransportRecovery]), and only once the hosts run out does
/// the quality come down. A dead CDN must never cost the viewer resolution.
library;

/// One second of playback health.
typedef PlaybackHealth = ({
  /// Seconds of media buffered ahead (`demuxer-cache-duration`).
  double cacheSeconds,

  /// `paused-for-cache`: playback has stopped waiting for data.
  bool stalled,
});

enum QualityAdvice {
  /// Nothing to do, or not enough evidence yet.
  keep,

  /// The stream is not keeping up at this quality.
  stepDown,

  /// There is room to spare; try one step better.
  stepUp,
}

abstract final class QualityAdvisor {
  /// Samples needed before advising anything. At one per second this is also
  /// the minimum time between two switches, since the caller clears the
  /// window after acting on advice.
  static const window = 6;

  /// Below this fraction of the configured buffer, the stream is behind.
  static const _lowWaterFraction = 0.35;

  /// Above this fraction, for the whole window, there is room to go up.
  static const _highWaterFraction = 0.9;

  /// [samples] is oldest-first and may be longer than [window]; only the last
  /// [window] entries count. [targetSeconds] is what the player was told to
  /// buffer (`cache-secs`), so the thresholds follow the user's own setting
  /// instead of a hard-coded number of seconds.
  static QualityAdvice advise({
    required List<PlaybackHealth> samples,
    required int currentIndex,
    required int qualityCount,
    required double targetSeconds,
    bool allowStepUp = true,
  }) {
    if (qualityCount <= 1 || targetSeconds <= 0) return QualityAdvice.keep;
    if (samples.length < window) return QualityAdvice.keep;
    final recent = samples.sublist(samples.length - window);

    // index 0 is the best quality, so "down" means a larger index
    final canStepDown = currentIndex < qualityCount - 1;
    final canStepUp = allowStepUp && currentIndex > 0;

    final low = targetSeconds * _lowWaterFraction;
    final high = targetSeconds * _highWaterFraction;

    // a stall is the unambiguous case: it already interrupted the viewer
    if (recent.any((s) => s.stalled)) {
      return canStepDown ? QualityAdvice.stepDown : QualityAdvice.keep;
    }

    final last = recent.last;
    final falling = _isFalling(recent);
    if (canStepDown && last.cacheSeconds < low && falling) {
      return QualityAdvice.stepDown;
    }

    if (canStepUp && recent.every((s) => s.cacheSeconds >= high)) {
      return QualityAdvice.stepUp;
    }

    return QualityAdvice.keep;
  }

  /// Falling across the window as a whole, rather than between two adjacent
  /// samples: a single dip is normal, a steady decline is not.
  static bool _isFalling(List<PlaybackHealth> window) {
    final first = window.first.cacheSeconds;
    final last = window.last.cacheSeconds;
    if (last >= first) return false;
    var drops = 0;
    for (var i = 1; i < window.length; i++) {
      if (window[i].cacheSeconds < window[i - 1].cacheSeconds) drops++;
    }
    return drops > window.length ~/ 2;
  }
}
