import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/utils/codec_support.dart';
import 'package:PiliPlus/utils/soft_decode.dart';
import 'package:flutter_test/flutter_test.dart';

// the order Pref.preferCodecs gives without AV1 hardware, and with it
const avcFirst = [
  ['avc1'],
  ['av01'],
];
const av1First = [
  ['av01'],
  ['avc1'],
];

// Pixel 4 XL (Snapdragon 855): no AV1 decoder in hardware
const noAv1 = {
  HwCodec.avc: true,
  HwCodec.hevc: true,
  HwCodec.vp9: true,
  HwCodec.av1: false,
};
const everything = {
  HwCodec.avc: true,
  HwCodec.hevc: true,
  HwCodec.vp9: true,
  HwCodec.av1: true,
};

bool soft(
  List<String> offered, {
  List<List<String>> preference = avcFirst,
  Map<HwCodec, bool> hardware = noAv1,
  bool on = true,
}) => softwareOnly(
  offered: offered,
  preference: preference,
  hardware: hardware,
  hardwareDecoding: on,
);

VideoItem video(int id, String codecs) =>
    VideoItem(id: id, codecs: codecs, quality: VideoQuality.fromCode(id));

YtFormat yt(int itag, String codecs, int height) => YtFormat({
  'itag': itag,
  'mimeType': 'video/mp4; codecs="$codecs"',
  'url': 'https://example.invalid/$itag',
  'bitrate': height * 1000,
  'width': height * 16 ~/ 9,
  'height': height,
});

