/// LibrePili: the self-test's window on Windows stays behind whatever the
/// user is doing. The runner shows it at the bottom without activating it
/// (windows/runner/main.cpp); window_manager's show / setSize would bring
/// it to the top and take the focus, so a test started from a terminal
/// would pull the user out of their work every run.
library;

import 'dart:io' show Platform;

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
}
