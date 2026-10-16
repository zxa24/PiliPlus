/// LibrePili (Windows): the computer going to sleep and waking, and its
/// display going off and on, from the runner's `WM_POWERBROADCAST`
/// (windows/runner/flutter_window.cpp), for the player.
///
/// A hardware decoder that crossed a sleep hung in the GPU driver and froze
/// the whole app (2026-10-15): the player lets go of it before the sleep
/// ([PlPlayerController.beforeSleep]). With modern standby the display
/// going off is the first thing said, so it counts too; while a video plays
/// the display stays on (wakelock), so off then means the lid, the power
/// button or a sleep.
///
/// Waking is the display coming on, not the resume message: with modern
/// standby Windows said "awake" one second after "going to sleep" and the
/// computer slept on for another minute (2026-10-16), which brought the
/// decoder back for the whole sleep.
library;

import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/services.dart';

abstract final class PowerEvents {
  static const _channel = MethodChannel('librepili/power');

  /// The display's last state said; the runner's registration says it at
  /// once. Off, a resume is not a wake.
  static var _displayOff = false;

  static void init() {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'suspend':
          EventLog.add('power', 'going to sleep');
          await _before('sleep');
        case 'resume':
          EventLog.add(
            'power',
            'awake${_displayOff ? ', the display still off: not yet' : ''}',
          );
          if (!_displayOff) _after('wake');
        case 'display':
          final state = call.arguments;
          EventLog.add(
            'power',
            'display ${switch (state) {
              0 => 'off',
              1 => 'on',
              2 => 'dimmed',
              _ => '$state',
            }}',
          );
          if (state == 0) {
            _displayOff = true;
            await _before('display off');
          } else if (state == 1) {
            _displayOff = false;
            _after('display on');
          }
      }
    });
  }

  static Future<void> _before(String why) async {
    await PlPlayerController.instance?.beforeSleep(why);
  }

  static void _after(String why) {
    PlPlayerController.instance?.afterSleep(why);
  }
}
