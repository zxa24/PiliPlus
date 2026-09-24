/// LibrePili: a translated unit back on the recogniser's timeline.
///
/// The translator never produces a time. The unit's span comes from the
/// recogniser and stays; what changes is how the translated text is cut
/// into lines and how the span is shared between them.
///
/// Three states per unit, three looks:
/// - translated: the translation, cut into lines, timed across the unit;
/// - not yet translated: the source lines, marked as waiting (decision 3A,
///   2026-09-23 — never blank, and never mistakable for a translation);
/// - failed: the source lines, unmarked, since nothing more is coming.
///
/// In [TranslationDisplay.dual] (decision 4A) a translated line carries the
/// source line under it. The two are cut differently, so the timeline is
/// the union of both sets of boundaries and each piece shows whichever of
/// each was current — the line that did not change is redrawn identically,
/// which on screen is no change at all.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';

enum TranslationDisplay { translated, dual }

/// Shown under a source line whose translation has not arrived.
const translationPendingMark = '（正在翻译…）';

/// A translated line may be this wide, in half-width units.
///
/// Wider than the 32 a transcript line gets: that limit is for someone
/// listening and glancing down, while someone who cannot follow the speech
/// is reading. Chinese at 44 is 22 characters, which still fits one line on
/// a phone held sideways.
const translationMaxWidth = 44;

/// Below this a sentence end does not start a new line; two short sentences
/// share one.
const _minLineWidth = 12;

/// A piece of the dual timeline shorter than this is not worth a cue of
/// its own; it goes to the piece before it.
const _sliver = 0.3;

/// How a unit stands: absent is still waiting, null is failed, text is done.
typedef TranslationResults = Map<int, String?>;

/// The display cues for a translation track.
///
/// [units] are the settled units in order and [results] what is known about
/// each, by index. [trailing] are cues the recogniser has produced that are
/// not in a unit yet; they are shown as waiting. The result is laid out
/// the same way a transcript is (small holes closed, no overlaps).
List<AsrCue> layOutTranslation({
  required List<TranslationUnit> units,
  required TranslationResults results,
  List<AsrCue> trailing = const [],
  TranslationDisplay display = TranslationDisplay.translated,
}) {
  final out = <AsrCue>[];
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (!results.containsKey(i)) {
      out.addAll(_pending(unit.cues));
      continue;
    }
    final text = results[i];
    if (text == null) {
      out.addAll(unit.cues);
      continue;
    }
    // A unit's last cue may be held past where the next unit starts — the
    // hold is decided inside one VAD segment, which cannot see the next.
    // Spread over that, the translation's last line would sit under the
    // next unit's first one.
    final next = i + 1 < units.length ? units[i + 1].from : null;
    final bounded = next != null && next < unit.to && next > unit.from
        ? TranslationUnit(
            from: unit.from,
            to: next,
            text: unit.text,
            cues: unit.cues,
          )
        : unit;
    final lines = timeTranslation(bounded, splitTranslation(text));
    out.addAll(
      display == TranslationDisplay.dual
          ? _dual(lines, [
              // the source lines under it end where the translation does
              for (final c in unit.cues)
                if (c.from < bounded.to)
                  AsrCue(
                    from: c.from,
                    to: c.to < bounded.to ? c.to : bounded.to,
                    content: c.content,
                  ),
            ])
          : lines,
    );
  }
  out.addAll(_pending(trailing));
  return AsrCueBuilder.layOut(out);
}

Iterable<AsrCue> _pending(List<AsrCue> cues) => cues.map(
  (cue) => AsrCue(
    from: cue.from,
    to: cue.to,
    content: '${cue.content}\n$translationPendingMark',
  ),
);

