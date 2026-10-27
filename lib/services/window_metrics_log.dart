/// LibrePili: the window's size and scale in the event log, on a desktop.
///
/// Reported 2026-10-27: on entering fullscreen by a double click, the
/// window covered its screen (3840x2160 at 125 %, next to one at 200 %)
/// and the controls answered, but the bottom bar was laid out about 2.2
/// times the screen's width and the danmaku drawn twice their size; after
/// leaving fullscreen it would not happen again. Nothing recorded what
/// size the view, the page or the player had at that moment, and a
/// release build has no other way to ask. These lines are that record:
/// the view's metrics here, the player's own sizes in PLVideoPlayer.
library;

import 'dart:async';

import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/widgets.dart';

abstract final class WindowMetricsLog {
  static _Observer? _observer;

  /// Starts noting changes of the view's scale (at once) and size (once a
  /// resize has stopped for [_settle]).
  static void start() {
    if (_observer != null) return;
    WidgetsBinding.instance.addObserver(_observer = _Observer());
  }

  static const _settle = Duration(milliseconds: 500);

  /// The first view's size and scale, its display's, and the scale the app
  /// lays out at (with 界面缩放): `view 3840x2160 @1.25 · display 3840x2160
  /// @1.25 · layout @1.25`.
  static String describe() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 'no view';
    final view = views.first;
    final parts = [
      'view ${sizeText(view.physicalSize)} @${_ratio(view.devicePixelRatio)}',
    ];
    try {
      final display = view.display;
      parts.add(
        'display ${sizeText(display.size)} @${_ratio(display.devicePixelRatio)}',
      );
    } catch (_) {
      // an engine that reports no display for the view
    }
    parts.add(
      'layout @${_ratio(ScaledWidgetsFlutterBinding.instance.devicePixelRatioScaled)}',
    );
    return parts.join(' · ');
  }

  /// `1280x720`, or `-` when there is none.
  static String sizeText(Size? size) => size == null
      ? '-'
      : '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';

  static String _ratio(double ratio) =>
      ratio.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}

class _Observer with WidgetsBindingObserver {
  double? _ratio;
  Size? _size;
  Timer? _settling;

  _Observer() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      _ratio = views.first.devicePixelRatio;
      _size = views.first.physicalSize;
    }
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    if (view.devicePixelRatio != _ratio) {
      _ratio = view.devicePixelRatio;
      _size = view.physicalSize;
      _settling?.cancel();
      EventLog.add('window', 'scale changed: ${WindowMetricsLog.describe()}');
      return;
    }
    if (view.physicalSize == _size) return;
    _settling?.cancel();
    _settling = Timer(WindowMetricsLog._settle, () {
      final now = WidgetsBinding.instance.platformDispatcher.views.first;
      if (now.physicalSize == _size) return;
      _size = now.physicalSize;
      EventLog.add('window', 'resized: ${WindowMetricsLog.describe()}');
    });
  }
}
