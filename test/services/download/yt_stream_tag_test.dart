// LibrePili: the name of a YouTube download's stream folder, its streams'
// identity (stage-2 plan §3.3, design §2.2 p4#6; AC13):
// `<videoItag>-<audioItag>`, the audio track as the first 12 hex digits of
// the SHA-1 of its id (so `en:4` and `en_4`, which a cleaned-up name would
// merge, stay two), `.drc` for DRC audio (a DRC 140 and a plain one are
// two); and the pair a folder name alone gives back, its track compared
// by digest.
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:flutter_test/flutter_test.dart';

YtFormat _video(int itag) => YtFormat({
  'itag': itag,
  'mimeType': 'video/mp4; codecs="avc1.640028"',
  'url': 'https://example.invalid/$itag',
  'width': 1920,
  'height': 1080,
});

YtFormat _audio(int itag, {String? track, bool drc = false}) => YtFormat({
  'itag': itag,
  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
  'url': 'https://example.invalid/$itag',
  if (track != null) 'audioTrack': {'id': track, 'audioIsDefault': true},
  if (drc) 'isDrc': true,
});

void main() {
  test('one track: the two itags', () {
    expect(YtStreamTag.of(_video(137), _audio(140)), '137-140');
  });

  test('a track: its digest, 12 lowercase hex digits', () {
    final tag = YtStreamTag.of(_video(137), _audio(140, track: 'en.4'));
    expect(tag, '137-140.${ytAudioTrackDigest('en.4')}');
    expect(tag, matches(RegExp(r'^137-140\.[0-9a-f]{12}$')));
    // the first 12 hex digits of SHA-1("en.4") (python hashlib)
    expect(ytAudioTrackDigest('en.4'), '3809de5ce6c5');
    expect(ytAudioTrackDigest(null), isNull);
  });

  test('en:4 and en_4: two folders', () {
    final a = YtStreamTag.of(_video(137), _audio(140, track: 'en:4'));
    final b = YtStreamTag.of(_video(137), _audio(140, track: 'en_4'));
    expect(a, isNot(b));
    expect(a, isNot(contains('en')));
  });

  test('DRC: a folder of its own, ending .drc', () {
    final plain = YtStreamTag.of(_video(137), _audio(140, track: 'en.4'));
    final drc = YtStreamTag.of(
      _video(137),
      _audio(140, track: 'en.4', drc: true),
    );
    expect(drc, isNot(plain));
    expect(drc, endsWith('.drc'));
    expect(drc, '$plain.drc');
    expect(YtStreamTag.of(_video(137), _audio(140, drc: true)), '137-140.drc');
  });

  test('matches: the pair of a folder by its name alone', () {
    final en = _audio(140, track: 'en.4');
    final tag = YtStreamTag.of(_video(137), en);
    expect(YtStreamTag.matches(tag, _video(137), en), isTrue);
    expect(
      YtStreamTag.matches(tag, _video(137), _audio(140, track: 'it.10')),
      isFalse,
    );
    expect(YtStreamTag.matches(tag, _video(136), en), isFalse);
    expect(
      YtStreamTag.matches(
        tag,
        _video(137),
        _audio(140, track: 'en.4', drc: true),
      ),
      isFalse,
    );
    expect(YtStreamTag.matches('137-140', _video(137), _audio(140)), isTrue);
    expect(YtStreamTag.matches('0', _video(137), _audio(140)), isFalse);
  });

  test('the pin a folder name gives', () {
    final en = _audio(140, track: 'en.4');
    final pin = YtStreamTag.pinOf('${YtStreamTag.of(_video(137), en)}.drc')!;
    expect(pin.videoItag, 137);
    expect(pin.audioItag, 140);
    expect(pin.drc, isTrue);
    expect(pin.audioTrackDigest, ytAudioTrackDigest('en.4'));
    expect(pin.matchesAudio(_audio(140, track: 'en.4', drc: true)), isTrue);
    expect(pin.matchesAudio(en), isFalse);
    expect(YtStreamTag.pinOf('137-140')!.audioTrackDigest, isNull);
    expect(YtStreamTag.pinOf('0'), isNull);
    expect(YtStreamTag.pinOf('137-140.EN4'), isNull);
  });
}
