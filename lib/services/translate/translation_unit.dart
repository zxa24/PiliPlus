/// LibrePili: what gets handed to the translator, one piece at a time.
///
/// Not the display cue. A cue is cut to fit a line — by width, by time — and
/// a sentence routinely spans two or three of them; translating those one by
/// one gives the translator fragments, and between languages with different
/// word order (ja → zh most of all) a fragment can come out meaning the
/// opposite of the whole: `私はこの提案に賛成` / `しません` → 我赞成这个提案 / 不。
///
/// The unit is the VAD segment: the largest stretch the recogniser finishes
/// in one go, so a unit never changes once it exists. Measured on real video
/// (research/translation-deliberation-2026-09-22.md), about a third of
/// segment boundaries still fall mid-sentence, and in Japanese 46% of them
/// are a gap under 0.5 s — the 20 s cap cutting a speaker off, not a pause.
/// Those are joined to the segment after, at most two to a unit, so a hard
/// cut does not become a translation boundary while a unit stays bounded.
///
/// Neighbouring text is deliberately not passed as context: a controlled
/// test found the models did no better with the real neighbours than with
/// shuffled ones (research/translation-bench-2026-09-23.md).
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';

/// A gap below this between two segments is a cut, not a pause.
const translationJoinGap = 0.5;

/// No unit is built from more segments than this.
const translationMaxSegments = 2;

class TranslationUnit {
  const TranslationUnit({
    required this.from,
    required this.to,
    required this.text,
    required this.cues,
  });

  /// Where the unit's first cue starts and its last one ends, in seconds.
  final double from;
  final double to;

  /// The source text as one piece, as the translator sees it.
  final String text;

  /// The display cues it was built from, in order.
  final List<AsrCue> cues;

  @override
  String toString() => 'TranslationUnit($from-$to: $text)';
}

typedef AsrSegmentSpan = ({double start, double duration});

/// Groups [cues] into translation units along [segments].
///
/// Both lists grow while recognition runs and only ever at the end. A unit
/// whose last segment is also the newest one cannot be settled yet — the
/// next segment might follow within [translationJoinGap] and belong to it —
/// so it is left out until either that segment arrives or [complete] says
/// none will. Everything returned is therefore final: the same call on longer
/// lists returns the same units first, followed by new ones.
List<TranslationUnit> buildTranslationUnits({
  required List<AsrSegmentSpan> segments,
  required List<AsrCue> cues,
  required bool complete,
}) {
  // which cues each segment produced: a cue starts inside the segment it
  // came from (its end may be held past it, its start never moves)
  final bySegment = <List<AsrCue>>[for (final _ in segments) <AsrCue>[]];
  var s = 0;
  for (final cue in cues) {
    while (s + 1 < segments.length && cue.from >= segments[s + 1].start) {
      s++;
    }
    if (segments.isEmpty) break;
    bySegment[s].add(cue);
  }

  final units = <TranslationUnit>[];
  var i = 0;
  while (i < segments.length) {
    var last = i;
    while (last + 1 < segments.length &&
        last + 1 - i < translationMaxSegments &&
        _gapAfter(segments, last) < translationJoinGap) {
      last++;
    }
    // the newest segment may still be joined by one not recognised yet
    final open =
        !complete &&
        last == segments.length - 1 &&
        last + 1 - i < translationMaxSegments;
    if (open) break;
    final unitCues = [
      for (var k = i; k <= last; k++) ...bySegment[k],
    ];
    if (unitCues.isNotEmpty) {
      units.add(
        TranslationUnit(
          from: unitCues.first.from,
          to: unitCues.last.to,
          text: joinCueText([for (final cue in unitCues) cue.content]),
          cues: unitCues,
        ),
      );
    }
    i = last + 1;
  }
  return units;
}

double _gapAfter(List<AsrSegmentSpan> segments, int i) {
  final end = segments[i].start + segments[i].duration;
  return segments[i + 1].start - end;
}

/// Puts display lines back together into running text.
///
/// Cues are only ever cut at a word start, and a Latin cue has its leading
/// space trimmed, so two Latin lines need the space back. Between CJK lines
/// there was never one.
String joinCueText(List<String> lines) {
  final out = StringBuffer();
  for (final line in lines) {
    final text = line.trim();
    if (text.isEmpty) continue;
    if (out.isNotEmpty) {
      final before = out.toString();
      final a = before.runes.last;
      final b = text.runes.first;
      if (AsrCueBuilder.displayWidth(String.fromCharCode(a)) == 1 &&
          AsrCueBuilder.displayWidth(String.fromCharCode(b)) == 1) {
        out.write(' ');
      }
    }
    out.write(text);
  }
  return out.toString();
}
