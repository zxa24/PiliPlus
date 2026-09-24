/// LibrePili: Simplified to Traditional Chinese, Taiwan standard with Taiwan
/// phrases — OpenCC's `s2twp`, from its text dictionaries (assets/opencc,
/// Apache-2.0, OpenCC 1.4.2).
///
/// Traditional Chinese subtitles are made this way rather than asked of the
/// translation model: asked for Traditional Chinese, Hy-MT2 wrote simplified
/// characters for 36–46 of 50 sentences and Gemma for 8 of 50 from Japanese,
/// where converting its Chinese translation gave none
/// (research/translation-targets-2026-09-24.md). No package covers every
/// platform the app builds for without native code fetched at build time
/// (research/opencc-flutter-2026-09-24.md), and the algorithm is small.
///
/// It follows OpenCC's own (s2twp.json and its source): normalise
/// compatibility ideographs; cut the text by forward maximum matching on the
/// phrase dictionaries; then run each piece through two conversions, each a
/// longest-prefix match that copies what it does not know. A "union" group
/// takes the longest match any of its dictionaries has; a "short circuit"
/// group the first dictionary, in order, that has one.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// One dictionary: its entries and its longest key, in code points.
final class _Dict {
  _Dict(this.entries)
    : maxLength = entries.keys.fold(
        0,
        (m, k) => k.runes.length > m ? k.runes.length : m,
      );

  final Map<String, String> entries;
  final int maxLength;

  /// The longest key starting at [at] in [chars], and its value.
  (int, String)? match(List<String> chars, int at) {
    final most = chars.length - at < maxLength ? chars.length - at : maxLength;
    for (var length = most; length > 0; length--) {
      final value = entries[chars.sublist(at, at + length).join()];
      if (value != null) return (length, value);
    }
    return null;
  }

  /// OpenCC's text format: `key<TAB>value [value…]`, `#` comments; the first
  /// value is the one used.
  static _Dict parse(String text) {
    final entries = <String, String>{};
    for (final line in text.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final values = line.substring(tab + 1).trim();
      if (values.isEmpty) continue;
      final space = values.indexOf(' ');
      entries.putIfAbsent(
        line.substring(0, tab),
        () => space == -1 ? values : values.substring(0, space),
      );
    }
    return _Dict(entries);
  }
}

/// A group of dictionaries asked as one.
sealed class _Group {
  (int, String)? match(List<String> chars, int at);
}

/// The longest match among all of them.
final class _Union extends _Group {
  _Union(this.dicts);
  final List<_Dict> dicts;

  @override
  (int, String)? match(List<String> chars, int at) {
    (int, String)? best;
    for (final dict in dicts) {
      final found = dict.match(chars, at);
      if (found != null && (best == null || found.$1 > best.$1)) best = found;
    }
    return best;
  }
}

/// The first of them, in order, that has a match.
final class _ShortCircuit extends _Group {
  _ShortCircuit(this.groups);
  final List<Object> groups;

  @override
  (int, String)? match(List<String> chars, int at) {
    for (final group in groups) {
      final found = switch (group) {
        final _Dict d => d.match(chars, at),
        final _Group g => g.match(chars, at),
        _ => null,
      };
      if (found != null) return found;
    }
    return null;
  }
}

final class S2twpConverter {
  S2twpConverter._(
    this._normalization,
    this._phrases,
    this._toTraditional,
    this._toTaiwan,
  );

  final _Dict _normalization;
  final _Union _phrases;
  final _ShortCircuit _toTraditional;
  final _ShortCircuit _toTaiwan;

  static const files = [
    'STPhrases',
    'STPhrases_GeneratedFromRegionalPhrases',
    'STCharacters',
    'TWPhrases',
    'TWVariantsPhrases',
    'TWVariants',
    'CJK_Compatibility_Ideographs',
  ];

  /// From the dictionaries' texts, by name (see [files]).
  factory S2twpConverter.fromTexts(Map<String, String> texts) {
    _Dict dict(String name) => _Dict.parse(texts[name]!);
    final phrases = _Union([
      dict('STPhrases'),
      dict('STPhrases_GeneratedFromRegionalPhrases'),
    ]);
    return S2twpConverter._(
      dict('CJK_Compatibility_Ideographs'),
      phrases,
      _ShortCircuit([phrases, dict('STCharacters')]),
      _ShortCircuit([
        dict('TWPhrases'),
        dict('TWVariantsPhrases'),
        dict('TWVariants'),
      ]),
    );
  }

  static Future<S2twpConverter>? _loading;

  /// The converter, its dictionaries read once and parsed off the UI
  /// isolate: about 1 MB of text, 50 000 phrases.
  static Future<S2twpConverter> load() => _loading ??= () async {
    final texts = {
      for (final name in files)
        name: await rootBundle.loadString('assets/opencc/$name.txt'),
    };
    return compute(S2twpConverter.fromTexts, texts);
  }();

  String convert(String text) {
    if (text.isEmpty) return text;
    final normalized = _convert(_chars(text), _normalization.match);
    final out = StringBuffer();
    for (final segment in _segment(_chars(normalized))) {
      final traditional = _convert(segment, _toTraditional.match);
      out.write(_convert(_chars(traditional), _toTaiwan.match));
    }
    return out.toString();
  }

  /// Code points, so a character outside the BMP is one character.
  static List<String> _chars(String text) => [
    for (final rune in text.runes) String.fromCharCode(rune),
  ];

  /// Forward maximum matching on the phrases: a match is a piece of its own,
  /// and what lies between matches is another.
  List<List<String>> _segment(List<String> chars) {
    final segments = <List<String>>[];
    var start = 0;
    var at = 0;
    while (at < chars.length) {
      final found = _phrases.match(chars, at);
      if (found == null) {
        at++;
        continue;
      }
      if (at > start) segments.add(chars.sublist(start, at));
      segments.add(chars.sublist(at, at + found.$1));
      at += found.$1;
      start = at;
    }
    if (start < chars.length) segments.add(chars.sublist(start));
    return segments;
  }

  static String _convert(
    List<String> chars,
    (int, String)? Function(List<String> chars, int at) match,
  ) {
    final out = StringBuffer();
    var at = 0;
    while (at < chars.length) {
      final found = match(chars, at);
      if (found == null) {
        out.write(chars[at]);
        at++;
      } else {
        out.write(found.$2);
        at += found.$1;
      }
    }
    return out.toString();
  }
}
