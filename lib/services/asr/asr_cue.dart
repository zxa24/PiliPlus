/// LibrePili: the result shape of on-device transcription.
///
/// Cues are emitted in the same `{from, to, content}` shape Bilibili's own
/// subtitle API uses, so [SubtitleUtils.json2Vtt] / `json2Srt` and the whole
/// existing subtitle path work on them unchanged.
library;

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

  String toVtt() => SubtitleUtils.json2Vtt(toJson());

  String toSrt() => SubtitleUtils.json2Srt(toJson());
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

  /// Characters per cue. Measured against the same video's official AI
  /// subtitle: continuous speech with no full stops otherwise ran to 35
  /// characters on one line, which nobody can read in six seconds.
  static const _maxChars = 14;

  /// And a cap that does not need permission from punctuation.
  ///
  /// [_maxChars] only ever *armed* a break at the next clause end, so speech
  /// without commas ran to the duration cap instead. Measured on a 15-minute
  /// video: median 28 characters, 90th percentile 42, longest 49, and 26 of
  /// 203 cues over 40 — three lines on a phone. A limit that a sentence can
  /// simply decline to honour is not a limit.
  static const _hardMaxChars = 22;

  /// Nothing is cut below this, otherwise punctuation-heavy speech flickers.
  static const _minDuration = 1.0;

  /// No cue is shown for less than this if there is room to hold it.
  /// Eleven of those 203 were under a second and six under half a second:
  /// long enough to notice something appeared, not long enough to read it.
  static const _minShown = 1.2;

  /// Silence longer than this inside a VAD segment is treated as a break.
  static const _gap = 0.8;

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
  }) {
    final clean = [
      for (final token in tokens)
        if (stripTags(token.text).isNotEmpty)
          (text: token.text.replaceAll(_tag, ''), time: token.time),
    ];
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

    final cues = <AsrCue>[];
    final buffer = StringBuffer();
    var start = clean.first.time;

    void flush(double end) {
      final content = _tidy(buffer.toString());
      buffer.clear();
      if (content.isEmpty) return;
      cues.add(
        AsrCue(from: offset + start, to: offset + end, content: content),
      );
    }

    for (var i = 0; i < clean.length; i++) {
      final token = clean[i];
      buffer.write(token.text);
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
      final long = buffer.length >= _maxChars;
      final breakHere =
          next == null ||
          held >= maxDuration ||
          // a hard stop, so a sentence without commas cannot run on
          buffer.length >= _hardMaxChars ||
          (held >= _minDuration &&
              (_sentenceEnd.contains(tail) ||
                  silent ||
                  // a long line breaks at the next clause end rather than
                  // running on to the duration cap
                  (long && _clauseEnd.contains(tail))));
      if (breakHere) {
        flush(shownTo);
        if (next != null) start = next.time;
      }
    }
    return _holdBriefly(_mergeRunts(cues));
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
  static List<AsrCue> _mergeRunts(List<AsrCue> cues) {
    final merged = <AsrCue>[];
    for (final cue in cues) {
      final bare = cue.content.replaceAll(_punctuation, '').isEmpty;
      // A cue under a second is a flash. It is folded into the one before —
      // but only when the result still fits on two lines, or fixing the
      // flicker would create the overlong line instead.
      final brief = cue.to - cue.from < _minDuration;
      final fits =
          merged.isNotEmpty &&
          merged.last.content.length + cue.content.length <= _hardMaxChars;
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

  static final RegExp _punctuation = RegExp(
    r'[\s。，、！？；：.,!?;:…—-]',
  );

  /// SenseVoice emits BPE pieces for non-CJK: `▁` marks a word start.
  static String _tidy(String raw) => raw
      .replaceAll('▁', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
