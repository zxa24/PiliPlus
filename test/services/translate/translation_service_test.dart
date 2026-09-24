import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart' show FakeEngine, pumpUntil;

AsrCue cue(double from, double to, String text) =>
    AsrCue(from: from, to: to, content: text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appSupportDirPath = Directory.systemTemp.path);

  group('TranslationService: the language translated into', () {
    late TranslationService service;
    late List<FakeEngine> engines;
    final cues = [cue(0, 3, 'Bonjour.')];

    setUp(() {
      engines = [];
      service = TranslationService()
        ..debugEngine = (_) async {
          final engine = FakeEngine();
          engines.add(engine);
          return engine;
        };
    });

    tearDown(() => service.stop(paused: true));

    test("the app's unless another is asked for", () async {
      final own = await service.startCaptions(cues: cues, position: () => 0);
      expect(own.target, service.target);
      final other = await service.startCaptions(
        cues: cues,
        position: () => 0,
        into: 'fr',
      );
      expect(other.target, 'fr');
      await pumpUntil(
        () => engines.length == 2 && engines.last.prompts.isNotEmpty,
      );
      expect(
        engines.last.prompts.single,
        startsWith('Translate the following text into French. '),
      );
    });

    test(
      'Traditional Chinese from Chinese is a conversion, no model',
      () async {
        final session = await service.startCaptions(
          cues: [cue(0, 3, '软件和网络。')],
          position: () => 0,
          into: TranslationService.traditionalChinese,
          from: 'zh',
        );
        expect(session.modelFree, isTrue);
        expect(session.target, 'zh');
        // the dictionaries come from the app's assets
        await pumpUntil(() => session.results.isNotEmpty, tries: 2000);
        expect(session.results.values.single, '軟體和網路。');
        expect(engines, isEmpty);
      },
    );

    test(
      'Traditional Chinese from another language: Chinese, converted',
      () async {
        final session = await service.startCaptions(
          cues: [cue(0, 3, 'Software.')],
          position: () => 0,
          into: TranslationService.traditionalChinese,
          from: 'en',
        );
        expect(session.modelFree, isFalse);
        expect(session.target, 'zh');
        await pumpUntil(() => session.results.isNotEmpty, tries: 2000);
        // the fake engine answers '译:<text>', which comes out converted
        expect(session.results.values.single, '譯:Software.');
        expect(
          engines.single.prompts.single,
          startsWith('将以下文本翻译为中文'),
        );
      },
    );

    test(
      'whether a language needs translating depends on the one asked for',
      () {
        expect(service.needed('fr', into: 'fr'), isFalse);
        expect(service.needed('en', into: 'fr'), isTrue);
        expect(service.needed('zh'), isFalse);
      },
    );
  });

  group('TranslationService: a page covered by another video', () {
    late TranslationService service;
    late List<FakeEngine> engines;
    final cues = [
      for (var i = 0; i < 5; i++) cue(i * 100.0, i * 100.0 + 3, 'Line $i.'),
    ];

    setUp(() {
      engines = [];
      service = TranslationService()
        ..debugEngine = (_) async {
          final engine = FakeEngine();
          engines.add(engine);
          return engine;
        };
    });

    tearDown(() => service.stop(paused: true));

    test('pauses, lets go of the model, and goes on when it is back', () async {
      var nowA = 0.0;
      var ownsA = true;
      final a = await service.startCaptions(
        cues: cues,
        position: () => nowA,
        ownsPlayer: () => ownsA,
      );
      await pumpUntil(
        () =>
            a.results.length == 2 &&
            a.state.value.stage == TranslationStage.waiting,
      );

      // another video's page opens over A and translates its own
      ownsA = false;
      final b = await service.startCaptions(
        cues: cues,
        position: () => 0,
        ownsPlayer: () => true,
      );
      expect(a.state.value.stage, TranslationStage.paused);
      expect(a.isRunning, isFalse);
      expect(engines.first.disposed, isTrue);
      expect(a.results.keys, [0, 1]);
      expect(service.debugIsParked(a), isTrue);
      expect(service.debugCurrent, same(b));
      await pumpUntil(() => b.results.length == 2);
      expect(engines, hasLength(2));

      // back to A: B's page closes, A has the player, further on
      await service.stop(only: b);
      ownsA = true;
      nowA = 150;
      a.poke();
      await pumpUntil(() => a.results.length == 3);
      expect(engines, hasLength(3));
      expect(a.results.keys, [0, 1, 2]);
      expect(service.debugCurrent, same(a));
      expect(service.debugIsParked(a), isFalse);
    });

    test(
      'does not take the model back from a start still getting going',
      () async {
        var ownsA = true;
        var ownsB = false;
        final a = await service.startCaptions(
          cues: cues,
          position: () => 0,
          ownsPlayer: () => ownsA,
        );
        await pumpUntil(() => a.results.length == 2);
        // B's translation starts before its page has handed the player its
        // video: for that moment A still has it
        final b = await service.startCaptions(
          cues: cues,
          position: () => 0,
          ownsPlayer: () => ownsB,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(engines, hasLength(1));
        expect(service.debugCurrent, same(b));
        ownsA = false;
        ownsB = true;
        b.poke();
        await pumpUntil(() => b.results.length == 2);
        expect(engines, hasLength(2));
        expect(a.state.value.stage, TranslationStage.paused);
      },
    );

    test('a stop of everything leaves paused ones, but deleting the model '
        'does not', () async {
      var ownsA = true;
      final a = await service.startCaptions(
        cues: cues,
        position: () => 0,
        ownsPlayer: () => ownsA,
      );
      await pumpUntil(() => a.results.length == 2);
      ownsA = false;
      await service.startCaptions(
        cues: cues,
        position: () => 0,
        ownsPlayer: () => true,
      );

      await service.stop(reason: 'memory');
      expect(a.state.value.stage, TranslationStage.paused);
      expect(service.debugIsParked(a), isTrue);

      await service.stop(reason: '翻译模型已删除', paused: true);
      expect(a.state.value.stage, TranslationStage.failed);
      expect(service.debugIsParked(a), isFalse);
    });

    test('its own page stopping it reaches it while paused', () async {
      var ownsA = true;
      final a = await service.startCaptions(
        cues: cues,
        position: () => 0,
        ownsPlayer: () => ownsA,
      );
      await pumpUntil(() => a.results.length == 2);
      ownsA = false;
      await service.startCaptions(
        cues: cues,
        position: () => 0,
        ownsPlayer: () => true,
      );
      await service.stop(only: a);
      expect(service.debugIsParked(a), isFalse);
      // and it never loads again
      ownsA = true;
      a.poke();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engines, hasLength(2));
    });
  });
}
