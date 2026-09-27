/// LibrePili: the one subtitle switch (research/subtitle-switch-design-
/// 2026-09-26.md, 甲): what the subtitle menu picks is remembered for every
/// video, and decides what each video opens with.
///
/// Pure: the pages hand in what they know about the video, and are told what
/// to show and whether to start anything on the device.
library;

import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';

/// The values the remembered switch takes: [off], [original], or the code
/// of a language (`zh`, `zh-Hant`, `en`, …) — the language subtitles are
/// shown in, the speech's own lines as they are and the rest translated.
abstract final class SubtitleChoice {
  /// No subtitles at all, and nothing made on the device.
  static const off = 'off';

  /// What is said, in whatever language it is said (原文).
  static const original = 'original';

  /// The code the pages and the menu use for [choice]: `asr` for
  /// [original], the language otherwise, null for [off].
  static String? codeOf(String choice) => switch (choice) {
    off || '' => null,
    original => 'asr',
    final language => language,
  };

  /// The choice for a page's [code] (see [codeOf]).
  static String fromCode(String? code) => switch (code) {
    null => off,
    'asr' => original,
    final language => language,
  };
}

/// What the remembered switch starts as for someone who used the settings
/// it replaces (decision 1B: by what they did): automatic transcription
/// and automatic translation both on — subtitles in the app's language;
/// automatic transcription alone — the speech as it is; anything else —
/// off.
///
/// The old values are read as stored: `asrMode` 0 manual, 1 foreign
/// videos, 2 any video without subtitles; `translateMode` 0 manual, 1
/// automatic. Neither counted until its one-time prompt was answered
/// (`asrAsked`, `translateAsked`), as the old checks had it.
String migrateSubtitleChoice({
  required Object? asrMode,
  required Object? asrAsked,
  required Object? translateMode,
  required Object? translateAsked,
  required String appLanguage,
}) {
  final transcribes = asrAsked == true && (asrMode == 1 || asrMode == 2);
  final translates = translateAsked == true && translateMode == 1;
  if (transcribes && translates) return appLanguage;
  if (transcribes) return SubtitleChoice.original;
  return SubtitleChoice.off;
}

/// Who made a video platform's subtitle track.
enum PlatformTrackKind {
  /// Written by whoever published the video.
  author,

  /// The platform's recogniser: a transcript, in the language spoken.
  generated,

  /// The platform's machine translation of another track
  /// (英语（自动翻译）). A subtitle in its language — but never the speech
  /// as it is.
  translated,
}

/// A platform track as far as choosing one is concerned: its language tag
/// as the platform gives it (`zh-CN`, `ai-zh`, `en`…) and who made it.
typedef PlatformTrack = ({String language, PlatformTrackKind kind});

/// Whether a track tagged [tag] is in [language], a menu language code.
///
/// Chinese in either script counts as `zh` — someone reading Chinese reads
/// both — but `zh-Hant` is Traditional Chinese only.
bool trackInLanguage(String tag, String language) {
  final t = tag.trim().toLowerCase().replaceFirst(RegExp('^ai-'), '');
  final major = captionLanguage(t);
  if (language == 'zh-Hant') return major == 'zh' && _isTraditional(t);
  if (language == 'zh') return major == 'zh' || major == 'yue';
  return major == language.toLowerCase();
}

bool _isTraditional(String tag) =>
    tag.contains('hant') ||
    tag.endsWith('-tw') ||
    tag.endsWith('-hk') ||
    tag.endsWith('-mo');

