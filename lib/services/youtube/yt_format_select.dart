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

import 'dart:async' show Zone;
import 'dart:convert' show utf8;

import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_quality_tier.dart';
import 'package:crypto/crypto.dart' show sha1;

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
    this.listedCodecsOnly = false,
    this.preferSdr = false,
    this.excludeMuxed = false,
    this.exactHeight,
    this.pin,
    this.preferNonDrc = false,
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

  /// Only the codecs listed in [videoCodecs] and [audioCodecs], with no
  /// fallback to whatever else is on offer: what a download needs, since
  /// the remuxer reads MP4 only (`avc1`/`av01` + `mp4a`), not WebM.
  final bool listedCodecsOnly;

  /// SDR before HDR at a height ([mp4Download] only): HDR AV1 shares the
  /// family `av01` with the SDR one and usually wins on bitrate, so a
  /// download above 1080p saved 10-bit PQ where the player had shown SDR
  /// VP9. Playback ranks as it always did.
  final bool preferSdr;

  /// Muxed formats ([YtFormat.isMuxed], e.g. itag 18) are not a video
  /// stream ([mp4Download] only): their codec family reads `avc1`.
  final bool excludeMuxed;

  /// LibrePili (stage-2 plan §3.3, §4.5): the video must be of this quality
  /// tier ([ytQualityTier]), or there is no pick — not the nearest under
  /// the cap. A download's chosen tier; the page never sets it (it goes by
  /// the short side and [maxHeight]).
  final int? exactHeight;

  /// LibrePili: the pair an earlier start of the download took; only that
  /// pair, or none (the bytes on disk are of it).
  final YtFormatPin? pin;

  /// LibrePili (§10-7 Q5 b): having picked a DRC audio format, the non-DRC
  /// one of the same itag and track instead when there is one. DRC alone
  /// is still picked; a [pin] decides over this.
  final bool preferNonDrc;

  /// With a [pin] or an [exactHeight]: a pick that can come up empty while
  /// the same preference without them finds a pair.
  bool get strict => pin != null || exactHeight != null;

  /// This preference without [pin] and [exactHeight].
  YtFormatPreference get loose => YtFormatPreference(
    maxHeight: maxHeight,
    videoCodecs: videoCodecs,
    audioCodecs: audioCodecs,
    allowDubbedAudio: allowDubbedAudio,
    preferredAudioLanguage: preferredAudioLanguage,
    listedCodecsOnly: listedCodecsOnly,
    preferSdr: preferSdr,
    excludeMuxed: excludeMuxed,
    preferNonDrc: preferNonDrc,
  );

  /// A pair the downloader can make one mp4 of, as close to [maxHeight] as
  /// MP4 goes; with [exactHeight], of that tier only; with [pin], that pair.
  static YtFormatPreference mp4Download(
    int maxHeight, {
    int? exactHeight,
    YtFormatPin? pin,
    bool preferNonDrc = false,
  }) => YtFormatPreference(
    maxHeight: maxHeight,
    videoCodecs: const ['avc1', 'av01'],
    audioCodecs: const ['mp4a'],
    listedCodecsOnly: true,
    preferSdr: true,
    excludeMuxed: true,
    exactHeight: exactHeight,
    pin: pin,
    preferNonDrc: preferNonDrc,
  );

  static const YtFormatPreference standard = YtFormatPreference();
}

/// LibrePili: the pair a download's earlier start took (stage-2 plan §3.3),
/// from its stream folder's `stream.json` — or, that unreadable, from the
/// folder's name, which carries the audio track as a digest only.
class YtFormatPin {
  const YtFormatPin({
    required this.videoItag,
    required this.audioItag,
    this.audioTrackId,
    this.audioTrackDigest,
    this.drc = false,
  });

  final int videoItag;
  final int audioItag;

  /// The audio track's id; null for a video with one track (or when only
  /// [audioTrackDigest] is known).
  final String? audioTrackId;

  /// [ytAudioTrackDigest] of the track, when the folder name is all there
  /// is; compared in place of [audioTrackId] then.
  final String? audioTrackDigest;

  /// The audio is DRC ([YtFormat.isDrc]).
  final bool drc;

  /// [f] is the pinned audio: its itag, its track, DRC or not alike.
  bool matchesAudio(YtFormat f) =>
      f.itag == audioItag &&
      f.isDrc == drc &&
      (audioTrackDigest != null
          ? ytAudioTrackDigest(f.audioTrackId) == audioTrackDigest
          : f.audioTrackId == audioTrackId);

  @override
  String toString() =>
      'YtFormatPin($videoItag-$audioItag, '
      'track ${audioTrackId ?? audioTrackDigest}, drc $drc)';
}

/// The first 12 lowercase hex digits of the SHA-1 of [audioTrackId]'s
/// UTF-8 bytes: how a stream folder's name carries the track (stage-2 plan
/// §3.3; ids such as `en:4` and `en_4` stay apart). Null without a track.
String? ytAudioTrackDigest(String? audioTrackId) => audioTrackId == null
    ? null
    : sha1.convert(utf8.encode(audioTrackId)).toString().substring(0, 12);

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
  // the self-tests' `--yt-inject drop:` (stage-2 plan §5): in a zone that
  // holds a set of itags under [ytSelfTestDropKey] (one source's calls),
  // those formats are not there
  if (Zone.current[ytSelfTestDropKey] case final Set<int> drop) {
    formats = formats.where((f) => !drop.contains(f.itag)).toList();
  }
  final video = selectYtVideoFormat(formats, pref);
  final audio = selectYtAudioFormat(formats, pref);
  if (video == null || audio == null) return null;
  return YtFormatSelection(video, audio);
}

/// The zone key of the itags a self-test leaves out ([selectYtFormats]).
const ytSelfTestDropKey = #librePiliYtSelfTestDrop;

