import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_test_support.dart';

List<YtFormat> _recordedFormats() => YtVideoDetail.fromPlayerJson(
  (loadYtFixture(YtFixtures.playerFormats)! as Map).cast<String, dynamic>(),
).formats;

int _shortSide(YtFormat f) => f.width! < f.height! ? f.width! : f.height!;

void main() {
  group('selection against the RECORDED 120-format response', () {
    late List<YtFormat> formats;

    setUp(() => formats = _recordedFormats());

    test('the fixture really does carry the traps this guards against', () {
      expect(formats.length, 120);
      expect(formats.every((f) => f.url != null), isTrue);
      expect(formats.any((f) => f.codecFamily == 'av01'), isTrue);
      final dubbed = formats.where(
        (f) => f.isAudio && f.audioTrackId != null && !f.audioIsDefault,
      );
      expect(dubbed.length, greaterThan(10));
      expect(
        formats.where((f) => f.isAudio && f.audioIsDefault).length,
        greaterThan(0),
      );
    });

    // THE audio trap: a naive "highest-bitrate mp4a" pick lands on a dub.
    test('audio pick is the DEFAULT track, never a dub', () {
      final audio = selectYtAudioFormat(formats)!;
      expect(audio.isAudio, isTrue);
      expect(audio.audioIsDefault, isTrue);
      expect(audio.codecFamily, 'mp4a');

      // And prove the naive rule would have picked something else: within the
      // codec we prefer, the loudest track is a dub. Recorded numbers: the
      // Hindi dub is 130 601 bps, the default track 130 307.
      final loudestMp4a = formats
          .where((f) => f.isAudio && f.codecFamily == 'mp4a')
          .reduce((a, b) => b.bitrate > a.bitrate ? b : a);
      expect(
        loudestMp4a.audioIsDefault,
        isFalse,
        reason: 'the naive highest-bitrate mp4a pick is a dubbed track here',
      );
      expect(loudestMp4a.bitrate, greaterThan(audio.bitrate));
    });

    test('a dub can be requested explicitly', () {
      final audio = selectYtAudioFormat(
        formats,
        const YtFormatPreference(
          allowDubbedAudio: true,
          preferredAudioLanguage: 'it',
        ),
      )!;
      expect(audio.audioTrackId, startsWith('it.'));
      expect(audio.audioIsDefault, isFalse);
    });

    test('an unavailable dub language falls back to the default track', () {
      final audio = selectYtAudioFormat(
        formats,
        const YtFormatPreference(
          allowDubbedAudio: true,
          preferredAudioLanguage: 'cy',
        ),
      )!;
      expect(audio.audioIsDefault, isTrue);
    });

    // THE video trap: a naive "highest resolution" pick lands on AV1.
    test('video pick prefers avc1 over vp9/av01', () {
      final video = selectYtVideoFormat(formats)!;
      expect(video.isVideo, isTrue);
      expect(video.codecFamily, 'avc1');
    });

    // The recorded video is PORTRAIT: its 720p rung is 720x1280. A naive
    // `height <= 1080` cap rejects it for being 1280 tall and silently serves
    // the 480p rung (480x854) instead.
    test(
      'the cap is applied to the SHORT side, so portrait is not downgraded',
      () {
        final video = selectYtVideoFormat(formats)!;
        expect(video.itag, 136);
        expect(video.width, 720);
        expect(video.height, 1280);
        expect(video.qualityLabel, '720p');
        expect(_shortSide(video), 720);
        // The trap, stated as an assertion: a height-based cap would have
        // rejected this exact format.
        expect(video.height, greaterThan(1080));
      },
    );

    test('a lower cap is honoured', () {
      final video = selectYtVideoFormat(
        formats,
        const YtFormatPreference(maxHeight: 480),
      )!;
      expect(_shortSide(video), lessThanOrEqualTo(480));
      expect(video.itag, 135);
      expect(_shortSide(video), 480);
    });

    test('maxHeight 0 lifts the cap but keeps the codec preference', () {
      final video = selectYtVideoFormat(
        formats,
        const YtFormatPreference(maxHeight: 0),
      )!;
      // avc1 tops out at 720 short-side in this response; vp9/av01 go no
      // higher, so an uncapped pick is still the 720p avc1.
      expect(video.codecFamily, 'avc1');
      expect(_shortSide(video), 720);
    });

    test('dropping avc1 from the preference reaches the vp9 rungs', () {
      final video = selectYtVideoFormat(
        formats,
        const YtFormatPreference(videoCodecs: ['vp9']),
      )!;
      expect(video.codecFamily, 'vp9');
    });

    test('selectYtFormats returns a usable pair', () {
      final pair = selectYtFormats(formats)!;
      expect(pair.video.isVideo, isTrue);
      expect(pair.audio.isAudio, isTrue);
      expect(pair.video.url, isNotNull);
      expect(pair.audio.url, isNotNull);
    });

    test('nothing in the recorded response needs JavaScript', () {
      expect(ytFormatsNeedingJavaScript(formats), isEmpty);
    });
  });

  group('selection edge cases', () {
    YtFormat f(Map<String, dynamic> m) => YtFormat(m);

    test('a cipher-only format is not playable and is flagged', () {
      final cipher = f(
        fakeFormat(
          itag: 137,
          mimeType: 'video/mp4; codecs="avc1.640028"',
          url: null,
          signatureCipher: 's=abc&sp=sig&url=https%3A%2F%2Fx.invalid',
        ),
      );
      expect(cipher.isPlayable, isFalse);
      expect(cipher.needsSignatureJs, isTrue);
      expect(cipher.needsJavaScript, isTrue);
      expect(ytFormatsNeedingJavaScript([cipher]), hasLength(1));
      expect(selectYtVideoFormat([cipher]), isNull);
    });

    test('a url carrying &n= needs the throttling function and is skipped', () {
      final throttled = f(
        fakeFormat(
          itag: 137,
          mimeType: 'video/mp4; codecs="avc1.640028"',
          url:
              'https://rr1.googlevideo.invalid/videoplayback?itag=137&n=Abc123',
          height: 1080,
          width: 1920,
        ),
      );
      expect(throttled.hasThrottleParam, isTrue);
      expect(throttled.needsJavaScript, isTrue);
      expect(throttled.isPlayable, isFalse);
      expect(selectYtVideoFormat([throttled]), isNull);
    });

    test('a SABR-shaped format list selects nothing', () {
      final sabr = [
        f(
          fakeFormat(
            itag: 137,
            mimeType: 'video/mp4; codecs="avc1"',
            url: null,
          ),
        ),
        f(
          fakeFormat(
            itag: 140,
            mimeType: 'audio/mp4; codecs="mp4a"',
            url: null,
          ),
        ),
      ];
      expect(selectYtFormats(sabr), isNull);
    });

    test('an empty list selects nothing', () {
      expect(selectYtFormats(const []), isNull);
      expect(selectYtVideoFormat(const []), isNull);
      expect(selectYtAudioFormat(const []), isNull);
    });

    test('video-only or audio-only input yields no pair', () {
      final videoOnly = [
        f(
          fakeFormat(
            itag: 137,
            mimeType: 'video/mp4; codecs="avc1.640028"',
            width: 1920,
            height: 1080,
          ),
        ),
      ];
      expect(selectYtVideoFormat(videoOnly), isNotNull);
      expect(selectYtAudioFormat(videoOnly), isNull);
      expect(selectYtFormats(videoOnly), isNull);
    });

    test(
      'when every rung is above the cap the SMALLEST is taken, not none',
      () {
        final only4k = [
          f(
            fakeFormat(
              itag: 401,
              mimeType: 'video/mp4; codecs="avc1.640034"',
              width: 3840,
              height: 2160,
            ),
          ),
          f(
            fakeFormat(
              itag: 402,
              mimeType: 'video/mp4; codecs="avc1.640034"',
              width: 2560,
              height: 1440,
            ),
          ),
        ];
        final picked = selectYtVideoFormat(only4k)!;
        expect(picked.height, 1440);
      },
    );

    test('an unknown codec is used rather than failing', () {
      final exotic = [
        f(
          fakeFormat(
            itag: 999,
            mimeType: 'video/mp4; codecs="vvc1.1.L1"',
            width: 1280,
            height: 720,
          ),
        ),
        f(fakeFormat(itag: 998, mimeType: 'audio/mp4; codecs="ec-3"')),
      ];
      final pair = selectYtFormats(exotic)!;
      expect(pair.video.itag, 999);
      expect(pair.audio.itag, 998);
    });

    test(
      'when NOTHING is marked default the loudest track is used rather than '
      'returning null',
      () {
        final noDefault = [
          f(
            fakeFormat(
              itag: 140,
              mimeType: 'audio/mp4; codecs="mp4a.40.2"',
              bitrate: 130000,
              audioTrackId: 'it.10',
            ),
          ),
          f(
            fakeFormat(
              itag: 139,
              mimeType: 'audio/mp4; codecs="mp4a.40.5"',
              bitrate: 50000,
              audioTrackId: 'fr.10',
            ),
          ),
        ];
        final audio = selectYtAudioFormat(noDefault)!;
        expect(audio.itag, 140);
      },
    );

    test('mp4a is preferred over opus even when opus is louder', () {
      final mixed = [
        f(
          fakeFormat(
            itag: 251,
            mimeType: 'audio/webm; codecs="opus"',
            bitrate: 160000,
          ),
        ),
        f(
          fakeFormat(
            itag: 140,
            mimeType: 'audio/mp4; codecs="mp4a.40.2"',
            bitrate: 130000,
          ),
        ),
      ];
      expect(selectYtAudioFormat(mixed)!.itag, 140);
    });

    test('higher fps wins at equal resolution', () {
      final sameRes = [
        f(
          fakeFormat(
            itag: 298,
            mimeType: 'video/mp4; codecs="avc1.4d4020"',
            width: 1280,
            height: 720,
            fps: 60,
          ),
        ),
        f(
          fakeFormat(
            itag: 136,
            mimeType: 'video/mp4; codecs="avc1.4d401f"',
            width: 1280,
            height: 720,
            fps: 30,
          ),
        ),
      ];
      expect(selectYtVideoFormat(sameRes)!.itag, 298);
    });
  });

  group('YtFormat parsing', () {
    test('codec, container and track fields come off the mime type', () {
      final fmt = YtFormat(
        fakeFormat(
          itag: 140,
          mimeType: 'audio/mp4; codecs="mp4a.40.2"',
          audioTrackId: 'de-DE.10',
        ),
      );
      expect(fmt.codec, 'mp4a.40.2');
      expect(fmt.codecFamily, 'mp4a');
      expect(fmt.container, 'audio/mp4');
      expect(fmt.isAudio, isTrue);
      expect(fmt.isVideo, isFalse);
      expect(fmt.audioTrackId, 'de-DE.10');
    });

    test('contentLength arrives as a decimal string', () {
      final fmt = YtFormat({
        'itag': 137,
        'mimeType': 'video/mp4; codecs="avc1"',
        'contentLength': '12773480',
        'approxDurationMs': '77535',
      });
      expect(fmt.contentLength, 12773480);
      expect(fmt.approxDurationMs, 77535);
    });

    test('a malformed url does not throw on the throttle check', () {
      final fmt = YtFormat({
        'itag': 1,
        'mimeType': 'video/mp4',
        'url': 'http://[oops',
      });
      expect(fmt.hasThrottleParam, isFalse);
    });
  });
}
