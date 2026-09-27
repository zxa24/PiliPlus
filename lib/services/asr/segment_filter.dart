/// LibrePili: recognised segments too odd to show.
///
/// In noisy video the recogniser turns background voices, songs and street
/// noise into lines that were never said: 14 of 220 segments hand-labelled
/// on four street clips (research/noisy-speech-design-2026-09-26.md, 6) —
/// `这光就 the酒精汉是少` in an English vlog, `哒哒哒哒`, `.`, `시れ`. Most
/// of them are one or two segments in another language than everything
/// around them, or have hardly any text, or are written in a script their
/// own language tag does not use.
///
/// What is hidden is only the *isolated* oddity (the user's decision 2A,
/// same document, 7): a video that changes language part way — Chinese,
/// then Japanese — keeps both, since each line is translated from its own
/// language. A stretch of another language counts as content from its
/// third segment on; one or two segments of it, with at least two segments
/// of one language before them and that language again after them (or
/// nothing after them), are hidden. A dialogue that alternates line by line
/// never has two of one language in a row, and is never touched.
///
/// Measured on the labels: 12 of the 14 hidden, 2 of 206 good segments lost
/// (both genuine Chinese speech in an English vlog: an isolated line in
/// another language is hidden whether it was said or not); on the same clips
/// cut with the current VAD settings, 8 of 9 hidden and 2 of 25 lost. The
/// Japanese and the other English clip lose nothing.
///
/// A segment in another language than the two before it can only be
/// decided once what follows it is known, so it is held back — and
/// everything after it with it, to keep the order — until the stretch ends
/// or reaches three. Nothing is held at the start of a run, before two
/// segments give a language to compare with: the first subtitle is never
/// delayed. The price is that an odd first line is shown.
library;

/// Why a segment is not shown.
enum AsrOddity {
  /// Fewer than two letters or digits: `.`, `う。`.
  short,

  /// Written in a script its own language tag does not use: Chinese
  /// characters in a segment tagged English, a line mostly in Latin letters
  /// tagged Chinese or Japanese.
  script,

  /// One word four or more times running, making up most of the text:
  /// `哒哒哒哒`, `sell sell sell sell sell`.
  repeat,

  /// One or two segments in another language than those around them.
  isolated,
}

typedef AsrFiltered<T> = ({T item, AsrOddity? hidden});

class _Entry<T> {
  _Entry(this.item, this.start);
  final T item;
  final double start;
  var decided = false;
  AsrOddity? hidden;

  void decide(AsrOddity? why) {
    decided = true;
    hidden = why;
  }
}

/// Decides, segment by segment and in order, which to show; one per run.
class AsrSegmentFilter<T> {
  /// A stretch of this many segments of another language or fewer is an
  /// oddity; one more is content.
  static const maxIsolated = 2;

  final _queue = <_Entry<T>>[];

  /// The language families of the last segments shown that had one.
  final _shown = <String>[];

  /// The undecided stretch: its language, the language around it, and its
  /// segments.
  String? _stretch;
  String? _around;
  final _members = <_Entry<T>>[];

  /// Where the first segment not handed back yet starts, or null.
  double? get firstHeld => _queue.isEmpty ? null : _queue.first.start;

  /// Adds the next segment — [item], starting at [start], its [text] and
  /// the [language] it was tagged with — and returns the segments now
  /// decided, in order: this one, ones held before it, or none.
  List<AsrFiltered<T>> add(
    T item, {
    required double start,
    required String text,
    required String language,
  }) {
    final entry = _Entry(item, start);
    _queue.add(entry);
    final odd = oddity(text, language);
    final family = familyOf(language);
    if (odd != null) {
      entry.decide(odd);
    } else if (family == null) {
      // untagged: nothing to compare, and nothing to compare with
      entry.decide(null);
    } else if (_stretch == family) {
      _members.add(entry);
      if (_members.length > maxIsolated) _resolve(hide: false);
    } else {
      if (_stretch != null) _resolve(hide: family == _around);
      _place(entry, family);
    }
    return _release();
  }

  /// No more segments are coming: a stretch still undecided has nothing
  /// after it, and is hidden.
  List<AsrFiltered<T>> finish() {
    if (_stretch != null) _resolve(hide: true);
    return _release();
  }

  void _place(_Entry<T> entry, String family) {
    final n = _shown.length;
    final around = n >= 2 && _shown[n - 1] == _shown[n - 2]
        ? _shown[n - 1]
        : null;
    if (around == null || around == family) {
      entry.decide(null);
      _shown.add(family);
      return;
    }
    _stretch = family;
    _around = around;
    _members
      ..clear()
      ..add(entry);
  }

  void _resolve({required bool hide}) {
    for (final m in _members) {
      m.decide(hide ? AsrOddity.isolated : null);
      if (!hide) _shown.add(_stretch!);
    }
    _members.clear();
    _stretch = null;
    _around = null;
  }

  List<AsrFiltered<T>> _release() {
    final out = <AsrFiltered<T>>[];
    while (_queue.isNotEmpty && _queue.first.decided) {
      final e = _queue.removeAt(0);
      out.add((item: e.item, hidden: e.hidden));
    }
    if (_shown.length > 8) _shown.removeRange(0, _shown.length - 2);
    return out;
  }

  /// What a language tag counts as when languages are compared: Cantonese
  /// as Chinese — the recogniser tells the two apart unreliably, and a
  /// Mandarin video is not to lose its lines tagged `yue`. Null for no tag
  /// or one it does not know.
  static String? familyOf(String language) => switch (language) {
    'zh' || 'yue' => 'zh',
    'en' || 'ja' || 'ko' => language,
    _ => null,
  };

  static final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _cjk = RegExp(
    '[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]',
  );
  static final _latin = RegExp('[A-Za-zÀ-ɏ]');
  static final _hangul = RegExp('[ᄀ-ᇿ㄰-㆏가-힯]');

  /// A Latin word, or any other single letter (a CJK character is a word).
  static final _word = RegExp("[A-Za-zÀ-ɏ']+|\\p{L}", unicode: true);

  /// What is wrong with a segment on its own — [text] as recognised,
  /// [language] as tagged — or null.
  static AsrOddity? oddity(String text, String language) {
    if (_letter.allMatches(text).length < 2) return AsrOddity.short;
    final cjk = _cjk.allMatches(text).length;
    final latin = _latin.allMatches(text).length;
    switch (familyOf(language)) {
      case 'en' when cjk > 0:
      case 'zh' || 'ja' when latin > cjk:
      case 'ko' when _hangul.allMatches(text).isEmpty:
        return AsrOddity.script;
    }
    final words = [
      for (final m in _word.allMatches(text.toLowerCase())) m[0]!,
    ];
    if (words.length >= 4) {
      final letters = words.fold(0, (sum, w) => sum + w.length);
      for (var i = 0; i < words.length;) {
        var j = i;
        while (j + 1 < words.length && words[j + 1] == words[i]) {
          j++;
        }
        final run = j - i + 1;
        if (run >= 4 && run * words[i].length * 2 >= letters) {
          return AsrOddity.repeat;
        }
        i = j + 1;
      }
    }
    return null;
  }
}
