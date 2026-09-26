/// Each transcript unit keeps its own language
/// (research/subtitle-switch-design-2026-09-26.md, decision 2A): a unit
/// already in the language asked for is shown as it is, without the model;
/// Chinese into Traditional Chinese is only converted; everything else is
/// translated. No unit spans two languages, and a stray short tag does not
/// load the model.
library;

import 'dart:io';

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/subtitle_punctuation.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart' show FakeEngine, cue, pumpUntil;

/// One segment of speech: when, its text, and the language it was tagged.
typedef Said = ({double start, double duration, String text, String lang});

Said said(double start, String text, String lang, {double duration = 3}) =>
    (start: start, duration: duration, text: text, lang: lang);

/// A finished run from 0 of [segments], added the way the recogniser adds
/// them: each with its cue, its tag and its weight (length plus one).
TranscriptStore storeSaying(List<Said> segments, {TranscriptStore? into}) {
  final store = into ?? TranscriptStore();
  final run = store.startRun(0);
  for (final s in segments) {
    store.addSegment(
      run,
      s.start,
      s.duration,
      [cue(s.start, s.start + s.duration, s.text)],
      language: s.lang,
      weight: s.text.length + 1,
    );
  }
  run.finish();
  return store;
}

/// Chinese, then English, then Chinese…: [count] segments 5 s apart.
List<Said> alternating(int count) => [
  for (var i = 0; i < count; i++)
    i.isEven
        ? said(i * 5.0, '这是第$i句中文。', 'zh')
        : said(i * 5.0, 'This is English line $i.', 'en'),
];

