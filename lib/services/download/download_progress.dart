import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// LibrePili: one download's progress over all of its parts as a single
/// fraction — the danmaku, the video and audio streams, the merge and the
/// extras saved next to the video (subtitles, comments, ...). Each part is
/// weighed by the time it is expected to take: bytes at the speed this
/// download gets, requests at the time one takes here. The estimates firm
/// up as the parts run (sizes from the response headers, the real number of
/// comments, measured speeds), so the bar can wait or jump a little, but
/// [value] never goes back.
class DownloadProgress extends ChangeNotifier {
  DownloadProgress({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  // --------------------------------------------------------------- extras

  static const stepCover = 'cover';
  static const stepDanmaku = 'danmaku';
  static const stepSubtitles = 'subtitles';
  static const stepCommentList = 'commentList';
  static const stepComments = 'comments';

  /// Seconds one unit of a step takes before it has been measured: a
  /// request (the comment lists wait 200 ms between pages and between a
  /// comment's reply pages), a comment with its pictures, a local copy.
  static const _unitSeconds = {
    stepCover: 0.05,
    stepDanmaku: 0.5,
    stepSubtitles: 0.4,
    stepCommentList: 0.6,
    stepComments: 0.4,
  };

  /// Comments per page of the hot list.
  static const commentsPerPage = 20;

  static String _stepName(String step) => switch (step) {
    stepCover => '保存封面',
    stepDanmaku => '导出弹幕',
    stepSubtitles => '保存字幕',
    stepCommentList => '获取评论列表',
    stepComments => '保存评论',
    _ => step,
  };

  final _steps = <String, _Step>{};

  /// The extras step running now.
  String? _step;

  /// The extras to come, as units per step (see [_unitSeconds]); replaces
  /// any earlier plan. An empty plan: nothing is saved next to the video.
  void planExtras(Map<String, int> units) {
    _steps
      ..clear()
      ..addAll({
        for (final MapEntry(:key, :value) in units.entries)
          key: _Step(_unitSeconds[key] ?? 0.4)..total = value,
      });
    _step = null;
    _changed();
  }

  /// The plan for the extras switched on: comments as the pages of their
  /// list plus each comment (with its replies and pictures).
  static Map<String, int> extrasPlan({
    required bool cover,
    required bool danmaku,
    required bool subtitles,
    required int comments,
  }) => {
    if (cover) stepCover: 1,
    if (danmaku) stepDanmaku: 1,
    if (subtitles) stepSubtitles: 2,
    if (comments > 0) ...{
      stepCommentList: (comments / commentsPerPage).ceil(),
      stepComments: comments,
    },
  };

  /// [step] begins (its units as planned).
  void extrasStart(String step) {
    _steps.putIfAbsent(step, () => _Step(_unitSeconds[step] ?? 0.4));
    _step = step;
    _changed();
  }

  /// [done] of [total] units of [step]; [total] replaces the planned count
  /// once the real one is known (e.g. fewer comments than asked for).
  void extras(String step, int done, int total) {
    final s = _steps[step] ??= _Step(_unitSeconds[step] ?? 0.4);
    _step = step;
    s
      ..start ??= _clock()
      ..total = math.max(total, 0)
      ..done = done.clamp(0, math.max(total, 0));
    // timed once a few units are in, so one slow first request does not
    // stretch the whole estimate
    if (s.done >= 3) {
      final elapsed = _clock().difference(s.start!).inMilliseconds / 1000;
      if (elapsed > 0) s.seconds = elapsed / s.done;
    }
    _changed();
  }

  /// [step] is over, whatever was reached (an error or nothing to save
  /// ends it too).
  void extrasDone(String step) {
    final s = _steps[step];
    if (s != null) s.done = s.total;
    if (_step == step) _step = null;
    _changed();
  }

  /// What the extras are doing now, e.g. "保存评论 12/200".
  String? get extrasLabel {
    final step = _step;
    if (step == null) return null;
    final s = _steps[step]!;
    return s.total > 1
        ? '${_stepName(step)} ${s.done}/${s.total}'
        : _stepName(step);
  }

  // ---------------------------------------------------------------- media

  int danmakuDone = 0;
  int danmakuTotal = 0;
  int videoReceived = 0;
  int videoTotal = 0;
  int audioReceived = 0;
  int audioTotal = 0;

  /// Expected size of both streams before the transfer reports them.
  int mediaGuess = 0;

  /// Whether an audio stream comes with the video (dash); unknown before
  /// the play URL.
  bool? expectAudio;

  bool merged = false;

  /// Measured over this run of the transfer; until then a fair connection.
  double bytesPerSecond = 3e6;

  /// Remuxing is a local copy, much faster than the network.
  static const _mergeBytesPerSecond = 150e6;

  static const _requestSeconds = 0.3;

  DateTime? _mediaStart;
  int _mediaStartBytes = 0;

  void danmaku(int done, int total) {
    danmakuDone = done;
    danmakuTotal = total;
    _changed();
  }

  void video(int received, int total) {
    videoReceived = received;
    if (total > 0) videoTotal = total;
    _measure();
  }

  void audio(int received, int total) {
    audioReceived = received;
    if (total > 0) audioTotal = total;
    _measure();
  }

  int get mediaReceived => videoReceived + audioReceived;

  /// Both streams once the transfer has reported them; the guess until then
  /// (a stream not reported yet would make the total jump up later). Either
  /// stream may report first.
  int get mediaTotal {
    final known = videoTotal + audioTotal;
    final allKnown = videoTotal > 0 && (expectAudio == false || audioTotal > 0);
    return allKnown ? known : math.max(known, mediaGuess);
  }

  /// A stream is complete: its last bytes are not always reported.
  void videoDone() => video(videoTotal, videoTotal);

  void audioDone() => audio(audioTotal, audioTotal);

  void _measure() {
    final now = _clock();
    final bytes = mediaReceived;
    if (_mediaStart == null) {
      _mediaStart = now;
      _mediaStartBytes = bytes;
    } else {
      final elapsed = now.difference(_mediaStart!).inMilliseconds / 1000;
      if (elapsed >= 2 && bytes > _mediaStartBytes) {
        bytesPerSecond = (bytes - _mediaStartBytes) / elapsed;
      }
    }
    _changed();
  }

  /// The download's status changed (what the bar's label says).
  void statusChanged() => notifyListeners();

  void mergeDone() {
    merged = true;
    _changed();
  }

  /// A new run of the transfer (started or resumed): the speed is measured
  /// again, the parts start over from what is on disk.
  void restart() {
    _mediaStart = null;
    expectAudio = null;
    danmakuDone = danmakuTotal = 0;
    audioReceived = audioTotal = 0;
    merged = false;
    _shown = 0;
    _changed();
  }

  // ---------------------------------------------------------------- total

  double _shown = 0;

  /// 0..1 over all parts; never goes back within a run.
  double get value => _shown;

  /// Everything is saved.
  void complete() {
    _step = null;
    for (final s in _steps.values) {
      s.done = s.total;
    }
    merged = true;
    _shown = 1;
    notifyListeners();
  }

  /// Expected seconds and the share done, per part.
  @visibleForTesting
  List<(double, double)> get parts {
    final total = mediaTotal;
    return [
      (
        danmakuTotal * _requestSeconds,
        danmakuTotal == 0 ? 1 : danmakuDone / danmakuTotal,
      ),
      (
        total / bytesPerSecond,
        total == 0 ? 0 : math.min(mediaReceived / total, 1),
      ),
      (math.max(0.5, total / _mergeBytesPerSecond), merged ? 1 : 0),
      for (final s in _steps.values)
        (s.total * s.seconds, s.total == 0 ? 1 : s.done / s.total),
    ];
  }

  void _changed() {
    var all = 0.0, done = 0.0;
    for (final (seconds, share) in parts) {
      all += seconds;
      done += seconds * share;
    }
    if (all > 0) _shown = math.max(_shown, math.min(done / all, 1));
    notifyListeners();
  }
}

class _Step {
  _Step(this.seconds);

  /// Per unit: the default until measured.
  double seconds;
  int done = 0;
  int total = 0;
  DateTime? start;
}