/// The track of [tracks] to show for [code] — `asr` for the speech as it
/// is, or a language — by index, or null when none will do.
///
/// For a language: an author's track before the platform's transcript, and
/// that before a machine translation; for Chinese, one in the script asked
/// for first.
///
/// For the speech as it is, a machine translation never: the language
/// spoken is the one the platform's own transcript is in — an author's
/// track in that language, else that transcript. With no transcript to say
/// which language is spoken, an author's track only when it is the one
/// track there is: a second means translations, and which is the original
/// cannot be told ("Me at the zoo" ships German before English, and is in
/// English).
int? platformTrackFor(List<PlatformTrack> tracks, String? code) {
  if (code == null) return null;
  if (code == 'asr') {
    final spoken = tracks.indexed
        .where((e) => e.$2.kind == PlatformTrackKind.generated)
        .firstOrNull;
    if (spoken != null) {
      final language = captionLanguage(spoken.$2.language);
      for (final (i, t) in tracks.indexed) {
        if (t.kind == PlatformTrackKind.author &&
            captionLanguage(t.language) == language) {
          return i;
        }
      }
      return spoken.$1;
    }
    return tracks.length == 1 && tracks.single.kind == PlatformTrackKind.author
        ? 0
        : null;
  }
  int? best;
  var bestRank = 1 << 30;
  for (final (i, t) in tracks.indexed) {
    if (!trackInLanguage(t.language, code)) continue;
    var rank = t.kind.index * 2;
    // Chinese in the other script: after every track in the one asked for
    if (code == 'zh' && _isTraditional(t.language.toLowerCase())) rank += 10;
    if (rank < bestRank) {
      best = i;
      bestRank = rank;
    }
  }
  return best;
}

/// What a page does with a video: show nothing, show one of its platform
/// tracks, or show the subtitle made on the device for [OpenPlan.code].
enum OpenAction { none, platform, onDevice }

/// See [decideOnOpen]. [track] is set for [OpenAction.platform]; [code]
/// (`asr` or a language) for [OpenAction.onDevice].
typedef OpenPlan = ({OpenAction action, int? track, String? code});

const OpenPlan _nothing = (action: OpenAction.none, track: null, code: null);

/// What a video opens with, for the remembered [choice] (see
/// [SubtitleChoice]), the video's own [tracks], and the [source] preferred
/// when both could supply the subtitle. Also what picking a language in
/// the menu does, with the source the viewer tapped as [source].
///
/// The platform's track is used when it is preferred, or when the device
/// cannot make the subtitle; the device's when it is preferred, or when the
/// platform has none. The device can make:
/// - the speech as it is: when there is audio to transcribe
///   ([canTranscribe]) and the recogniser is on the device ([asrReady]);
/// - a language: with the translation model on the device
///   ([translateReady]), from the video's own track in another language
///   when there is one to translate (design 2026-09-19: a video's own
///   foreign subtitles are translated rather than transcribed), else from
///   a transcript.
///
/// Nothing that would need a model download is planned: an automatic
/// start never asks anything, and the menu asks before it plans again.
OpenPlan decideOnOpen({
  required String choice,
  required List<PlatformTrack> tracks,
  required SubtitleSourcePreference source,
  required bool canTranscribe,
  required bool asrReady,
  required bool translateReady,
}) {
  final code = SubtitleChoice.codeOf(choice);
  if (code == null) return _nothing;
  final match = platformTrackFor(tracks, code);
  final bool possible;
  if (code == 'asr') {
    possible = canTranscribe && asrReady;
  } else {
    possible =
        translateReady &&
        (captionToTranslateFor(tracks, code) != null ||
            (canTranscribe && asrReady));
  }
  if (match != null &&
      (source == SubtitleSourcePreference.platform || !possible)) {
    return (action: OpenAction.platform, track: match, code: null);
  }
  if (possible) return (action: OpenAction.onDevice, track: null, code: code);
  return _nothing;
}

/// The track of [tracks] the device would translate into [into], if any
/// (see [pickCaptionToTranslateInto]).
///
/// Never a machine translation: translating a translation compounds two
/// sets of errors, and it is no transcript to tell the language spoken by.
/// It still counts as a track in its language — the video has subtitles
/// in [into] when it has one.
int? captionToTranslateFor(List<PlatformTrack> tracks, String into) {
  if (tracks.any((t) => trackInLanguage(t.language, into))) return null;
  return pickCaptionToTranslateInto(
    [
      for (final t in tracks)
        (
          language: t.kind == PlatformTrackKind.translated ? '' : t.language,
          generated: t.kind == PlatformTrackKind.generated,
        ),
    ],
    into: into,
  );
}
