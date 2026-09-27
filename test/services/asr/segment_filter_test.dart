import 'package:PiliPlus/services/asr/segment_filter.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Seg = ({String text, String language});

const zh = (text: '我们今天去看看这个地方怎么样', language: 'zh');
const ja = (text: '今日はここに行ってみましょう', language: 'ja');
const en = (text: 'and then we walked over to the market', language: 'en');

/// Runs [segments] through a filter one by one, and returns for each what
/// was decided and after how many segments had been added.
List<({AsrOddity? hidden, int at})> run(
  List<Seg> segments, {
  bool finish = true,
}) {
  final filter = AsrSegmentFilter<int>();
  final out = <int, ({AsrOddity? hidden, int at})>{};
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    for (final d in filter.add(
      i,
      start: i.toDouble(),
      text: s.text,
      language: s.language,
    )) {
      out[d.item] = (hidden: d.hidden, at: i);
    }
  }
  if (finish) {
    for (final d in filter.finish()) {
      out[d.item] = (hidden: d.hidden, at: segments.length);
    }
  }
  return [for (var i = 0; i < segments.length; i++) ?out[i]];
}

List<int> hiddenOf(List<Seg> segments) => [
  for (final (i, d) in run(segments).indexed)
    if (d.hidden != null) i,
];

