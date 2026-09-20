/// Choosing which of a video's formats to play.
///
/// Both halves of this have a measured trap behind them:
///
///  * **audio** — a naive "highest-bitrate `mp4a`" pick landed on the **Italian
///    dub** of the probe video, which carries 21 dubbed audio tracks. Only
///    `audioTrack.audioIsDefault` distinguishes the original; bitrate does not;
///  * **video** — the mirror image, measured in the Invidious spike: a naive
///    "highest resolution" pick landed on an **AV1** stream, which many of this
///    app's target devices cannot decode in hardware.
///
/// So both sides are codec-constrained first and only then ranked.
library;

import 'package:PiliPlus/services/youtube/yt_models.dart';

/// Video codecs in descending order of preference.
///
/// `avc1` first because it is the one every target device decodes in hardware.
/// `vp9` is a reasonable second; `av01` is last because hardware support is
/// still patchy on the phones this app runs on.
const List<String> ytVideoCodecPreference = ['avc1', 'vp9', 'av01'];

/// Audio codecs in descending order of preference. `mp4a` first: it muxes into
/// the mp4 container the downloader already produces without re-encoding.
const List<String> ytAudioCodecPreference = ['mp4a', 'opus', 'vorbis'];

/// How a caller narrows the video pick.
class YtFormatPreference {
  const YtFormatPreference({
    this.maxHeight = 1080,
    this.videoCodecs = ytVideoCodecPreference,
    this.audioCodecs = ytAudioCodecPreference,
    this.allowDubbedAudio = false,
    this.preferredAudioLanguage,
  });

  /// Cap on the *smaller* of the two video dimensions, so a portrait video is
  /// capped the same way a landscape one is. 0 means "no cap".
  final int maxHeight;

  final List<String> videoCodecs;
  final List<String> audioCodecs;

  /// When false (the default) a dubbed audio track is never selected unless it
  /// is the only thing on offer.
  final bool allowDubbedAudio;

  /// e.g. `de-DE`. Only consulted when [allowDubbedAudio] is true; matched
  /// against the language part of `audioTrack.id` (`de-DE.10` → `de-DE`).
  final String? preferredAudioLanguage;

  static const YtFormatPreference standard = YtFormatPreference();
}

/// A video stream and an audio stream chosen to be played together.
class YtFormatSelection {
  const YtFormatSelection(this.video, this.audio);

  final YtFormat video;
  final YtFormat audio;

  @override
  String toString() => 'YtFormatSelection(video: $video, audio: $audio)';
}

/// Pick a playable adaptive pair, or null when no pair satisfies [pref].
///
/// Only formats that can be handed straight to a player are considered
/// ([YtFormat.isPlayable] — a plain `url` with no `&n=` throttle parameter).
/// A format that would need JavaScript is NOT silently skipped elsewhere: the
/// caller reports it as (d) clientBroken, because it means our identity has
/// moved onto a cipher-bearing path.
YtFormatSelection? selectYtFormats(
  List<YtFormat> formats, [
  YtFormatPreference pref = YtFormatPreference.standard,
]) {
  final video = selectYtVideoFormat(formats, pref);
  final audio = selectYtAudioFormat(formats, pref);
  if (video == null || audio == null) return null;
  return YtFormatSelection(video, audio);
}

/// The best video-only format under [pref], or null.
YtFormat? selectYtVideoFormat(
  List<YtFormat> formats, [
  YtFormatPreference pref = YtFormatPreference.standard,
]) {
  final playable = formats
      .where((f) => f.isVideo && f.isPlayable)
      .toList(growable: false);
  if (playable.isEmpty) return null;

  for (final codec in pref.videoCodecs) {
    final pool = playable
        .where((f) => f.codecFamily == codec)
        .toList(growable: false);
    if (pool.isEmpty) continue;
    final best = _bestUnderHeightCap(pool, pref.maxHeight);
    if (best != null) return best;
  }
  // No preferred codec present: take whatever is there rather than failing,
  // and let the caller's codec support decide.
  return _bestUnderHeightCap(playable, pref.maxHeight);
}

