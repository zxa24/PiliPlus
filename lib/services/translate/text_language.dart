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
    final count = _count(text);
    final han = count[_Script.han]!;
    final kana = count[_Script.kana]!;
    final letters = count.values.fold(0, (a, b) => a + b);
    // three Han characters say as much as four letters: 哈哈 does not
    if (han * 4 + (letters - han) * 3 < _minLetters * 3) return null;
    // any kana at all: Japanese writes Han with kana, Chinese never does
    if (kana > 0 && kana + han >= letters / 2) return 'ja';
    final scripts = <String, int>{
      'zh': han,
      'ko': count[_Script.hangul]!,
      'cyrillic': count[_Script.cyrillic]!,
      'ar': count[_Script.arabic]!,
      'th': count[_Script.thai]!,
      'hi': count[_Script.devanagari]!,
      'el': count[_Script.greek]!,
      'he': count[_Script.hebrew]!,
      'latin': count[_Script.latin]!,
    };
    final top = scripts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return switch (top.key) {
      'cyrillic' => RegExp('[іїєґІЇЄҐ]').hasMatch(text) ? 'uk' : 'ru',
      'latin' => _latin(text),
      final code => code,
    };
  }

  /// How many letters of each script [text] has.
  static Map<_Script, int> _count(String text) {
    final count = {for (final script in _Script.values) script: 0};
    for (final r in text.runes) {
      final script = switch (r) {
        _ when r >= 0x3040 && r <= 0x30FF || r >= 0x31F0 && r <= 0x31FF =>
          _Script.kana,
        _ when r >= 0x4E00 && r <= 0x9FFF || r >= 0x3400 && r <= 0x4DBF =>
          _Script.han,
        _ when r >= 0xAC00 && r <= 0xD7A3 || r >= 0x1100 && r <= 0x11FF =>
          _Script.hangul,
        _ when r >= 0x0400 && r <= 0x04FF => _Script.cyrillic,
        _ when r >= 0x0600 && r <= 0x06FF => _Script.arabic,
        _ when r >= 0x0E00 && r <= 0x0E7F => _Script.thai,
        _ when r >= 0x0900 && r <= 0x097F => _Script.devanagari,
        _ when r >= 0x0370 && r <= 0x03FF => _Script.greek,
        _ when r >= 0x0590 && r <= 0x05FF => _Script.hebrew,
        _
            when (r >= 0x41 && r <= 0x5A) ||
                (r >= 0x61 && r <= 0x7A) ||
                (r >= 0xC0 && r <= 0x24F) ||
                (r >= 0x1E00 && r <= 0x1EFF) =>
          _Script.latin,
        _ => null,
      };
      if (script != null) count[script] = count[script]! + 1;
    }
    return count;
  }

  /// The scripts a translation into each language is written in. Latin is
  /// left out of the non-Latin ones on purpose: names and brands are kept
  /// in it by any language (`我简直太 impressed 了` aside).
  static const _targetScripts = {
    'zh': {_Script.han},
    'ja': {_Script.kana, _Script.han},
    'ko': {_Script.hangul},
    'ru': {_Script.cyrillic},
    'uk': {_Script.cyrillic},
    'ar': {_Script.arabic},
    'hi': {_Script.devanagari},
    'th': {_Script.thai},
  };

  /// What is wrong with [translation] as a translation of [source] into
  /// [target], by the scripts it is written in; null when nothing is.
  ///
  /// Checked after [cleanTranslation]: this is about the language a reply
  /// came back in, not its shape. A small model asked for Chinese sometimes
  /// answers in Japanese, or copies the source unchanged
  /// (research/hardsub-compare-2026-09-26.md: 4 of 125 Japanese units came
  /// back Japanese, 1 copied). What can be told:
  ///
  /// - into any language: an unchanged copy of a source in a language
  ///   other than [target] (letters and digits compared, case ignored). A
  ///   source already in [target], or too short to tell, may well be copied.
  /// - into Chinese: kana. More kana than half the Han characters is
  ///   Japanese ([TranslationFlaw.usable] false); fewer is a Japanese word
  ///   or name left in a Chinese sentence (`这是三菱的ジェットストリーム笔`),
  ///   worth asking again but better than the Japanese source if asking
  ///   again does not help.
  /// - into a language with a script of its own (Chinese, Japanese, Korean,
  ///   Russian, Ukrainian, Arabic, Hindi, Thai): more letters of another
  ///   non-Latin script than of its own, or Latin letters and none of its
  ///   own. Latin words among its own are accepted, however many: names
  ///   and brands are kept in Latin, and a word left in English
  ///   (`我简直太 impressed 了`) cannot be told from them by script.
  /// - into Japanese: a sentence of Han characters without any kana, from a
  ///   Chinese source — Chinese given back.
  /// - into a language written in Latin letters: more non-Latin letters
  ///   than Latin ones (a Han, kana or hangul character counting as two).
  ///   Which Latin language it is cannot be told reliably from a subtitle
  ///   line (see [_latin]), so French given back for a Spanish request
  ///   passes unless it is a copy.
  static TranslationFlaw? checkTranslation(
    String translation, {
    required String source,
    required String target,
  }) {
    final into = target.split('-').first.toLowerCase();
    final from = detect(source);
    final latinTarget = _words.containsKey(into) || into == 'ms';
    final sourceInTarget =
        from != null &&
        (AsrService.isSameMajorLanguage(from, target) ||
            // an unknown Latin language may be the one asked for
            (from == 'latin' && latinTarget));
    String bare(String text) => text.toLowerCase().replaceAll(
      RegExp(r'[\p{P}\p{S}\s]', unicode: true),
      '',
    );
    if (from != null && !sourceInTarget) {
      final copy = bare(translation);
      if (copy.isNotEmpty && copy == bare(source)) {
        return const TranslationFlaw('a copy of the source');
      }
    }
    final count = _count(translation.replaceAll(_notLanguage, ' '));
    final latin = count[_Script.latin]!;
    const cjk = {_Script.han, _Script.kana, _Script.hangul};
    final own = _targetScripts[into == 'yue' ? 'zh' : into];
    if (own != null) {
      final kana = count[_Script.kana]!;
      final han = count[_Script.han]!;
      if (own.length == 1 && own.first == _Script.han && kana > 0) {
        return TranslationFlaw(
          'kana in Chinese',
          usable: kana * 2 <= han,
        );
      }
      var mine = 0, foreign = 0;
      for (final MapEntry(key: script, value: n) in count.entries) {
        if (own.contains(script)) {
          mine += n;
        } else if (script != _Script.latin) {
          foreign += n;
        }
      }
      if (foreign > mine) return const TranslationFlaw('another script');
      // with any of its own script it may be a line of names, or a word
      // left in English: neither is told from a sentence left untranslated
      if (latin >= _minLetters && mine == 0) {
        return const TranslationFlaw('only Latin letters');
      }
      if (into == 'ja' && kana == 0 && han >= 8 && from == 'zh') {
        return const TranslationFlaw('Chinese, not Japanese');
      }
      return null;
    }
    if (latinTarget) {
      var foreign = 0;
      for (final MapEntry(key: script, value: n) in count.entries) {
        if (script == _Script.latin) continue;
        foreign += cjk.contains(script) ? n * 2 : n;
      }
      if (foreign > latin) return const TranslationFlaw('not Latin letters');
    }
    return null;
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
  static List<String> get native =>
      debugNative ?? [AsrService.appLanguage, ...pinnedTranslationLanguages];

  /// For the self-test (`--native`): the viewer's languages. Nothing else
  /// sets it.
  static List<String>? debugNative;

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

enum _Script {
  han,
  kana,
  hangul,
  cyrillic,
  arabic,
  thai,
  devanagari,
  greek,
  hebrew,
  latin,
}

/// Why a translation is not in the language asked for (see
/// [TextLanguage.checkTranslation]).
class TranslationFlaw {
  const TranslationFlaw(this.reason, {this.usable = false});

  /// A few words for the event log.
  final String reason;

  /// Still better shown than the source: mostly in the language asked for,
  /// with a little of another. Asked again all the same, and kept if the
  /// second answer is no better.
  final bool usable;

  @override
  String toString() => usable ? '$reason (usable)' : reason;
}