void main() {
  group('on its own', () {
    test('fewer than two letters', () {
      expect(AsrSegmentFilter.oddity('.', 'en'), AsrOddity.short);
      expect(AsrSegmentFilter.oddity('う。', 'ja'), AsrOddity.short);
      expect(AsrSegmentFilter.oddity('Be.', 'en'), isNull);
      expect(AsrSegmentFilter.oddity('好的。', 'zh'), isNull);
    });

    test('a script the tag does not use', () {
      expect(AsrSegmentFilter.oddity('Oh汪.', 'en'), AsrOddity.script);
      expect(AsrSegmentFilter.oddity('시れ.', 'en'), AsrOddity.script);
      expect(AsrSegmentFilter.oddity('Happy new year', 'zh'), AsrOddity.script);
      // Latin words in Chinese speech are normal
      expect(AsrSegmentFilter.oddity('这个app真的很好用', 'zh'), isNull);
      expect(AsrSegmentFilter.oddity('Happy台苹果来得有大有。', 'zh'), isNull);
      expect(AsrSegmentFilter.oddity('안녕하세요', 'ko'), isNull);
      expect(AsrSegmentFilter.oddity('こんにちは', 'ko'), AsrOddity.script);
    });

    test('one word four times running, making up most of the text', () {
      expect(AsrSegmentFilter.oddity('哒哒哒哒。', 'zh'), AsrOddity.repeat);
      expect(
        AsrSegmentFilter.oddity('Se sell sell sell sell sell sell.', 'en'),
        AsrOddity.repeat,
      );
      // three is not four, and a repeat inside a sentence is speech
      expect(AsrSegmentFilter.oddity('sell sell sell', 'en'), isNull);
      expect(AsrSegmentFilter.oddity('对对对对，我觉得这个地方真的很不错', 'zh'), isNull);
    });

    test('Cantonese counts as Chinese; unknown tags as none', () {
      expect(AsrSegmentFilter.familyOf('yue'), 'zh');
      expect(AsrSegmentFilter.familyOf('en'), 'en');
      expect(AsrSegmentFilter.familyOf(''), isNull);
      expect(AsrSegmentFilter.familyOf('nospeech'), isNull);
    });
  });

  group('among its neighbours', () {
    test('an isolated segment in another language is hidden', () {
      expect(hiddenOf([zh, zh, zh, ja, zh, zh]), [3]);
      expect(hiddenOf([zh, zh, zh, ja, ja, zh, zh]), [3, 4]);
    });

    test('a sustained stretch of another language is content, both parts '
        'of a video that changes language are kept', () {
      expect(hiddenOf([zh, zh, zh, zh, ja, ja, ja, ja, ja]), isEmpty);
      // and the first three are held until the third says so
      final decided = run([zh, zh, zh, ja, ja, ja, ja]);
      expect([for (final d in decided) d.at], [0, 1, 2, 5, 5, 5, 6]);
    });

    test('at the end of the audio an isolated stretch is hidden', () {
      expect(hiddenOf([en, en, en, zh, zh]), [3, 4]);
    });

    test('a line-by-line dialogue in two languages is never touched', () {
      expect(hiddenOf([zh, ja, zh, ja, zh, ja, zh, ja]), isEmpty);
    });

    test('nothing is held or hidden before two segments give a language', () {
      final decided = run([ja, zh, zh, zh]);
      expect([for (final d in decided) d.hidden], [null, null, null, null]);
      expect([for (final d in decided) d.at], [0, 1, 2, 3]);
    });

    test('a third language after the stretch: not surrounded, shown', () {
      expect(hiddenOf([zh, zh, zh, en, ja, ja, ja]), isEmpty);
    });

    test('odd segments inside a stretch are skipped over, and held with it '
        'to keep the order', () {
      const dots = (text: '.', language: 'en');
      const hangul = (text: 'W失れ.', language: 'en');
      final decided = run([en, en, zh, dots, hangul, en]);
      expect(
        [for (final d in decided) d.hidden],
        [
          null,
          null,
          AsrOddity.isolated,
          AsrOddity.short,
          AsrOddity.script,
          null,
        ],
      );
      expect([for (final d in decided) d.at], [0, 1, 5, 5, 5, 5]);
    });

    test('an untagged segment is shown and does not count', () {
      const untagged = (text: 'mm hmm', language: '');
      expect(hiddenOf([en, en, untagged, zh, en]), [3]);
    });

    test('a hidden segment does not become the language around the next', () {
      expect(hiddenOf([en, en, zh, en, zh, en]), [2, 4]);
    });

    test('without finish, an undecided stretch stays held', () {
      final filter = AsrSegmentFilter<int>();
      for (final (i, s) in [en, en, zh].indexed) {
        filter.add(i, start: i * 5.0, text: s.text, language: s.language);
      }
      expect(filter.firstHeld, 10.0);
    });
  });

  test('the hand-labelled noisy clip V1 (current VAD settings): 8 of 9 '
      'garbage segments hidden, the 2 lost are real Chinese speech', () {
    // research/noisy-speech-design-2026-09-26.md, 6: segment texts and tags
    // as the app's recogniser gives them
    final v1 = <Seg>[
      (text: 'The reason Qingdao is the beer capital of China', language: 'en'),
      (text: 'German, Germany, wait, so also look at this', language: 'en'),
      (text: 'these things were invented here in Qingdao', language: 'en'),
      (text: 'I have bread over here.', language: 'en'),
      (text: 'Super delicious northeast barbecue. more beer.', language: 'en'),
      (text: 'Se sell sell sell sell sell sell.', language: 'en'), // bad
      (text: "Oh, there's gas prices.", language: 'en'),
      (
        text: "Let's see, I don't know what any of this means, but.",
        language: 'en',
      ),
      (text: "I'm assuming it's all beer not gas.", language: 'en'),
      (text: '这款酒的究竟排名是多少？', language: 'zh'), // real Chinese
      (text: 'Good luck.', language: 'en'),
      (text: '稍等一下，稍等我见，OK,谢谢你发最身的希望。', language: 'zh'), // real
      (text: 'So questions okay, you go.', language: 'en'),
      (text: '只是属于你的，虽然我不知道。', language: 'zh'), // bad
      (text: "There you go No I don't know what's going on", language: 'en'),
      (text: ', is place anyway what you cookie, whatever', language: 'en'),
      (text: 'Come on, Raa, we got this, got this.', language: 'en'),
      (text: '哒哒哒哒。', language: 'zh'), // bad
      (text: 'That.', language: 'en'), // bad, missed
      (text: 'さ了。', language: 'ja'), // bad
      (text: 'W失れ.', language: 'en'), // bad
      (text: "Where did she win, That's cute.", language: 'en'),
      (text: "That was amazing, I'm like super impressed.", language: 'en'),
      (text: 'Where is this, what place are we at is crazy', language: 'en'),
      (text: 'Auto machines that you want to use when', language: 'en'),
      (text: 'I wonder if they were built by the Germans', language: 'en'),
      (text: 'A little bit. So the foods better', language: 'en'),
      (text: 'Yeah.', language: 'en'),
      (text: 'W, KFC is doing a burger.', language: 'en'),
      (text: '.', language: 'en'), // bad
      (text: "Yeah, let's go under our shopping and I if you.", language: 'en'),
      (text: "Well, it's got to be like fire hydr red.", language: 'en'),
      (text: 'Happy台苹果来得有大有。', language: 'zh'), // bad
      (text: '早秋就大从你。', language: 'zh'), // bad
    ];
    expect(hiddenOf(v1), [5, 9, 11, 13, 17, 19, 20, 29, 32, 33]);
  });
}
