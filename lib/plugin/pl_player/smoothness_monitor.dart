/// LibrePili: every stretch of playback that does not look smooth, as one
/// line in the event log (user 2026-10-01: "所有被感知到的不流畅掉帧都被记录").
///
/// Two layers can each lose frames the other cannot see:
/// - mpv: a frame the decoder dropped, one the output dropped to keep up
///   with the sound, one shown late, one shown at the wrong moment, the
///   picture drifting from the sound, the playhead not moving at all;
/// - Flutter, which draws mpv's frames: a frame mpv delivered on time and
///   the app put on screen late, because a build or a raster ran long.
/// The player samples mpv once a second and Flutter reports its frame
/// timings; both land here, which merges the bad seconds into episodes and
/// says which layer lost what. Buffering is logged where it happens (see
/// PlPlayerController._logBuffering); here it only pauses the count.
///
/// Pure: no mpv, no Flutter, so the thresholds can be tested. The
/// thresholds are what is usually visible; a screen recording compared
/// against these lines is what will settle them (TODO.md).
library;

import 'dart:math' as math;

/// One second of mpv, as the player reads it. Counters are mpv's running
/// totals; null when mpv did not answer.
class SmoothSample {
  const SmoothSample({
    required this.at,
    required this.position,
    required this.playing,
    required this.buffering,
    this.decoderDrops,
    this.outputDrops,
    this.delayed,
    this.mistimed,
    this.avsync,
    this.quiet = false,
    this.atEnd = false,
  });

  /// Within a second of the end of the video.
  final bool atEnd;

  final DateTime at;

  /// The playhead, in seconds.
  final double? position;
  final bool playing;
  final bool buffering;

  /// `decoder-frame-drop-count`, `frame-drop-count`,
  /// `vo-delayed-frame-count`, `mistimed-frame-count`.
  final int? decoderDrops;
  final int? outputDrops;
  final int? delayed;
  final int? mistimed;

  /// `avsync`, seconds: how far the picture is from the sound.
  final double? avsync;

  /// Just after an open or a seek: frames are dropped there on purpose
  /// (a precise seek decodes up to its target), so they are not counted.
  final bool quiet;
}

/// What a bad stretch lost, by layer.
class SmoothEpisode {
  SmoothEpisode(this.start, this.position, this.context);

  final DateTime start;
  DateTime end = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where the playhead was when it began.
  final double? position;

  /// What else was going on (resolution, decoding, transcription…), read
  /// when it began.
  final String context;

  int decoderDrops = 0;
  int outputDrops = 0;
  int delayed = 0;
  int mistimed = 0;

  /// Video frames Flutter put on screen late or not at all.
  int uiMissed = 0;

  /// The longest gap between two frames Flutter drew, ms.
  int longestGapMs = 0;

  /// The furthest the picture was from the sound, ms.
  int worstAvsyncMs = 0;

  Duration get length => end.difference(start);

  String describe() {
    final at = position == null ? '' : ' @${position!.toStringAsFixed(0)}s';
    final seconds = (length.inMilliseconds / 1000).toStringAsFixed(1);
    final total = decoderDrops + outputDrops + delayed + mistimed + uiMissed;
    return '不流畅 $seconds s$at: $total 帧'
        ' (解码丢 $decoderDrops · 输出丢 $outputDrops · 晚到 $delayed'
        ' · 时机错 $mistimed · 界面漏 $uiMissed)'
        '${longestGapMs > 0 ? ' · 最长间隔 $longestGapMs ms' : ''}'
        '${worstAvsyncMs > 0 ? ' · 声画差 $worstAvsyncMs ms' : ''}'
        '${context.isEmpty ? '' : ' · $context'}';
  }
}

class SmoothnessMonitor {
  SmoothnessMonitor({
    required this.log,
    this.context = _none,
    this.badFramesPerSecond = 2,
    this.avsyncVisible = 0.08,
    this.stuckAfter = 3,
    this.longestEpisode = const Duration(seconds: 10),
  });

  /// Where the lines go (the event log).
  final void Function(String line) log;

  /// What else is going on, read when an episode begins.
  final String Function() context;
  static String _none() => '';

  /// Lost frames in one second that make it a bad one: a single dropped
  /// frame is rarely seen, a few in a second are.
  final int badFramesPerSecond;

  /// Picture and sound this far apart (seconds) are seen as out of step.
  final double avsyncVisible;

  /// Seconds of a playhead that does not move, playing and not buffering,
  /// before it is called stuck.
  final int stuckAfter;

  /// An episode this long is logged and a new one begun, so a stretch that
  /// never ends still shows.
  final Duration longestEpisode;

