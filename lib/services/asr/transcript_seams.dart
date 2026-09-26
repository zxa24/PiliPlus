/// LibrePili: where one run's text meets another's
/// (research/chunked-transcription-design-2026-09-25.md, 4.3).
///
/// Two runs over the same audio do not cut it the same way: the VAD's
/// state differs, a 20 s forced cut lands elsewhere, and the recogniser's
/// text normalisation depends on where a segment begins (assumption A4, the
/// one expected to fail). So a seam is never made by lining up text. It is
/// made of whole segments: at a run's start the segments before the target
/// are dropped, and where a run runs into text already there, it goes
/// on until it ends a segment where the old text also has a boundary, and
/// its segments then replace the old ones they overlap — never cutting
/// inside one.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';

/// A segment the VAD called speech, with the cues recognised in it.
typedef SeamSegment = ({double start, double duration, List<AsrCue> cues});

/// Two boundaries this close are the same boundary.
const seamTolerance = 0.3;

/// How far into the known stretch a join goes looking for a boundary both
/// runs share before it settles for the last clean one it has. Segments
/// are meant to be at most 20 s, but the VAD was seen to hand over one of
/// 41 s in continuous speech.
const seamMaxOverlap = 90.0;

/// Whether a run started for [target] keeps a segment it recognised
/// (design 4.3, start).
///
/// Every segment that ends after the target is kept — the sentence being
/// spoken where the viewer landed is the one they need. Before it, nothing
/// is: those segments lie in the pre-roll, and the one that begins at the
/// extraction start itself was cut short by it. A [clean] start cuts
/// nothing (the start of the media, or exactly where known text ends), and
/// keeps everything.
///
/// The cut segment is dropped only when it ends before the target, which is
/// what the pre-roll is for. In continuous speech it does not: the VAD
/// opens a segment at the extraction start and runs it 20 s and more past
/// the target. Dropping that one, as the design first had it, lost a
/// 23.7 s segment — 20 s of speech after the target — in the first real
/// run (V3, BV16Ltu6wELb from 399.7 s). Kept, at most its first word,
/// before the target, is cut; and a run later filling the gap before it
/// replaces it whole at the join.
bool keepAtRunStart({
  required double start,
  required double duration,
  required double target,
  required double extractFrom,
  required bool clean,
}) {
  if (clean) return true;
  return start + duration > target;
}

/// What a finished join does to the transcript: removes the old segments
/// starting before [until] (whole), and puts [segments] — the new run's,
/// held back while the two overlapped — in their place.
typedef SeamCommit = ({double until, List<SeamSegment> segments});

/// A run running into text already known (design 4.3, end).
///
/// Built when the run's first segment reaching into the known stretch
/// arrives; from then on each of its segments is [offer]ed, and held back —
/// shown nowhere — until the join can be made.
class SeamJoin {
  SeamJoin(List<({double start, double duration})> old, {double? from})
    : _old = [...old]..sort((a, b) => a.start.compareTo(b.start)),
      _target = old.isEmpty ? 0 : _endOf(old.first),
      _from = from ?? (old.isEmpty ? 0 : old.first.start);

  /// Where the known stretch begins: how far into it the join has gone is
  /// measured from here.
  final double _from;

  /// The known stretch's segments, in time order.
  final List<({double start, double duration})> _old;

  /// The boundary the run must reach: at first where the known stretch's
  /// first segment ends.
  double _target;

  final _held = <SeamSegment>[];

  /// The new run's segments held back so far.
  List<SeamSegment> get held => List.unmodifiable(_held);

  static double _endOf(({double start, double duration}) s) =>
      s.start + s.duration;

  /// Takes the new run's next segment, and says whether the join is made.
  SeamCommit? offer(SeamSegment segment) {
    _held.add(segment);
    final end = segment.start + segment.duration;
    if (_old.isEmpty) return (until: end, segments: [..._held]);
    if (end < _target - seamTolerance) return null;
    // an old segment the new end falls inside: cutting there would drop
    // or repeat part of its text, so go on to where it ends
    final inside = _old
        .where(
          (o) =>
              o.start < end - seamTolerance && _endOf(o) > end + seamTolerance,
        )
        .firstOrNull;
    if (inside == null) return (until: end, segments: [..._held]);
    if (end - _from < seamMaxOverlap) {
      _target = _endOf(inside);
      return null;
    }
    // No shared boundary within reach: everything held goes in, and of the
    // old only what ends by the new text's end goes out (see [replaces]).
    // The old segment the new end falls inside stays whole — part of it is
    // then said twice, rather than dropped. (The first real run cut through
    // such a segment and lost 168 characters.)
    return (until: end, segments: [..._held]);
  }

  /// Whether an old segment goes when [commit] is made: every one that
  /// starts before the new text ends, as a whole — one starting within
  /// [seamTolerance] of that end is the next one, and stays — and, where
  /// no shared boundary was found, only if it also ends by then.
  static bool replaces(SeamCommit commit, double start, [double? end]) =>
      start < commit.until - seamTolerance &&
      (end == null || end <= commit.until + seamTolerance);
}
