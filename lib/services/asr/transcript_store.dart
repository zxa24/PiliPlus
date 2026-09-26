/// LibrePili: a transcript kept by time, not by arrival.
///
/// Transcription used to run once, from the first second to the last, and
/// its result was a list only ever appended to. Starting from where the
/// viewer is (research/chunked-transcription-design-2026-09-25.md) makes
/// that false: a run started at 30:00 produces text that belongs after
/// what a run from 0 has not reached yet, and before what it will. So the
/// transcript is kept in time order whatever order it arrives in, with the
/// stretches that are known ([covered]) kept apart from the gaps between.
///
/// Each segment remembers the run that produced it: translation units are
/// cut within one run and never across two (design 4.6), so text a later
/// run puts in front of them does not change units already handed out.
///
/// A session with one run from 0 has one stretch, and everything here then
/// reads exactly as the old append-only lists did.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_seams.dart';
import 'package:get/get.dart';

/// A stretch of media time, in seconds.
typedef TimeSpan = ({double from, double to});

/// A stretch the VAD called speech, and the run it came from.
typedef TranscriptSegment = ({double start, double duration, int run});

/// One run's share of the transcript: its segments and cues, in the order
/// the recogniser produced them, which is time order within a run.
class TranscriptRun {
  TranscriptRun._(this.id, this.start);

  final int id;

  /// Where in the media the run started.
  final double start;

  final segments = <({double start, double duration})>[];
  final cues = <AsrCue>[];

  /// How many of [cues] each of [segments] brought: which cues go when a
  /// seam replaces a segment.
  final _cueCounts = <int>[];

  /// How far the run has recognised: the end of its last segment, or how
  /// far its audio is known to hold no more speech, or its start before
  /// either.
  double get end => _end;
  late double _end = start;

  /// Where its text starts: its start, or the start of a segment it kept
  /// from before it (the sentence under way where the viewer landed).
  double get from => segments.isEmpty || segments.first.start > start
      ? start
      : segments.first.start;

  /// No more segments are coming from this run: its newest one is settled.
  bool get finished => _finished;
  var _finished = false;

  void finish() => _finished = true;
}

class TranscriptStore {
  /// Every cue, sorted by start whatever run it came from.
  ///
  /// An RxList, as the old append-only list was: pages, the translation
  /// track and the self-test `listen` to it for "there is new text". It
  /// changes once per segment that brought cues, as before.
  final cues = <AsrCue>[].obs;

  final _segments = <TranscriptSegment>[];
  final _runs = <TranscriptRun>[];

  /// Every segment, sorted by start.
  List<TranscriptSegment> get segments => List.unmodifiable(_segments);

  /// The runs, sorted by where they started.
  List<TranscriptRun> get runs => List.unmodifiable(_runs);

  /// The stretches of media known, sorted and not overlapping: the runs'
  /// extents, merged where they meet.
  List<TimeSpan> get covered {
    final out = <TimeSpan>[];
    final runs = [..._runs]..sort((a, b) => a.from.compareTo(b.from));
    for (final run in runs) {
      if (out.isNotEmpty && run.from <= out.last.to) {
        final last = out.removeLast();
        out.add((from: last.from, to: run.end > last.to ? run.end : last.to));
      } else {
        out.add((from: run.from, to: run.end));
      }
    }
    return out;
  }

  /// Where the known stretch that [t] lies in ends; [t] itself when it lies
  /// in none.
  double coveredEnd(double t) => coveredEndOf(covered, t);

  /// Begins a run from [start] and returns it; segments are added to it
  /// with [addSegment].
  TranscriptRun startRun(double start) {
    final run = TranscriptRun._(_runs.length, start);
    var at = _runs.length;
    while (at > 0 && _runs[at - 1].start > start) {
      at--;
    }
    _runs.insert(at, run);
    return run;
  }

  /// A segment [run] recognised, with the cues it produced.
  ///
  /// Both go in at their place in time. Together, in one call: translation
  /// builds its units from both, and must never see one ahead of the other.
  void addSegment(
    TranscriptRun run,
    double start,
    double duration,
    List<AsrCue> segmentCues,
  ) {
    final segment = (start: start, duration: duration, run: run.id);
    run.segments.add((start: start, duration: duration));
    run.cues.addAll(segmentCues);
    run._cueCounts.add(segmentCues.length);
    final end = start + duration;
    if (end > run._end) run._end = end;
    // a cue starts inside its segment; never let one lie past the known end
    for (final cue in segmentCues) {
      if (cue.from > run._end) run._end = cue.from;
    }
    _segments.insert(_insertAt(_segments, start, (s) => s.start), segment);
    if (segmentCues.isEmpty) return;
    // A segment's cues are one run of starts, and the segments of all runs
    // do not overlap: they go in together at one place, after anything
    // starting at the same moment (so a single run reads as appended).
    final at = _insertAt(cues, segmentCues.first.from, (c) => c.from);
    if (at == cues.length) {
      cues.addAll(segmentCues);
    } else {
      cues.insertAll(at, segmentCues);
    }
  }