  SmoothSample? _last;
  SmoothEpisode? _episode;

  /// Flutter's account since the last sample: frames missed, longest gap.
  int _uiMissed = 0;
  int _uiGapMs = 0;

  /// Seconds the playhead has not moved.
  int _still = 0;
  bool _stuckLogged = false;
  double? _stuckAt;

  /// The episode under way, for the debug overlay.
  SmoothEpisode? get current => _episode;

  /// Frames Flutter drew while a video played: [gapsMs] between one frame's
  /// end and the next's, against the video's own frame interval.
  void addUiGaps(Iterable<int> gapsMs, {required double videoFps}) {
    if (videoFps <= 0) return;
    final interval = 1000 / videoFps;
    for (final gap in gapsMs) {
      // half a frame of slack: a 24 fps video on a 60 Hz screen alternates
      // 33 and 50 ms and is smooth as it can be
      if (gap > interval * 1.5) {
        _uiMissed += math.max(1, (gap / interval).round() - 1);
      }
      if (gap > _uiGapMs) _uiGapMs = gap;
    }
  }

  void add(SmoothSample s) {
    final last = _last;
    _last = s;
    final counting =
        last != null && s.playing && last.playing && !s.buffering && !s.quiet;
    if (!counting) {
      // a pause, a buffering, an open or a seek ends the stretch
      _finish(s.at);
      _endStuck(s);
      _still = 0;
      _uiMissed = 0;
      _uiGapMs = 0;
      return;
    }

    int delta(int? now, int? before) {
      if (now == null || before == null) return 0;
      // a new source starts its counters at 0
      return now >= before ? now - before : now;
    }

    final decoder = delta(s.decoderDrops, last.decoderDrops);
    final output = delta(s.outputDrops, last.outputDrops);
    final delayed = delta(s.delayed, last.delayed);
    final mistimed = delta(s.mistimed, last.mistimed);
    final ui = _uiMissed;
    final gap = _uiGapMs;
    _uiMissed = 0;
    _uiGapMs = 0;
    final avsync = (s.avsync ?? 0).abs();

    _watchStuck(s, last);

    final lost = decoder + output + delayed + mistimed + ui;
    final bad = lost >= badFramesPerSecond || avsync >= avsyncVisible;
    if (!bad) {
      _finish(s.at);
      return;
    }
    final episode = _episode ??= SmoothEpisode(
      last.at,
      last.position,
      _safeContext(),
    );
    episode
      ..end = s.at
      ..decoderDrops += decoder
      ..outputDrops += output
      ..delayed += delayed
      ..mistimed += mistimed
      ..uiMissed += ui
      ..longestGapMs = math.max(episode.longestGapMs, gap)
      ..worstAvsyncMs = math.max(
        episode.worstAvsyncMs,
        avsync >= avsyncVisible ? (avsync * 1000).round() : 0,
      );
    if (episode.length >= longestEpisode) _finish(s.at);
  }

  /// The playhead not moving, playing and not buffering: mpv says it plays
  /// and nothing on screen changes (a 403 after a 9.5 h pause did this).
  void _watchStuck(SmoothSample s, SmoothSample last) {
    final now = s.position;
    final before = last.position;
    if (now == null || before == null || (now - before).abs() > 0.05) {
      _endStuck(s);
      _still = 0;
      return;
    }
    // the end of the video is where a playhead stops
    if (s.atEnd) return;
    _still++;
    if (_still >= stuckAfter && !_stuckLogged) {
      _stuckLogged = true;
      _stuckAt = now;
      log(
        '卡住: 播放中、未缓冲，画面 $_still s 未动 @${now.toStringAsFixed(1)}s'
        '${_safeContext().isEmpty ? '' : ' · ${_safeContext()}'}',
      );
    }
  }

  void _endStuck(SmoothSample s) {
    if (!_stuckLogged) return;
    _stuckLogged = false;
    log(
      '卡住结束: ${_still}s 后'
      '${s.position == null ? '' : ' 位置 ${s.position!.toStringAsFixed(1)}s'}'
      '${_stuckAt == null ? '' : '（自 ${_stuckAt!.toStringAsFixed(1)}s）'}',
    );
    _stuckAt = null;
  }

  void _finish(DateTime at) {
    final episode = _episode;
    if (episode == null) return;
    _episode = null;
    log(episode.describe());
  }

  /// Logs what is under way; for the end of a source.
  void flush() {
    _finish(DateTime.now());
    _last = null;
    _still = 0;
    _stuckLogged = false;
    _uiMissed = 0;
    _uiGapMs = 0;
  }

  String _safeContext() {
    try {
      return context();
    } catch (_) {
      return '';
    }
  }
}
