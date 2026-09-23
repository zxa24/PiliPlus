import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';
import 'package:flutter_test/flutter_test.dart';

AsrCue cue(double from, double to, String content) =>
    AsrCue(from: from, to: to, content: content);

void main() {
  group('buildTranslationUnits', () {
    test('one unit per segment when the gaps are pauses', () {
      final units = buildTranslationUnits(
        segments: [(start: 0, duration: 3), (start: 5, duration: 3)],
        cues: [
          cue(0, 1.5, 'Hello there.'),
          cue(1.5, 3, 'I am Kate.'),
          cue(5, 8, 'Hi.'),
        ],
        complete: true,
      );
      expect(units.map((u) => u.text), ['Hello there. I am Kate.', 'Hi.']);
      expect(units.first.cues, hasLength(2));
      expect((units.first.from, units.first.to), (0, 3));
    });

    test('a cut under half a second joins the next segment, two at most', () {
      final units = buildTranslationUnits(
        segments: [
          (start: 0, duration: 20),
          (start: 20.1, duration: 20),
          (start: 40.2, duration: 5),
        ],
        cues: [
          cue(0, 20, '私はこの提案に'),
          cue(20.1, 40, '賛成しません。'),
          cue(40.2, 45, 'はい。'),
        ],
        complete: true,
      );
      expect(units.map((u) => u.text), ['私はこの提案に賛成しません。', 'はい。']);
    });

    test('the newest segment is held back until it is settled', () {
      final segments = [
        (start: 0.0, duration: 3.0),
        (start: 3.2, duration: 3.0),
      ];
      final cues = [cue(0, 3, 'one'), cue(3.2, 6, 'two')];
      // 0 and 1 join, and two is the cap: the unit is full, so it settles
      // even though the transcript is not
      expect(
        buildTranslationUnits(
          segments: segments,
          cues: cues,
          complete: false,
        ).map((u) => u.text),
        ['one two'],
      );
      // a lone newest segment is open
      expect(
        buildTranslationUnits(
          segments: [(start: 0, duration: 3), (start: 5, duration: 3)],
          cues: [cue(0, 3, 'one'), cue(5, 8, 'two')],
          complete: false,
        ).map((u) => u.text),
        ['one'],
      );
    });

    test('a segment that produced no cues makes no unit', () {
      final units = buildTranslationUnits(
        segments: [(start: 0, duration: 3), (start: 5, duration: 3)],
        cues: [cue(5, 8, 'two')],
        complete: true,
      );
      expect(units.map((u) => u.text), ['two']);
    });
  });

  test('joinCueText puts back the space only between Latin lines', () {
    expect(
      joinCueText(['I am pretty much', 'always watching']),
      'I am pretty much always watching',
    );
    expect(joinCueText(['我们今天', '去公园。']), '我们今天去公园。');
    expect(joinCueText(['ホテルに', 'Wi-Fiがある']), 'ホテルにWi-Fiがある');
  });

  group('splitTranslation', () {
    test('short text is one line', () {
      expect(splitTranslation('我叫凯特。'), ['我叫凯特。']);
    });

    test('a sentence end starts a new line once the line is worth reading', () {
      expect(
        splitTranslation('我叫凯特，是一名设计师。我一直在观察人们如何使用设计好的东西。'),
        ['我叫凯特，是一名设计师。', '我一直在观察人们如何使用设计好的东西。'],
      );
      // two short sentences share
      expect(splitTranslation('好的。谢谢。'), ['好的。谢谢。']);
    });

    test('an overlong sentence breaks at its last clause end', () {
      final lines = splitTranslation(
        '当日常用品的设计没有达到目的时，人们就会自己动手来填补空白，这就是临时标志的由来',
      );
      expect(lines.first, '当日常用品的设计没有达到目的时，');
      for (final l in lines) {
        expect(
          AsrCueBuilder.displayWidth(l),
          lessThanOrEqualTo(translationMaxWidth),
        );
      }
    });

    test('never cuts inside a Latin word or number', () {
      final lines = splitTranslation(
        '这是一个非常非常非常非常非常长的句子里面有个单词Photoshop2026',
        maxWidth: 50,
      );
      expect(lines.join(), contains('Photoshop2026'));
      expect(lines.any((l) => l.contains('Photoshop2026')), isTrue);
    });
  });

  group('timeTranslation', () {
    test(
      'shares the span by width and snaps to where a source line starts',
      () {
        final unit = TranslationUnit(
          from: 10,
          to: 20,
          text: 'x',
          cues: [cue(10, 16.5, 'a'), cue(16.5, 20, 'b')],
        );
        final timed = timeTranslation(unit, ['一二三四五六', '七八九十']);
        // proportional would put the boundary at 16.0; a line starts at 16.5
        expect(timed.map((c) => (c.from, c.to)), [(10, 16.5), (16.5, 20)]);
      },
    );

    test('stays proportional when no source line starts nearby', () {
      final unit = TranslationUnit(
        from: 0,
        to: 10,
        text: 'x',
        cues: [cue(0, 10, 'a')],
      );
      final timed = timeTranslation(unit, ['一二三', '四五六七八九十']);
      expect(timed.map((c) => (c.from, c.to)), [(0, 3), (3, 10)]);
    });
  });

  group('layOutTranslation', () {
    final units = [
      TranslationUnit(
        from: 0,
        to: 3,
        text: 'Hello.',
        cues: [cue(0, 3, 'Hello.')],
      ),
      TranslationUnit(from: 4, to: 7, text: 'Bye.', cues: [cue(4, 7, 'Bye.')]),
    ];

    test('waiting units show their source, marked', () {
      final out = layOutTranslation(units: units, results: {0: '你好。'});
      expect(out.map((c) => c.content), [
        '你好。',
        'Bye.\n$translationPendingMark',
      ]);
    });

    test('a failed unit shows its source unmarked', () {
      final out = layOutTranslation(units: units, results: {0: '你好。', 1: null});
      expect(out.last.content, 'Bye.');
    });

    test('dual puts the source line under the translation', () {
      final out = layOutTranslation(
        units: units,
        results: {0: '你好。', 1: '再见。'},
        display: TranslationDisplay.dual,
      );
      expect(out.map((c) => c.content), ['你好。\nHello.', '再见。\nBye.']);
    });

    test('dual follows both sets of boundaries without slivers', () {
      final unit = TranslationUnit(
        from: 0,
        to: 6,
        text: 'x',
        cues: [cue(0, 3, 'A'), cue(3, 6, 'B')],
      );
      final out = layOutTranslation(
        units: [unit],
        results: {0: '一二三四五六七八九十一二三。十四十五十六十七十八十九二十。'},
        display: TranslationDisplay.dual,
      );
      for (final c in out) {
        expect(c.to - c.from, greaterThanOrEqualTo(0.3));
        expect(c.content.split('\n'), hasLength(2));
      }
      expect(out.first.content.endsWith('A'), isTrue);
      expect(out.last.content.endsWith('B'), isTrue);
    });

    test('cues not yet in a unit are shown as waiting', () {
      final out = layOutTranslation(
        units: const [],
        results: const {},
        trailing: [cue(0, 2, 'Hi.')],
      );
      expect(out.single.content, 'Hi.\n$translationPendingMark');
    });
  });

  group('cleanTranslation', () {
    test('strips thinking and wrapping quotes', () {
      expect(
        cleanTranslation('<think>hmm</think>\n“你好。”', source: 'Hello.'),
        '你好。',
      );
    });

    test('rejects an empty or runaway reply', () {
      expect(cleanTranslation('  ', source: 'Hi'), isNull);
      expect(cleanTranslation('解释' * 60, source: 'Hi'), isNull);
    });
  });

  test('the prompt asks for simplified Chinese', () {
    expect(translationPrompt('Hi', target: 'zh'), contains('简体中文'));
    expect(translationPrompt('Hi', target: 'zh'), endsWith('\n\nHi'));
  });

  group('TranslationSession', () {
    late List<AsrSegmentSpan> segments;
    late List<AsrCue> cues;
    late bool complete;
    late double now;
    late FakeEngine engine;

    TranslationSession make() => TranslationSession(
      transcript: (
        segments: () => segments,
        cues: () => cues,
        complete: () => complete,
      ),
      position: () => now,
      engine: () async => engine,
      target: 'zh',
    );

    setUp(() {
      segments = [
        for (var i = 0; i < 5; i++) (start: i * 100.0, duration: 3.0),
      ];
      cues = [
        for (var i = 0; i < 5; i++) cue(i * 100.0, i * 100.0 + 3, 'unit $i'),
      ];
      complete = true;
      now = 0;
      engine = FakeEngine();
    });

    test('translates only within the lead of the playhead', () async {
      final session = make()..start();
      await pumpUntil(
        () =>
            session.state.value.stage == TranslationStage.waiting &&
            session.results.length == 2,
      );
      // units at 0 and 100 are within 120 s; 200 is not
      expect(session.results.keys, [0, 1]);
      expect(engine.prompts.map((p) => p.split('\n\n').last), [
        'unit 0',
        'unit 1',
      ]);
      await session.dispose();
      expect(engine.disposed, isTrue);
    });

    test('a seek skips what is behind and picks up ahead', () async {
      now = 250;
      final session = make()..start();
      await pumpUntil(
        () =>
            session.results.isNotEmpty &&
            session.state.value.stage == TranslationStage.waiting,
      );
      // 300 is within 120 s of 250; 400 is not yet
      expect(session.results.keys, [3]);
      expect(session.cues().first.content, endsWith(translationPendingMark));
      await session.dispose();
    });

    test('settledFrom stops at the first unit still waiting', () {
      final session = make()
        ..units = buildTranslationUnits(
          segments: segments,
          cues: cues,
          complete: true,
        );
      session.results.addAll({0: 'a', 1: null});
      expect(session.settledFrom(0), 103);
      expect(session.settledFrom(150), 150);
    });

    test('three failures in a row give up', () async {
      engine.fail = true;
      segments = [for (var i = 0; i < 5; i++) (start: i * 10.0, duration: 3.0)];
      cues = [
        for (var i = 0; i < 5; i++) cue(i * 10.0, i * 10.0 + 3, 'unit $i'),
      ];
      final session = make()..start();
      await pumpUntil(
        () => session.state.value.stage == TranslationStage.failed,
      );
      expect(engine.disposed, isTrue);
      await session.dispose();
    });

    test(
      'done once every unit of a finished transcript has a result',
      () async {
        now = 0;
        segments = [(start: 0, duration: 3)];
        cues = [cue(0, 3, 'Hello.')];
        final session = make()..start();
        await pumpUntil(
          () => session.state.value.stage == TranslationStage.done,
        );
        expect(session.cues().single.content, '译:Hello.');
      },
    );
  });
}

class FakeEngine implements TranslationEngine {
  final prompts = <String>[];
  var fail = false;
  var disposed = false;

  @override
  Future<String> complete(String prompt) async {
    prompts.add(prompt);
    if (fail) throw StateError('engine down');
    return '译:${prompt.split('\n\n').last}';
  }

  @override
  Future<void> dispose() async => disposed = true;
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'condition not reached');
}