  /// [run] has got to [to] with no more speech before it: its stretch
  /// reaches there even where that is silence after its last segment.
  void advance(TranscriptRun run, double to) {
    if (to > run._end) run._end = to;
  }

  /// A seam (design 4.3): the segments [removes] picks — of any run, whole,
  /// with their cues — are taken out, and [segments] go into [run] in their
  /// place. One change to [cues] for all of it.
  void replace(
    TranscriptRun run,
    List<SeamSegment> segments,
    bool Function(TranscriptSegment segment) removes,
  ) {
    for (final other in _runs) {
      var cueAt = 0;
      for (var i = 0; i < other.segments.length;) {
        final s = other.segments[i];
        final count = other._cueCounts[i];
        if (removes((start: s.start, duration: s.duration, run: other.id))) {
          other.segments.removeAt(i);
          other._cueCounts.removeAt(i);
          other.cues.removeRange(cueAt, cueAt + count);
        } else {
          cueAt += count;
          i++;
        }
      }
    }
    for (final segment in segments) {
      run.segments.add((start: segment.start, duration: segment.duration));
      run.cues.addAll(segment.cues);
      run._cueCounts.add(segment.cues.length);
      advance(run, segment.start + segment.duration);
    }
    _segments
      ..clear()
      ..addAll([
        for (final other in _runs)
          for (final s in other.segments)
            (start: s.start, duration: s.duration, run: other.id),
      ]);
    mergeSortBy(_segments, (s) => s.start);
    final all = [for (final other in _runs) ...other.cues];
    mergeSortBy(all, (c) => c.from);
    // one change, not two: assignAll clears and adds, each a change
    cues.value = all;
  }

  /// A stable sort by [key]: equal keys keep their order.
  static void mergeSortBy<T>(List<T> list, double Function(T) key) {
    if (list.length < 2) return;
    final sorted =
        [
          for (var i = 0; i < list.length; i++) (i, list[i]),
        ]..sort((a, b) {
          final by = key(a.$2).compareTo(key(b.$2));
          return by != 0 ? by : a.$1.compareTo(b.$1);
        });
    for (var i = 0; i < list.length; i++) {
      list[i] = sorted[i].$2;
    }
  }

  /// The index after the last item of [list] whose key is at most [key].
  static int _insertAt<T>(List<T> list, double key, double Function(T) of) {
    var lo = 0;
    var hi = list.length;
    // the common case, a single run: straight to the end
    if (hi == 0 || of(list[hi - 1]) <= key) return hi;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (of(list[mid]) <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// [TranscriptStore.coveredEnd] for a list of stretches.
double coveredEndOf(List<TimeSpan> covered, double t) =>
    coveredSpanOf(covered, t).to;

/// The stretch of [covered] that [t] lies in; `(t, t)` when none.
TimeSpan coveredSpanOf(List<TimeSpan> covered, double t) {
  for (final span in covered) {
    if (span.from > t) break;
    if (t <= span.to) return span;
  }
  return (from: t, to: t);
}

/// How far a track handed to the player reaches, stretch by stretch.
///
/// Publishing decides whether a rebuilt track is worth a reload by how far
/// the one on screen reaches past the playhead. With one stretch that was
/// where its last cue ends; with several it is where the last cue of the
/// stretch the playhead is in — or last passed — ends: the viewer runs out
/// of subtitle there, whatever lies further on (design 4.7).
class PublishedReach {
  const PublishedReach._(this._spans);

  /// Nothing handed over yet.
  static const none = PublishedReach._([]);

  /// For each stretch, from its start: where the last of its cues ends.
  final List<TimeSpan> _spans;

  /// What [cues] (in time order) reach within [covered]. A cue belongs to
  /// the last stretch starting at or before it — the first stretch takes
  /// anything before it too. Without [covered] (captions, all known up
  /// front) everything is one stretch.
  factory PublishedReach.of(List<AsrCue> cues, [List<TimeSpan>? covered]) {
    final stretches = covered == null || covered.isEmpty
        ? const <TimeSpan>[(from: double.negativeInfinity, to: double.infinity)]
        : covered;
    final spans = <TimeSpan>[];
    var s = 0;
    double? last;
    for (final cue in cues) {
      while (s + 1 < stretches.length && cue.from >= stretches[s + 1].from) {
        if (last != null) spans.add((from: _start(stretches, s), to: last));
        last = null;
        s++;
      }
      last = cue.to;
    }
    if (last != null) spans.add((from: _start(stretches, s), to: last));
    return PublishedReach._(spans);
  }

  static double _start(List<TimeSpan> stretches, int s) =>
      s == 0 ? double.negativeInfinity : stretches[s].from;

  /// Where the track reaches from [t]: the end of the last stretch starting
  /// at or before it. -1 when there is none, as with nothing published.
  double at(double t) {
    var end = -1.0;
    for (final span in _spans) {
      if (span.from > t) break;
      end = span.to;
    }
    return end;
  }
}
