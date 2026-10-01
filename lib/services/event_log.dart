/// LibrePili: what the app has lately done and seen, for the report shown
/// when a feature stops working altogether (see [FailureReport]).
///
/// Kept in memory and in release builds too: what playback recovery decided
/// (a host left, a stream handed over, a quality stepped down) is otherwise
/// only printed in debug builds, and the error log keeps crashes, not
/// decisions. Without it, "the video would not play" arrives with nothing
/// to say what was tried.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

abstract final class EventLog {
  /// Lines kept; the oldest go first.
  static const _max = 300;

  static final _lines = <String>[];

  /// When each of [_lines] was added, for a reader asking only for what is
  /// new since a moment (the command-line reader, `/log?since=`).
  static final _times = <DateTime>[];

  /// Records [message] under [area] (`player`, `asr`, `mpv`…), and prints it
  /// in a debug build.
  static void add(String area, String message) {
    final at = DateTime.now();
    final line = '${at.toIso8601String().substring(11, 23)} [$area] $message';
    _lines.add(line);
    _times.add(at);
    if (_lines.length > _max) {
      _lines.removeAt(0);
      _times.removeAt(0);
    }
    if (kDebugMode) debugPrint(line);
    // only built when someone listens: 调试模式 off, nothing more is done
    if (_added.hasListener) _added.add((at: at, area: area, message: message));
  }

  /// Not synchronous: a line added while a frame is being built must not
  /// rebuild a listener (the debug overlay) in that same build.
  static final _added = StreamController<EventLogEntry>.broadcast();

  /// Each line as it is added, from when the listening starts (the debug
  /// overlay, see DebugOverlay).
  static Stream<EventLogEntry> get added => _added.stream;

  /// Oldest first.
  static List<String> get recent => List.unmodifiable(_lines);

  /// Oldest first, each with the moment it was added; only those after
  /// [since] when given.
  static List<(DateTime, String)> entries({DateTime? since}) => [
    for (var i = 0; i < _lines.length; i++)
      if (since == null || _times[i].isAfter(since)) (_times[i], _lines[i]),
  ];
}

typedef EventLogEntry = ({DateTime at, String area, String message});
