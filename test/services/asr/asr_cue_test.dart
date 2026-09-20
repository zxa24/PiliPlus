import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:flutter_test/flutter_test.dart';

List<AsrToken> _tokens(List<(String, double)> raw) => [
  for (final (text, time) in raw) (text: text, time: time),
];

void main() {
  group('AsrCueBuilder.fromSegment', () {
    test('drops SenseVoice metadata tags', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 2,
        tokens: _tokens([
          ('<|zh|>', 0),
          ('<|NEUTRAL|>', 0),
          ('<|Speech|>', 0),
          ('<|woitn|>', 0),
          ('你', 0.2),
          ('好', 0.5),
        ]),
      );
      expect(cues, [const AsrCue(from: 0.2, to: 2, content: '你好')]);
    });

    test('drops a BGM-only segment entirely', () {
      expect(
        AsrCueBuilder.fromSegment(
          offset: 3,
          duration: 5,
          tokens: _tokens([('<|BGM|>', 0)]),
        ),
        isEmpty,
      );
    });

    test('turns BPE word marks into spaces', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 2,
        tokens: _tokens([('▁HEL', 0.0), ('LO', 0.3), ('▁WORLD', 0.6)]),
      );
      expect(cues.single.content, 'HELLO WORLD');
    });

    test('offsets every cue by the segment start', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 12.5,
        duration: 3,
        tokens: _tokens([('a', 0.5)]),
      );
      expect(cues.single.from, 13.0);
      expect(cues.single.to, 15.5);
    });

    test('cuts at a sentence end once the cue is long enough', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 6,
        tokens: _tokens([
          ('第', 0.0),
          ('一', 0.5),
          ('句', 1.0),
          ('。', 1.5),
          ('第', 2.0),
          ('二', 2.5),
          ('句', 3.0),
        ]),
      );
      expect(cues.map((c) => c.content), ['第一句。', '第二句']);
      expect(cues.first.to, 2.0);
      expect(cues.last.from, 2.0);
    });

    test('does not cut at punctuation below the minimum duration', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 3,
        tokens: _tokens([('好', 0.0), ('。', 0.1), ('的', 0.3)]),
      );
      expect(cues, hasLength(1));
    });

    test('cuts at internal silence', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 8,
        tokens: _tokens([('前', 0.0), ('面', 1.2), ('后', 4.0), ('面', 4.5)]),
      );
      expect(cues.map((c) => c.content), ['前面', '后面']);
    });

    test('cuts at maxDuration when nothing else breaks', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 20,
        tokens: _tokens([
          for (var i = 0; i < 20; i++) ('字', i.toDouble()),
        ]),
        maxDuration: 6,
      );
      expect(cues.length, greaterThan(2));
      for (final cue in cues) {
        expect(cue.to - cue.from, lessThanOrEqualTo(6.001));
      }
      // no speech is lost or duplicated
      expect(cues.map((c) => c.content).join(), '字' * 20);
    });

    test('cues never overlap and stay inside the segment', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 10,
        duration: 12,
        tokens: _tokens([
          ('a', 0.0),
          ('b', 3.0),
          ('。', 3.2),
          ('c', 7.0),
          ('d', 11.0),
        ]),
      );
      for (var i = 0; i < cues.length; i++) {
        expect(cues[i].from, greaterThanOrEqualTo(10));
        expect(cues[i].to, lessThanOrEqualTo(22));
        expect(cues[i].to, greaterThan(cues[i].from));
        if (i > 0) {
          expect(cues[i].from, greaterThanOrEqualTo(cues[i - 1].to));
        }
      }
    });

    test('falls back to one cue when there are no timestamps', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 4,
        duration: 9,
        tokens: const [],
        text: '<|en|><|NEUTRAL|>hello there',
      );
      expect(cues, [const AsrCue(from: 4, to: 13, content: 'hello there')]);
    });

    test('empty in, empty out', () {
      expect(
        AsrCueBuilder.fromSegment(
          offset: 0,
          duration: 1,
          tokens: const [],
          text: '   ',
        ),
        isEmpty,
      );
    });
  });

  group('serialisation', () {
    const cues = [
      AsrCue(from: 0, to: 1.5, content: '你好'),
      AsrCue(from: 1.5, to: 3, content: 'world'),
    ];

    test('matches the shape the subtitle path already consumes', () {
      expect(cues.toJson(), [
        {'from': 0.0, 'to': 1.5, 'content': '你好'},
        {'from': 1.5, 'to': 3.0, 'content': 'world'},
      ]);
    });

    test('vtt', () {
      expect(
        cues.toVtt(),
        'WEBVTT\n\n'
        '00:00:00.000 --> 00:00:01.500\n你好\n\n'
        '00:00:01.500 --> 00:00:03.000\nworld',
      );
    });

    test('srt', () {
      expect(
        cues.toSrt(),
        '1\n00:00:00,000 --> 00:00:01,500\n你好\n\n'
        '2\n00:00:01,500 --> 00:00:03,000\nworld',
      );
    });
  });

  // found by the first real end-to-end run on Windows (a 60 s Bilibili clip)
  group('regressions from the first real run', () {
    test('reads the language out of the tag instead of stripping it', () {
      // stripping `<|zh|>` leaves nothing, which is what the run reported
      expect(AsrCueBuilder.tagValue('<|zh|>'), 'zh');
      expect(AsrCueBuilder.tagValue('<|en|>'), 'en');
      expect(AsrCueBuilder.tagValue('yue'), 'yue');
      expect(AsrCueBuilder.tagValue(''), '');
    });

    test('a trailing punctuation-only cue joins the one before it', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 3.1,
        tokens: _tokens([
          ('严', 0.0),
          ('师', 0.4),
          ('客', 0.8),
          ('。', 3.0),
        ]),
      );
      expect(cues, hasLength(1));
      expect(cues.single.content, '严师客。');
      expect(cues.single.to, 3.1);
    });

    test('a punctuation-only segment produces nothing at all', () {
      expect(
        AsrCueBuilder.fromSegment(
          offset: 0,
          duration: 1,
          tokens: _tokens([('。', 0.1)]),
        ),
        isEmpty,
      );
    });

    test('a short first cue with real words is kept, not dropped', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 0.2,
        tokens: _tokens([('好', 0.0)]),
      );
      expect(cues.single.content, '好');
    });

    test('no cue shorter than a fifth of a second survives', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 8,
        tokens: _tokens([
          ('这', 0.0),
          ('是', 1.0),
          ('。', 2.0),
          ('下', 2.05),
          ('句', 6.0),
          ('。', 7.98),
        ]),
      );
      for (final cue in cues) {
        expect(cue.to - cue.from, greaterThan(0.2), reason: '$cue');
      }
    });
  });
}
