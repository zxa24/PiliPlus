/// Where one run's text meets another's, with synthetic segments
/// (research/chunked-transcription-design-2026-09-25.md, 4.3).
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_seams.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

AsrCue cue(double from, double to, String content) =>
    AsrCue(from: from, to: to, content: content);

SeamSegment seg(double start, double end, String text) =>
    (start: start, duration: end - start, cues: [cue(start, end, text)]);

void main() {
  group('start of a run', () {
    bool keep(double start, double end, {bool clean = false}) => keepAtRunStart(
      start: start,
      duration: end - start,
      target: 100,
      extractFrom: 97,
      clean: clean,
    );

    test('the segment the extraction start cut short is dropped', () {
      expect(keep(97, 99.5), isFalse);
    });

    test('unless it runs past the target: continuous speech', () {
      // dropping it lost 20 s of speech after the target (V3)
      expect(keep(97.2, 120.9), isTrue);
    });

    test('the sentence under way at the target is kept', () {
      // began in the pre-roll, after the cut, and runs past the target
      expect(keep(98.5, 104), isTrue);
      expect(keep(100.5, 103), isTrue);
    });

    test('whole segments before the target are not the run\'s', () {
      expect(keep(97.8, 99.9), isFalse);
    });

    test('a clean start keeps everything', () {
      expect(keep(97, 99, clean: true), isTrue);
    });
  });

  group('join into known text', () {
    test('ends where the new run completes the known first segment', () {
      // known: [200,206] [207,215] [216,222]
      final join = SeamJoin(const [
        (start: 200, duration: 6),
        (start: 207, duration: 8),
        (start: 216, duration: 6),
      ]);
      // the new run cuts the same audio differently
      expect(join.offer(seg(198, 203, 'a')), isNull);
      final commit = join.offer(seg(203.2, 206.1, 'b'));
      expect(commit, isNotNull);
      expect(commit!.until, closeTo(206.1, 1e-9));
      expect(commit.segments.map((s) => s.cues.single.content), ['a', 'b']);
      expect(SeamJoin.replaces(commit, 200), isTrue);
      // the next known segment starts after: it stays
      expect(SeamJoin.replaces(commit, 207), isFalse);
    });

    test('never cuts inside a known segment: goes on to where it ends', () {
      final join = SeamJoin(const [
        (start: 200, duration: 4),
        (start: 205, duration: 15),
        (start: 221, duration: 5),
      ]);
      // ends past the first known segment, but inside the second
      expect(join.offer(seg(199, 210, 'a')), isNull);
      // and now where the second ends
      final commit = join.offer(seg(210.5, 220.2, 'b'));
      expect(commit, isNotNull);
      expect(SeamJoin.replaces(commit!, 205), isTrue);
      expect(SeamJoin.replaces(commit, 221), isFalse);
    });

    test('a known segment starting right at the new end is the next one', () {
      final join = SeamJoin(const [
        (start: 200, duration: 5),
        (start: 205.1, duration: 5),
      ]);
      final commit = join.offer(seg(199, 205.2, 'a'))!;
      expect(SeamJoin.replaces(commit, 200), isTrue);
      expect(SeamJoin.replaces(commit, 205.1), isFalse);
    });

    test('no shared boundary within reach: the old segment the new end '
        'falls inside stays whole', () {
      // the known run and the new one never share a boundary
      final old = [
        for (var s = 200.0; s < 400; s += 20) (start: s, duration: 20.0),
      ];
      final join = SeamJoin(old, from: 200);
      SeamCommit? commit;
      for (var s = 190.0; commit == null && s < 400; s += 20) {
        commit = join.offer(seg(s, s + 20, 'x'));
      }
      expect(commit, isNotNull);
      final until = commit!.until;
      expect(until - 200, lessThanOrEqualTo(seamMaxOverlap + 20));
      // no old text past the new text's end is dropped: an old segment
      // goes only if it ends by then
      var kept = 0;
      for (final o in old) {
        final goes = SeamJoin.replaces(commit, o.start, o.start + o.duration);
        if (goes) {
          expect(o.start + o.duration, lessThanOrEqualTo(until + 0.3));
        } else if (o.start < until) {
          kept++;
        }
      }
      // the one the new end falls inside stays
      expect(kept, 1);
    });
  });

  group('TranscriptStore.replace', () {
    test('old segments go whole with their cues, the new take their place', () {
      final store = TranscriptStore();
      final later = store.startRun(200);
      store
        ..addSegment(later, 200, 6, [cue(200, 203, 'o1'), cue(203, 206, 'o2')])
        ..addSegment(later, 207, 8, [cue(207, 215, 'o3')]);
      final early = store.startRun(100);
      store.addSegment(early, 190, 5, [cue(190, 195, 'e1')]);
      var changes = 0;
      store.cues.listen((_) => changes++);

      store.replace(
        early,
        [seg(198, 203, 'n1'), seg(203.2, 206.1, 'n2')],
        (s) => s.run == later.id && s.start < 206.1 - seamTolerance,
      );
      expect(store.cues.map((c) => c.content), ['e1', 'n1', 'n2', 'o3']);
      expect(store.segments.map((s) => (s.start, s.run)), [
        (190.0, early.id),
        (198.0, early.id),
        (203.2, early.id),
        (207.0, later.id),
      ]);
      expect(later.cues.map((c) => c.content), ['o3']);
      // one stretch now: the early run reaches where the later one goes on
      expect(store.covered, [(from: 100.0, to: 215.0)]);
      return Future<void>.delayed(Duration.zero, () => expect(changes, 1));
    });

    test('a run keeps a sentence it began before its target', () {
      final store = TranscriptStore();
      final run = store.startRun(100);
      store.addSegment(run, 98.5, 4, [cue(98.5, 102.5, 'kept')]);
      expect(store.covered, [(from: 98.5, to: 102.5)]);
      store.advance(run, 130);
      expect(store.covered, [(from: 98.5, to: 130.0)]);
      // never backwards
      store.advance(run, 110);
      expect(store.coveredEnd(100), 130);
    });
  });
}
