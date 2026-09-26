/// Where transcription works, decided from where the viewer is
/// (research/chunked-transcription-design-2026-09-25.md, 4.4 and 12).
library;

import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lead window (section 12)', () {
    test('battery: the water marks from the measured speed and cost', () {
      // c·s = 30 s: the translation's lead decides the low mark
      final slow = asrLeadWindow(
        speed: 15,
        restartCost: 2,
        power: AsrPower.battery,
      );
      expect(slow.low, 150);
      expect(slow.high, 150 + 120);
      expect(slow.pauses, isTrue);
      // c·s = 200 s: restarting is what decides
      final costly = asrLeadWindow(
        speed: 25,
        restartCost: 8,
        power: AsrPower.battery,
      );
      expect(costly.low, 230);
      expect(costly.high, 230 + 600);
    });

    test('a desktop or a charger never pauses', () {
      final lead = asrLeadWindow(
        speed: 25,
        restartCost: 2,
        power: AsrPower.unlimited,
      );
      expect(lead.pauses, isFalse);
      expect(lead.high, double.infinity);
    });

    test('barely faster than playback never pauses, even on battery', () {
      final lead = asrLeadWindow(
        speed: 1.05,
        restartCost: 2,
        power: AsrPower.battery,
      );
      expect(lead.pauses, isFalse);
    });

    test('battery saver keeps only enough not to run out', () {
      final lead = asrLeadWindow(
        speed: 15,
        restartCost: 2,
        power: AsrPower.saver,
      );
      expect(lead.low, 150);
      expect(lead.high - lead.low, lessThanOrEqualTo(15));
      expect(lead.pauses, isTrue);
    });

    test('the pace is measured: the first value replaces the guess', () {
      // bursts: a second of audio in 10 ms, then a segment's decode
      final pace = AsrPace();
      for (var i = 0; i < 4; i++) {
        pace
          ..addProgress(10, 0.01)
          ..addProgress(0, 0.49);
      }
      // two seconds of wall clock: 40 s of audio, 20x — not the average of
      // the bursts
      expect(pace.speedSamples, 1);
      expect(pace.speed, closeTo(20, 1e-9));
      pace.addProgress(20, 2);
      expect(pace.speed, closeTo(18, 1e-9));
      pace.addRestart(1.5);
      expect(pace.restartCost, 1.5);
      // under two seconds says nothing yet
      pace.addProgress(5, 0.1);
      expect(pace.speedSamples, 2);
    });
  });

  group('decideAsrStep', () {
    final pace = AsrPace(speed: 20, restartCost: 2);
    final battery = asrLeadWindow(
      speed: 20,
      restartCost: 2,
      power: AsrPower.battery,
    );
    final unlimited = asrLeadWindow(
      speed: 20,
      restartCost: 2,
      power: AsrPower.unlimited,
    );

    AsrStep decide({
      required double p,
      required List<TimeSpan> covered,
      AsrRunView? run,
      AsrLeadWindow? lead,
      double? duration = 3600,
    }) => decideAsrStep(
      playhead: p,
      duration: duration,
      covered: covered,
      run: run,
      lead: lead ?? battery,
      pace: pace,
    );

    test('nothing yet: a run where the viewer is', () {
      final step = decide(p: 0, covered: const []);
      expect(step, isA<AsrStartAt>());
      expect((step as AsrStartAt).at, 0);
    });

    test('a seek far ahead of the run stops it for one at the playhead', () {
      final step = decide(
        p: 1800,
        covered: const [(from: 0, to: 200)],
        run: (start: 0, frontier: 200, paused: false),
      );
      expect(step, isA<AsrStartAt>());
      expect((step as AsrStartAt).at, 1800);
      expect(step.adjacent, isFalse);
    });

    test('a seek just past the frontier lets the run carry on there', () {
      // (c + pre-roll) · s = 100 s: running on is quicker
      final step = decide(
        p: 280,
        covered: const [(from: 0, to: 200)],
        run: (start: 0, frontier: 200, paused: false),
      );
      expect(step, isA<AsrKeep>());
      // paused there: resumed rather than replaced
      final paused = decide(
        p: 280,
        covered: const [(from: 0, to: 200)],
        run: (start: 0, frontier: 200, paused: true),
      );
      expect(paused, isA<AsrResume>());
    });

    test('a seek back into known text starts nothing', () {
      final step = decide(
        p: 60,
        covered: const [(from: 0, to: 500), (from: 1800, to: 2100)],
        run: (start: 1800, frontier: 2100, paused: false),
        lead: unlimited,
      );
      expect(step, isA<AsrKeep>());
    });

    test('battery: pauses at the high mark, not before', () {
      const run = (start: 0.0, frontier: 400.0, paused: false);
      expect(
        decide(p: 200, covered: const [(from: 0, to: 400)], run: run),
        isA<AsrKeep>(),
      );
      // 270 s ahead: the high mark
      expect(
        decide(
          p: 130,
          covered: const [(from: 0, to: 400)],
          run: run,
        ),
        isA<AsrPause>(),
      );
    });

    test('battery: resumes at the low mark, the same run', () {
      const run = (start: 0.0, frontier: 400.0, paused: true);
      // 200 s ahead: above the low mark, stays paused
      expect(
        decide(p: 200, covered: const [(from: 0, to: 400)], run: run),
        isA<AsrKeep>(),
      );
      // 149 s ahead: below it
      expect(
        decide(p: 251, covered: const [(from: 0, to: 400)], run: run),
        isA<AsrResume>(),
      );
    });

    test('sequential viewing on battery never makes a new run', () {
      // the viewer plays on, the run pauses and resumes: a seam would be a
      // start
      var frontier = 0.0;
      var paused = false;
      var starts = 0;
      for (var p = 0.0; p < 3000; p += 5) {
        final step = decide(
          p: p,
          covered: [(from: 0, to: frontier)],
          run: (start: 0, frontier: frontier, paused: paused),
        );
        switch (step) {
          case AsrPause():
            paused = true;
          case AsrResume():
            paused = false;
          case AsrStartAt():
            starts++;
          case _:
        }
        // 20x realtime while running
        if (!paused) frontier += 100;
      }
      expect(starts, 0);
    });

    test('unlimited: never pauses, runs to the end', () {
      expect(
        decide(
          p: 10,
          covered: const [(from: 0, to: 3000)],
          run: (start: 0, frontier: 3000, paused: false),
          lead: unlimited,
        ),
        isA<AsrKeep>(),
      );
    });

    test('unlimited: after the end, the gap nearest the viewer', () {
      final step = decide(
        p: 1900,
        covered: const [
          (from: 0, to: 300),
          (from: 1000, to: 1200),
          (from: 1800, to: 3600),
        ],
        lead: unlimited,
      );
      expect(step, isA<AsrStartAt>());
      // 1200..1800 ends 100 s before the viewer; 300..1000 is further
      expect((step as AsrStartAt).at, 1200);
      expect(step.adjacent, isTrue);
      expect(step.backfill, isTrue);
    });

    test('battery: gaps are not filled, a stray run pauses', () {
      expect(
        decide(
          p: 1900,
          covered: const [(from: 0, to: 300), (from: 1800, to: 2400)],
          run: (start: 0, frontier: 300, paused: false),
        ),
        isA<AsrPause>(),
      );
      expect(
        decide(
          p: 1900,
          covered: const [(from: 0, to: 300), (from: 1800, to: 2400)],
        ),
        isA<AsrKeep>(),
      );
    });

    test('a run started at the edge of the viewer stretch serves it', () {
      // the viewer is back at 60 in 0..75; a run was started at 75 to
      // extend it: that run is kept, not started again
      expect(
        decide(
          p: 60,
          covered: const [(from: 0, to: 75.3)],
          run: (start: 75, frontier: 75.3, paused: false),
        ),
        isA<AsrKeep>(),
      );
    });

    test('running out with nobody extending: a run at the edge', () {
      final step = decide(
        p: 100,
        covered: const [(from: 0, to: 200)],
      );
      expect(step, isA<AsrStartAt>());
      expect((step as AsrStartAt).at, 200);
      expect(step.adjacent, isTrue);
    });

    test('covered from start to end: complete', () {
      expect(
        decide(
          p: 100,
          covered: const [(from: 0, to: 3599.5)],
          duration: 3600,
        ),
        isA<AsrComplete>(),
      );
    });
  });

  test('gaps and the nearest one', () {
    const covered = [(from: 0.0, to: 100.0), (from: 500.0, to: 600.0)];
    expect(gapsIn(covered, 1000), [
      (from: 100.0, to: 500.0),
      (from: 600.0, to: 1000.0),
    ]);
    // slack between two runs is not a gap
    expect(gapsIn(const [(from: 0, to: 100), (from: 100.5, to: 200)], 200), []);
    expect(nearestGap(covered, 1000, 580), (from: 600.0, to: 1000.0));
    expect(nearestGap(covered, 1000, 520), (from: 100.0, to: 500.0));
    expect(isCoveredWhole(const [(from: 0.5, to: 999.2)], 1000), isTrue);
    expect(isCoveredWhole(covered, 1000), isFalse);
  });
}