/// Cuts a translation into display lines.
///
/// A line ends at a sentence end once it holds enough to be worth reading,
/// otherwise at the last clause end that keeps it within
/// [translationMaxWidth], and failing that wherever it fills up — but never
/// inside a run of Latin letters or digits, which is a word or a number the
/// model kept from the source.
List<String> splitTranslation(
  String text, {
  int maxWidth = translationMaxWidth,
}) {
  final lines = <String>[];
  final line = StringBuffer();
  var width = 0;
  // position in [line] just after the last clause end, and the width there
  var clauseAt = -1;
  var clauseWidth = 0;

  void emit(String piece) {
    final trimmed = piece.trim();
    if (trimmed.isNotEmpty) lines.add(trimmed);
  }

  final chars = text.replaceAll(RegExp(r'\s+'), ' ').trim().runes.toList();
  for (var i = 0; i < chars.length; i++) {
    final c = String.fromCharCode(chars[i]);
    final w = AsrCueBuilder.displayWidth(c);
    if (width + w > maxWidth && line.isNotEmpty) {
      final current = line.toString();
      if (clauseAt > 0) {
        emit(current.substring(0, clauseAt));
        final rest = current.substring(clauseAt);
        line
          ..clear()
          ..write(rest);
        width -= clauseWidth;
      } else {
        // no clause end: back off to the start of a Latin word or number
        var cut = current.length;
        while (cut > 0 &&
            _isWordChar(current.codeUnitAt(cut - 1)) &&
            _isWordChar(chars[i])) {
          cut--;
        }
        if (cut == 0) cut = current.length;
        emit(current.substring(0, cut));
        final rest = current.substring(cut);
        line
          ..clear()
          ..write(rest);
        width = AsrCueBuilder.displayWidth(rest);
      }
      clauseAt = -1;
      clauseWidth = 0;
    }
    line.write(c);
    width += w;
    if (_sentenceEnd.contains(c) && width >= _minLineWidth) {
      final next = i + 1 < chars.length
          ? String.fromCharCode(chars[i + 1])
          : '';
      // keep a closing quote or bracket on the line it closes, and a run of
      // marks together: 但现在…… once left "…" as a line of its own
      if (!_closers.contains(next) && !_sentenceEnd.contains(next)) {
        emit(line.toString());
        line.clear();
        width = 0;
        clauseAt = -1;
        clauseWidth = 0;
        continue;
      }
    }
    if (_clauseEnd.contains(c) || _sentenceEnd.contains(c)) {
      clauseAt = line.length;
      clauseWidth = width;
    }
  }
  emit(line.toString());
  return lines;
}

const _sentenceEnd = '。！？!?…';
const _clauseEnd = '，、；：,;:';
const _closers = '”’」』）)】';

bool _isWordChar(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A);

/// Shares the unit's span between [lines], in proportion to how wide each
/// is, then moves each boundary to where a source line starts if one is
/// close by — a translated sentence that changes when the speaker starts
/// the next one reads as in sync; one that changes a second before does not.
List<AsrCue> timeTranslation(TranslationUnit unit, List<String> lines) {
  if (lines.isEmpty) return const [];
  final span = unit.to - unit.from;
  final widths = [for (final l in lines) AsrCueBuilder.displayWidth(l)];
  final total = widths.fold(0, (a, b) => a + b);
  final starts = [for (final cue in unit.cues.skip(1)) cue.from];
  final bounds = <double>[unit.from];
  var acc = 0;
  for (var k = 0; k < lines.length - 1; k++) {
    acc += widths[k];
    var t = unit.from + span * acc / total;
    double? best;
    for (final s in starts) {
      if ((s - t).abs() <= _snap &&
          (best == null || (s - t).abs() < (best - t).abs())) {
        best = s;
      }
    }
    if (best != null) t = best;
    // never behind the previous boundary, or a line would get no time
    if (t <= bounds.last) t = bounds.last + (span / lines.length) * 0.5;
    bounds.add(t < unit.to ? t : unit.to);
  }
  bounds.add(unit.to);
  return [
    for (var k = 0; k < lines.length; k++)
      AsrCue(from: bounds[k], to: bounds[k + 1], content: lines[k]),
  ];
}

/// How far a boundary may move to meet a source line start, in seconds.
const _snap = 1.0;

/// Translated lines over their source lines, on the union of both sets of
/// boundaries.
List<AsrCue> _dual(List<AsrCue> translated, List<AsrCue> source) {
  final points = <double>{
    for (final c in translated) ...[c.from, c.to],
    for (final c in source) ...[c.from, c.to],
  }.toList()..sort();
  String? at(List<AsrCue> cues, double t) {
    for (final c in cues) {
      if (c.from <= t && t < c.to) return c.content;
    }
    return null;
  }

  final out = <AsrCue>[];
  for (var k = 0; k + 1 < points.length; k++) {
    final a = points[k];
    final b = points[k + 1];
    final mid = (a + b) / 2;
    final top = at(translated, mid);
    final bottom = at(source, mid);
    if (top == null && bottom == null) continue;
    final content = [?top, ?bottom].join('\n');
    final last = out.isEmpty ? null : out.last;
    if (last != null &&
        (last.content == content || b - a < _sliver) &&
        (a - last.to).abs() < 1e-9) {
      // same text, or too brief to show: the piece before carries on
      out[out.length - 1] = AsrCue(
        from: last.from,
        to: b,
        content: last.content,
      );
      continue;
    }
    out.add(AsrCue(from: a, to: b, content: content));
  }
  return out;
}
