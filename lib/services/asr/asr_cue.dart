/// LibrePili: the result shape of on-device transcription.
///
/// Cues are emitted in the same `{from, to, content}` shape Bilibili's own
/// subtitle API uses, so [SubtitleUtils.json2Vtt] / `json2Srt` and the whole
/// existing subtitle path work on them unchanged.
library;

import 'package:PiliPlus/services/asr/line_planner.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';

/// One recognised token and the time it starts at, both as reported by
/// SenseVoice (60 ms granularity).
typedef AsrToken = ({String text, double time});

class AsrCue {
  const AsrCue({required this.from, required this.to, required this.content});

  /// Seconds from the start of the media.
  final double from;
  final double to;
  final String content;

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'content': content,
  };

  @override
  String toString() => 'AsrCue($from-$to: $content)';

  @override
  bool operator ==(Object other) =>
      other is AsrCue &&
      other.from == from &&
      other.to == to &&
      other.content == content;

  @override
  int get hashCode => Object.hash(from, to, content);
}

extension AsrCueList on List<AsrCue> {
  List<Map<String, dynamic>> toJson() => [for (final cue in this) cue.toJson()];

  /// The cues as they are shown, gaps closed.
  ///
  /// Bridging has to happen here rather than inside [AsrCueBuilder.fromSegment]
  /// because most of the remaining gaps fall *between* VAD segments, and a
  /// segment cannot see the one after it.
  List<AsrCue> get displayed => AsrCueBuilder.layOut(this);

  String toVtt() => SubtitleUtils.json2Vtt(displayed.toJson());

  String toSrt() => SubtitleUtils.json2Srt(displayed.toJson());
}

abstract final class AsrCueBuilder {
  /// SenseVoice wraps its metadata in `<|…|>`: language (`<|zh|>`), emotion
  /// (`<|NEUTRAL|>`), audio event (`<|BGM|>`, `<|Applause|>`) and the ITN flag.
  /// None of it belongs in a subtitle.
  static final RegExp _tag = RegExp(r'<\|[^|]*\|>');

  /// A cue ends after one of these even when it is still short.
  static const _sentenceEnd = '。！？.!?…';

  /// A clause end: only used to break a cue that is already too long to read.
  static const _clauseEnd = '，、,;；：:';

  /// How much room a cue may take, in half-width units: a CJK character
  /// counts 2, a Latin letter 1.
  ///
  /// This used to count characters, which is the same thing only if every
  /// video is Chinese. Measured against the author's own English track on a
  /// 467 s video: they wrote 159 cues of a median 32 characters, we produced
  /// 261 of a median 17 — the limit tuned for Chinese cut English into about
  /// three words a line. Counting width instead leaves Chinese untouched
  /// (every character is 2, so the thresholds scale exactly) and gives Latin
  /// text the room the same line has.
  static const _maxWidth = 20;

  /// And a cap that does not need permission from punctuation.
  ///
  /// [_maxChars] only ever *armed* a break at the next clause end, so speech
  /// without commas ran to the duration cap instead. Measured on a 15-minute
  /// video: median 28 characters, 90th percentile 42, longest 49, and 26 of
  /// 203 cues over 40 — three lines on a phone. A limit that a sentence can
  /// simply decline to honour is not a limit.
  /// Measured against the captions YouTube ships for the same video: their
  /// median cue is 11 characters and their longest 28, held for a median of
  /// 1.5 s. Ours were 22 and 27 at 3.0 s — twice the text for twice as long,
  /// which reads as one long line rather than two short ones.
  static const _hardMaxWidth = 32;

  /// Nothing is cut below this, otherwise punctuation-heavy speech flickers.
  static const _minDuration = 1.0;

