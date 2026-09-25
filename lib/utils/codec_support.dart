/// LibrePili: whether the device decodes AV1 in hardware, which decides the
/// codec a stream is chosen in when the user has not chosen one.
///
/// Bilibili serves the same 1080P as AV1 at about a quarter of AVC's bitrate
/// (BV18yt46NEC5: 0.9 against 3.8 Mbps). With a hardware decoder that is the
/// same picture for a quarter of the traffic; without one it is software
/// decoding, which costs a phone its battery and can drop frames, so AVC
/// stays first there.
library;

import 'dart:io' show Platform;

import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/services.dart';

abstract final class CodecSupport {
  static const _channel = MethodChannel('librepili/codecs');

  /// Asks the platform once per start and remembers the answer (read by
  /// Pref.av1Preferred): Android's codec list, Windows' D3D11 decoder
  /// profiles. Elsewhere, or on an Android below 10, nothing is known and
  /// AVC stays first.
  static Future<void> check() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    // once mpv has decoded AV1 in software here, the device's own word is
    // not taken again
    if (GStorage.setting.get(SettingBoxKey.av1Software) == true) return;
    try {
      final hardware = await _channel.invokeMethod<bool>('av1Hardware');
      EventLog.add('player', 'codecs: AV1 in hardware: $hardware');
      if (hardware == null) return;
      await GStorage.setting.put(SettingBoxKey.av1Hardware, hardware);
    } catch (_) {
      // a platform without the channel: nothing known
    }
  }

  /// mpv played AV1 without hardware decoding although hardware decoding
  /// was on: whatever the device says, AVC comes first from now on.
  static void noteSoftwareAv1() {
    if (GStorage.setting.get(SettingBoxKey.av1Software) == true) return;
    EventLog.add('player', 'codecs: AV1 was decoded in software');
    GStorage.setting.putAll({
      SettingBoxKey.av1Software: true,
      SettingBoxKey.av1Hardware: false,
    });
  }
}
