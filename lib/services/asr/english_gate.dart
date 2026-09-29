/// LibrePili: when a session's speech is English enough to be recognised by
/// the English model (research/noisy-speech-design-2026-09-26.md, 11–12,
/// user 2026-09-29: English on the phone is recognised by Parakeet).
///
/// SenseVoice starts every session: it tags each segment with a language
/// and its first lines come quickest. Once this says English, the session
/// loads the English model in the background and recognises every later
/// segment with it instead — it tags nothing, so the decision is made once
/// and kept for the session (see AsrSession).
library;

/// Decides, from SenseVoice's tagged segments in the order they came, when
/// a session is English.
///
/// The rule: [minSpeech] seconds of speech tagged with a language, and
/// English holding at least [minShare] of it (by duration). Segments with
/// no tag — hidden, silent, noise — do not count.
class AsrEnglishGate {
  AsrEnglishGate({this.minSpeech = 20, this.minShare = 0.75});

  /// Seconds of tagged speech before anything is decided.
  final double minSpeech;

  /// How much of it English must hold.
  final double minShare;

  final _seconds = <String, double>{};
  var _english = false;

  /// English, and settled: the session switches. Once true, it stays.
  bool get english => _english;

  /// Seconds of tagged speech so far.
  double get tagged => _seconds.values.fold(0.0, (a, b) => a + b);

  /// Adds a segment tagged [language] (`en`, `zh`, …; empty for none) that
  /// lasted [duration] seconds. Returns true when this made it English.
  ///
  /// Never settled the other way: a video that opens in another language
  /// and goes on in English is switched once English has the share.
  bool add(String language, double duration) {
    if (_english || language.isEmpty || duration <= 0) return false;
    // Cantonese and Mandarin are one language here, as everywhere else
    final key = language == 'yue' ? 'zh' : language;
    _seconds[key] = (_seconds[key] ?? 0) + duration;
    final all = tagged;
    if (all < minSpeech) return false;
    return _english = (_seconds['en'] ?? 0) >= all * minShare;
  }
}

/// Whether a session may switch to the English model at all, and whether
/// it starts with it: [enabled] is the setting (英语使用专用模型),
/// [installed] whether the model is downloaded, [forced] the language the
/// recogniser is forced to (empty for none). Forced to another language,
/// nothing would ever be tagged English; forced to English, SenseVoice is
/// not needed even to begin with.
({bool use, bool first}) asrEnglishChoice({
  required bool enabled,
  required bool installed,
  required String forced,
}) {
  final use = enabled && installed && (forced.isEmpty || forced == 'en');
  return (use: use, first: use && forced == 'en');
}
