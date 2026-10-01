/// LibrePili: 调试模式 — what the app decides while a video plays (a run of
/// the transcription started or paused and why, the translation's stages,
/// a CDN host stalling), shown over the player's bottom-left corner like a
/// terminal: new lines at the bottom, each gone 15 s after it last changed.
///
/// Fed by [EventLog], which records these decisions anyway; and by
/// [DebugOverlay.progress] for what reports progress (how far the
/// transcription has got, a download's percentage), which changes a line
/// in place instead of adding one every second — and stays out of the
/// event log, whose 300 lines a failure report shows.
library;

import 'dart:async';

import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/foundation.dart';

/// One line of the overlay. [key] is the progress it reports, null for a
/// line from the event log.
class DebugLine {
  DebugLine._(this.id, this.key, this.message, this.text, this.at);

  /// Stays the same while the line is updated in place, so the view keeps
  /// its place (and its fade) for it.
  final int id;
  final String? key;

  /// As given, to tell an update that changes nothing.
  String message;

  /// As shown: the time and the area before [message].
  String text;

  /// When it was added or last changed: it goes [DebugOverlayModel.lifetime]
  /// after.
  DateTime at;
}

/// The lines, without the timers and the app around them (tested on their
/// own).
class DebugOverlayModel {
  DebugOverlayModel({
    this.maxLines = 8,
    this.lifetime = const Duration(seconds: 15),
  });

  /// More would cover the video; a terminal scrolls the rest away.
  final int maxLines;
  final Duration lifetime;

  final _lines = <DebugLine>[];
  var _ids = 0;

  /// Oldest (top) first, including lines past their [lifetime] until
  /// [prune] runs.
  List<DebugLine> get lines => List.unmodifiable(_lines);

  /// mpv's warnings arrive by the dozen while a stream opens (and only its
  /// errors in a release build anyway): just its errors, or they would push
  /// every decision off the screen.
  static bool shows(String area, String message) =>
      area != 'mpv' ||
      message.startsWith('error') ||
      message.startsWith('fatal');

  static String format(DateTime at, String area, String message) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)} '
        '[$area] $message';
  }

  /// A line from the event log, at the bottom. False when it is not shown.
  bool add(DateTime at, String area, String message) {
    if (!shows(area, message)) return false;
    _lines.add(
      DebugLine._(_ids++, null, message, format(at, area, message), at),
    );
    _trim();
    return true;
  }

  /// The line of progress [key] changed where it is, or added at the
  /// bottom if there is none (any more). The same [message] again is no
  /// change: a line stuck at one figure goes like any other. Whether
  /// anything changed.
  bool progress(DateTime at, String key, String area, String message) {
    for (final line in _lines) {
      if (line.key == key) {
        if (line.message == message) return false;
        line
          ..message = message
          ..text = format(at, area, message)
          ..at = at;
        return true;
      }
    }
    _lines.add(
      DebugLine._(_ids++, key, message, format(at, area, message), at),
    );
    _trim();
    return true;
  }

  /// The line of progress [key] gone: what it reported is over. Whether
  /// there was one.
  bool drop(String key) {
    final before = _lines.length;
    _lines.removeWhere((line) => line.key == key);
    return _lines.length != before;
  }

  /// Lines older than [lifetime] gone. Whether any were.
  bool prune(DateTime now) {
    final before = _lines.length;
    _lines.removeWhere((line) => now.difference(line.at) >= lifetime);
    return _lines.length != before;
  }

  /// When the next line goes, if any is left.
  DateTime? nextExpiry() {
    DateTime? next;
    for (final line in _lines) {
      final end = line.at.add(lifetime);
      if (next == null || end.isBefore(next)) next = end;
    }
    return next;
  }

  void clear() => _lines.clear();

  void _trim() {
    // the top line scrolls away, as in a terminal — a progress line too:
    // its next update brings it back at the bottom
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
  }
}

abstract final class DebugOverlay {
  /// The setting (设置 → 其它设置 → 调试模式, or the player's ⋮ menu), as
  /// the overlay and the switches follow it without a restart.
  static final enabled = ValueNotifier(false);

  /// Read before building anything for [progress]: off, nothing is.
  static bool get on => enabled.value;

  static final model = DebugOverlayModel();

  /// Changes whenever [model] does, for the view to rebuild.
  static final revision = ValueNotifier(0);

  static StreamSubscription<EventLogEntry>? _events;

  /// When each progress key last changed its line, and the update held
  /// back since (see [progress]).
  static final _lastAt = <String, DateTime>{};
  static final _held = <String, Timer>{};
  static final _pending = <String, (String, String Function())>{};

  static void setEnabled(bool value) {
    if (value == enabled.value) return;
    enabled.value = value;
    if (value) {
      _events = EventLog.added.listen((e) {
        if (model.add(e.at, e.area, e.message)) _changed();
      });
    } else {
      _events?.cancel();
      _events = null;
      for (final timer in _held.values) {
        timer.cancel();
      }
      _held.clear();
      _pending.clear();
      _lastAt.clear();
      model.clear();
      _changed();
    }
  }

  /// The line of progress [key] (one per thing that progresses: `asr`,
  /// `download <model>`) shows [text] under [area]. At most once per
  /// [every]: the transcription checks four times a second and a download
  /// reports every chunk, and a line rewritten that often cannot be read.
  /// The last update in between is shown when [every] has passed, so the
  /// final figure is never lost. [text] is only called when it is shown.
  static void progress(
    String key,
    String area,
    String Function() text, {
    Duration every = const Duration(seconds: 1),
  }) {
    if (!on) return;
    final now = DateTime.now();
    final last = _lastAt[key];
    final wait = last == null ? Duration.zero : every - now.difference(last);
    if (wait <= Duration.zero) {
      _held.remove(key)?.cancel();
      _pending.remove(key);
      _show(now, key, area, text());
      return;
    }
    // one timer per key, showing whatever was asked last
    _pending[key] = (area, text);
    _held[key] ??= Timer(wait, () {
      _held.remove(key);
      if (_pending.remove(key) case (final area, final text)? when on) {
        _show(DateTime.now(), key, area, text());
      }
    });
  }

  /// The line of progress [key] gone, with any update held back for it.
  static void drop(String key) {
    _held.remove(key)?.cancel();
    _pending.remove(key);
    _lastAt.remove(key);
    if (model.drop(key)) _changed();
  }

  static void _show(DateTime at, String key, String area, String text) {
    _lastAt[key] = at;
    if (model.progress(at, key, area, text)) _changed();
  }

  static void _changed() => revision.value++;
}
