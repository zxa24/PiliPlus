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

/// A segment whose language tag weighs less than this — a text of six
/// characters or fewer (the weight is the length plus one, see RunSegment)
/// — is too short for the tag to be trusted, and takes its neighbour's.
///
/// Both recorded transcripts the translation replay runs on open with a
/// stray `The.` tagged as another language than the speech. Passed through
/// or translated on its own tag, one such word in a Chinese video would
/// load the 1–3 GB model to translate it (research/subtitle-switch-design-
/// 2026-09-26.md, 5).
const translationMinLanguageWeight = 8;

class TranslationUnit {
  TranslationUnit({
    required this.from,
    required this.to,
    required this.text,
    required this.cues,
    this.language = '',
    int? key,
  }) : key = key ?? (from * 1000).round();

  /// The language its segments were tagged as (after
  /// [smoothSegmentLanguages]); empty when unknown — captions, or a
  /// recogniser that gave none. A unit never spans two languages.
  final String language;

  /// Where the unit's first cue starts and its last one ends, in seconds.
  final double from;
  final double to;

  /// What its translation is kept under: where it starts, in milliseconds.
  ///
  /// Not its place in the list. Text can now arrive in front of what is
  /// already there — a run started further on, then one from before it
  /// (research/chunked-transcription-design-2026-09-25.md, 4.6) — and every
  /// unit after it would move up a place, taking the translation of the
  /// one before. The time a unit starts does not move. Two units that
  /// start in the same millisecond are told apart by [withUniqueKeys].
  final int key;

  /// The source text as one piece, as the translator sees it.
  final String text;

  /// The display cues it was built from, in order.
  final List<AsrCue> cues;

  @override
  String toString() => 'TranslationUnit($from-$to: $text)';
}

typedef AsrSegmentSpan = ({double start, double duration});

/// [units], in the order given, with no two sharing a [TranslationUnit.key]:
/// one that would is moved to the next free millisecond. A translation is
/// kept with the text it was made from, so a key that ends up naming
/// another unit only loses a translation, never shows the wrong one.
List<TranslationUnit> withUniqueKeys(List<TranslationUnit> units) {
  final seen = <int>{};
  var out = units;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    var key = unit.key;
    if (seen.add(key)) continue;
    while (!seen.add(key)) {
      key++;
    }
    if (identical(out, units)) out = List.of(units);
    out[i] = TranslationUnit(
      from: unit.from,
      to: unit.to,
      text: unit.text,
      cues: unit.cues,
      language: unit.language,
      key: key,
    );
  }
  return out;
}

/// The language each segment counts as, for [buildTranslationUnits]: its
/// own tag, unless the tag is too short to trust
/// ([translationMinLanguageWeight]) — then the tag of the nearest segment
/// before it that is long enough, or, with none before it, the nearest
/// after it.
///
/// An untagged segment stays untagged, and lends nothing to its
/// neighbours: an unknown language is never guessed. A weight of 0 is no
/// weight given, and the tag stands.
///
/// Null where it cannot be decided yet: a short segment with no long one
/// before it and none after it so far. With [complete], none is coming,
/// and the segment keeps its own tag. Once decided, a segment's language
/// never changes as more segments arrive: before it they are all known,
/// and the first long one after it is the first to arrive.
List<String?> smoothSegmentLanguages(
  List<({String language, int weight})> segments, {
  required bool complete,
}) {
  bool trusted(({String language, int weight}) s) =>
      s.language.isNotEmpty &&
      (s.weight <= 0 || s.weight >= translationMinLanguageWeight);
  final out = List<String?>.filled(segments.length, null);
  String? before;
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    if (s.language.isEmpty || trusted(s)) {
      out[i] = s.language;
      if (trusted(s)) before = s.language;
      continue;
    }
    if (before != null) {
      out[i] = before;
      continue;
    }
    String? after;
    for (var k = i + 1; k < segments.length; k++) {
      if (trusted(segments[k])) {
        after = segments[k].language;
        break;
      }
    }
    out[i] = after ?? (complete ? s.language : null);
  }
  return out;
}

/// Groups [cues] into translation units along [segments]: one run's (see
/// TranscriptStore), since a unit is never made across two.
///
/// [languages], when given, is the language of each segment (see
/// [smoothSegmentLanguages]): two segments of different languages are never
/// joined, each unit carries its segments' language, and one whose language
/// is not decided yet (null) is left out like an open one. Without it every
/// segment is of one unknown language, and units are cut as they always
/// were.
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
  List<String?>? languages,
}) {
  String? languageOf(int i) => languages == null ? '' : languages[i];
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
    final language = languageOf(i);
    // not decided until a segment long enough to trust arrives
    if (language == null) break;
    var last = i;
    while (last + 1 < segments.length &&
        last + 1 - i < translationMaxSegments &&
        _gapAfter(segments, last) < translationJoinGap &&
        // a cut between two languages is a boundary all the same
        languageOf(last + 1) == language) {
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
          language: language,
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
