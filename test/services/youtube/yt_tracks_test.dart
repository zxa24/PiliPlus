/// A YouTube video with dubbed audio: which automatic track is the speech.
library;

import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_menu.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_tracks.dart';
import 'package:flutter_test/flutter_test.dart';

YtFormat _audio(String? id, {bool original = false}) => YtFormat({
  'itag': 140,
  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
  'url': 'https://example.invalid/a',
  'audioTrack': ?(id == null
      ? null
      : {'id': id, 'displayName': id, 'audioIsDefault': original}),
});

YtCaptionTrack _auto(String language) => YtCaptionTrack(
  languageCode: language,
  baseUrl: '',
  vssId: 'a.$language',
  name: language,
  translatable: true,
);

void main() {
  test('the original audio is the one marked default', () {
    final formats = [
      _audio('ar.3'),
      _audio('en-US.4', original: true),
      _audio('it.10'),
    ];
    expect(ytOriginalAudioLanguage(formats), 'en');
  });

  test('a single audio track, or none marked, tells nothing', () {
    expect(ytOriginalAudioLanguage([_audio(null)]), isNull);
    expect(ytOriginalAudioLanguage([_audio('ar.3'), _audio('it.10')]), isNull);
  });

  // MwsckIZlc0Q (2026-09-29): spoken in English, 21 dubs, the Arabic dub's
  // automatic track listed first — and taken for the video's language
  test('only the original language\'s automatic track is the speech', () {
    final kinds = {
      for (final l in ['ar', 'pl', 'de-DE', 'en'])
        l: ytTrackKind(_auto(l), 'en'),
    };
    expect(kinds['en'], PlatformTrackKind.generated);
    expect(kinds['ar'], PlatformTrackKind.translated);
    expect(kinds['de-DE'], PlatformTrackKind.translated);
  });

  test('without dubs every automatic track is the speech, as before', () {
    expect(ytTrackKind(_auto('ja'), null), PlatformTrackKind.generated);
  });

  test("an author's track stays an author's", () {
    const track = YtCaptionTrack(
      languageCode: 'ar',
      baseUrl: '',
      vssId: '.ar',
      name: 'ar',
      translatable: true,
    );
    expect(ytTrackKind(track, 'en'), PlatformTrackKind.author);
  });

  test('spokenOf now finds English on such a video', () {
    final tracks = [
      for (final l in ['ar', 'pl', 'en'])
        (language: l, kind: ytTrackKind(_auto(l), 'en')),
    ];
    expect(spokenOf(null, tracks), ['en']);
  });
}
