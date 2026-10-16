/// LibrePili: tells, once a second, a stream that stopped arriving from one
/// still on its way, from the playhead and the end of the cache.
///
/// Behind the cache with the playhead moving is a track gone dry: the sound
/// plays on over a picture where the video ran out (see
/// PlPlayerController._watchForDryTrack), and is acted on at once.
///
/// Behind the cache with the playhead standing still is an open or a seek
/// waiting for its bytes: mpv holds the playhead at the target and does not
/// call it buffering. Taken for a dry track, it cost the user's copy two
/// loads that were on their way (2026-10-16, BV1ea4y1J7d1 opened at 149 s on
/// links of 5 Mbps: switched after 4 s twice, the third load, let run,
/// played after 9 s). It is acted on once nothing more has arrived for
/// [stuckSeconds] (the host has stopped), or once it has stood there for
/// [slowSeconds] (what arrives comes too slowly: on a host throttled to 0.3 s
/// of video a second it stood 19 s, 2026-10-16 self-test).
///
/// Pure: no mpv, so it can be tested.
library;

enum DryVerdict {
  /// Nothing to do.
  fine,

  /// The playhead ran past what arrived: another host.
  dry,

  /// Standing still behind the cache, with nothing arriving for
  /// [DryWatch.stuckSeconds]: another host.
  stuck,

  /// Standing still behind the cache for [DryWatch.slowSeconds], the bytes
  /// coming too slowly to get there: a slow stream.
  slow,
}

class DryWatch {
  DryWatch({this.stuckSeconds = 10, this.slowSeconds = 12});

  /// Ticks (seconds) with nothing arriving before a playhead standing still
  /// is given up on: mpv's own reconnect has had its go by then (it gives a
  /// read about 5 s).
  final int stuckSeconds;

  /// Ticks standing still behind the cache, arriving or not, before what
  /// arrives is taken as too slow: the load that played in the user's copy
  /// took 9 s to get there.
  final int slowSeconds;

  /// Checks in a row the playhead has been past what arrived; below zero, a
  /// grace period after an open or a recovery.
  int _dryTicks = 0;

  /// Checks in a row standing still behind the cache with nothing arriving.
  int _stuckTicks = 0;

  /// Checks in a row standing still behind the cache.
  int _standingTicks = 0;

  double? _lastPosition, _lastCacheEnd;

  /// Seconds standing still behind the cache, so far.
  int get standingTicks => _standingTicks;

  /// The next [ticks] checks are not judged: a source opened mid-video reads
  /// its cache behind the playhead for a moment.
  void grace([int ticks = 3]) {
    _dryTicks = -ticks;
    _stuckTicks = 0;
    _standingTicks = 0;
    _forget();
  }

  /// A tick not judged (paused, buffering, live): what was counted towards
  /// a dry track starts over; the next tick has nothing to compare with.
  void skip() {
    if (_dryTicks > 0) _dryTicks = 0;
    _stuckTicks = 0;
    _standingTicks = 0;
    _forget();
  }

  void _forget() {
    _lastPosition = null;
    _lastCacheEnd = null;
  }

  DryVerdict tick({
    required double? position,
    required double? cacheEnd,
    required double? duration,
  }) {
    if (_dryTicks < 0) {
      _dryTicks++;
      _forget();
      return DryVerdict.fine;
    }
    final lastPosition = _lastPosition, lastCacheEnd = _lastCacheEnd;
    _lastPosition = position;
    _lastCacheEnd = cacheEnd;
    final moved =
        lastPosition != null &&
        position != null &&
        (position - lastPosition).abs() > 0.1;
    if (moved) {
      _stuckTicks = 0;
      _standingTicks = 0;
      if (!behind(position: position, cacheEnd: cacheEnd, duration: duration)) {
        _dryTicks = 0;
        return DryVerdict.fine;
      }
      // one tick can be a seek landing between two property reads
      if (++_dryTicks < 2) return DryVerdict.fine;
      return DryVerdict.dry;
    }
    _dryTicks = 0;
    // Standing still, any way short of the playhead is short: mpv waits for
    // the frame there. With the second's margin the dry track is given, a
    // cache that stopped at 148.1 s under a playhead at 149.0 s went
    // unnoticed for 13 s (2026-10-16 self-test).
    if (!behind(
      position: position,
      cacheEnd: cacheEnd,
      duration: duration,
      margin: 0,
    )) {
      _stuckTicks = 0;
      _standingTicks = 0;
      return DryVerdict.fine;
    }
    final arriving = lastCacheEnd != null && cacheEnd! > lastCacheEnd + 0.01;
    if (arriving || lastCacheEnd == null) {
      _stuckTicks = 0;
    } else if (++_stuckTicks >= stuckSeconds) {
      _stuckTicks = 0;
      _standingTicks = 0;
      return DryVerdict.stuck;
    }
    if (++_standingTicks >= slowSeconds) {
      _stuckTicks = 0;
      _standingTicks = 0;
      return DryVerdict.slow;
    }
    return DryVerdict.fine;
  }

  /// Whether the playhead, in seconds, is more than [margin] past the end
  /// of what the cache holds, away from the end of the video.
  static bool behind({
    required double? position,
    required double? cacheEnd,
    required double? duration,
    double margin = 1,
  }) {
    if (position == null || cacheEnd == null) return false;
    if (duration != null && duration > 0 && position >= duration - 2) {
      return false;
    }
    return position > cacheEnd + margin;
  }
}
