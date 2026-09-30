/// LibrePili: what the device decodes in hardware.
///
/// Two uses. AV1's answer decides the codec a stream is chosen in when the
/// user has not chosen one: Bilibili serves the same 1080P as AV1 at about a
/// quarter of AVC's bitrate (BV18yt46NEC5: 0.9 against 3.8 Mbps). With a
/// hardware decoder that is the same picture for a quarter of the traffic;
/// without one it is software decoding, which costs a phone its battery and
/// can drop frames, so AVC stays first there.
///
/// All four codecs' answers mark, in the quality lists, a quality this
/// device would decode in software (see soft_decode.dart), so the viewer
/// knows it may stutter or heat the phone up.
library;

import 'dart:io' show Platform;

import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// The video codecs the two platforms serve, by the decoder that plays them.
enum HwCodec {
  avc,
  hevc,
  vp9,
  av1;

  /// The decoder a stream's codec string needs: `avc1.640032` → [avc].
  /// Dolby Vision (`dvh1`, `dvhe`) is HEVC underneath, and mpv decodes it
  /// with the HEVC decoder. Null for anything else.
  static HwCodec? of(String codec) {
    final c = codec.toLowerCase();
    if (c.startsWith('avc1') || c.startsWith('avc3')) return avc;
    if (c.startsWith('hev1') ||
        c.startsWith('hvc1') ||
        c.startsWith('dvh1') ||
        c.startsWith('dvhe')) {
      return hevc;
    }
    if (c.startsWith('vp09') || c.startsWith('vp9')) return vp9;
    if (c.startsWith('av01')) return av1;
    return null;
  }
}

abstract final class CodecSupport {
  static const _channel = MethodChannel('librepili/codecs');

  /// Asks the platform once per start and remembers the answers: Android's
  /// codec list, Windows' D3D11 decoder profiles. Elsewhere nothing is
  /// known: AVC stays first and no quality is marked.
  static Future<void> check() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    await _checkAv1();
    try {
      final raw = await _channel.invokeMethod<Object?>('hardwareDecoders');
      final decoders = parseDecoders(raw);
      EventLog.add('player', 'codecs: in hardware: ${describe(decoders)}');
      if (decoders.isEmpty) return;
      await store(decoders);
    } catch (_) {
      // a platform without the method: what was known stays
    }
  }

  /// Read by Pref.av1Preferred. On an Android below 10 the device's word is
  /// not taken (null): AVC stays first there, as it always has.
  static Future<void> _checkAv1() async {
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

  /// The platform's answer, `{'avc': true, 'av1': false, ...}`: the codecs
  /// it answered for, each a bool. Anything else is left out, so a codec is
  /// either known or absent, never guessed.
  @visibleForTesting
  static Map<HwCodec, bool> parseDecoders(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final codec in HwCodec.values)
        if (raw[codec.name] case final bool hardware) codec: hardware,
    };
  }

  @visibleForTesting
  static Future<void> store(Map<HwCodec, bool> decoders) =>
      GStorage.setting.put(SettingBoxKey.hardwareDecoders, {
        for (final e in decoders.entries) e.key.name: e.value,
      });

  /// What is known of this device, from the last start's answer. AV1 also
  /// counts as software once mpv has been seen decoding it so
  /// ([noteSoftwareAv1]), whatever the device said.
  static Map<HwCodec, bool> get hardware {
    final known = Map.of(
      parseDecoders(GStorage.setting.get(SettingBoxKey.hardwareDecoders)),
    );
    if (GStorage.setting.get(SettingBoxKey.av1Software) == true) {
      known[HwCodec.av1] = false;
    }
    return known;
  }

  /// Hardware decoding is on at all: 设置 → 硬件解码, and a `--hwdec` that
  /// is not just `no`. Off, mpv decodes everything in software.
  static bool get hardwareDecodingOn {
    if (!Pref.enableHA) return false;
    return Pref.hardwareDecoding
        .split(',')
        .map((e) => e.trim())
        .any((e) => e.isNotEmpty && e != 'no');
  }

  static String describe(Map<HwCodec, bool> decoders) => decoders.isEmpty
      ? 'unknown'
      : [for (final e in decoders.entries) '${e.key.name}=${e.value}'].join(
          ' ',
        );

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
