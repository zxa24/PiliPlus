/// LibrePili: what a YouTube caption track is to the subtitle menu.
///
/// A video with AI-dubbed audio carries one automatic track per dub, every
/// one `a.<lang>` like the transcript of the original speech. Taken in the
/// order YouTube lists them, the first was the video's language:
/// MwsckIZlc0Q, spoken in English with 21 dubs, came out as Arabic
/// (2026-09-29). The original is the audio track YouTube marks default.
library;

import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';

/// The language of the original audio, when [formats] carry dubs: that of
/// the audio track marked default. Null with a single audio track (no
/// `audioTrack` at all) or none marked — nothing then tells the tracks
/// apart, and every automatic one is taken as the speech, as before.
String? ytOriginalAudioLanguage(List<YtFormat> formats) {
  for (final f in formats) {
    if (f.isAudio && f.audioIsDefault) {
      final language = ytAudioLanguageOf(f);
      if (language != null && language.isNotEmpty) {
        return captionLanguage(language);
      }
    }
  }
  return null;
}

/// [track]'s kind: an automatic track in another language than the
/// [original] audio's is the transcript of a dub — the speech translated,
/// not the speech as it is.
///
/// A track of no known language (an Invidious instance that refused its
/// caption list, a label it did not know) is taken as the speech, as with
/// no dubs: nothing says it is a dub.
PlatformTrackKind ytTrackKind(YtCaptionTrack track, String? original) {
  if (!track.isAutomatic) return PlatformTrackKind.author;
  if (original == null) return PlatformTrackKind.generated;
  final language = _current(captionLanguage(track.languageCode));
  if (language.isEmpty) return PlatformTrackKind.generated;
  return language == _current(original)
      ? PlatformTrackKind.generated
      : PlatformTrackKind.translated;
}

/// The codes YouTube still uses for a few languages (Hebrew `iw`,
/// Indonesian `in`, Yiddish `ji`) as their current ones: the audio track
/// and the caption track need not say it the same way.
String _current(String language) => switch (language) {
  'iw' => 'he',
  'in' => 'id',
  'ji' => 'yi',
  _ => language,
};