void main() {
  group('smoothSegmentLanguages', () {
    List<String?> smooth(
      List<(String, String)> segments, {
      bool complete = false,
    }) => smoothSegmentLanguages([
      for (final (text, lang) in segments)
        (language: lang, weight: text.length + 1),
    ], complete: complete);

    test('a stray short tag at the start takes the first long one after', () {
      // both replay transcripts open this way
      expect(
        smooth([('The.', 'en'), ('今天我们来聊一聊这个问题。', 'zh')]),
        ['zh', 'zh'],
      );
    });

    test('a short tag inside takes the long one before it', () {
      expect(
        smooth([
          ('今天我们来聊一聊这个问题。', 'zh'),
          ('OK.', 'en'),
          ('然后我们再看下一个问题。', 'zh'),
        ]),
        ['zh', 'zh', 'zh'],
      );
    });

    test('long segments keep their own tags', () {
      expect(
        smooth([
          ('今天我们来聊一聊这个问题。', 'zh'),
          ('And now a whole sentence in English.', 'en'),
        ]),
        ['zh', 'en'],
      );
    });

    test('untagged stays untagged, and lends nothing', () {
      expect(smooth([('Hello there friend.', ''), ('Hi.', 'en')]), ['', null]);
      expect(
        smooth([('Hello there friend.', ''), ('Hi.', 'en')], complete: true),
        ['', 'en'],
      );
    });

    test('undecided until a long segment arrives, or the run ends', () {
      expect(smooth([('The.', 'en')]), [null]);
      expect(smooth([('The.', 'en')], complete: true), ['en']);
    });

    test('a decided language never changes as more arrive', () {
      final growing = [
        ('The.', 'en'),
        ('今天我们来聊一聊这个问题。', 'zh'),
        ('Yes.', 'en'),
        ('And now a whole sentence in English.', 'en'),
        ('好。', 'zh'),
      ];
      List<String?>? before;
      for (var n = 1; n <= growing.length; n++) {
        final now = smooth(growing.sublist(0, n));
        if (before != null) {
          for (var i = 0; i < before.length; i++) {
            if (before[i] != null) expect(now[i], before[i]);
          }
        }
        before = now;
      }
      expect(before, ['zh', 'zh', 'zh', 'en', 'en']);
    });
  });

  group('buildTranslationUnits with languages', () {
    test('no unit spans a language boundary, even across a cut', () {
      // gaps of 0.1 s: one language would join them two by two
      final segments = [
        for (var i = 0; i < 6; i++) (start: i * 3.1, duration: 3.0),
      ];
      final languages = ['zh', 'en', 'en', 'zh', 'zh', 'en'];
      final units = buildTranslationUnits(
        segments: segments,
        cues: [
          for (var i = 0; i < 6; i++) cue(i * 3.1, i * 3.1 + 3, 's$i'),
        ],
        complete: true,
        languages: languages,
      );
      expect(units.map((u) => (u.text, u.language)), [
        ('s0', 'zh'),
        ('s1 s2', 'en'),
        ('s3 s4', 'zh'),
        ('s5', 'en'),
      ]);
    });

    test('one language is cut exactly as without languages', () {
      // gaps that join and gaps that do not, and a segment with no cues
      final starts = [0.0, 3.2, 6.3, 12.0, 15.1, 15.2, 25.0, 28.4, 31.5];
      final segments = [for (final s in starts) (start: s, duration: 3.0)];
      final cues = [
        for (var i = 0; i < starts.length; i++)
          if (i != 5) cue(starts[i], starts[i] + 3, 'line $i'),
      ];
      for (final complete in [false, true]) {
        final plain = buildTranslationUnits(
          segments: segments,
          cues: cues,
          complete: complete,
        );
        for (final language in ['', 'ja']) {
          final tagged = buildTranslationUnits(
            segments: segments,
            cues: cues,
            complete: complete,
            languages: [for (final _ in starts) language],
          );
          expect(
            tagged.map((u) => (u.from, u.to, u.text, u.key)),
            plain.map((u) => (u.from, u.to, u.text, u.key)),
          );
          expect(tagged.every((u) => u.language == language), isTrue);
        }
      }
    });

    test('a unit whose language is undecided waits', () {
      final units = buildTranslationUnits(
        segments: const [(start: 0, duration: 1)],
        cues: [cue(0, 1, 'The.')],
        complete: false,
        languages: const [null],
      );
      expect(units, isEmpty);
    });
  });

  group('TranslationService.routeFor', () {
    test('each language against what was asked for', () {
      expect(TranslationService.routeFor('zh', 'zh'), UnitRoute.pass);
      expect(TranslationService.routeFor('yue', 'zh'), UnitRoute.pass);
      expect(TranslationService.routeFor('en', 'zh'), UnitRoute.model);
      expect(TranslationService.routeFor('en', 'en'), UnitRoute.pass);
      expect(TranslationService.routeFor('zh', 'en'), UnitRoute.model);
      const hant = TranslationService.traditionalChinese;
      expect(TranslationService.routeFor('zh', hant), UnitRoute.convert);
      expect(TranslationService.routeFor('en', hant), UnitRoute.model);
      // not known is not assumed to be the viewer's own
      expect(TranslationService.routeFor('', 'zh'), UnitRoute.model);
      expect(TranslationService.routeFor('', hant), UnitRoute.model);
    });
  });

  group('a session deciding unit by unit', () {
    var now = 0.0;
    late List<FakeEngine> engines;

    TranslationSession make(
      TranscriptStore store, {
      String into = 'zh',
      bool Function()? complete,
    }) {
      final traditional = into == TranslationService.traditionalChinese;
      return TranslationSession(
        transcript: transcriptView(store, complete: complete ?? () => true),
        position: () => now,
        engine: (_) async {
          final engine = FakeEngine();
          engines.add(engine);
          return engine;
        },
        target: traditional ? 'zh' : into,
        // stands in for S2twpConverter: marks what it converted
        convert: traditional
            ? () async =>
                  (text) => '繁:$text'
            : null,
        routeOf: (language) => TranslationService.routeFor(language, into),
      );
    }

    List<String> prompted() => [
      for (final engine in engines)
        for (final p in engine.prompts) p.split('\n\n').last,
    ];

    setUp(() {
      now = 0;
      engines = [];
    });

    test('all Chinese into Chinese: the model is never loaded', () async {
      final store = storeSaying([
        for (var i = 0; i < 8; i++) said(i * 5.0, '这是第$i句中文。', 'zh'),
      ]);
      final session = make(store)..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 0);
      expect(engines, isEmpty);
      expect(session.units, hasLength(8));
      expect(session.units.every((u) => session.results.of(u)!.passed), true);
      // shown as it is
      expect(
        session.cues().map((c) => c.content),
        [for (var i = 0; i < 8; i++) '这是第$i句中文。'],
      );
      await session.dispose();
    });

    test('Chinese and English into Chinese: only English reaches the '
        'model', () async {
      final store = storeSaying(alternating(6));
      final session = make(store)..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(prompted(), [
        'This is English line 1.',
        'This is English line 3.',
        'This is English line 5.',
      ]);
      expect(session.modelLoads, 1);
      expect(session.cues().map((c) => c.content), [
        '这是第0句中文。',
        '译:This is English line 1.',
        '这是第2句中文。',
        '译:This is English line 3.',
        '这是第4句中文。',
        '译:This is English line 5.',
      ]);
      await session.dispose();
    });

    test('Chinese and English into Traditional Chinese: Chinese converted, '
        'English translated then converted', () async {
      final store = storeSaying(alternating(4));
      final session = make(
        store,
        into: TranslationService.traditionalChinese,
      )..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(prompted(), [
        'This is English line 1.',
        'This is English line 3.',
      ]);
      expect(session.cues().map((c) => c.content), [
        '繁:这是第0句中文。',
        '繁:译:This is English line 1.',
        '繁:这是第2句中文。',
        '繁:译:This is English line 3.',
      ]);
      expect(session.results.values.any((r) => r.passed), isFalse);
      await session.dispose();
    });

    test('one mis-tagged short segment in Chinese does not load the '
        'model', () async {
      final store = storeSaying([
        // as both replay transcripts open, and once more in the middle
        said(0, 'The.', 'en', duration: 1.5),
        said(5, '今天我们来聊一聊这个问题。', 'zh'),
        said(10, 'Yeah.', 'en', duration: 0.8),
        said(15, '然后我们再看下一个问题。', 'zh'),
      ]);
      final session = make(store)..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 0);
      expect(session.units.map((u) => u.language), everyElement('zh'));
      await session.dispose();
    });

    test('units needing no model are settled behind the playhead and past '
        'the lead too; the others only within it', () async {
      now = 300;
      final store = storeSaying([
        said(0, '第一句中文在这里。', 'zh'),
        said(5, 'English behind the viewer.', 'en'),
        said(300, 'English where the viewer is.', 'en'),
        said(900, '很远以后的一句中文。', 'zh'),
        said(905, 'English far ahead of the viewer.', 'en'),
      ]);
      final session = make(store)..start();
      await pumpUntil(
        () =>
            session.results.length == 3 &&
            session.state.value.stage == TranslationStage.waiting,
      );
      expect(prompted(), ['English where the viewer is.']);
      expect(
        session.units.where((u) => session.results.of(u)?.passed ?? false),
        hasLength(2),
      );
      await session.dispose();
    });

    test('units of unknown language are translated', () async {
      final store = storeSaying([
        said(0, '这是一句没有标签的话。', ''),
        said(5, '这是第二句中文。', 'zh'),
      ]);
      final session = make(store)..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(prompted(), ['这是一句没有标签的话。']);
      await session.dispose();
    });

    test('while the transcript grows, same-language units settle as they '
        'come, and the model loads for the first foreign one', () async {
      var complete = false;
      final store = TranscriptStore();
      final run = store.startRun(0);
      final session = make(store, complete: () => complete)..start();
      void add(Said s) {
        store.addSegment(
          run,
          s.start,
          s.duration,
          [cue(s.start, s.start + s.duration, s.text)],
          language: s.lang,
          weight: s.text.length + 1,
        );
        session.poke();
      }

      add(said(0, '第一句中文在这里。', 'zh'));
      add(said(5, '第二句中文在这里。', 'zh'));
      await pumpUntil(() => session.results.length == 1);
      expect(session.modelLoads, 0);
      add(said(10, 'Now some English, finally.', 'en'));
      add(said(15, '第三句中文在这里。', 'zh'));
      await pumpUntil(() => session.results.length == 3);
      expect(session.modelLoads, 1);
      complete = true;
      session.poke();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(prompted(), ['Now some English, finally.']);
      await session.dispose();
    });
  });

  group('layout of a unit passed through', () {
    final units = [
      TranslationUnit(
        from: 0,
        to: 3,
        text: '你好，朋友。',
        cues: [cue(0, 3, '你好，朋友。')],
        language: 'zh',
      ),
      TranslationUnit(
        from: 4,
        to: 7,
        text: 'Bye.',
        cues: [cue(4, 7, 'Bye.')],
        language: 'en',
      ),
    ];
    final TranslationResults results = {
      units[0].key: (source: units[0].text, text: units[0].text, passed: true),
      units[1].key: (source: units[1].text, text: '再见。', passed: false),
    };

    test('dual shows it once, with its own punctuation', () {
      final out = layOutTranslation(
        units: units,
        results: results,
        display: TranslationDisplay.dual,
        showTranslated: (line) => punctuateForDisplay(line, 'zh'),
        showSource: (line) => punctuateForDisplay(line, null),
        showSourceIn: punctuateForDisplay,
      );
      expect(out.map((c) => c.content), ['你好 朋友', '再见\nBye.']);
    });

    test('translated display shows its source in its place', () {
      final out = layOutTranslation(units: units, results: results);
      expect(out.map((c) => c.content), ['你好，朋友。', '再见。']);
    });
  });

  group('TranslationService', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => appSupportDirPath = Directory.systemTemp.path);

    late TranslationService service;
    late List<FakeEngine> engines;
    int resident() => engines.where((e) => !e.disposed).length;
    var most = 0;

    setUp(() {
      engines = [];
      most = 0;
      service = TranslationService()
        ..debugExtraLinger = const Duration(milliseconds: 200)
        ..debugEngine = (_) async {
          final engine = FakeEngine();
          engines.add(engine);
          if (resident() > most) most = resident();
          return engine;
        };
    });

    tearDown(() => service.stop(paused: true));

    AsrSession asrSaying(List<Said> segments, {String? language}) {
      final asr = AsrSession.debugFor('t');
      storeSaying(segments, into: asr.transcript);
      asr.debugSet(AsrState(stage: AsrStage.done, language: language));
      return asr;
    }

    test('a transcript in the language asked for starts, and never loads '
        'the model, whatever the session language says', () async {
      final asr = asrSaying([
        for (var i = 0; i < 4; i++) said(i * 5.0, '这是第$i句中文。', 'zh'),
      ]);
      final session = await service.start(
        asr: asr,
        position: () => 0,
        into: 'zh',
      );
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(engines, isEmpty);
      expect(session.results.values.every((r) => r.passed), isTrue);
    });

    test('Chinese speech into Traditional Chinese that turns English is '
        'translated there, not only converted', () async {
      // the session's vote says Chinese; before 2A that converted every
      // line, English ones too
      final asr = asrSaying(alternating(4), language: 'zh');
      final session = await service.start(
        asr: asr,
        position: () => 0,
        into: TranslationService.traditionalChinese,
      );
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(engines, hasLength(1));
      expect(engines.single.prompts, hasLength(2));
    });

    test('comments while a same-language transcript runs: their own '
        'session, and still one model at most', () async {
      final asr = asrSaying([
        for (var i = 0; i < 4; i++) said(i * 5.0, '这是第$i句中文。', 'zh'),
        said(600, 'English far ahead, not due yet.', 'en'),
      ]);
      final subtitles = await service.start(
        asr: asr,
        position: () => 0,
        into: 'zh',
      );
      await pumpUntil(() => subtitles.results.length == 4);
      expect(subtitles.servesExtras, isFalse);
      expect(await service.translateText('Hello.', into: 'zh'), '译:Hello.');
      expect(service.debugExtrasSession, isNotNull);
      expect(subtitles.modelLoads, 0);
      // the viewer reaches the English: the transcript's session takes the
      // model over from the comments' one
      final later = await service.start(
        asr: asr,
        position: () => 590,
        into: 'zh',
      );
      // (the Chinese behind the viewer is settled too: it needs no model)
      await pumpUntil(() => later.results.length == 5);
      expect(later.results.values.where((r) => !r.passed), hasLength(1));
      expect(later.modelLoads, 1);
      expect(most, 1, reason: 'two models were resident at once');
    });
  });
}
