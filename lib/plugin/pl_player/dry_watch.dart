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
/// Standing still *at* the end of the cache is the same wait: both tracks of
/// one host stopped together, so the playhead stops on the last frame there
/// rather than running past it — and mpv went on calling it playing, not
/// buffering (the user's copy, 2026-10-16, BV1CzpS6uEaf at 311.9 s on
/// akamai: reads timing out, under half a second of cache, never acted on).
/// [waiting] says so after [waitingAfter] ticks, for the page to show it is
/// loading.
///
/// The playhead moving with no frames coming is a video track that broke
/// off while the sound plays on, its cache ahead or not: the user's copy
/// played the sound of BV1va4X65E2a for 3.5 min over no picture after a
/// reopen whose video request akamai answered 502 (`root atom … partial
/// file`, 2026-10-17); the cache went on growing, so nothing above saw it.
/// After [blindSeconds] it is [DryVerdict.blind].
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

  /// The playhead moving for [DryWatch.blindSeconds] with no frames from
  /// the video track: another host.
  blind,
}

class DryWatch {
  DryWatch({
    this.stuckSeconds = 10,
    this.slowSeconds = 12,
    this.blindSeconds = 3,
  });

  /// How close to the end of the cache a playhead standing still counts as
  /// waiting at it: the frame there is the last one that arrived.
  static const atEndWithin = 0.5;

  /// Ticks standing still at (or behind) the end of the cache before it is
  /// shown as a load: a moment's hold is not one.
  static const waitingAfter = 2;

  /// Ticks (seconds) with nothing arriving before a playhead standing still
  /// is given up on: mpv's own reconnect has had its go by then (it gives a
  /// read about 5 s).
  final int stuckSeconds;

  /// Ticks standing still behind the cache, arriving or not, before what
  /// arrives is taken as too slow: the load that played in the user's copy
  /// took 9 s to get there.
  final int slowSeconds;

  /// Ticks the playhead moves with no frames before the video track is
  /// given up on: a reopen's first frame comes within a second.
  final int blindSeconds;

  /// Checks in a row the playhead has moved with no frames coming.
  int _blindTicks = 0;

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

  /// Whether the playhead has stood at the end of what arrived long enough
  /// to be waiting for more ([waitingAfter]).
  bool get waiting => _standingTicks >= waitingAfter;

  /// The next [ticks] checks are not judged: a source opened mid-video reads
  /// its cache behind the playhead for a moment.
  void grace([int ticks = 3]) {
    _dryTicks = -ticks;
    _blindTicks = 0;
    _stuckTicks = 0;
    _standingTicks = 0;
    _forget();
  }

  /// A tick not judged (paused, buffering, live): what was counted towards
  /// a dry track starts over; the next tick has nothing to compare with.
  void skip() {
    if (_dryTicks > 0) _dryTicks = 0;
    _blindTicks = 0;
    _stuckTicks = 0;
    _standingTicks = 0;
    _forget();
  }

  void _forget() {
    _lastPosition = null;
    _lastCacheEnd = null;
  }

  /// [picture]: whether frames come from the video track; null when there
  /// is none to look at (sound only, a cover picture).
  DryVerdict tick({
    required double? position,
    required double? cacheEnd,
    required double? duration,
    bool? picture,
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
        if (picture != false) {
          _blindTicks = 0;
        } else if (++_blindTicks >= blindSeconds) {
          _blindTicks = 0;
          return DryVerdict.blind;
        }
        return DryVerdict.fine;
      }
      // one tick can be a seek landing between two property reads
      if (++_dryTicks < 2) return DryVerdict.fine;
      return DryVerdict.dry;
    }
    _dryTicks = 0;
    // standing still, no frame is due: a load, judged below
    _blindTicks = 0;
    // Standing still, any way short of the playhead is short: mpv waits for
    // the frame there. With the second's margin the dry track is given, a
    // cache that stopped at 148.1 s under a playhead at 149.0 s went
    // unnoticed for 13 s (2026-10-16 self-test). Nor does the cache need to
    // be short of it: one ending right at it has nothing more to play.
    if (!behind(
      position: position,
      cacheEnd: cacheEnd,
      duration: duration,
      margin: -atEndWithin,
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