YtFormat? _bestUnderHeightCap(List<YtFormat> pool, int maxHeight) {
  if (pool.isEmpty) return null;
  final sorted = pool.toList()..sort(_byResolutionThenBitrate);
  if (maxHeight <= 0) return sorted.last;
  final within = sorted.where((f) => _shortSide(f) <= maxHeight);
  // Everything is above the cap (e.g. a 4K-only video with a 1080 cap): take
  // the smallest rather than nothing.
  return within.isEmpty ? sorted.first : within.last;
}

/// The smaller dimension, so a 720x1280 portrait video counts as 720p.
int _shortSide(YtFormat f) {
  final w = f.width ?? 0;
  final h = f.height ?? 0;
  if (w == 0 || h == 0) return w == 0 ? h : w;
  return w < h ? w : h;
}

int _byResolutionThenBitrate(YtFormat a, YtFormat b) {
  final byShortSide = _shortSide(a).compareTo(_shortSide(b));
  if (byShortSide != 0) return byShortSide;
  final byPixels = ((a.width ?? 0) * (a.height ?? 0)).compareTo(
    (b.width ?? 0) * (b.height ?? 0),
  );
  if (byPixels != 0) return byPixels;
  final byFps = (a.fps ?? 0).compareTo(b.fps ?? 0);
  if (byFps != 0) return byFps;
  return a.bitrate.compareTo(b.bitrate);
}

/// The best audio-only format under [pref], or null.
///
/// The default track is selected first and the bitrate ranking happens only
/// inside it. Doing it the other way round is the dubbed-audio bug.
YtFormat? selectYtAudioFormat(
  List<YtFormat> formats, [
  YtFormatPreference pref = YtFormatPreference.standard,
]) {
  final playable = formats
      .where((f) => f.isAudio && f.isPlayable)
      .toList(growable: false);
  if (playable.isEmpty) return null;

  // A video with a single audio track has no `audioTrack` object at all; one
  // with dubs marks exactly one entry `audioIsDefault: true`.
  var pool = playable
      .where((f) => f.audioTrackId == null || f.audioIsDefault)
      .toList(growable: false);

  if (pref.allowDubbedAudio && pref.preferredAudioLanguage != null) {
    final lang = pref.preferredAudioLanguage!.toLowerCase();
    final dubbed = playable
        .where((f) => _audioLanguageOf(f)?.toLowerCase() == lang)
        .toList(growable: false);
    if (dubbed.isNotEmpty) pool = dubbed;
  }

  // Nothing is marked default (shape drift, or an odd video): fall back to
  // every track rather than returning nothing.
  if (pool.isEmpty) pool = playable;

  for (final codec in pref.audioCodecs) {
    final byCodec = pool.where((f) => f.codecFamily == codec).toList();
    if (byCodec.isEmpty) continue;
    byCodec.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return byCodec.last;
  }
  final rest = pool.toList()..sort((a, b) => a.bitrate.compareTo(b.bitrate));
  return rest.last;
}

/// `de-DE.10` → `de-DE`; null when the format carries no audio track id.
String? _audioLanguageOf(YtFormat f) {
  final id = f.audioTrackId;
  if (id == null) return null;
  final dot = id.lastIndexOf('.');
  return dot <= 0 ? id : id.substring(0, dot);
}

/// Formats that would need a JavaScript engine. Measured 0/852 today; the
/// caller turns a non-empty result into a loud (d) clientBroken verdict rather
/// than skipping them, because their appearance means YouTube moved us onto a
/// cipher-bearing path.
List<YtFormat> ytFormatsNeedingJavaScript(List<YtFormat> formats) =>
    formats.where((f) => f.needsJavaScript).toList(growable: false);
