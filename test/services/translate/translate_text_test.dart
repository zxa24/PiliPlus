import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart' show FakeEngine, pumpUntil;

/// Short texts (comments) translated with the subtitles' model, without
/// taking it from them (research/comment-translation-design-2026-09-25.md,
/// E1).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appSupportDirPath = Directory.systemTemp.path);

  late TranslationService service;
  late List<FakeEngine> engines;

  /// Models loaded and not yet let go of: never more than one.
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

  test('with no translation running, a session of their own', () async {
    final a = service.translateText('Hello.', into: 'zh');
    final b = service.translateText('Good night.', into: 'zh');
    expect(await a, '译:Hello.');
    expect(await b, '译:Good night.');
    expect(engines, hasLength(1));
    expect(service.debugExtrasSession, isNotNull);
    expect(service.debugCurrent, isNull);
  });

  test('the session of their own lets the model go after a while', () async {
    await service.translateText('Hello.', into: 'zh');
    await pumpUntil(() => engines.single.disposed);
  });

  test('a translation running does them, with its own model', () async {
    // a line far ahead keeps it waiting, alive, with its model
    final subtitles = await service.startCaptions(
      cues: [
        AsrCue(from: 0, to: 3, content: 'Bonjour.'),
        AsrCue(from: 500, to: 503, content: 'Salut.'),
      ],
      position: () => 0,
    );
    await pumpUntil(() => subtitles.results.isNotEmpty);
    expect(await service.translateText('Hello.', into: 'zh'), '译:Hello.');
    expect(engines, hasLength(1));
    expect(service.debugExtrasSession, isNull);
  });

  test('a translation starting takes the model and the texts over', () async {
    // a burst of comments, being translated by a session of their own
    final texts = [
      for (var i = 0; i < 6; i++) service.translateText('Line $i.', into: 'zh'),
    ];
    await pumpUntil(() => engines.isNotEmpty);
    final subtitles = await service.startCaptions(
      cues: [AsrCue(from: 0, to: 3, content: 'Bonjour.')],
      position: () => 0,
    );
    final results = await Future.wait(texts);
    for (var i = 0; i < 6; i++) {
      expect(results[i], '译:Line $i.');
    }
    await pumpUntil(() => subtitles.results.isNotEmpty);
    expect(most, 1, reason: 'two models were resident at once');
    expect(service.debugExtrasSession, isNull);
  });

  test('texts dropped by who asked come back null', () async {
    const tag = 'comments';
    final kept = service.translateText('Kept.', into: 'zh');
    final dropped = [
      for (var i = 0; i < 5; i++)
        service.translateText('Dropped $i.', into: 'zh', tag: tag),
    ];
    service.dropTexts(tag);
    expect(await kept, '译:Kept.');
    // any already under way may still finish; the rest are dropped
    final results = await Future.wait(dropped);
    expect(results.where((r) => r == null).length, greaterThanOrEqualTo(4));
  });

  test(
    'Traditional Chinese: translated into Chinese, then converted',
    () async {
      final result = await service.translateText(
        'Software.',
        into: TranslationService.traditionalChinese,
      );
      expect(engines.single.prompts.single, contains('中文'));
      // the fake answers 译:<text>; the conversion turns 译 into 譯
      expect(result, '譯:Software.');
    },
  );

  test('a stop of everything leaves no text waiting for ever', () async {
    final texts = [
      for (var i = 0; i < 20; i++)
        service.translateText('Line $i.', into: 'zh'),
    ];
    await service.stop(reason: 'memory');
    // every one answered — translated or null — and no model left
    await Future.wait(texts).timeout(const Duration(seconds: 5));
    expect(resident(), 0);
  });

  test('a paused session does not take texts', () async {
    final session = TranslationSession(
      transcript: (
        units: () => const [],
        cues: () => const [],
        complete: () => true,
      ),
      position: () => 0,
      engine: (_) async => FakeEngine(),
      target: 'zh',
    );
    expect(session.servesExtras, isFalse, reason: 'not started');
  });
}