/// The best video-only format under [pref], or null.
YtFormat? selectYtVideoFormat(
  List<YtFormat> formats, [
  YtFormatPreference pref = YtFormatPreference.standard,
]) {
  final playable = formats
      .where(
        (f) =>
            f.isVideo &&
            f.isPlayable &&
            !(pref.excludeMuxed && f.isMuxed) &&
            (!pref.listedCodecsOnly ||
                pref.videoCodecs.contains(f.codecFamily)),
      )
      .toList(growable: false);
  if (playable.isEmpty) return null;
  final rank = pref.preferSdr ? _bySdrThenResolution : _byResolutionThenBitrate;

  // a download's earlier pair: that video, or none
  if (pref.pin case final pin?) {
    final pinned = playable.where((f) => f.itag == pin.videoItag).toList()
      ..sort(rank);
    return pinned.isEmpty ? null : pinned.last;
  }

  // a download's tier: one of it, or none (never the nearest)
  if (pref.exactHeight case final tier?) {
    final atTier = playable
        .where((f) => ytQualityTier(f.width ?? 0, f.height ?? 0) == tier)
        .toList(growable: false);
    if (atTier.isEmpty) return null;
    // plan §4.5: the size first, by resolution then bitrate (two sizes of
    // one tier, e.g. 1920x800 and 1920x1080); then the codec and SDR order
    // among the formats of that size (review 2bc)
    final top = (atTier.toList()..sort(_byResolutionThenBitrate)).last;
    return _inCodecOrder(
      atTier
          .where((f) => f.width == top.width && f.height == top.height)
          .toList(growable: false),
      pref,
      rank,
    );
  }

  // The height first, the codec within it. Codec first (as it was) capped
  // each codec separately, and AVC tops out at 1080p: 1440p and 2160p,
  // offered only as VP9 and AV1, were never reached — picking 2160P played
  // 1080p AVC (LXb3EKWsInQ, 2026-09-29). The height list the page shows now
  // gets what it says.
  final top = _bestUnderHeightCap(playable, pref.maxHeight);
  if (top == null) return null;
  final side = _shortSide(top);
  final atHeight = playable
      .where((f) => _shortSide(f) == side)
      .toList(growable: false);
  return _inCodecOrder(atHeight, pref, rank);
}

/// The best of [atHeight] in [pref]'s codec order.
YtFormat _inCodecOrder(
  List<YtFormat> atHeight,
  YtFormatPreference pref,
  int Function(YtFormat a, YtFormat b) rank,
) {
  for (final codec in pref.videoCodecs) {
    final pool = atHeight
        .where((f) => f.codecFamily == codec)
        .toList(growable: false);
    if (pool.isEmpty) continue;
    return (pool.toList()..sort(rank)).last;
  }
  // No preferred codec at that height: whatever is there, and let the
  // caller's codec support decide.
  return (atHeight.toList()..sort(rank)).last;
}

/// SDR before HDR within a height ([YtFormatPreference.preferSdr]).
int _bySdrThenResolution(YtFormat a, YtFormat b) {
  final bySdr = (_isHdr(a) ? 0 : 1).compareTo(_isHdr(b) ? 0 : 1);
  if (bySdr != 0) return bySdr;
  return _byResolutionThenBitrate(a, b);
}

/// `colorInfo.transferCharacteristics` other than BT.709; none given is SDR.
bool _isHdr(YtFormat f) {
  final info = f.raw['colorInfo'];
  final transfer = info is Map ? info['transferCharacteristics'] : null;
  return transfer is String && !transfer.endsWith('BT709');
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

/// The smaller dimension, so a 720x1280 portrait video counts as 720p: what
/// a height cap and the quality list both go by.
int ytShortSide(YtFormat f) => _shortSide(f);

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
      .where(
        (f) =>
            f.isAudio &&
            f.isPlayable &&
            (!pref.listedCodecsOnly ||
                pref.audioCodecs.contains(f.codecFamily)),
      )
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
        .where((f) => ytAudioLanguageOf(f)?.toLowerCase() == lang)
        .toList(growable: false);
    if (dubbed.isNotEmpty) pool = dubbed;
  }

  // Nothing is marked default (shape drift, or an odd video): fall back to
  // every track rather than returning nothing.
  if (pool.isEmpty) pool = playable;

  int byBitrate(YtFormat a, YtFormat b) => a.bitrate.compareTo(b.bitrate);

  // a download's earlier pair: that audio (track and DRC alike), in the
  // default track's pool, or none
  if (pref.pin case final pin?) {
    final pinned = pool.where(pin.matchesAudio).toList()..sort(byBitrate);
    return pinned.isEmpty ? null : pinned.last;
  }

  YtFormat? picked;
  for (final codec in pref.audioCodecs) {
    final byCodec = pool.where((f) => f.codecFamily == codec).toList();
    if (byCodec.isEmpty) continue;
    byCodec.sort(byBitrate);
    picked = byCodec.last;
    break;
  }
  final chosen = picked ?? (pool.toList()..sort(byBitrate)).last;

  // DRC only when there is no plain one of the same itag and track
  if (pref.preferNonDrc && chosen.isDrc) {
    final plain =
        pool
            .where(
              (f) =>
                  !f.isDrc &&
                  f.itag == chosen.itag &&
                  f.audioTrackId == chosen.audioTrackId,
            )
            .toList()
          ..sort(byBitrate);
    if (plain.isNotEmpty) return plain.last;
  }
  return chosen;
}

/// `de-DE.10` → `de-DE`; null when the format carries no audio track id.
/// The language part of [f]'s `audioTrack.id` (`en-US.4` → `en-US`).
String? ytAudioLanguageOf(YtFormat f) {
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
