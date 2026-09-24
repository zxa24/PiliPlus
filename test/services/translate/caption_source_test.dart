import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:flutter_test/flutter_test.dart';

// the opening of 5CvlKCBrPHI's automatic English track, as YouTube serves it
const _rolling = '''WEBVTT
Kind: captions
Language: en

00:00:04.400 --> 00:00:07.550 align:start position:0%

My<00:00:04.520><c> name</c><00:00:04.720><c> is</c><00:00:04.880><c> Kate.</c><00:00:05.920><c> I</c><00:00:06.000><c> am</c><00:00:06.120><c> a</c><00:00:06.200><c> designer.</c>

00:00:07.550 --> 00:00:07.560 align:start position:0%
My name is Kate. I am a designer.


00:00:07.560 --> 00:00:10.270 align:start position:0%
My name is Kate. I am a designer.
And<00:00:07.760><c> my</c><00:00:08.080><c> design</c><00:00:08.680><c> superpower</c>

00:00:10.270 --> 00:00:10.280 align:start position:0%
And my design superpower


00:00:10.280 --> 00:00:12.030 align:start position:0%
And my design superpower
is<00:00:10.400><c> noticing.</c>
''';

// and of jefegEyJJfQ's automatic Japanese one
const _events = '''WEBVTT

00:00:01.309 --> 00:00:05.884 align:start position:0%

[音楽]

00:00:05.884 --> 00:00:05.894 align:start position:0%



00:00:08.440 --> 00:00:13.870 align:start position:0%

ハーベスティ<00:00:09.240><c>花</c><00:00:09.480><c>だ</c><00:00:09.599><c>よ</c><00:00:09.840><c>。</c>
''';