  /// No cue is shown for less than this if there is room to hold it.
  /// Eleven of those 203 were under a second and six under half a second:
  /// long enough to notice something appeared, not long enough to read it.
  ///
  /// Raised from 1.2 s against the author's own track on a 467 s video: they
  /// hold a line for a median of 2.30 s and leave almost no gap between
  /// lines (90th percentile 1.07 s), which is why 89% of their video carries
  /// a subtitle against our 67%. A cue can only grow into silence that is
  /// already empty — [_holdBriefly] stops at the next cue's start — so this
  /// buys coverage without ever overlapping the next line.
  static const _minShown = 2.0;

  /// Silence longer than this inside a VAD segment is treated as a break.
  static const _gap = 0.8;

  /// A hole smaller than this between two cues is closed rather than left.
  ///
  /// The author's own track on the measured video leaves a median gap of
  /// 0.03 s and a 90th percentile of 1.07 s — in other words, the screen
  /// almost never goes blank between two lines. Ours left a 90th percentile
  /// of 2.32 s on the same video, which is the flicker between sentences.
  /// Anything larger than this is a real pause and stays one: a line held
  /// across six seconds of silence is worse than no line.
  static const _bridgeGap = 2.0;

  /// Lays the finished cues out for display: small holes closed, overlaps
  /// removed.
  ///
  /// Both need the whole list, which is why this cannot live in
  /// [fromSegment]: a VAD segment cannot see the one after it. That is also
  /// how cues came to overlap — a segment's last cue was held for
  /// [_minShown] with no idea that the next segment had already started, so
  /// a 2 s hold ran 0.18 s into the following line.
  ///
  /// A cue is only ever moved at its end, never at its start and never in
  /// its text. Shrinking takes precedence: two lines on screen at once is
  /// worse than a gap.
  static List<AsrCue> layOut(List<AsrCue> cues) {
    if (cues.length < 2) return cues;
    final out = <AsrCue>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      final next = i + 1 < cues.length ? cues[i + 1] : null;
      if (next == null) {
        out.add(cue);
        continue;
      }
      final hole = next.from - cue.to;
      final to = hole < 0
          // overlap: give the line back to the one that starts next
          ? (next.from > cue.from ? next.from : cue.to)
          : (hole < _bridgeGap ? next.from : cue.to);
      out.add(AsrCue(from: cue.from, to: to, content: cue.content));
    }
    return out;
  }

  /// What [text] takes up on screen, counting a full-width character as two.
  ///
  /// Line length is a question about width, not about how many code points
  /// happen to be involved: 16 Chinese characters and 16 English letters do
  /// not occupy remotely the same line.
  static int displayWidth(String text) {
    var width = 0;
    for (final rune in text.runes) {
      width += _isFullWidth(rune) ? 2 : 1;
    }
    return width;
  }

  /// The East Asian Wide / Fullwidth ranges, which is all this needs: every
  /// script the recogniser supports is either one of these or half-width.
  static bool _isFullWidth(int rune) =>
      (rune >= 0x1100 && rune <= 0x115F) || // hangul jamo
      (rune >= 0x2E80 && rune <= 0x303E) || // CJK radicals, punctuation
      (rune >= 0x3041 && rune <= 0x33FF) || // kana, hangul compat, CJK squared
      (rune >= 0x3400 && rune <= 0x4DBF) || // CJK ext A
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified
      (rune >= 0xA000 && rune <= 0xA4CF) || // Yi
      (rune >= 0xAC00 && rune <= 0xD7A3) || // hangul syllables
      (rune >= 0xF900 && rune <= 0xFAFF) || // CJK compatibility ideographs
      (rune >= 0xFE30 && rune <= 0xFE4F) || // CJK compatibility forms
      (rune >= 0xFF00 && rune <= 0xFF60) || // fullwidth forms
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x20000 && rune <= 0x3FFFD); // CJK ext B and beyond

  /// Suffixes SenseVoice glues onto the end of an English word that are not
  /// speech: a spoken-punctuation word ("switchperiod", "humancomma") or a
  /// piece of one ("instructioniod", "switchperd").
  static const _junkSuffixes = {'period', 'perd', 'iod', 'comma'};

  /// Removes recogniser artefacts from a segment's tokens.
  ///
  /// Measured on a 467 s English talk: 12 of 63 segments carried them, and a
  /// translator copied them straight into the Chinese ("照片>"). They come
  /// from the model itself, not from inverse text normalisation — switching
  /// ITN off left 9 and cost casing, punctuation and numerals.
  ///
  /// What makes them removable without touching real words is where they
  /// sit: glued to the previous word with no leading space, while a real
  /// word starts with one. So "a period of time" keeps its word — " period"
  /// begins with a space — and the rule works on tokens rather than on the
  /// joined text, where the difference is gone. A word whose stem plus
  /// suffix spells "period" or "comma" is the speaker saying it, and stays.
  ///
  /// Angle brackets are dropped outright: nothing in a subtitle uses them.
  /// "thisio" is left alone; removing "io" would also remove it from radio.
  static List<({String text, double time})> dropRecogniserJunk(
    List<({String text, double time})> tokens,
  ) {
    final out = <({String text, double time})>[];
    for (final t in tokens) {
      final text = t.text.replaceAll(RegExp('[<>]'), '');
      if (text.isNotEmpty) out.add((text: text, time: t.time));
    }
    var i = 0;
    while (i < out.length) {
      if (!out[i].text.startsWith(' ')) {
        i++;
        continue;
      }
      // the word: this token and every following one that does not start a
      // new word or a punctuation run
      var end = i + 1;
      while (end < out.length &&
          !out[end].text.startsWith(' ') &&
          RegExp(r'^[A-Za-z]').hasMatch(out[end].text)) {
        end++;
      }
      if (end - i > 1) {
        final stem = out[i].text.trim().toLowerCase();
        final suffix = out
            .sublist(i + 1, end)
            .map((t) => t.text)
            .join()
            .toLowerCase();
        final whole = stem + suffix;
        if (_junkSuffixes.contains(suffix) &&
            whole != 'period' &&
            whole != 'comma' &&
            stem.length >= 2) {
          out.removeRange(i + 1, end);
          end = i + 1;
        }
      }
      i = end;
    }
    return out;
  }

  /// Indexes of the tokens that begin a phrase, or null when there is no
  /// [segmenter] or its answer cannot be trusted.
  ///
  /// The phrases must concatenate back to the text exactly; if they do not,
  /// offsets would point at the wrong tokens, and falling back to the old
  /// behaviour is safer than breaking in places nobody chose.
  static Set<int>? _phraseStarts(
    List<({String text, double time})> clean,
    List<String> Function(String text)? segmenter,
  ) {
    if (segmenter == null) return null;
    final joined = clean.map((t) => t.text).join();
    final phrases = segmenter(joined);
    if (phrases.join() != joined) return null;
    final starts = <int>{};
    var offset = 0;
    for (final phrase in phrases) {
      starts.add(offset);
      offset += phrase.length;
    }
    final tokens = <int>{};
    offset = 0;
    for (var i = 0; i < clean.length; i++) {
      if (starts.contains(offset)) tokens.add(i);
      offset += clean[i].text.length;
    }
    return tokens;
  }

  /// Whether [text] contains kana, which only Japanese does.
  ///
  /// Used alongside the recogniser's own language tag rather than instead
  /// of it: the tag is per segment and occasionally wrong on short ones.
  static bool hasKana(String text) => text.runes.any(
    (r) => (r >= 0x3041 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF),
  );

  /// Whether [next] begins a word, and so whether a cue may end before it.
  ///
  /// SenseVoice marks a word start with a **leading space**: the pieces for
  /// "superpower" come back as `" super"` and `"power"`, and for "noticing"
  /// as `" not"`, `"ic"`, `"ing"`. A piece with no leading space continues
  /// the word before it, and ending a cue there cuts the word in half.
  /// (`▁` is accepted too — other sentencepiece models use it, and the
  /// tidying step has always replaced it.)
  ///
  /// Trailing punctuation carries no space either, which is the behaviour
  /// wanted: `"."` attaches to the line it ends rather than opening the next.
  ///
  /// Full-width scripts mark nothing and every character stands alone, so
  /// they may break anywhere — which is why none of this showed on Chinese.
  static bool _startsWord(String next) {
    if (next.isEmpty) return true;
    final first = next.runes.first;
    if (first == 0x20 || first == 0x2581) return true;
    return _isFullWidth(first);
  }

  /// Whether [text] begins with a mark that belongs to what comes before
  /// it: an end of sentence or clause, or a closing quote or bracket.
  static bool _opensWithMark(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return false;
    return _trailingMarks.contains(trimmed[0]);
  }

  /// Whether [next] carries on a run of ASCII letters or digits that [text]
  /// ends in, with no space between them.
  static bool _continuesRun(String text, String next) {
    if (text.isEmpty || next.isEmpty || next.startsWith(' ')) return false;
    return _alnum.hasMatch(text[text.length - 1]) && _alnum.hasMatch(next[0]);
  }

  static final _alnum = RegExp('[A-Za-z0-9]');

  static const _trailingMarks = '$_sentenceEnd$_clauseEnd”’」』）)】》〉';

  static String stripTags(String text) => text.replaceAll(_tag, '').trim();

  /// The value inside the first `<|…|>`, e.g. `<|zh|>` → `zh`.
  ///
  /// SenseVoice reports the detected language in that form. Stripping the
  /// tags — the obvious thing to do — leaves nothing at all, which is how a
  /// first run ended up reporting an empty language.
  static String tagValue(String text) {
    final match = _tag.firstMatch(text);
    if (match == null) return text.trim();
    final value = match[0]!;
    return value.substring(2, value.length - 2).trim();
  }

  /// A cue below this is not readable on its own; it belongs to the one
  /// before it.
  static const _runtDuration = 0.4;

  /// Turns one VAD segment's recognition result into display cues.
  ///
  /// [offset] is where the segment starts in the media, [duration] how long it
  /// is; [tokens] carry times relative to the segment. A segment can be up to
  /// 20 s of continuous speech, which is far too long to show at once, so it is
  /// cut at sentence ends, at internal silence, and failing both at
  /// [maxDuration].
  ///
  /// With no usable timestamps the whole segment becomes a single cue — wrong
  /// looking but never wrong: the text still lines up with the speech.
  static List<AsrCue> fromSegment({
    required double offset,
    required double duration,
    required List<AsrToken> tokens,
    String? text,
    double maxDuration = 6,
    List<String> Function(String text)? segmenter,
    bool planLines = false,
  }) {
    final clean = dropRecogniserJunk([
      for (final token in tokens)
        if (stripTags(token.text).isNotEmpty)
          (text: token.text.replaceAll(_tag, ''), time: token.time),
    ]);
    // Where a cue may end, for a script that marks no words. SenseVoice
    // gives Japanese one character per token and no spaces, so without this
    // every break was wherever the width cap fell: ホテ / ル, ニュ / ーヨーク,
    // 思っ / て, 4 / つのうち. [segmenter] splits the segment's text into
    // phrases (BudouX); a break is allowed only before one of those.
    final phraseStarts = _phraseStarts(clean, segmenter);
    // How wide each phrase is, keyed by the token it starts at, so a break
    // can be taken *before* a phrase that would not fit rather than after it.
    // Waiting for the next legal break once over the cap let a Japanese line
    // run on by a whole phrase: 16 characters became 24, and one 33.
    final phraseWidth = <int, int>{};
    if (phraseStarts != null) {
      final sorted = phraseStarts.toList()..sort();
      for (var k = 0; k < sorted.length; k++) {
        final from = sorted[k];
        final to = k + 1 < sorted.length ? sorted[k + 1] : clean.length;
        var width = 0;
        for (var t = from; t < to; t++) {
          width += displayWidth(clean[t].text);
        }
        phraseWidth[from] = width;
      }
    }
    if (clean.isEmpty) {
      final fallback = stripTags(text ?? '');
      if (fallback.isEmpty) return const [];
      return [
        AsrCue(from: offset, to: offset + duration, content: fallback),
      ];
    }

    // How long a token takes to say, estimated from this segment's own
    // pace. Only token *starts* are reported, so the last token of a cue has
    // no known end — assuming it was over within [_gap] cut the final word
    // in half on slow speech, which is what "the subtitle ends before the
    // sentence does" was.
    final spacings = <double>[
      for (var i = 0; i + 1 < clean.length; i++)
        if (clean[i + 1].time - clean[i].time < _gap)
          clean[i + 1].time - clean[i].time,
    ]..sort();
    final typicalToken = spacings.isEmpty
        ? 0.3
        : spacings[spacings.length ~/ 2];
    // enough for the word itself plus a moment to finish reading it
    final tailHold = (typicalToken * 3).clamp(_gap, 2.0);

    final planned = planLines && phraseStarts != null
        ? _plannedBreaks(clean, phraseStarts, typicalToken, maxDuration)
        : null;

    final cues = <AsrCue>[];
    final buffer = StringBuffer();
    // tracked alongside the buffer rather than recomputed: the check runs
    // once per token and measuring the whole buffer each time is quadratic
    var bufferWidth = 0;
    var start = clean.first.time;

    void flush(double end) {
      final content = _tidy(buffer.toString());
      buffer.clear();
      bufferWidth = 0;
      if (content.isEmpty) return;
      cues.add(
        AsrCue(from: offset + start, to: offset + end, content: content),
      );
    }

    for (var i = 0; i < clean.length; i++) {
      final token = clean[i];
      buffer.write(token.text);
      bufferWidth += displayWidth(token.text);
      final trimmed = token.text.trimRight();
      final next = i + 1 < clean.length ? clean[i + 1] : null;
      // only token *starts* are reported, so silence shows up as a large gap
      // between two starts
      final silent = next != null && next.time - token.time >= _gap;
      // the token's own end is unknown: normally the next start closes it, but
      // across silence the cue would otherwise sit on screen through the pause
      final end = next == null
          ? duration
          // across silence the cue must not sit through the pause, but it
          // must outlast the word it ends on: hold for the segment's own
          // token pace, never past the next token
          : (silent
                ? (token.time + tailHold).clamp(token.time, next.time)
                : next.time);
      // never past the segment it came from
      final shownTo = end > duration ? duration : end;
      // Two different questions. How long this cue has been *collecting
      // speech* decides whether to break; how long it should stay on screen
      // decides `end`. Measuring the break against the padded end made a
      // 1.2 s pause between two syllables long enough to split a word.
      // Two different questions. How long this cue has been *collecting
      // speech* decides whether to break; how long it stays on screen
      // decides its end. The speech ends when the last token finishes —
      // not when the next one starts, which counts the silence after it,
      // and not at the padded end, which counts the hold.
      final held = (token.time + typicalToken) - start;
      final tail = trimmed.isEmpty ? '' : trimmed[trimmed.length - 1];
      final long = bufferWidth >= _maxWidth;
      // Never in the middle of a word. Every break below is decided by
      // length or by time, and a token is a sentencepiece *fragment*, so
      // without this the caps land wherever they happen to fall: a real
      // video produced "a little extra coach" / "ing." and "something is
      // technical" / "ly fully functioning". Unreadable on screen, and
      // useless as input to a translator, which would be handed fragments
      // that are not words.
      //
      // Nor before a mark: a full-width one counts as a character of its
      // own, and a line began with the comma or full stop of the line before
      // it (8 of 198 lines in a Chinese transcript: 「，有两只」).
      //
      // Nor inside a number or a Latin word the recogniser spelled out a
      // character at a time: a phrase model split 只要29 / 71.
      final atWord =
          next == null ||
          (!_opensWithMark(next.text) &&
              !_continuesRun(token.text, next.text) &&
              (phraseStarts != null
                  ? phraseStarts.contains(i + 1) || next.text.startsWith(' ')
                  : _startsWord(next.text)));
      // A tokeniser that marks no words at all must not turn the whole
      // segment into one cue: past twice the cap, break wherever we are.
      final overrun = bufferWidth >= _hardMaxWidth * 2;
      // The next phrase would not fit on this line: end the line before it.
      // Not below half a line, or a long phrase would leave a stub behind.
      final nextWouldOverflow =
          next != null &&
          bufferWidth >= _maxWidth ~/ 2 &&
          bufferWidth + (phraseWidth[i + 1] ?? 0) > _hardMaxWidth;
      final breakHere = planned != null
          ? next == null || planned.contains(i + 1)
          : next == null ||
                // A pause of [_gap] is a break whatever the segmenter says: the
                // speaker stopped, which no phrase model can overrule. Gating it
                // on phrase starts glued ベスティ花だよ onto the sentence after it.
                (silent && held >= _minDuration) ||
                ((atWord || overrun) &&
                    (held >= maxDuration ||
                        // a hard stop, so a sentence without commas cannot run on
                        bufferWidth >= _hardMaxWidth ||
                        nextWouldOverflow ||
                        (held >= _minDuration &&
                            (_sentenceEnd.contains(tail) ||
                                silent ||
                                // a long line breaks at the next clause end rather
                                // than running on to the duration cap
                                (long && _clauseEnd.contains(tail))))));
      if (breakHere) {
        flush(shownTo);
        if (next != null) start = next.time;
      }
    }
    final merged = _mergeRunts(cues, keepSentences: planned != null);
    return _holdBriefly(planned != null ? _joinNext(merged) : merged);
  }

  /// With `planLines`: the tokens lines start at, chosen per sentence by
  /// [planLineBreaks] rather than as the lines fill.
  ///
  /// A sentence here runs to a sentence mark or to a pause of [_gap] — the
  /// study split only at marks; a pause that long is a break the old rule
  /// always took, and keeping it keeps a line from holding a silence.
  static Set<int> _plannedBreaks(
    List<({String text, double time})> clean,
    Set<int> phraseStarts,
    double typical,
    double maxDuration,
  ) {
    final breaks = <int>{};
    var from = 0;
    void plan(int to) {
      if (from >= to) return;
      if (from > 0) breaks.add(from);
      final text = StringBuffer();
      final tokenAt = <int>[];
      final times = <double>[];
      final starts = <int>{};
      final phrases = <int>{};
      for (var t = from; t < to; t++) {
        starts.add(text.length);
        if (phraseStarts.contains(t) || clean[t].text.startsWith(' ')) {
          phrases.add(text.length);
        }
        for (var c = 0; c < clean[t].text.length; c++) {
          tokenAt.add(t);
          times.add(clean[t].time);
        }
        text.write(clean[t].text);
      }
      final string = text.toString();
      for (final k in planLineBreaks(
        string,
        phraseStarts: phrases,
        // only between phrases: the study let a word split at a cost, and on
        // a sentence two lines too tight it chose 沙子然 / 后又 over a third
        // line
        breakable: (k) =>
            phrases.contains(k) &&
            !_continuesRun(clean[tokenAt[k] - 1].text, clean[tokenAt[k]].text),
        times: times,
        typical: typical,
        cap: _hardMaxWidth,
        maxDuration: maxDuration,
      )) {
        breaks.add(tokenAt[k]);
      }
      from = to;
    }

    for (var i = 0; i < clean.length; i++) {
      final trimmed = clean[i].text.trimRight();
      final tail = trimmed.isEmpty ? '' : trimmed[trimmed.length - 1];
      final silent =
          i + 1 < clean.length && clean[i + 1].time - clean[i].time >= _gap;
      // a mark at the start of the next token still belongs to this line
      final markNext =
          i + 1 < clean.length && _opensWithMark(clean[i + 1].text);
      if ((_sentenceEnd.contains(tail) || silent) && !markNext) plan(i + 1);
    }
    plan(clean.length);
    return breaks;
  }

  /// Joins a cue too brief to read onto the one after it, when that one
  /// starts before the brief one could be held for [_minShown]: holding
  /// cannot help it then, and the one before has ended its sentence (see
  /// [_mergeRunts]). Planned lines left 7 of 255 under a second on a real
  /// transcript, 「第一天，」 for 0.42 s among them.
  static List<AsrCue> _joinNext(List<AsrCue> cues) {
    final out = <AsrCue>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      final next = i + 1 < cues.length ? cues[i + 1] : null;
      if (next != null &&
          cue.to - cue.from < _minDuration &&
          next.from - cue.from < _minShown) {
        cues[i + 1] = AsrCue(
          from: cue.from,
          to: next.to,
          content: _tidy('${cue.content}${next.content}'),
        );
        continue;
      }
      out.add(cue);
    }
    return out;
  }

  /// Gives a cue that is too brief to read the time to be read, taking it
  /// from the silence that follows rather than from the next cue.
  ///
  /// Nothing is moved and nothing overlaps: a cue only grows into a gap that
  /// is already empty. Where there is no gap the cue was already merged by
  /// [_mergeRunts], or it genuinely butts against the next line.
  static List<AsrCue> _holdBriefly(List<AsrCue> cues) {
    final out = <AsrCue>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      final wanted = cue.from + _minShown;
      final ceiling = i + 1 < cues.length ? cues[i + 1].from : wanted;
      final to = cue.to >= wanted
          ? cue.to
          : (wanted <= ceiling ? wanted : ceiling);
      out.add(
        AsrCue(
          from: cue.from,
          to: to > cue.to ? to : cue.to,
          content: cue.content,
        ),
      );
    }
    return out;
  }

  /// Folds away cues that are too short to read or hold nothing but
  /// punctuation — a trailing `。` of its own for a tenth of a second is a
  /// flicker, not a subtitle. They keep their text by joining the cue before.
  ///
  /// With [keepSentences], a brief cue stays out of a sentence that has
  /// ended: the lines were planned, and folding them undid the plan —
  /// 「3个月前，」 went back onto 「即待一场大雨。」.
  static List<AsrCue> _mergeRunts(
    List<AsrCue> cues, {
    bool keepSentences = false,
  }) {
    final merged = <AsrCue>[];
    for (final cue in cues) {
      final bare = cue.content.replaceAll(_punctuation, '').isEmpty;
      // A cue under a second is a flash. It is folded into the one before —
      // but only when the result still fits on two lines, or fixing the
      // flicker would create the overlong line instead.
      final brief = cue.to - cue.from < _minDuration;
      final fits =
          merged.isNotEmpty &&
          displayWidth(merged.last.content) + displayWidth(cue.content) <=
              _hardMaxWidth &&
          !(keepSentences && _endsSentence(merged.last.content));
      final isRunt =
          bare || cue.to - cue.from < _runtDuration || (brief && fits);
      if (isRunt && merged.isNotEmpty) {
        final previous = merged.removeLast();
        merged.add(
          AsrCue(
            from: previous.from,
            to: cue.to,
            content: _tidy('${previous.content}${cue.content}'),
          ),
        );
      } else if (!bare) {
        // nothing to merge into: a short cue with real words still beats
        // dropping the words
        merged.add(cue);
      }
    }
    return merged;
  }

  static bool _endsSentence(String text) {
    var end = text.trimRight();
    while (end.isNotEmpty && '”’」』）)】》〉'.contains(end[end.length - 1])) {
      end = end.substring(0, end.length - 1);
    }
    return end.isNotEmpty && _sentenceEnd.contains(end[end.length - 1]);
  }

  static final RegExp _punctuation = RegExp(
    r'[\s。，、！？；：.,!?;:…—-]',
  );

  /// SenseVoice emits BPE pieces for non-CJK: `▁` marks a word start.
  static String _tidy(String raw) =>
      raw.replaceAll('▁', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
