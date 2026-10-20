/// Traditional Chinese of a transcript started without the model
/// (oct-pass1-D2): Chinese is converted, speech in another language is
/// shown in its own words — never a silent download — and the model is
/// offered once; asked for, it translates those lines after all.
library;

import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_language_test.dart' show alternating, said, storeSaying;
import 'translation_test.dart' show FakeEngine, pumpUntil;

void main() {
  const hant = TranslationService.traditionalChinese;

  group('TranslationService.startsWithoutModel', () {
    test('Traditional Chinese from a Chinese caption track', () {
      expect(TranslationService.startsWithoutModel(hant, caption: 'zh'), true);
      expect(
        TranslationService.startsWithoutModel(hant, caption: 'ai-zh'),
        true,
      );
      expect(
        TranslationService.startsWithoutModel(hant, caption: 'zh-Hans'),
        true,
      );
      // the track translated decides, not the speech
      expect(
        TranslationService.startsWithoutModel(
          hant,
          caption: 'en',
          spoken: const ['zh'],
        ),
        false,
      );
    });

    test('Traditional Chinese from a transcript of speech mostly in '
        'Chinese', () {
      expect(
        TranslationService.startsWithoutModel(hant, spoken: const ['zh']),
        true,
      );
      expect(
        TranslationService.startsWithoutModel(hant, spoken: const ['yue']),
        true,
      );
      expect(
        TranslationService.startsWithoutModel(hant, spoken: const ['en']),
        false,
      );
      // not known yet: the model is asked about, as before
      expect(TranslationService.startsWithoutModel(hant), false);
    });

    test('never another language', () {
      expect(
        TranslationService.startsWithoutModel('zh', caption: 'zh'),
        false,
      );
      expect(
        TranslationService.startsWithoutModel('en', spoken: const ['zh']),
        false,
      );
    });
  });

  group('a Traditional Chinese session without the model', () {
    late List<FakeEngine> engines;
    late bool allowed;
    late int offers;

    TranslationSession make(TranscriptStore store) => TranslationSession(
      transcript: transcriptView(store, complete: () => true),
      position: () => 0,
      engine: (_) async {
        final engine = FakeEngine();
        engines.add(engine);
        return engine;
      },
      target: 'zh',
      // stands in for S2twpConverter: marks what it converted
      convert: () async =>
          (text) => '繁:$text',
      routeOf: (language) => TranslationService.routeFor(language, hant),
      mayLoadModel: () => allowed,
    )..onModelWanted = () => offers++;

    setUp(() {
      engines = [];
      allowed = false;
      offers = 0;
    });

    test('Chinese converted, the rest in its own words, the model offered '
        'once and never loaded', () async {
      final session = make(storeSaying(alternating(6)))..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 0);
      expect(engines, isEmpty);
      expect(offers, 1);
      expect(session.cues().map((c) => c.content), [
        '繁:这是第0句中文。',
        'This is English line 1.',
        '繁:这是第2句中文。',
        'This is English line 3.',
        '繁:这是第4句中文。',
        'This is English line 5.',
      ]);
      // no text: the subtitle cache keeps none of them
      final english = session.units.where((u) => u.language == 'en');
      expect(
        english.map((u) => session.results.of(u)!.text),
        everyElement(null),
      );
      await session.dispose();
    });

    test('the model asked for: those lines are translated after all, even '
        'after the session finished', () async {
      final session = make(storeSaying(alternating(4)))..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 0);
      allowed = true;
      session.retranslate();
      await pumpUntil(
        () =>
            session.modelLoads == 1 &&
            session.state.value.stage == TranslationStage.done,
      );
      expect(session.cues().map((c) => c.content), [
        '繁:这是第0句中文。',
        '繁:译:This is English line 1.',
        '繁:这是第2句中文。',
        '繁:译:This is English line 3.',
      ]);
      // Chinese was not done again
      expect(
        [
          for (final engine in engines)
            for (final p in engine.prompts) p.split('\n\n').last,
        ],
        ['This is English line 1.', 'This is English line 3.'],
      );
      expect(offers, 1);
      await session.dispose();
    });

    test('speech not tagged with a language: in its own words, and no '
        'offer of the model', () async {
      final session = make(
        storeSaying([
          said(0, '第一句中文在这里。', 'zh'),
          said(5, 'Untagged words here.', ''),
        ]),
      )..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 0);
      expect(offers, 0);
      expect(session.cues().map((c) => c.content), [
        '繁:第一句中文在这里。',
        'Untagged words here.',
      ]);
      await session.dispose();
    });

    test('the model on the device: everything as before', () async {
      allowed = true;
      final session = make(storeSaying(alternating(2)))..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.modelLoads, 1);
      expect(offers, 0);
      expect(session.cues().map((c) => c.content), [
        '繁:这是第0句中文。',
        '繁:译:This is English line 1.',
      ]);
      await session.dispose();
    });
  });
}
