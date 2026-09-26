/// LibrePili: where transcription should be working, decided from where the
/// viewer is (research/chunked-transcription-design-2026-09-25.md, 4.4 and
/// 12).
///
/// Transcription used to run once, from the first second to the last. Now
/// a session makes runs: one from wherever the viewer starts, a new one when
/// they jump somewhere nothing is known, and — so that ordinary viewing
/// never has a seam in it — the same run paused and resumed rather than
/// stopped when it is far enough ahead. Everything here is pure: the session
/// feeds it what it measured and does what it says.
library;

import 'dart:math' as math;

import 'package:PiliPlus/services/asr/transcript_store.dart';

/// How much the device lets transcription run ahead of the viewer.
enum AsrPower {
  /// A desktop, or a phone on its charger: run to the end, then fill the
  /// gaps. Nothing is saved by stopping early.
  unlimited,

  /// A phone on battery: only as far ahead as the viewer needs.
  battery,

  /// Battery saver on, or under 20 %: only enough not to run out.
  saver,
}

/// How far ahead the translation of a transcript runs (TranslationSession's
/// lead), in seconds. The transcript has to be further ahead still.
const asrTranslationLead = 120.0;

/// How far before the target a run starts extracting: the segment the VAD
/// finds first is cut short by the start, and has to lie before the target.
const asrPreRoll = 3.0;

/// A seek within this of where a playhead report expected the viewer to be
/// is ordinary playback, not a jump.
const asrSeekDebounce = Duration(milliseconds: 500);

/// When to pause a run and when to resume it, in seconds of transcript
/// ahead of the playhead.
typedef AsrLeadWindow = ({double low, double high, bool pauses});

/// Transcription speed `s` (seconds of media per second of wall clock) and
/// restart cost `c` (seconds from starting or resuming a run to its first
/// new segment), measured as the session goes.
class AsrPace {
  AsrPace({this.speed = 10, this.restartCost = 2});

  /// Media seconds per wall second, a moving average.
  double speed;

  /// Wall seconds from a start or resume to the first new segment.
  double restartCost;

  /// How many measurements each value rests on; the first replaces the
  /// guess outright.
  var speedSamples = 0;
  var costSamples = 0;

  double _media = 0;
  double _wall = 0;

  /// [media] seconds of audio recognised in [wall] seconds of running.
  ///
  /// Summed over two seconds of wall clock before it counts: progress comes
  /// in bursts — a second of audio read in milliseconds, then half a second
  /// decoding a segment with none — and averaging the bursts one by one
  /// measured 1.6x for a run going at 25x.
  void addProgress(double media, double wall) {
    if (wall < 0 || media < 0) return;
    _media += media;
    _wall += wall;
    if (_wall < 2) return;
    final value = _media / _wall;
    _media = 0;
    _wall = 0;
    speed = speedSamples == 0 ? value : speed * 0.8 + value * 0.2;
    speedSamples++;
  }

  void addRestart(double wall) {
    if (wall <= 0) return;
    restartCost = costSamples == 0 ? wall : restartCost * 0.7 + wall * 0.3;
    costSamples++;
  }
}

/// The lead window of design section 12, from what was measured.
///
/// `L_low = max(translation lead + 30 s, c·s + 30 s)`: resuming at this
/// much lead is back up to speed before the viewer — or the translation,
/// which runs 120 s ahead of them — catches up.
/// `L_high = L_low + max(120 s, 3·c·s)`: each resume then does a long
/// stretch, so its fixed cost is spread thin.
///
/// Where running on costs nothing — [AsrPower.unlimited] — or transcription
/// is barely faster than playback (`s < 1.1`, any pause risks running out),
/// it never pauses. Under [AsrPower.saver] the high mark sits just above the
/// low one: only enough not to run out, with 15 s between the two so that a
/// frontier moving a segment at a time does not flip it every second.
AsrLeadWindow asrLeadWindow({
  required double speed,
  required double restartCost,
  required AsrPower power,
}) {
  final cs = restartCost * speed;
  final low = math.max(asrTranslationLead + 30, cs + 30);
  if (power == AsrPower.unlimited || speed < 1.1) {
    return (low: low, high: double.infinity, pauses: false);
  }
  if (power == AsrPower.saver) return (low: low, high: low + 15, pauses: true);
  return (low: low, high: low + math.max(120, 3 * cs), pauses: true);
}

/// What the scheduler needs to know about the run in progress.
typedef AsrRunView = ({
  /// Where the run's own text starts.
  double start,

  /// How far it has settled: everything before is either text or silence.
  double frontier,
  bool paused,
});

/// What the session should do next.
sealed class AsrStep {
  const AsrStep();
}

/// Carry on as things are.
class AsrKeep extends AsrStep {
  const AsrKeep();
}

class AsrPause extends AsrStep {
  const AsrPause();
}

class AsrResume extends AsrStep {
  const AsrResume();
}

/// Stop the current run, if any, and start one at [at].
///
/// [adjacent]: [at] is where known text ends, not a place the viewer jumped
/// to; the run starts exactly there, with no pre-roll to drop.
class AsrStartAt extends AsrStep {
  const AsrStartAt(this.at, {this.adjacent = false, this.backfill = false});
  final double at;
  final bool adjacent;

