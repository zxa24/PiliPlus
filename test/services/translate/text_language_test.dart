import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:flutter_test/flutter_test.dart';

/// Comments as they are written: short, informal, with emotes and numbers.
/// research/comment-translation-design-2026-09-25.md, C1.
void main() {
  const samples = <(String, String)>[
    // Chinese
    ('这个视频做得太好了，UP主辛苦了', 'zh'),
    ('前排围观，第一次这么早', 'zh'),
    ('笑死我了哈哈哈哈哈哈', 'zh'),
    ('这里的配乐是什么歌？求告知', 'zh'),
    ('三连了，期待下一期[doge]', 'zh'),
    // Japanese
    ('この動画めっちゃ好きです', 'ja'),
    ('日本から見てます！応援してます', 'ja'),
    ('かわいすぎる…', 'ja'),
    ('字幕ありがとうございます', 'ja'),
    // Korean
    ('한국에서 보고 있어요 너무 좋아요', 'ko'),
    ('이 노래 제목이 뭐예요?', 'ko'),
    // Russian / Ukrainian
    ('Очень красивое видео, спасибо', 'ru'),
    ('Дякую за відео, це чудово', 'uk'),
    // Thai, Arabic, Hindi
    ('ชอบมากเลยครับ', 'th'),
    ('فيديو رائع جدا شكرا لك', 'ar'),
    ('बहुत अच्छा वीडियो है', 'hi'),
    // English
    ('This is the best video I have seen this year', 'en'),
    ('who is here after the update?', 'en'),
    ('I love how you explained it', 'en'),
    ('the music at 3:20 is so good', 'en'),
    ('Thanks for the subtitles, really helpful', 'en'),
    // French
    ('C\'est vraiment une très belle vidéo', 'fr'),
    ('Je ne comprends pas pourquoi il fait ça', 'fr'),
    // German
    ('Das ist wirklich sehr schön gemacht', 'de'),
    ('Ich finde das Video großartig', 'de'),
    // Spanish
    ('¡Qué bonito! Me encanta este video', 'es'),
    ('No entiendo por qué hay tan pocas vistas', 'es'),
    // Portuguese
    ('Muito bom, não sabia disso', 'pt'),
    ('Eu amo esse canal, você é demais', 'pt'),
    // Italian
    ('Questo video è molto bello', 'it'),
    // Indonesian
    ('Videonya bagus banget, saya suka', 'id'),
    // Turkish
    ('Bu video çok güzel olmuş', 'tr'),
    // Polish
    ('To jest bardzo dobre, dziękuję', 'pl'),
    // Vietnamese
    ('Video này rất hay, cảm ơn bạn', 'vi'),
    // Filipino
    ('Ang ganda naman ng video na ito po', 'fil'),
  ];

  test('the language of a comment, by script and words', () {
    var right = 0;
    final wrong = <String>[];
    for (final (text, lang) in samples) {
      final got = TextLanguage.detect(text);
      if (got == lang) {
        right++;
      } else {
        wrong.add('$text → $got (want $lang)');
      }
    }
    // ignore: avoid_print
    print('language: $right/${samples.length} right; wrong: $wrong');
    // pre-registered: script-level decisions all right, Latin languages
    // nearly all
    expect(
      right / samples.length,
      greaterThanOrEqualTo(0.94),
      reason: '$wrong',
    );
    for (final (text, lang) in samples) {
      if (!const {
        'en',
        'fr',
        'de',
        'es',
        'pt',
        'it',
        'id',
        'tr',
        'pl',
        'vi',
        'fil',
      }.contains(lang)) {
        expect(TextLanguage.detect(text), lang, reason: text);
      }
    }
  });

  test('too short to tell is left alone', () {
    for (final text in ['[doge]', '哈哈', '233', '666666', '？？？', 'ok', '👍👍']) {
      expect(TextLanguage.detect(text), isNull, reason: text);
      expect(
        TextLanguage.needsTranslation(text, native: const ['zh']),
        isFalse,
        reason: text,
      );
    }
  });

  test('what is translated for a Chinese reader', () {
    const native = ['zh'];
    expect(TextLanguage.needsTranslation('这个视频做得太好了', native: native), isFalse);
    expect(
      TextLanguage.needsTranslation('この動画めっちゃ好きです', native: native),
      isTrue,
    );
    expect(
      TextLanguage.needsTranslation(
        'I love how you explained it',
        native: native,
      ),
      isTrue,
    );
    // no native language in Latin letters: an unknown one is translated
    expect(
      TextLanguage.needsTranslation('Wow amazing nice', native: native),
      isTrue,
    );
  });

  test('a reader of Chinese and English: English is left, French is not', () {
    const native = ['zh', 'en'];
    expect(
      TextLanguage.needsTranslation(
        'I love how you explained it',
        native: native,
      ),
      isFalse,
    );
    expect(
      TextLanguage.needsTranslation(
        'C\'est vraiment une très belle vidéo',
        native: native,
      ),
      isTrue,
    );
    // no telling which Latin language: it may be English, so it is left
    expect(
      TextLanguage.needsTranslation('Wow amazing nice', native: native),
      isFalse,
    );
  });

  test('Traditional Chinese is Chinese for a reader of either', () {
    expect(
      TextLanguage.needsTranslation('這個影片做得太好了', native: const ['zh-Hant']),
      isFalse,
    );
    expect(
      TextLanguage.needsTranslation('这个视频做得太好了', native: const ['zh-Hant']),
      isFalse,
    );
  });
}
