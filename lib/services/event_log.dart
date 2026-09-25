/// LibrePili: what the app has lately done and seen, for the report shown
/// when a feature stops working altogether (see [FailureReport]).
///
/// Kept in memory and in release builds too: what playback recovery decided
/// (a host left, a stream handed over, a quality stepped down) is otherwise
/// only printed in debug builds, and the error log keeps crashes, not
/// decisions. Without it, "the video would not play" arrives with nothing
/// to say what was tried.
library;

import 'package:flutter/foundation.dart';

abstract final class EventLog {
  /// Lines kept; the oldest go first.
  static const _max = 300;

  static final _lines = <String>[];

  /// Records [message] under [area] (`player`, `asr`, `mpv`…), and prints it
  /// in a debug build.
  static void add(String area, String message) {
    final now = DateTime.now().toIso8601String();
    final line = '${now.substring(11, 23)} [$area] $message';
    _lines.add(line);
    if (_lines.length > _max) _lines.removeAt(0);
    if (kDebugMode) debugPrint(line);
  }

  /// Oldest first.
  static List<String> get recent => List.unmodifiable(_lines);
}