  /// Filling a gap behind or away from the viewer, not serving them.
  final bool backfill;

  @override
  String toString() => 'AsrStartAt($at, adjacent: $adjacent)';
}

/// Nothing is left to do: the transcript covers the whole media.
class AsrComplete extends AsrStep {
  const AsrComplete();
}

/// How close to the media's end counts as reaching it: the last run's
/// settled frontier stops a little short of the audio's end.
const _endSlack = 1.0;

/// Small enough to be the same instant for transcript positions.
const _eps = 0.25;

/// Decides the next step (design 4.4, 12).
///
/// [covered] is the transcript's known stretches with the current run's
/// frontier in them. [duration] is the media's length, when known.
AsrStep decideAsrStep({
  required double playhead,
  required double? duration,
  required List<TimeSpan> covered,
  required AsrRunView? run,
  required AsrLeadWindow lead,
  required AsrPace pace,
}) {
  final p = playhead;
  if (duration != null && isCoveredWhole(covered, duration)) {
    return const AsrComplete();
  }
  final span = coveredSpanOf(covered, p);
  final isCovered = span.to > span.from && p < span.to - _eps;
  // how far ahead of its frontier a run gets to faster by carrying on than
  // a new run would by starting there
  final catchUp = (pace.restartCost + asrPreRoll) * pace.speed;

  if (!isCovered) {
    if (run != null &&
        run.start <= p + _eps &&
        p >= run.frontier - _eps &&
        p - run.frontier <= catchUp) {
      return run.paused ? const AsrResume() : const AsrKeep();
    }
    // the viewer is where nothing is known, and no run will be soon
    final atEnd = duration != null && p >= duration - _endSlack;
    if (atEnd) return _elsewhere(p, duration, covered, run, lead);
    return AsrStartAt(p);
  }

  final ahead = span.to - p;
  final reachesEnd = duration != null && span.to >= duration - _endSlack;
  // the run is the growing edge of the stretch the viewer is in: it starts
  // inside it — behind the viewer, or at the edge when it was started
  // there to extend it — and its frontier is where the stretch ends
  final serving =
      run != null &&
      run.start >= span.from - _eps &&
      run.start <= span.to + _eps &&
      (run.frontier - span.to).abs() <= _eps;
  if (serving) {
    if (run.paused) {
      return ahead < lead.low ? const AsrResume() : const AsrKeep();
    }
    if (lead.pauses && ahead >= lead.high) return const AsrPause();
    return const AsrKeep();
  }
  if (!reachesEnd && ahead < lead.low) {
    // running out and nobody is extending it: a run at its edge
    return AsrStartAt(span.to, adjacent: true);
  }
  if (!reachesEnd && !lead.pauses && run == null) {
    // unlimited: forward first, all the way to the end
    return AsrStartAt(span.to, adjacent: true);
  }
  return _elsewhere(p, duration, covered, run, lead);
}

/// The viewer needs nothing more right now: what to do with the run, and
/// whether to fill a gap.
AsrStep _elsewhere(
  double p,
  double? duration,
  List<TimeSpan> covered,
  AsrRunView? run,
  AsrLeadWindow lead,
) {
  if (lead.pauses) {
    // on battery nothing is done that the viewer does not need (section
    // 12: gaps are filled only where running on is allowed)
    if (run != null && !run.paused) return const AsrPause();
    return const AsrKeep();
  }
  // unlimited: a run working anywhere is doing something useful
  if (run != null) return run.paused ? const AsrResume() : const AsrKeep();
  final gap = nearestGap(covered, duration, p);
  if (gap == null) return const AsrKeep();
  return AsrStartAt(gap.from, adjacent: gap.from > 0, backfill: true);
}

/// Whether [covered] runs from the start of the media to its end.
bool isCoveredWhole(List<TimeSpan> covered, double duration) {
  if (covered.isEmpty) return false;
  final first = covered.first;
  return first.from <= _endSlack && first.to >= duration - _endSlack;
}

/// The stretches of [0, duration] not in [covered], shortest first dropped:
/// a gap under a second is the slack between two runs, not missing speech.
/// Without [duration], the gaps between stretches only.
List<TimeSpan> gapsIn(List<TimeSpan> covered, double? duration) {
  final gaps = <TimeSpan>[];
  var at = 0.0;
  for (final span in covered) {
    if (span.from - at > _endSlack) gaps.add((from: at, to: span.from));
    if (span.to > at) at = span.to;
  }
  if (duration != null && duration - at > _endSlack) {
    gaps.add((from: at, to: duration));
  }
  return gaps;
}

/// The gap nearest [p], by the distance from [p] to its nearest point.
TimeSpan? nearestGap(List<TimeSpan> covered, double? duration, double p) {
  TimeSpan? best;
  var bestDistance = double.infinity;
  for (final gap in gapsIn(covered, duration)) {
    final distance = p < gap.from
        ? gap.from - p
        : (p > gap.to ? p - gap.to : 0.0);
    if (distance < bestDistance) {
      best = gap;
      bestDistance = distance;
    }
  }
  return best;
}
