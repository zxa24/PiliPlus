import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart' show pumpUntil;

/// A translation must come back in the language asked for
/// (research/hardsub-compare-2026-09-26.md: Gemma answered 4 of 125
/// Japanese units in Japanese and copied one).
void main() {
  TranslationFlaw? check(String translation, String source, String target) =>
      TextLanguage.checkTranslation(
        translation,
        source: source,
        target: target,
      );

  group('checkTranslation into Chinese', () {
    test(
      'Chinese with a Latin brand name or a word left in English passes',
      () {
        expect(
          check(
            '我在iPhone上发现了一个用手指画画的软件。',
            'アイフォンで指で絵を描くソフトを見つけたんです。',
            'zh',
          ),
          isNull,
        );
        expect(
          check('阿兹，我简直太 impressed 了。', "Aaz, I'm like super impressed.", 'zh'),
          isNull,
        );
        // a line mostly of names
        expect(
          check(
            '比如《Harper Valley P.A.》或者《Goodbye Earl》由Dixie Chicks演唱的歌',
            'like Harper Valley P.A. or Goodbye Earl by the Dixie Chicks',
            'zh',
          ),
          isNull,
        );
      },
    );

    test('Japanese given back is wrong', () {
      final flaw = check(
        '一点ずつ仕事がわかるようになったりとか。',
        'ちょっとずつ仕事がわかるようになったりとか。',
        'zh',
      );
      expect(flaw, isNotNull);
      expect(flaw!.usable, isFalse);
    });

    test('a Japanese word left in a Chinese sentence is usable, not fine', () {
      final flaw = check(
        '不知道该用什么，とりあえず和画布面对面。',
        '何をどう使っていいか分からずに、とりあえずキャンバスと向き合。',
        'zh',
      );
      expect(flaw, isNotNull);
      expect(flaw!.usable, isTrue);
    });

    test('a copy of a source in another language is wrong', () {
      expect(check('入社した時にはい。', '入社した時にはい。', 'zh')?.usable, isFalse);
      expect(
        check('I like it a lot', 'I like it a lot.', 'zh')?.reason,
        'a copy of the source',
      );
    });

    test('a copy of Chinese, or of a line too short to tell, passes', () {
      expect(check('上来吧。', '上来吧。', 'zh'), isNull);
      expect(check('OK.', 'OK.', 'zh'), isNull);
      expect(check('14', '14', 'zh'), isNull);
    });

    test('English left untranslated, in other words, is wrong', () {
      expect(
        check(
          "I'm super impressed, Aaz.",
          "Aaz, I'm like super impressed.",
          'zh',
        ),
        isNotNull,
      );
    });

    test('into Traditional Chinese the same, on the Chinese', () {
      expect(check('我太爱我的iPhone了。', 'I love my iPhone.', 'zh-Hant'), isNull);
      expect(check('我太愛我的iPhone了。', 'I love my iPhone.', 'zh-Hant'), isNull);
      expect(check('はい、そうです。', 'はい、そうです。', 'zh-Hant'), isNotNull);
    });
  });

  group('checkTranslation into other languages', () {
    test('into a Latin language: only copies and other scripts are told', () {
      expect(check('Bonjour à tous.', 'Good morning everyone.', 'fr'), isNull);
      expect(
        check('This is my song.', 'This is my song.', 'fr')?.reason,
        'a copy of the source',
      );
      // English not told by its words: it may be French, and is let through
      expect(
        check('Good morning everyone.', 'Good morning everyone.', 'fr'),
        isNull,
      );
      expect(check('大家早上好。', 'Good morning everyone.', 'fr'), isNotNull);
      // which Latin language cannot be told reliably: Spanish passes
      expect(
        check('Buenos días a todos.', 'Good morning everyone.', 'fr'),
        isNull,
      );
      // a source that may already be in it may be copied
      expect(check('Bonjour à tous.', 'Bonjour à tous.', 'fr'), isNull);
      expect(check('Guten Morgen, Tokio!', '東京、おはよう！', 'de'), isNull);
    });

    test('into a language with a script of its own', () {
      expect(
        check('Доброе утро всем.', 'Good morning everyone.', 'ru'),
        isNull,
      );
      expect(check('Good morning, everyone', '大家早上好。', 'ru'), isNotNull);
      expect(check('모두 좋은 아침입니다.', 'Good morning everyone.', 'ko'), isNull);
      expect(check('大家早上好，今天天气很好。', 'Good morning everyone.', 'ko'), isNotNull);
      expect(check('皆さん、おはようございます。', '大家早上好。', 'ja'), isNull);
      // Chinese given back for Japanese
      expect(
        check('大家早上好今天天气很好我们去公园', '大家早上好，今天天气很好，我们去公园吧', 'ja')?.reason,
        'Chinese, not Japanese',
      );
    });
  });

  test('the second prompt keeps the first one\'s shape', () {
    expect(
      strictTranslationPrompt('Hello.', target: 'fr', from: 'en'),
      startsWith('Translate the following English text into French.'),
    );
    expect(
      strictTranslationPrompt('Hello.', target: 'fr', from: 'en'),
      endsWith('\n\nHello.'),
    );
    // a source not told: not named
    expect(
      strictTranslationPrompt('OK.', target: 'zh'),
      startsWith('将以下文本翻译为中文'),
    );
    expect(
      strictTranslationPrompt('Hello there.', target: 'zh', from: 'en'),
      isNot(contains('假名')),
    );
  });

  group('a wrong answer is asked again', () {
    setUp(EventLogTesting.clear);

    TranslationSession sessionFor(
      ScriptedEngine engine, {
      String text = 'ちょっとずつ仕事がわかるようになったりとか。',
      String Function(String)? convert,
    }) => TranslationSession(
      transcript: fixedTranscript([
        TranslationUnit(
          from: 12.5,
          to: 15,
          text: text,
          cues: [AsrCue(from: 12.5, to: 15, content: text)],
        ),
      ]),
      position: () => 0,
      engine: (_) async => engine,
      target: 'zh',
      convert: convert == null ? null : () async => convert,
    );

    String? resultOf(TranslationSession session) =>
        session.results.values.single.text;

    test('first wrong, second right: the second is kept', () async {
      final engine = ScriptedEngine([
        '一点ずつ仕事がわかるようになったりとか。',
        '渐渐地开始明白工作了。',
      ]);
      final session = sessionFor(engine)..start();
      await pumpUntil(() => session.results.isNotEmpty);
      expect(resultOf(session), '渐渐地开始明白工作了。');
      expect(engine.prompts, hasLength(2));
      expect(engine.prompts.first, startsWith('将以下文本翻译为中文'));
      // asked again naming the source's language
      expect(engine.prompts.last, startsWith('将以下日语翻译为中文'));
      expect(engine.prompts.last, contains('日文假名'));
      // the same shape: the text after a blank line
      expect(
        engine.prompts.last.split('\n\n').last,
        'ちょっとずつ仕事がわかるようになったりとか。',
      );
      expect(session.languageRetries, 1);
      expect(session.languageFailures, 0);
      expect(translateLines(), isEmpty);
      await session.dispose();
    });

    test('both wrong: failed, with one line in the event log', () async {
      final engine = ScriptedEngine([
        '一点ずつ仕事がわかるようになったりとか。',
        'ちょっとずつ仕事がわかるようになった。',
      ]);
      final session = sessionFor(engine)..start();
      await pumpUntil(() => session.results.isNotEmpty);
      expect(resultOf(session), isNull);
      expect(session.languageFailures, 1);
      final lines = translateLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('12.5 s'));
      expect(lines.single, contains('kana in Chinese'));
      // a failed unit shows its source
      expect(
        session.cues(markPending: false).single.content,
        'ちょっとずつ仕事がわかるようになったりとか。',
      );
      await session.dispose();
    });

    test('a right first answer is asked once and kept as it was', () async {
      final engine = ScriptedEngine(['渐渐地开始明白工作了。']);
      final session = sessionFor(engine)..start();
      await pumpUntil(() => session.results.isNotEmpty);
      expect(resultOf(session), '渐渐地开始明白工作了。');
      expect(engine.prompts, hasLength(1));
      expect(session.languageRetries, 0);
      await session.dispose();
    });

    test(
      'a usable first answer is kept when the second is no better',
      () async {
        final engine = ScriptedEngine([
          '不知道该用什么，とりあえず和画布面对面。',
          'とりあえずキャンバスと向き合。',
        ]);
        final session = sessionFor(
          engine,
          text: '何をどう使っていいか分からずに、とりあえずキャンバスと向き合。',
        )..start();
        await pumpUntil(() => session.results.isNotEmpty);
        expect(resultOf(session), '不知道该用什么，とりあえず和画布面对面。');
        expect(session.languageRetries, 1);
        expect(session.languageFailures, 0);
        expect(translateLines(), isEmpty);
        await session.dispose();
      },
    );

    test(
      'into Traditional Chinese: checked on the Chinese, then converted',
      () async {
        final engine = ScriptedEngine([
          '一点ずつ仕事がわかるようになったりとか。',
          '渐渐地开始明白工作了。',
        ]);
        final session = sessionFor(
          engine,
          convert: (text) => text.replaceAll('渐渐', '漸漸'),
        )..start();
        await pumpUntil(() => session.results.isNotEmpty);
        expect(resultOf(session), '漸漸地开始明白工作了。');
        expect(engine.prompts, hasLength(2));
        await session.dispose();
      },
    );
  });

  group('a text (comment) asked again', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => appSupportDirPath = Directory.systemTemp.path);
    setUp(EventLogTesting.clear);

    test('both wrong: null, with one line in the event log', () async {
      final service = TranslationService()
        ..debugExtraLinger = const Duration(milliseconds: 100)
        ..debugEngine = (_) async => ScriptedEngine(['はい、そうです。', 'はい、そうです。']);
      final result = await service.translateText('はい、そうです。', into: 'zh');
      expect(result, isNull);
      expect(translateLines(), hasLength(1));
      await service.stop(paused: true);
    });

    test('first wrong, second right: the second', () async {
      final service = TranslationService()
        ..debugExtraLinger = const Duration(milliseconds: 100)
        ..debugEngine = (_) async => ScriptedEngine(['はい、そうです。', '是的，没错。']);
      expect(await service.translateText('はい、そうです。', into: 'zh'), '是的，没错。');
      expect(translateLines(), isEmpty);
      await service.stop(paused: true);
    });
  });
}

/// The lines under 'translate' in the event log since [EventLogTesting.clear].
List<String> translateLines() => [
  for (final line in EventLog.recent.skip(EventLogTesting.mark))
    if (line.contains('[translate]')) line,
];

abstract final class EventLogTesting {
  static var mark = 0;
  static void clear() => mark = EventLog.recent.length;
}

/// Answers in the order given, the last one again once they run out.
class ScriptedEngine implements TranslationEngine {
  ScriptedEngine(this.answers);
  final List<String> answers;
  final prompts = <String>[];

  @override
  Future<String> complete(String prompt) async {
    prompts.add(prompt);
    return answers[(prompts.length - 1).clamp(0, answers.length - 1)];
  }

  @override
  void cancel() {}

  @override
  Future<void> dispose() async {}
}
