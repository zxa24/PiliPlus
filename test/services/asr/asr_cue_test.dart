import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:flutter_test/flutter_test.dart';

List<AsrToken> _tokens(List<(String, double)> raw) => [
  for (final (text, time) in raw) (text: text, time: time),
];

void main() {
  group('AsrCueBuilder.fromSegment', () {
    test('a sentence without punctuation is still cut into readable lines', () {
      // Measured on a 15-minute video before this existed: median 28
      // characters, 90th percentile 42, longest 49, and 26 of 203 cues over
      // 40 — three lines on a phone. The 20-character limit only ever armed
      // a break at the next comma, so speech without commas ignored it.
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 12,
        tokens: [
          // as SenseVoice emits them: '▁' marks the start of a word
          for (var i = 0; i < 60; i++)
            (text: ' word', time: i * 0.2),
        ],
      );
      expect(cues, isNotEmpty);
      for (final cue in cues) {
        expect(
          cue.content.length,
          lessThanOrEqualTo(40),
          reason: 'a cue that needs three lines: ${cue.content}',
        );
      }
    });

    test('no cue is left on screen too briefly to read', () {
      // Eleven of those 203 were under a second, six under half a second.
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 10,
        tokens: const [
          (text: '好。', time: 0.0),
          (text: '这是一句完整的话。', time: 3.0),
          (text: '嗯。', time: 7.0),
        ],
      );
      expect(cues, isNotEmpty);
      for (final cue in cues) {
        expect(
          cue.to - cue.from,
          greaterThanOrEqualTo(0.5),
          reason: 'a flash, not a subtitle: ${cue.content}',
        );
      }
    });

    test('holding a brief cue never overlaps the next one', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 6,
        tokens: const [
          (text: '一。', time: 0.0),
          (text: '二。', time: 0.6),
          (text: '三。', time: 1.2),
        ],
      );
      for (var i = 0; i + 1 < cues.length; i++) {
        expect(
          cues[i].to,
          lessThanOrEqualTo(cues[i + 1].from),
          reason: 'cue $i runs into the next',
        );
      }
    });


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
      // held to `from + _minShown` (2.0 s) rather than stopping at the end
      // of the segment: a cue that ends the moment the speech does is the
      // "subtitle gone before the sentence is" complaint, and there is
      // nothing after it to overlap
      expect(
        cues,
        [const AsrCue(from: 0.2, to: 2.2, content: '你好')],
      );
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

  // continuous speech with commas but no full stop: the official AI subtitle
  // for the same video split it into readable lines, ours ran to 35 chars
  group('long lines break at a clause end', () {
    test('a comma-separated run is split, not left as one long line', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 7,
        tokens: _tokens([
          for (var i = 0; i < 12; i++) ('字', i * 0.2),
          ('，', 2.4),
          for (var i = 0; i < 12; i++) ('词', 2.6 + i * 0.2),
          ('，', 5.0),
          ('完', 5.2),
        ]),
      );
      expect(cues.length, greaterThan(1));
      for (final cue in cues) {
        expect(cue.content.length, lessThanOrEqualTo(26), reason: '$cue');
      }
    });

    test('a short line is not split at a comma', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 4,
        tokens: _tokens([
          ('好', 0.0),
          ('的', 0.5),
          ('，', 1.0),
          ('走', 1.5),
          ('吧', 2.0),
        ]),
      );
      expect(cues, hasLength(1));
      expect(cues.single.content, '好的，走吧');
    });
  });

  group('line length is measured in width, not characters', () {
    /// Evenly spaced tokens, one per [step] seconds.
    List<AsrToken> spaced(List<String> texts, {double step = 0.3}) => [
      for (var i = 0; i < texts.length; i++)
        (text: texts[i], time: i * step),
    ];

    test('a CJK character counts double and a Latin letter once', () {
      expect(AsrCueBuilder.displayWidth('你好'), 4);
      expect(AsrCueBuilder.displayWidth('hi'), 2);
      expect(AsrCueBuilder.displayWidth('你好hi'), 6);
      // kana and hangul are wide too
      expect(AsrCueBuilder.displayWidth('こん'), 4);
      expect(AsrCueBuilder.displayWidth('한글'), 4);
      // fullwidth punctuation is wide, ASCII punctuation is not
      expect(AsrCueBuilder.displayWidth('，'), 2);
      expect(AsrCueBuilder.displayWidth(','), 1);
    });

    test('Chinese is cut exactly where it always was', () {
      // The guarantee that made this change safe to ship: for text that is
      // entirely full-width, width is twice the character count, so the
      // doubled thresholds fall in the same places. A regression here means
      // Chinese subtitles changed, which is what the previous round of
      // tuning was for.
      final tokens = spaced([for (var i = 0; i < 40; i++) '话']);
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 12,
        tokens: tokens,
      );
      expect(cues, isNotEmpty);
      for (final cue in cues) {
        expect(
          AsrCueBuilder.displayWidth(cue.content),
          lessThanOrEqualTo(32),
          reason: 'cue "${cue.content}" is wider than the hard cap',
        );
        // 32 half-widths is 16 Chinese characters — the old _hardMaxChars
        expect(cue.content.length, lessThanOrEqualTo(16));
      }
    });

    test('English is no longer cut into three words a line', () {
      // 16 characters of English is about three words. The author's own
      // track on the measured video ran to a median of 32 characters, which
      // is what 32 half-widths allows.
      final words = [
        for (var i = 0; i < 40; i++) ' word',
      ];
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 12,
        tokens: spaced(words),
      );
      expect(cues, isNotEmpty);
      final longest = cues
          .map((c) => c.content.length)
          .reduce((a, b) => a > b ? a : b);
      // the old limit would have capped every cue at 16
      expect(longest, greaterThan(16));
      for (final cue in cues) {
        // The cap is checked after a token is appended, so a cue can run one
        // token past it — a single character in Chinese, a whole word in
        // English. Breaking *before* the token instead would change where
        // Chinese cues fall, which is the one thing this change must not do.
        expect(AsrCueBuilder.displayWidth(cue.content), lessThanOrEqualTo(40));
      }
    });
  });

  group('layOut', () {
    AsrCue cue(double from, double to, [String text = 'x']) =>
        AsrCue(from: from, to: to, content: text);

    test('a short hole is closed by extending the earlier cue', () {
      final out = AsrCueBuilder.layOut([
        cue(0, 2, 'one'),
        cue(3, 5, 'two'),
      ]);
      expect(out.first.to, 3);
      expect(out.first.content, 'one');
      expect(out.last.from, 3);
    });

    test('a real pause is left alone', () {
      // a line held across six seconds of silence is worse than no line
      final out = AsrCueBuilder.layOut([
        cue(0, 2, 'one'),
        cue(8, 10, 'two'),
      ]);
      expect(out.first.to, 2);
    });

    test('nothing is moved, shortened or overlapped', () {
      final input = [cue(0, 2), cue(2.5, 4), cue(9, 11), cue(11, 12)];
      final out = AsrCueBuilder.layOut(input);
      expect(out, hasLength(input.length));
      for (var i = 0; i < input.length; i++) {
        expect(out[i].from, input[i].from, reason: 'start moved at $i');
        expect(out[i].to, greaterThanOrEqualTo(input[i].to));
        expect(out[i].content, input[i].content);
        if (i + 1 < out.length) {
          expect(out[i].to, lessThanOrEqualTo(out[i + 1].from),
              reason: 'overlap at $i');
        }
      }
    });

    test('the last cue is never extended — there is nothing to reach', () {
      final out = AsrCueBuilder.layOut([cue(0, 2), cue(2.5, 4)]);
      expect(out.last.to, 4);
    });

    test('toVtt serialises the bridged cues, not the raw ones', () {
      // The probe and the player must measure the same thing. They did not,
      // and that is how a visible defect survived three rounds of stats.
      final vtt = [cue(0, 2, 'one'), cue(3, 5, 'two')].toVtt();
      expect(vtt, contains('00:03'));
      expect(vtt, isNot(contains('00:02.000 -->')));
    });
  });

  group('never breaks inside a word', () {
    /// SenseVoice pieces: '▁' starts a word, a bare piece continues one.
    List<AsrToken> pieces(List<String> texts) => [
      for (var i = 0; i < texts.length; i++) (text: texts[i], time: i * 0.25),
    ];

    test('a cue does not end on half a word', () {
      // Observed on a real video: "a little extra coach" / "ing." and
      // "something is technical" / "ly fully functioning". On screen it is
      // unreadable; handed to a translator it is two things that are not
      // words.
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 20,
        tokens: pieces([
          // as SenseVoice really emits them: a leading space starts a word,
          // a bare piece continues the one before
          for (var i = 0; i < 12; i++) ...[' coach', 'ing', ' and'],
        ]),
      );
      expect(cues.length, greaterThan(1), reason: 'nothing was cut at all');
      for (final cue in cues) {
        expect(
          cue.content,
          isNot(endsWith('coach')),
          reason: 'cut inside "coaching": ${cue.content}',
        );
        expect(
          cue.content,
          isNot(startsWith('ing')),
          reason: 'a cue beginning with a word fragment: ${cue.content}',
        );
      }
    });

    test('Chinese still breaks anywhere — it has no word marker', () {
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 20,
        tokens: pieces([for (var i = 0; i < 40; i++) '话']),
      );
      expect(cues.length, greaterThan(1));
      for (final cue in cues) {
        expect(AsrCueBuilder.displayWidth(cue.content), lessThanOrEqualTo(34));
      }
    });

    test('a tokeniser with no word markers still gets cut', () {
      // The safety valve: preferring word starts must never mean one cue per
      // segment if the pieces carry no marks at all.
      final cues = AsrCueBuilder.fromSegment(
        offset: 0,
        duration: 20,
        // no marker anywhere: the safety valve is all that cuts these
        tokens: pieces([for (var i = 0; i < 60; i++) 'word']),
      );
      expect(cues.length, greaterThan(1));
      for (final cue in cues) {
        expect(AsrCueBuilder.displayWidth(cue.content), lessThanOrEqualTo(70));
      }
    });
  });

  group('overlaps', () {
    test('a held cue is cut back where the next one starts', () {
      // Cues are built per VAD segment, so a segment's last cue was held for
      // _minShown with no idea the next segment had already begun — two
      // lines on screen at once.
      final out = AsrCueBuilder.layOut([
        const AsrCue(from: 5.83, to: 7.83, content: 'I am a designer.'),
        const AsrCue(from: 7.65, to: 10.31, content: 'And my design.'),
      ]);
      expect(out.first.to, 7.65);
      expect(out.first.to, lessThanOrEqualTo(out.last.from));
      expect(out.first.content, 'I am a designer.');
    });
  });
}