void main() {
  group('parseCaptionCues', () {
    test('each line of a rolling track arrives once', () {
      final cues = parseCaptionCues(_rolling);
      expect(cues.map((c) => c.content), [
        'My name is Kate. I am a designer.',
        'And my design superpower',
        'is noticing.',
      ]);
      expect((cues[1].from, cues[1].to), (7.56, 10.27));
    });

    test('a line holding one space does not end the cue', () {
      // YouTube pads rolling cues with these; a split on blank lines took
      // them for a boundary and lost the text below
      const vtt =
          'WEBVTT\n\n00:00:04.400 --> 00:00:07.550 align:start\n \n'
          'My<00:00:04.520><c> name</c>\n\n'
          '00:00:07.550 --> 00:00:07.560 align:start\nMy name\n \n\n'
          '00:00:07.560 --> 00:00:10.270 align:start\nMy name\nis Kate.\n';
      expect(parseCaptionCues(vtt).map((c) => c.content), [
        'My name',
        'is Kate.',
      ]);
    });

    test('sound events are not speech', () {
      expect(parseCaptionCues(_events).map((c) => c.content), ['ハーベスティ花だよ。']);
    });

    test('on-screen text in brackets is kept', () {
      const vtt =
          'WEBVTT\n\n00:01.000 --> 00:03.000\n'
          "[This is not a toilet. It's over there]\n\n"
          '00:03.000 --> 00:04.000\n[Applause]\n';
      expect(parseCaptionCues(vtt).map((c) => c.content), [
        "[This is not a toilet. It's over there]",
      ]);
    });

    test("bilibili's subtitle JSON, as the page converts it", () {
      // the `body` of a bilibili subtitle file, as VideoHttp.getSubtitles
      // receives it and hands to json2Vtt
      final body = [
        {
          'from': 0.52,
          'to': 2.3,
          'sid': 1,
          'location': 2,
          'content': 'So here we are,',
          'music': 0.0,
        },
        {
          'from': 2.3,
          'to': 4.1,
          'sid': 2,
          'location': 2,
          'content': 'in front of\nthe elephants.',
          'music': 0.0,
        },
        {
          'from': 6.0,
          'to': 7.5,
          'sid': 3,
          'location': 2,
          'content': 'That is cool.',
          'music': 0.0,
        },
      ];
      final cues = parseCaptionCues(SubtitleUtils.json2Vtt(body));
      expect(cues.map((c) => c.content), [
        'So here we are,',
        'in front of the elephants.',
        'That is cool.',
      ]);
      expect((cues.first.from, cues.first.to), (0.52, 2.3));
      expect(buildCaptionUnits(cues).map((u) => u.text), [
        'So here we are, in front of the elephants.',
        'That is cool.',
      ]);
    });

    test('an ordinary track and SRT timing read as they are', () {
      const vtt =
          'WEBVTT\n\n00:01.000 --> 00:03.500\nHello there.\n\n'
          '00:03.500 --> 00:06.000\nSecond line\nwith a break.\n';
      expect(parseCaptionCues(vtt).map((c) => c.content), [
        'Hello there.',
        'Second line with a break.',
      ]);
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nOne.\n';
      expect(parseCaptionCues(srt).single.from, 1.0);
    });

    test('an ordinary track says a line twice when it is said twice', () {
      // back to back, as a rolling track's cues are, but with none of its
      // timing tags or hold cues
      const vtt =
          'WEBVTT\n\n00:01.000 --> 00:02.000\nNo!\n\n'
          '00:02.000 --> 00:03.000\nNo!\n';
      expect(parseCaptionCues(vtt).map((c) => c.content), ['No!', 'No!']);
      const srt =
          '1\n00:00:01,000 --> 00:00:02,000\nNo!\n\n'
          '2\n00:00:02,000 --> 00:00:03,000\nNo!\nNot again.\n';
      expect(parseCaptionCues(srt).map((c) => c.content), [
        'No!',
        'No! Not again.',
      ]);
    });
  });

  group('buildCaptionUnits', () {
    test('a sentence spread over lines is one unit', () {
      final units = buildCaptionUnits(parseCaptionCues(_rolling));
      expect(units.map((u) => u.text), [
        'My name is Kate. I am a designer.',
        'And my design superpower is noticing.',
      ]);
      expect(units[1].cues, hasLength(2));
    });

    test('without punctuation, a pause or the cap ends a unit', () {
      const vtt =
          'WEBVTT\n\n00:00.000 --> 00:01.000\na\n\n'
          '00:01.000 --> 00:02.000\nb\n\n00:05.000 --> 00:06.000\nc\n\n'
          '00:06.000 --> 00:07.000\nd\n\n00:07.000 --> 00:08.000\ne\n\n'
          '00:08.000 --> 00:09.000\nf\n\n00:09.000 --> 00:10.000\ng\n';
      expect(buildCaptionUnits(parseCaptionCues(vtt)).map((u) => u.text), [
        'a b', // pause after
        'c d e f', // four lines
        'g',
      ]);
    });
  });

  group('pickCaptionToTranslate', () {
    test('nothing when a track is already in the app language', () {
      expect(
        pickCaptionToTranslate([
          (language: 'en', generated: false),
          (language: 'zh-CN', generated: false),
        ], appLanguage: 'zh'),
        isNull,
      );
      // bilibili's AI Chinese counts
      expect(
        pickCaptionToTranslate([
          (language: 'en-US', generated: false),
          (language: 'ai-zh', generated: true),
        ], appLanguage: 'zh'),
        isNull,
      );
    });

    test("an author's track before a generated one", () {
      expect(
        pickCaptionToTranslate([
          (language: 'en', generated: true),
          (language: 'en', generated: false),
        ], appLanguage: 'zh'),
        1,
      );
      expect(
        pickCaptionToTranslate([
          (language: 'ai-en', generated: true),
        ], appLanguage: 'zh'),
        0,
      );
    });

    test("the author's track in the spoken language", () {
      // the generated track is a transcript: its language is the audio's
      expect(
        pickCaptionToTranslate([
          (language: 'fr', generated: false),
          (language: 'ja', generated: false),
          (language: 'ja', generated: true),
        ], appLanguage: 'zh'),
        1,
      );
      // no transcript to go by: English before the rest
      expect(
        pickCaptionToTranslate([
          (language: 'de', generated: false),
          (language: 'en', generated: false),
        ], appLanguage: 'zh'),
        1,
      );
      // spoken language known but no author wrote in it: the transcript,
      // not a translation into a third language
      expect(
        pickCaptionToTranslate([
          (language: 'fr', generated: false),
          (language: 'ja', generated: true),
        ], appLanguage: 'zh'),
        1,
      );
    });

    test('tracks with no language (made on the device) are skipped', () {
      expect(
        pickCaptionToTranslate([
          (language: '', generated: false),
        ], appLanguage: 'zh'),
        isNull,
      );
    });
  });
}
