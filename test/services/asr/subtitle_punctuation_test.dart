import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/subtitle_punctuation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules are research/subtitle-punctuation-2026-09-24.md; where a
/// guide gives an example, it is used as it is.
void main() {
  group('Simplified Chinese', () {
    String show(String line) => punctuateForDisplay(line, 'zh');

    test('commas and full stops become one space', () {
      expect(show('然而，此刻河道已经干涸，'), '然而 此刻河道已经干涸');
      expect(show('即待一场大雨。3个月前，'), '即待一场大雨 3个月前');
    });

    test('question and exclamation marks stay', () {
      expect(show('能否达到生态平衡呢？'), '能否达到生态平衡呢？');
      expect(show('真的吗？我不信。'), '真的吗？ 我不信');
    });

    test('an enumeration comma stays inside a list, not at the end', () {
      expect(show('软件、网络、'), '软件、网络');
    });

    test('numbers keep their point', () {
      expect(show('温度达到3.5度。'), '温度达到3.5度');
    });

    test('Cantonese follows the same rules', () {
      expect(punctuateForDisplay('係咪呀，唔知。', 'yue'), '係咪呀 唔知');
    });
  });

  group('Traditional Chinese', () {
    String show(String line) => punctuateForDisplay(line, 'zh-Hant');

    test('the guide’s own lines keep their commas inside', () {
      expect(show('我最愛海灘了，因為…'), '我最愛海灘了，因為…');
    });

    test('no full stop, and none of ，、 at the end', () {
      expect(show('這是我的魚卵。'), '這是我的魚卵');
      expect(show('現在僅需少量水源喚醒，'), '現在僅需少量水源喚醒');
      expect(show('下雨了。我們回家吧！'), '下雨了 我們回家吧！');
    });
  });

  group('Japanese', () {
    String show(String line) => punctuateForDisplay(line, 'ja');

    test('。 is a full-width space, 、 a half-width one', () {
      expect(show('ホテルだから、ビルがある。今回は'), 'ホテルだから ビルがある　今回は');
    });

    test('the guide’s example: まさか？　そんな！', () {
      expect(show('まさか？そんな！'), 'まさか？　そんな！');
    });

    test('nothing left hanging at either end', () {
      expect(show('いますね。'), 'いますね');
    });
  });

  test('other languages keep normal punctuation', () {
    expect(
      punctuateForDisplay('Did you see Jane? I thought so.', 'en'),
      'Did you see Jane? I thought so.',
    );
    expect(punctuateForDisplay('Bonjour, ça va.', 'fr'), 'Bonjour, ça va.');
    expect(punctuateForDisplay('然而，此刻', null), '然而，此刻');
  });

  test('a cue is shown line by line', () {
    final cues = [
      const AsrCue(from: 0, to: 1, content: '然而，此刻。\n另一行，'),
    ].forDisplay('zh');
    expect(cues.single.content, '然而 此刻\n另一行');
    expect(cues.single.from, 0);
    expect(cues.single.to, 1);
  });

  group('by the language of each line\'s own speech', () {
    // a Chinese video with an English stretch, and a stray English word
    // the recogniser tagged Chinese
    final spans = speechSpansOf([
      (start: 0.0, duration: 4.0, language: 'zh', weight: 12),
      (start: 5.0, duration: 3.0, language: 'en', weight: 30),
      (start: 9.0, duration: 0.5, language: 'zh', weight: 5),
      (start: 11.0, duration: 2.0, language: '', weight: 20),
    ], fallback: 'en');
    const cues = [
      AsrCue(from: 0.1, to: 3.9, content: '然而，此刻。'),
      AsrCue(from: 5.06, to: 7.9, content: 'Did you see Jane? I thought so.'),
      AsrCue(from: 9.0, to: 9.5, content: 'The.'),
      AsrCue(from: 11.2, to: 12.8, content: 'Hello, there.'),
      // in no segment at all
      AsrCue(from: 20, to: 21, content: 'Late, too.'),
    ];

    test('each line keeps its own language\'s rules', () {
      final shown = cues.forDisplayBySpeech(spans, 'en');
      expect([for (final c in shown) c.content], [
        '然而 此刻',
        // one language for the whole transcript took these full stops off
        'Did you see Jane? I thought so.',
        // six characters or fewer: the session's language, not the tag
        'The.',
        // untagged: the session's
        'Hello, there.',
        'Late, too.',
      ]);
    });

    test('with the session in Chinese, the untrusted lines follow it', () {
      final zh = speechSpansOf([
        (start: 0.0, duration: 4.0, language: 'en', weight: 5),
      ], fallback: 'zh');
      expect(
        [
          const AsrCue(from: 0, to: 1, content: '好的，走吧。'),
        ].forDisplayBySpeech(zh, 'zh').single.content,
        '好的 走吧',
      );
    });

    test('no segments: as the session\'s language says', () {
      expect(
        cues.take(1).toList().forDisplayBySpeech(const [], 'zh').single.content,
        '然而 此刻',
      );
    });
  });
}
