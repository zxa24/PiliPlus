// LibrePili: the timing arithmetic of joining MP4 segments with their own
// leading edits (lib/utils/mp4_join.dart, user 2026-10-19 D9 A). The joins
// of real files are in flv_demux_test.dart.
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('played end', () {
    test('without an edit: the decode end, as before', () {
      expect(
        Mp4Remuxer.debugJoinPlayedEnd(
          lead: 0,
          mediaTime: 0,
          mediaEnd: 120,
          firstOffset: 80,
          timescale: 1000,
        ),
        0.120,
      );
    });

    test('AAC priming does not play', () {
      expect(
        Mp4Remuxer.debugJoinPlayedEnd(
          lead: 0,
          mediaTime: 2112,
          mediaEnd: 44100 + 2112,
          firstOffset: 0,
          timescale: 44100,
        ),
        1.0,
      );
    });

    test('a B-frame delay edit skips nothing of the end', () {
      expect(
        Mp4Remuxer.debugJoinPlayedEnd(
          lead: 0.5,
          mediaTime: 80,
          mediaEnd: 1000,
          firstOffset: 80,
          timescale: 1000,
        ),
        1.5,
      );
    });
  });

  group('placing a later segment', () {
    test('same edits as the first: at the join', () {
      // joined edit from 2112 (priming); the segment's own the same
      expect(
        Mp4Remuxer.debugJoinPlaceAt(
          start: 1.0,
          lead: 0,
          mediaTime: 2112,
          ownLead: 0,
          ownMediaTime: 2112,
          timescale: 44100,
        ),
        44100,
      );
    });

    test('its own empty edit: that much later', () {
      expect(
        Mp4Remuxer.debugJoinPlaceAt(
          start: 1.0,
          lead: 0,
          mediaTime: 0,
          ownLead: 0.04,
          ownMediaTime: 0,
          timescale: 1000,
        ),
        1040,
      );
    });

    test('its own priming, under a joined edit without it', () {
      // its time 1024 must sit where the joined edit plays 1.0 s
      final at = Mp4Remuxer.debugJoinPlaceAt(
        start: 1.0,
        lead: 0,
        mediaTime: 0,
        ownLead: 0,
        ownMediaTime: 1024,
        timescale: 48000,
      );
      expect(at + 1024, 48000);
    });
  });

  group('fitting a segment on', () {
    const aac = [1024, 1024, 1024, 1024];
    const allSync = [true, true, true, true];

    test('no edit, starting at the end: nothing changes', () {
      expect(
        Mp4Remuxer.debugJoinFit(
          offset: 0,
          mediaTime: 0,
          durations: aac,
          syncs: allSync,
          lastDuration: 1024,
        ),
        (drop: 0, extend: 0, shorten: 0),
      );
    });

    test('a gap is added to the previous sample', () {
      expect(
        Mp4Remuxer.debugJoinFit(
          offset: 300,
          mediaTime: 0,
          durations: aac,
          syncs: allSync,
          lastDuration: 1024,
        ),
        (drop: 0, extend: 300, shorten: 0),
      );
    });

    test('priming: the frames wholly before it go, the rest is taken off', () {
      // 2112 samples of priming placed so that 2112 plays at the end
      final fit = Mp4Remuxer.debugJoinFit(
        offset: -2112,
        mediaTime: 2112,
        durations: aac,
        syncs: allSync,
        lastDuration: 1024,
      );
      expect(fit, (drop: 2, extend: 0, shorten: 64));
      // the first frame kept starts 64 samples before the end, where its
      // 64 samples of priming end at it
    });

    test('a video is never cut before its next key frame', () {
      final fit = Mp4Remuxer.debugJoinFit(
        offset: -80,
        mediaTime: 80,
        durations: const [40, 40, 40],
        syncs: const [true, false, false],
        lastDuration: 40,
      );
      expect(fit.drop, 0);
      // taken off the previous frame, which keeps at least 1
      expect(fit.shorten, 39);
    });

    test('at least one sample stays', () {
      final fit = Mp4Remuxer.debugJoinFit(
        offset: -5000,
        mediaTime: 5000,
        durations: const [1024, 1024],
        syncs: const [true, true],
        lastDuration: 1024,
      );
      expect(fit.drop, 1);
    });
  });
}
