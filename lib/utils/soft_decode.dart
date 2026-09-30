/// LibrePili: would this quality be decoded in software here?
///
/// The quality lists mark such a quality 「软解码」 (user 2026-09-29): it
/// plays, but a phone may drop frames or heat up doing it. A label, not a
/// rule; nothing is hidden or chosen differently because of it.
///
/// The answer is about the codec the app would actually pick for that
/// quality, not about whether some codec on offer is decodable: bilibili's
/// 4K can come as HEVC and AV1 while the preference picks AV1, and that is
/// what would play.
library;

import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/utils/codec_support.dart';

/// The codec the app picks among [offered] (one quality's streams): the
/// first entry of [preference] (codec prefixes, most wanted first) that one
/// of them starts with, else the first offered, as the players fall back.
String? pickCodec(
  Iterable<String> offered,
  List<List<String>> preference,
) {
  for (final prefixes in preference) {
    for (final codec in offered) {
      if (prefixes.any(codec.startsWith)) return codec;
    }
  }
  return offered.firstOrNull;
}

/// Whether the quality whose streams come in [offered] codecs would be
/// decoded in software: hardware decoding is off, or the codec picked under
/// [preference] is one [hardware] says this device has no decoder for.
/// A codec the device did not answer for is not marked; nothing is known.
bool softwareOnly({
  required Iterable<String> offered,
  required List<List<String>> preference,
  required Map<HwCodec, bool> hardware,
  required bool hardwareDecoding,
}) {
  final picked = pickCodec(offered, preference);
  if (picked == null) return false;
  if (!hardwareDecoding) return true;
  final codec = HwCodec.of(picked);
  return codec != null && hardware[codec] == false;
}

/// For a quality [softwareOnly] marks with hardware decoding on: another
/// offered codec this device does decode in hardware, which the preference
/// passed over. Null when there is none. Not used to choose anything: it
/// says the preference, not the device, is why the quality is software.
String? hardwareAlternative({
  required Iterable<String> offered,
  required List<List<String>> preference,
  required Map<HwCodec, bool> hardware,
}) {
  final picked = pickCodec(offered, preference);
  if (picked == null) return null;
  final pickedCodec = HwCodec.of(picked);
  if (pickedCodec == null || hardware[pickedCodec] != false) return null;
  for (final codec in offered) {
    final c = HwCodec.of(codec);
    if (c != null && hardware[c] == true) return codec;
  }
  return null;
}

/// Bilibili: the qualities among [videos] (a play URL's dash streams) that
/// [softwareOnly] marks. [preference] is the order the player picks a
/// quality's stream in (VideoDetailController.findVideoByQa): the codec
/// playing now, then Pref.preferCodecs.
Set<int> biliSoftwareQualities({
  required Iterable<VideoItem> videos,
  required List<List<String>> preference,
  required Map<HwCodec, bool> hardware,
  required bool hardwareDecoding,
}) {
  final byQuality = <int, List<String>>{};
  for (final video in videos) {
    if (video.codecs case final codecs?) {
      (byQuality[video.id] ??= []).add(codecs);
    }
  }
  return {
    for (final MapEntry(key: quality, value: offered) in byQuality.entries)
      if (softwareOnly(
        offered: offered,
        preference: preference,
        hardware: hardware,
        hardwareDecoding: hardwareDecoding,
      ))
        quality,
  };
}

/// YouTube: of [heights] (the list's entries), those whose pick would be
/// decoded in software. Choosing a height caps the pick at it, and the pick
/// is [selectYtVideoFormat]'s under that cap, so that is the stream judged.
Set<int> ytSoftwareHeights({
  required List<YtFormat> formats,
  required Iterable<int> heights,
  required Map<HwCodec, bool> hardware,
  required bool hardwareDecoding,
}) => {
  for (final height in heights)
    if (selectYtVideoFormat(formats, YtFormatPreference(maxHeight: height))
        case final picked?
        when softwareOnly(
          offered: [picked.codec],
          preference: const [],
          hardware: hardware,
          hardwareDecoding: hardwareDecoding,
        ))
      height,
};