void main() {
  group('HwCodec.of', () {
    test('names every codec string the two platforms serve', () {
      expect(HwCodec.of('avc1.640032'), HwCodec.avc);
      expect(HwCodec.of('hev1.1.6.L150.90'), HwCodec.hevc);
      expect(HwCodec.of('hvc1.2.4.L153.90'), HwCodec.hevc);
      // Dolby Vision: HEVC underneath
      expect(HwCodec.of('dvh1.08.07'), HwCodec.hevc);
      expect(HwCodec.of('vp9'), HwCodec.vp9);
      expect(HwCodec.of('vp09.00.51.08'), HwCodec.vp9);
      expect(HwCodec.of('av01.0.13M.08'), HwCodec.av1);
      expect(HwCodec.of('mp4a.40.2'), isNull);
      expect(HwCodec.of(''), isNull);
    });
  });

  group('pickCodec', () {
    test(
      'the first preference on offer, whatever order they are offered in',
      () {
        expect(pickCodec(['av01.0', 'avc1.64'], avcFirst), 'avc1.64');
        expect(pickCodec(['avc1.64', 'av01.0'], av1First), 'av01.0');
      },
    );

    test('nothing preferred on offer: the first offered, as the player', () {
      expect(
        pickCodec(
          ['hev1.1', 'av01.0'],
          [
            ['avc1'],
          ],
        ),
        'hev1.1',
      );
      expect(pickCodec(['hev1.1'], const []), 'hev1.1');
      expect(pickCodec(const [], avcFirst), isNull);
    });
  });

  group('softwareOnly', () {
    test('a hardware-decodable pick is not marked', () {
      expect(soft(['avc1.640032', 'av01.0.08M.08']), isFalse);
      expect(soft(['hev1.1.6.L150.90']), isFalse);
    });

    test('an AV1-only quality without an AV1 decoder is marked', () {
      expect(soft(['av01.0.13M.08']), isTrue);
    });

    test('hardware decoding off marks every quality', () {
      expect(soft(['avc1.640032'], on: false), isTrue);
      expect(soft(['avc1.640032'], hardware: everything, on: false), isTrue);
    });

    test('judged on the pick: the preference can pick the software one', () {
      // AV1 wanted first although it is software here: that is what plays
      expect(
        soft(['avc1.640032', 'av01.0.08M.08'], preference: av1First),
        isTrue,
      );
      expect(
        hardwareAlternative(
          offered: ['avc1.640032', 'av01.0.08M.08'],
          preference: av1First,
          hardware: noAv1,
        ),
        'avc1.640032',
      );
    });

    test('a codec the device did not answer for is not marked', () {
      expect(soft(['av01.0.13M.08'], hardware: const {}), isFalse);
      expect(
        soft(['av01.0.13M.08'], hardware: const {HwCodec.avc: true}),
        isFalse,
      );
      expect(soft(['xyz1']), isFalse);
    });

    test('no stream at all is not marked', () {
      expect(soft(const []), isFalse);
      expect(soft(const [], on: false), isFalse);
    });
  });

  group('hardwareAlternative', () {
    test('none when the pick is hardware or nothing else is', () {
      expect(
        hardwareAlternative(
          offered: ['avc1.64', 'av01.0'],
          preference: avcFirst,
          hardware: noAv1,
        ),
        isNull,
      );
      expect(
        hardwareAlternative(
          offered: ['av01.0'],
          preference: avcFirst,
          hardware: noAv1,
        ),
        isNull,
      );
    });
  });

  group('biliSoftwareQualities', () {
    // shaped like a real response: 4K in HEVC and AV1, 1080P in all three
    final videos = [
      video(120, 'hev1.1.6.L153.90'),
      video(120, 'av01.0.12M.08'),
      video(80, 'avc1.640032'),
      video(80, 'hev1.1.6.L120.90'),
      video(80, 'av01.0.08M.08'),
      video(64, 'avc1.64001F'),
    ];

    test('the current codec, then the preference, per quality', () {
      // playing AVC: 4K has none, falls to the preference's AV1 — software
      expect(
        biliSoftwareQualities(
          videos: videos,
          preference: [
            ['avc1'],
            ...avcFirst,
          ],
          hardware: noAv1,
          hardwareDecoding: true,
        ),
        {120},
      );
      // playing HEVC: 4K stays HEVC
      expect(
        biliSoftwareQualities(
          videos: videos,
          preference: [
            ['hev1', 'hvc1'],
            ...avcFirst,
          ],
          hardware: noAv1,
          hardwareDecoding: true,
        ),
        isEmpty,
      );
    });

    test('everything with hardware decoding off', () {
      expect(
        biliSoftwareQualities(
          videos: videos,
          preference: avcFirst,
          hardware: everything,
          hardwareDecoding: false,
        ),
        {120, 80, 64},
      );
    });
  });

  group('ytSoftwareHeights', () {
    final formats = [
      yt(137, 'avc1.640028', 1080),
      yt(136, 'avc1.4d401f', 720),
      yt(248, 'vp9', 1080),
      yt(271, 'vp9', 1440),
      yt(313, 'vp9', 2160),
      yt(401, 'av01.0.12M.08', 2160),
    ];

    test('judges the stream each cap picks', () {
      // the height first, then the codec: 2160 and 1440 are VP9 (hardware
      // here), 1080 and 720 AVC (not) — before 2026-09-29 every cap picked
      // AVC at 1080 at most
      expect(
        ytSoftwareHeights(
          formats: formats,
          heights: [2160, 1440, 1080, 720],
          hardware: const {
            HwCodec.avc: false,
            HwCodec.vp9: true,
            HwCodec.av1: true,
          },
          hardwareDecoding: true,
        ),
        {1080, 720},
      );
      expect(
        ytSoftwareHeights(
          formats: formats,
          heights: [2160, 1440, 1080, 720],
          hardware: noAv1,
          hardwareDecoding: true,
        ),
        isEmpty,
      );
    });

    test('a VP9-only video on a device without VP9 hardware', () {
      expect(
        ytSoftwareHeights(
          formats: [yt(313, 'vp9', 2160), yt(248, 'vp9', 1080)],
          heights: [2160, 1080],
          hardware: const {HwCodec.vp9: false},
          hardwareDecoding: true,
        ),
        {2160, 1080},
      );
    });
  });
}
