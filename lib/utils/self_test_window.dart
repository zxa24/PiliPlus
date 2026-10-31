/// LibrePili: the self-test's window on Windows stays behind whatever the
/// user is doing. The runner shows it at the bottom without activating it
/// (windows/runner/main.cpp); window_manager's show / setSize would bring
/// it to the top and take the focus, so a test started from a terminal
/// would pull the user out of their work every run.
library;

import 'dart:io' show Platform;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

abstract final class SelfTestWindow {
  static const _channel = MethodChannel('librepili/selftest');

  /// Whether the runner, not window_manager, shows and sizes the window.
  static bool get quiet => Platform.isWindows;

  /// [WindowManager.setSize], without raising or focusing the window where
  /// the runner can.
  static Future<void> setSize(Size size) async {
    if (!quiet) return windowManager.setSize(size);
    final ratio = windowManager.getDevicePixelRatio();
    await _channel.invokeMethod<void>('resize', {
      'width': (size.width * ratio).round(),
      'height': (size.height * ratio).round(),
    });
  }

  // The rest is Windows only (the runner's channel); nothing but the
  // self-test calls them. See feature-logs/watch-page-shell/design.md §5
  // 「自测窗口」.

  /// The screens, as `{width, height, dpi, primary}` (physical pixels).
  static Future<List<Map<Object?, Object?>>> monitors() async =>
      (await _channel.invokeListMethod<Map<Object?, Object?>>('monitors'))!;

  /// Moves the window, unmaximized, to the top left of the work area of the
  /// one screen of this resolution (physical) and DPI, not to the n-th one
  /// enumerated: the order is not stable. The move can change the window's
  /// DPI and Windows then resizes it, so the size is set after
  /// ([setContentSize]). Throws when no screen, or more than one, matches.
  static Future<void> moveToMonitor({
    required int width,
    required int height,
    required int dpi,
  }) => _channel.invokeMethod<void>('moveToMonitor', {
    'width': width,
    'height': height,
    'dpi': dpi,
  });

  /// Sizes the window so that its content (the client area) is [size] in
  /// logical pixels as the app lays out (`uiScale` applied, as
  /// `MediaQuery.sizeOf` reports), at the DPI the window has now: [resize]
  /// sets the outer window, and a title bar takes its height off the
  /// content. The runner reads the client area back and corrects once,
  /// and sets it again at the new DPI when the resize carried the window
  /// onto a screen of another; returned is what it got, in physical
  /// pixels, with the DPI in effect.
  static Future<({int width, int height, int dpi})> setContentSize(
    Size size,
  ) async {
    final got = (await _channel.invokeMapMethod<String, int>(
      'contentSize',
      {
        'width': size.width,
        'height': size.height,
        'scale': Pref.uiScale,
      },
    ))!;
    return (width: got['width']!, height: got['height']!, dpi: got['dpi']!);
  }

  /// Maximizes the window (it covers a screen: a run using it goes in a
  /// batch), then puts it back at the bottom of the window order without
  /// activating it, where the runner placed it. Maximizing can still
  /// activate it within the process for a moment: whether it then becomes
  /// the foreground window is Windows' foreground lock's to decide (the
  /// fullscreen probe never saw it become foreground). Answers whether it
  /// is maximized after.
  static Future<bool> maximize() async =>
      (await _channel.invokeMethod<bool>('maximize'))!;

  /// Undoes [maximize] without activating the window. Answers whether it
  /// is still maximized.
  static Future<bool> restore() async =>
      (await _channel.invokeMethod<bool>('restore'))!;

  /// Whether the window is the foreground one.
  static Future<bool> isForeground() async =>
      (await _channel.invokeMethod<bool>('foreground'))!;
}
