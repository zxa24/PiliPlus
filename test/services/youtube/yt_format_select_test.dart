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

  // Picking 2160P played 1080p AVC: the codec was chosen before the height
  // (LXb3EKWsInQ, 2026-09-29)
  group('the height is chosen before the codec', () {
    YtFormat v(int itag, String codec, int height) => YtFormat({
      'itag': itag,
      'mimeType': 'video/${codec == 'avc1' ? 'mp4' : 'webm'}; codecs="$codec"',
      'url': 'https://example.invalid/$itag',
      'width': height * 16 ~/ 9,
      'height': height,
      'bitrate': height * 1000,
    });
    final formats = [
      v(137, 'avc1', 1080),
      v(248, 'vp9', 1080),
      v(271, 'vp9', 1440),
      v(313, 'vp9', 2160),
      v(401, 'av01', 2160),
    ];

    test('a 2160 cap gets 2160, in the preferred codec there', () {
      final f = selectYtVideoFormat(
        formats,
        const YtFormatPreference(maxHeight: 2160),
      )!;
      expect(f.height, 2160);
      expect(f.codecFamily, 'vp9');
    });

    test('1440 likewise', () {
      expect(
        selectYtVideoFormat(
          formats,
          const YtFormatPreference(maxHeight: 1440),
        )!.height,
        1440,
      );
    });

    test('where AVC is on offer at the height, AVC as before', () {
      final f = selectYtVideoFormat(formats)!;
      expect(f.height, 1080);
      expect(f.codecFamily, 'avc1');
    });
  });

  group('HDR', () {
    YtFormat av1(int itag, int bitrate, String? transfer) => YtFormat({
      'itag': itag,
      'mimeType': 'video/mp4; codecs="av01.0.12M.10"',
      'url': 'https://example.invalid/$itag',
      'width': 3840,
      'height': 2160,
      'fps': 30,
      'bitrate': bitrate,
      if (transfer != null) 'colorInfo': {'transferCharacteristics': transfer},
    });

    test('an MP4 download takes SDR AV1 over the HDR one at a height', () {
      final f = selectYtVideoFormat([
        av1(401, 12000000, 'COLOR_TRANSFER_CHARACTERISTICS_BT709'),
        av1(701, 20000000, 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084'),
      ], YtFormatPreference.mp4Download(2160))!;
      expect(f.itag, 401);
    });

    test('no colorInfo counts as SDR', () {
      final f = selectYtVideoFormat([
        av1(701, 20000000, 'COLOR_TRANSFER_CHARACTERISTICS_ARIB_STD_B67'),
        av1(401, 12000000, null),
      ], YtFormatPreference.mp4Download(2160))!;
      expect(f.itag, 401);
    });

    test('playback ranks as before: the higher-bitrate HDR one', () {
      final f = selectYtVideoFormat([
        av1(401, 12000000, 'COLOR_TRANSFER_CHARACTERISTICS_BT709'),
        av1(701, 20000000, 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084'),
      ], const YtFormatPreference(maxHeight: 2160))!;
      expect(f.itag, 701);
    });

    test('HDR only: still picked', () {
      final f = selectYtVideoFormat([
        av1(701, 20000000, 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084'),
      ], YtFormatPreference.mp4Download(2160))!;
      expect(f.itag, 701);
    });
  });

  // LibrePili, stage 2c (stage-2 plan §3.3, §4.5; AC13): what a download's
  // preference adds — muxed formats left out, its pinned pair, its exact
  // tier, plain audio before DRC. The cases above are unchanged.
  group("a download's preference", () {
    YtFormat video(int itag, int w, int h, {String codec = 'avc1.640028'}) =>
        YtFormat(
          fakeFormat(
            itag: itag,
            mimeType: 'video/mp4; codecs="$codec"',
            width: w,
            height: h,
            bitrate: w * h,
          ),
        );
    YtFormat audio(
      int itag, {
      int bitrate = 128000,
      String? track,
      bool isDefault = true,
      bool drc = false,
    }) => YtFormat({
      ...fakeFormat(
        itag: itag,
        mimeType: 'audio/mp4; codecs="mp4a.40.2"',
        bitrate: bitrate,
        audioTrackId: track,
        audioIsDefault: isDefault,
      ),
      if (drc) 'isDrc': true,
    });
    // itag 18: 360p video and audio in one stream, its codec family avc1
    final muxed = YtFormat(
      fakeFormat(
        itag: 18,
        mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
        width: 640,
        height: 360,
        bitrate: 9000000,
      ),
    );

    test('muxed and DRC read off the format', () {
      expect(muxed.isMuxed, isTrue);
      expect(video(134, 640, 360).isMuxed, isFalse);
      expect(audio(140, drc: true).isDrc, isTrue);
      expect(audio(140).isDrc, isFalse);
    });

    test('itag 18 is not the video stream of a download', () {
      final picked = selectYtFormats([
        muxed,
        video(134, 640, 360),
        audio(140),
      ], YtFormatPreference.mp4Download(360))!;
      expect(picked.video.itag, 134);
      // muxed alone: no video stream to pair
      expect(
        selectYtVideoFormat([muxed], YtFormatPreference.mp4Download(360)),
        isNull,
      );
      // the page is unchanged: it may still play it
      expect(
        selectYtVideoFormat([muxed], YtFormatPreference.standard),
        muxed,
      );
    });

    group('the two 140s', () {
      // the original track (default) and a dub, both itag 140
      final original = audio(140, track: 'en.4');
      final dub = audio(140, track: 'it.10', isDefault: false, bitrate: 256000);
      final formats = [video(137, 1920, 1080), original, dub];

      test('pinned to the original: the original', () {
        final picked = selectYtFormats(
          formats,
          YtFormatPreference.mp4Download(
            1080,
            pin: const YtFormatPin(
              videoItag: 137,
              audioItag: 140,
              audioTrackId: 'en.4',
            ),
          ),
        )!;
        expect(picked.audio, original);
      });

      test('pinned to the dub: none — a pin is looked for in the default '
          "track's pool only", () {
        expect(
          selectYtFormats(
            formats,
            YtFormatPreference.mp4Download(
              1080,
              pin: const YtFormatPin(
                videoItag: 137,
                audioItag: 140,
                audioTrackId: 'it.10',
              ),
            ),
          ),
          isNull,
        );
      });

      test('pinned by a folder name (the digest): the original', () {
        final picked = selectYtFormats(
          formats,
          YtFormatPreference.mp4Download(
            1080,
            pin: YtFormatPin(
              videoItag: 137,
              audioItag: 140,
              audioTrackDigest: ytAudioTrackDigest('en.4'),
            ),
          ),
        )!;
        expect(picked.audio, original);
      });

      test('a pinned video that is not there: none', () {
        expect(
          selectYtVideoFormat(
            formats,
            YtFormatPreference.mp4Download(
              1080,
              pin: const YtFormatPin(videoItag: 299, audioItag: 140),
            ),
          ),
          isNull,
        );
      });
    });

    group('the exact tier', () {
      final hd = [video(137, 1920, 1080), video(136, 1280, 720), audio(140)];

      test('a tier that is there: that one, not the cap', () {
        final pref = YtFormatPreference.mp4Download(1080, exactHeight: 720);
        expect(selectYtVideoFormat(hd, pref)!.itag, 136);
      });

      test('a tier that is not there: none (not the nearest), while without '
          'it there is a pair', () {
        final pref = YtFormatPreference.mp4Download(1440, exactHeight: 1440);
        expect(selectYtFormats(hd, pref), isNull);
        expect(pref.strict, isTrue);
        expect(pref.loose.exactHeight, isNull);
        expect(pref.loose.strict, isFalse);
        expect(selectYtFormats(hd, pref.loose)!.video.itag, 137);
      });

      test('a wide film by tier, not by short side', () {
        final wide = [
          video(399, 1920, 800, codec: 'av01.0.08M.08'),
          video(398, 1280, 534, codec: 'av01.0.05M.08'),
          video(397, 854, 356, codec: 'av01.0.04M.08'),
          audio(140),
        ];
        expect(
          selectYtVideoFormat(
            wide,
            YtFormatPreference.mp4Download(1080, exactHeight: 1080),
          )!.itag,
          399,
        );
        expect(
          selectYtVideoFormat(
            wide,
            YtFormatPreference.mp4Download(1080, exactHeight: 720),
          )!.itag,
          398,
        );
      });

      test('within a tier, the codec order as before', () {
        final both = [
          video(399, 1920, 1080, codec: 'av01.0.08M.08'),
          video(137, 1920, 1080),
          audio(140),
        ];
        expect(
          selectYtVideoFormat(
            both,
            YtFormatPreference.mp4Download(1080, exactHeight: 1080),
          )!.itag,
          137,
        );
      });

      // review 2bc, plan §4.5: two sizes in one tier — the size by
      // resolution then bitrate first (1920x1080 over 1920x800), SDR and
      // codec order only within that size
      YtFormat sized(int itag, int w, int h, {required bool hdr}) => YtFormat({
        ...fakeFormat(
          itag: itag,
          mimeType: 'video/mp4; codecs="av01.0.08M.08"',
          width: w,
          height: h,
          bitrate: w * h,
        ),
        'colorInfo': {
          'transferCharacteristics': hdr
              ? 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084'
              : 'COLOR_TRANSFER_CHARACTERISTICS_BT709',
        },
      });

      test('two sizes of one tier: the larger, though only it is HDR', () {
        final pick = selectYtVideoFormat([
          sized(399, 1920, 800, hdr: false),
          sized(699, 1920, 1080, hdr: true),
          audio(140),
        ], YtFormatPreference.mp4Download(1080, exactHeight: 1080))!;
        expect((pick.width, pick.height), (1920, 1080));
      });

      test('within that size: SDR before HDR, as mp4Download ranks', () {
        final pick = selectYtVideoFormat([
          sized(399, 1920, 800, hdr: false),
          sized(699, 1920, 1080, hdr: true),
          sized(400, 1920, 1080, hdr: false),
          audio(140),
        ], YtFormatPreference.mp4Download(1080, exactHeight: 1080))!;
        expect(pick.itag, 400);
      });
    });

    // user 2026-11-01 (the 4320 tier): on an 8K video an exact 2160 pick
    // takes the 4K stream, not the 8K one that used to share its tier
    group('an 8K video', () {
      final formats = [
        video(571, 7680, 4320, codec: 'av01.0.16M.08'),
        video(401, 3840, 2160, codec: 'av01.0.12M.08'),
        video(400, 2560, 1440, codec: 'av01.0.12M.08'),
        audio(140),
      ];

      test('an exact 2160 pick: 3840x2160, not 7680x4320', () {
        final pick = selectYtVideoFormat(
          formats,
          YtFormatPreference.mp4Download(4320, exactHeight: 2160),
        )!;
        expect((pick.itag, pick.width, pick.height), (401, 3840, 2160));
      });

      test('an exact 4320 pick: the 8K stream', () {
        expect(
          selectYtVideoFormat(
            formats,
            YtFormatPreference.mp4Download(4320, exactHeight: 4320),
          )!.itag,
          571,
        );
      });
    });

    group('DRC', () {
      final plain = audio(140, bitrate: 128000);
      final drc = audio(140, bitrate: 130000, drc: true);

      test('plain before DRC, though DRC has the higher bitrate', () {
        expect(
          selectYtAudioFormat([
            drc,
            plain,
          ], YtFormatPreference.mp4Download(1080, preferNonDrc: true)),
          plain,
        );
        // without the preference: by bitrate, as before
        expect(
          selectYtAudioFormat([
            drc,
            plain,
          ], YtFormatPreference.mp4Download(1080)),
          drc,
        );
      });

      test('DRC alone: DRC', () {
        expect(
          selectYtAudioFormat([
            drc,
          ], YtFormatPreference.mp4Download(1080, preferNonDrc: true)),
          drc,
        );
      });

      test('pinned to DRC: DRC; pinned to plain: plain', () {
        YtFormat? pinned(bool isDrc) => selectYtAudioFormat(
          [drc, plain],
          YtFormatPreference.mp4Download(
            1080,
            preferNonDrc: true,
            pin: YtFormatPin(videoItag: 137, audioItag: 140, drc: isDrc),
          ),
        );
        expect(pinned(true), drc);
        expect(pinned(false), plain);
      });
    });
  });
}
