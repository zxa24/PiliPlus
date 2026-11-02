/// LibrePili: what the command line may do to the running app beside
/// reading it — `POST /control/...` on the reader's server ([CtlServer]),
/// only while 设置 → 其它设置 → 允许命令行控制 is on. Made for diagnosing
/// performance on a desktop from a terminal (feature-logs/linux-4k-perf):
/// scroll what is under a point, size the window, trace who asks for
/// frames. Nothing here reads or changes an account, a setting or a file.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/services/ctl/ctl_frames.dart';
import 'package:PiliPlus/services/ctl/ctl_server.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

abstract final class CtlControl {
  static final Map<String, CtlControlEndpoint> endpoints = {
    '/control/scroll': scroll,
    '/control/window': window,
    '/control/trace-frames': traceFrames,
  };

  static double? _num(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value == null) return null;
    if (value is num && value.isFinite) return value.toDouble();
    throw CtlBadRequest('$key: a number, not $value');
  }

  /// A pointer of its own, apart from the mouse's, so a scroll from here
  /// never joins one the user is making.
  static const _device = 7311;

  /// Bumped by every scroll: a newer one ends the one still running.
  static var _scrolls = 0;

  /// `{dy = 120, times = 10, intervalMs = 50, x, y}`: [times] mouse-wheel
  /// steps of [dy] logical pixels (positive: down the page), [intervalMs]
  /// apart, at (x, y) in the window's logical pixels (the middle of the
  /// window by default). Answers at once; the steps run after.
  static Object? scroll(Map<String, Object?> body) {
    final dy = _num(body, 'dy') ?? 120;
    final times = (_num(body, 'times') ?? 10).round();
    final interval = (_num(body, 'intervalMs') ?? 50).round();
    if (times < 1 || times > 2000) throw const CtlBadRequest('times: 1–2000');
    if (interval < 8 || interval > 2000) {
      throw const CtlBadRequest('intervalMs: 8–2000');
    }
    if (times * interval > 120000) {
      throw const CtlBadRequest('times × intervalMs: at most 120 s');
    }
    final view = RendererBinding.instance.renderViews.firstOrNull;
    if (view == null) throw const CtlBadRequest('no window to scroll');
    final size = view.size;
    final at = Offset(
      _num(body, 'x') ?? size.width / 2,
      _num(body, 'y') ?? size.height / 2,
    );
    if (!(Offset.zero & size).contains(at)) {
      throw CtlBadRequest('x, y: inside ${size.width} × ${size.height}');
    }
    final run = ++_scrolls;
    unawaited(() async {
      for (var i = 0; i < times && run == _scrolls; i++) {
        GestureBinding.instance.handlePointerEvent(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            device: _device,
            viewId: view.flutterView.viewId,
            position: at,
            scrollDelta: Offset(0, dy),
          ),
        );
        await Future<void>.delayed(Duration(milliseconds: interval));
      }
    }());
    EventLog.add('ctl', 'control: scroll $dy × $times every $interval ms');
    return {
      'started': true,
      'x': at.dx,
      'y': at.dy,
      'window': [size.width, size.height],
      'dy': dy,
      'times': times,
      'intervalMs': interval,
      'durationMs': times * interval,
    };
  }

  /// `{action}`: `info` (the default), `maximize`, `unmaximize`, `minimize`,
  /// `restore`, or `size` with `width` and `height` in logical pixels.
  /// Desktop only. Answers with the window as it is after, half a second
  /// on (the window manager answers before the size lands).
  static Future<Object?> window(Map<String, Object?> body) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      throw const CtlBadRequest('window: desktop only');
    }
    final action = body['action'] ?? 'info';
    switch (action) {
      case 'info':
        break;
      case 'maximize':
        await windowManager.maximize();
      case 'unmaximize':
        await windowManager.unmaximize();
      case 'minimize':
        await windowManager.minimize();
      case 'restore':
        await windowManager.restore();
      case 'size':
        final width = _num(body, 'width');
        final height = _num(body, 'height');
        if (width == null || height == null || width < 200 || height < 200) {
          throw const CtlBadRequest('size: width and height, 200 or more');
        }
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        }
        await windowManager.setSize(Size(width, height));
      default:
        throw CtlBadRequest(
          'action: info, maximize, unmaximize, minimize, restore or size, '
          'not $action',
        );
    }
    if (action != 'info') {
      EventLog.add('ctl', 'control: window $action');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final size = await windowManager.getSize();
    final view = RendererBinding.instance.renderViews.firstOrNull?.flutterView;
    return {
      'action': action,
      'maximized': await windowManager.isMaximized(),
      'minimized': await windowManager.isMinimized(),
      // the window's, frame included, in logical pixels
      'size': [size.width, size.height],
      // what Flutter draws: its view, in the screen's pixels
      'physical': view == null
          ? null
          : [view.physicalSize.width, view.physicalSize.height],
      'devicePixelRatio': view?.devicePixelRatio,
    };
  }

  /// `{seconds = 10}`: the stacks of the frames asked for, from now, read
  /// back by `GET /frames` (`trace`).
  static Object? traceFrames(Map<String, Object?> body) {
    final seconds = (_num(body, 'seconds') ?? 10).round();
    try {
      final answer = CtlFrames.trace(seconds);
      EventLog.add('ctl', 'control: trace frames ${answer['seconds']} s');
      return answer;
    } on StateError catch (e) {
      throw CtlBadRequest(e.message);
    }
  }
}
