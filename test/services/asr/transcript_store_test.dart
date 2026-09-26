import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

AsrCue cue(double from, double to, String content) =>
    AsrCue(from: from, to: to, content: content);

void main() {
  group('TranscriptStore', () {
    test('one run from 0 reads as the old append-only lists', () {
      final store = TranscriptStore();
      var changes = 0;
      store.cues.listen((_) => changes++);
      final run = store.startRun(0);
      expect(store.covered, [(from: 0.0, to: 0.0)]);
      store
        ..addSegment(run, 0.5, 3, [cue(0.5, 2, 'a'), cue(2, 3.5, 'b')])
        // a silent stretch the VAD called speech: no cues, no change
        ..addSegment(run, 5, 1, const [])
        ..addSegment(run, 8, 2, [cue(8, 10.4, 'c')]);
      expect(store.cues.map((c) => c.content), ['a', 'b', 'c']);
      expect(store.segments.map((s) => (s.start, s.run)), [
        (0.5, 0),
        (5.0, 0),
        (8.0, 0),
      ]);
      expect(store.covered, [(from: 0.0, to: 10.0)]);
      expect(store.coveredEnd(4), 10);
      // past what is known: nothing ahead
      expect(store.coveredEnd(12), 12);
      return Future<void>.delayed(Duration.zero, () => expect(changes, 2));
    });

    test('text arriving in front of what is there goes in at its time', () {
      final store = TranscriptStore();
      var changes = 0;
      store.cues.listen((_) => changes++);
      final late = store.startRun(100);
      store.addSegment(late, 100, 5, [cue(100, 105, 'late')]);
      final early = store.startRun(0);
      store
        ..addSegment(early, 0, 5, [cue(0, 2, 'e1'), cue(2, 5, 'e2')])
        ..addSegment(early, 10, 5, [cue(10, 15, 'e3')]);
      final middle = store.startRun(50);
      store.addSegment(middle, 50, 5, [cue(50, 55, 'mid')]);

      expect(store.cues.map((c) => c.content), [
        'e1',
        'e2',
        'e3',
        'mid',
        'late',
      ]);
      expect(store.segments.map((s) => s.start), [0, 10, 50, 100]);
      expect(store.segments.map((s) => s.run), [
        early.id,
        early.id,
        middle.id,
        late.id,
      ]);
      expect(store.runs.map((r) => r.start), [0, 50, 100]);
      expect(store.covered, [
        (from: 0.0, to: 15.0),
        (from: 50.0, to: 55.0),
        (from: 100.0, to: 105.0),
      ]);
      expect(store.coveredEnd(12), 15);
      expect(store.coveredEnd(30), 30);
      expect(store.coveredEnd(100), 105);
      // one change per segment that brought cues, wherever it went
      return Future<void>.delayed(Duration.zero, () => expect(changes, 4));
    });

    test('runs that meet are one stretch', () {
      final store = TranscriptStore();
      final a = store.startRun(0);
      store.addSegment(a, 0, 50, [cue(0, 50, 'a')]);
      final b = store.startRun(40);
      store.addSegment(b, 52, 20, [cue(52, 72, 'b')]);
      expect(store.covered, [(from: 0.0, to: 72.0)]);
    });
  });

  group('PublishedReach', () {
    test('one stretch: where the last cue ends, wherever the playhead is', () {
      // the old `_asrPublishedTo = cues.last.to` and the translation
      // track's `_publishedEnd`, for every position
      final cues = [cue(0.5, 3, 'a'), cue(3, 9.5, 'b'), cue(12, 14.25, 'c')];
      final covered = [(from: 0.0, to: 14.0)];
      final reach = PublishedReach.of(cues, covered);
      for (final t in [0.0, 1.0, 10.0, 14.0, 60.0, 600.0]) {
        expect(reach.at(t), cues.last.to);
      }
      // no stretches (captions): the same
      expect(PublishedReach.of(cues).at(5), 14.25);
      expect(PublishedReach.none.at(5), -1);
      expect(PublishedReach.of(const [], covered).at(5), -1);
    });

    test('several stretches: the one the playhead is in, or last passed', () {
      final cues = [
        cue(0, 10, 'a'),
        cue(10, 29, 'b'),
        cue(200, 220, 'c'),
        cue(221, 240, 'd'),
      ];
      final covered = [(from: 0.0, to: 30.0), (from: 200.0, to: 240.0)];
      final reach = PublishedReach.of(cues, covered);
      expect(reach.at(5), 29);
      // in the gap the viewer is past the end of what is shown: it is
      // behind them, and new text there must be published
      expect(reach.at(100), 29);
      expect(reach.at(200), 240);
      expect(reach.at(500), 240);
    });
  });
}
