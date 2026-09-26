/// LibrePili: the language a short text is written in, for deciding which
/// comments to translate (research/comment-translation-design-2026-09-25.md,
/// E2 and E5).
///
/// No model and no dependency. The script decides most languages outright:
/// kana is Japanese, hangul Korean, Han without kana Chinese, and so on.
/// Languages sharing the Latin script are told apart by their commonest
/// words and their own letters (ñ, ß, ł, ğ, the Vietnamese tone marks…).
/// A text too short to tell — an emote, 哈哈, a number — is left alone:
/// translating it would only replace it with the same thing.
library;

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';

abstract final class TextLanguage {
  static final _notLanguage = RegExp(
    r'\[[^\[\]]{1,16}\]|https?://\S+|www\.\S+|@\S+|\d+[:：]\d+(?:[:：]\d+)?',
  );

  /// Letters below this, a text is not judged.
  static const _minLetters = 4;

  /// The language [text] is written in, as a code the translator knows
  /// ('zh', 'ja', 'en', …); null when it cannot be told.
  ///
  /// For a Latin text with no word or letter to go by, 'latin': a language
  /// written in that script, which one unknown.
  static String? detect(String text) {
    // not words of any language: emote codes ([doge] read as Latin), links,
    // @names and timestamps
    text = text.replaceAll(_notLanguage, ' ');
    var han = 0, kana = 0, hangul = 0, cyrillic = 0, arabic = 0;
    var thai = 0, devanagari = 0, latin = 0, greek = 0, hebrew = 0;
    for (final r in text.runes) {
      if (r >= 0x3040 && r <= 0x30FF || r >= 0x31F0 && r <= 0x31FF) {
        kana++;
      } else if (r >= 0x4E00 && r <= 0x9FFF || r >= 0x3400 && r <= 0x4DBF) {
        han++;
      } else if (r >= 0xAC00 && r <= 0xD7A3 || r >= 0x1100 && r <= 0x11FF) {
        hangul++;
      } else if (r >= 0x0400 && r <= 0x04FF) {
        cyrillic++;
      } else if (r >= 0x0600 && r <= 0x06FF) {
        arabic++;
      } else if (r >= 0x0E00 && r <= 0x0E7F) {
        thai++;
      } else if (r >= 0x0900 && r <= 0x097F) {
        devanagari++;
      } else if (r >= 0x0370 && r <= 0x03FF) {
        greek++;
      } else if (r >= 0x0590 && r <= 0x05FF) {
        hebrew++;
      } else if ((r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A) ||
          (r >= 0xC0 && r <= 0x24F) ||
          (r >= 0x1E00 && r <= 0x1EFF)) {
        latin++;
      }
    }
    final letters =
        han +
        kana +
        hangul +
        cyrillic +
        arabic +
        thai +
        devanagari +
        latin +
        greek +
        hebrew;
    // three Han characters say as much as four letters: 哈哈 does not
    if (han * 4 + (letters - han) * 3 < _minLetters * 3) return null;
    // any kana at all: Japanese writes Han with kana, Chinese never does
    if (kana > 0 && kana + han >= letters / 2) return 'ja';
    final scripts = <String, int>{
      'zh': han,
      'ko': hangul,
      'cyrillic': cyrillic,
      'ar': arabic,
      'th': thai,
      'hi': devanagari,
      'el': greek,
      'he': hebrew,
      'latin': latin,
    };
    final top = scripts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return switch (top.key) {
      'cyrillic' => RegExp('[іїєґІЇЄҐ]').hasMatch(text) ? 'uk' : 'ru',
      'latin' => _latin(text),
      final code => code,
    };
  }

  /// The commonest words of each language written in Latin letters: the
  /// ones a sentence can hardly do without, and that the others do not
  /// share (en "a", "in" are left out for that reason).
  static const _words = {
    'en': {
      'the',
      'and',
      'is',
      'you',
      'that',
      'this',
      'it',
      'was',
      'for',
      'are',
      'with',
      'have',
      'not',
      'what',
      'just',
      'like',
      'but',
      'so',
      'my',
      'of',
      'to',
      'i',
      'be',
      'they',
      'do',
      'can',
      'will',
      'your',
    },
    'fr': {
      'le',
      'la',
      'les',
      'est',
      'et',
      'des',
      'une',
      'pas',
      'que',
      'je',
      'vous',
      'il',
      'elle',
      'c\'est',
      'du',
      'dans',
      'pour',
      'sur',
      'mais',
      'avec',
      'très',
      'nous',
      'qui',
      'au',
      'ce',
      'sont',
    },
    'de': {
      'der',
      'die',
      'das',
      'und',
      'ist',
      'nicht',
      'ich',
      'ein',
      'eine',
      'es',
      'zu',
      'mit',
      'auf',
      'sie',
      'wie',
      'auch',
      'sehr',
      'aber',
      'wir',
      'den',
      'dem',
      'nur',
      'noch',
      'schon',
      'mir',
      'hat',
    },
    'es': {
      'el',
      'los',
      'las',
      'es',
      'y',
      'que',
      'de',
      'una',
      'por',
      'con',
      'para',
      'muy',
      'pero',
      'como',
      'más',
      'yo',
      'esto',
      'este',
      'está',
      'lo',
      'del',
      'son',
      'hay',
      'qué',
      'también',
      'todo',
    },
    'pt': {
      'o',
      'os',
      'as',
      'é',
      'e',
      'que',
      'um',
      'uma',
      'não',
      'com',
      'para',
      'muito',
      'mas',
      'como',
      'isso',
      'eu',
      'você',
      'do',
      'da',
      'dos',
      'das',
      'está',
      'tem',
      'ele',
      'ela',
      'mais',
    },
    'it': {
      'il',
      'lo',
      'gli',
      'è',
      'e',
      'che',
      'di',
      'un',
      'una',
      'non',
      'con',
      'per',
      'molto',
      'ma',
      'come',
      'questo',
      'sono',
      'io',
      'del',
      'della',
      'anche',
      'ho',
      'mi',
      'ti',
      'si',
      'bello',
    },
    'nl': {
      'de',
      'het',
      'een',
      'en',
      'is',
      'niet',
      'ik',
      'je',
      'dat',
      'van',
      'met',
      'op',
      'zijn',
      'maar',
      'ook',
      'heel',
      'wat',
      'dit',
      'er',
      'wel',
    },
    'id': {
      'yang',
      'dan',
      'ini',
      'itu',
      'di',
      'ke',
      'dari',
      'tidak',
      'ada',
      'saya',
      'aku',
      'kamu',
      'dengan',
      'untuk',
      'juga',
      'sangat',
      'bisa',
      'sudah',
      'akan',
      'banget',
      'gak',
      'nya',
    },
    'tr': {
      'bir',
      've',
      'bu',
      'da',
      'de',
      'çok',
      'ne',
      'ben',
      'sen',
      'için',
      'ama',
      'gibi',
      'var',
      'yok',
      'daha',
      'olan',
      'değil',
      'mi',
    },
    'pl': {
      'nie',
      'jest',
      'to',
      'się',
      'na',
      'że',
      'jak',
      'ale',
      'co',
      'tak',
      'bardzo',
      'mnie',
      'jestem',
      'czy',
      'już',
      'tylko',
      'ten',
      'ta',
    },
    'vi': {
      'là',
      'và',
      'của',
      'có',
      'không',
      'một',
      'này',
      'được',
      'cho',
      'với',
      'tôi',
      'bạn',
      'rất',
      'những',
      'các',
      'người',
      'đã',
      'thì',
    },
    'fil': {
      'ang',
      'ng',
      'mga',
      'sa',
      'na',
      'ay',
      'at',
      'ko',
      'mo',
      'ako',
      'siya',
      'hindi',
      'lang',
      'naman',
      'talaga',
      'ito',
      'yung',
      'po',
    },
  };

  /// Letters only one of these languages uses (among them).
  static final _letters = {
    'es': RegExp('[ñ¿¡]'),
    'de': RegExp('[ßäöü]'),
    'pt': RegExp('[ãõ]'),
    'fr': RegExp('[œæèêëîïûùÿ]'),
    'tr': RegExp('[ğşı]'),
    'pl': RegExp('[łąężźśćń]'),
    'vi': RegExp('[ăđơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]'),
  };

  static String _latin(String text) {
    final lower = text.toLowerCase();
    final words = lower
        .split(RegExp(r"[^a-zà-ɏḀ-ỿ']+"))
        .where((w) => w.isNotEmpty);
    final score = <String, double>{};
    for (final w in words) {
      for (final MapEntry(key: lang, value: common) in _words.entries) {
        if (common.contains(w)) score[lang] = (score[lang] ?? 0) + 1;
      }
    }
    for (final MapEntry(key: lang, value: letters) in _letters.entries) {
      final n = letters.allMatches(lower).length;
      // a letter of its own weighs more than a shared word
      if (n > 0) score[lang] = (score[lang] ?? 0) + 2 * n;
    }
    if (score.isEmpty) return 'latin';
    final best = score.entries.reduce((a, b) => a.value >= b.value ? a : b);
    // a tie between two languages is not an answer
    final ties = score.values.where((v) => v == best.value).length;
    return ties > 1 ? 'latin' : best.key;
  }

  /// The languages the viewer reads without a translation: the app's and
  /// those kept in the subtitle menu (user 2026-09-25, 4B).
  static List<String> get native => [
    AsrService.appLanguage,
    ...pinnedTranslationLanguages,
  ];

  /// Whether [text] should be translated for a viewer reading [native]:
  /// it is in a language told apart from all of them. An unknown Latin
  /// language is translated only when no native language is written in
  /// Latin letters — otherwise it may well be one of them.
  static bool needsTranslation(String text, {List<String>? native}) {
    native ??= TextLanguage.native;
    final lang = detect(text);
    if (lang == null) return false;
    bool isNative(String code) => native!.any(
      (n) =>
          AsrService.isSameMajorLanguage(code, n) ||
          n.split('-').first == code.split('-').first,
    );
    if (lang == 'latin') return !native.any(_writtenInLatin);
    return !isNative(lang);
  }

  static bool _writtenInLatin(String code) =>
      _words.containsKey(code.split('-').first);
}
