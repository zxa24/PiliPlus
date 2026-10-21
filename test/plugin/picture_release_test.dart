import 'package:PiliPlus/plugin/pl_player/picture_release.dart';
import 'package:flutter_test/flutter_test.dart';

/// When the picture held over a reopen goes. On the phone (mediacodec) mpv
/// gave no picture type and the picture never went (Pixel 4 XL, 2026-10-21:
/// a still frame for 55 s over the sound); on Windows it went 0.05-0.09 s
/// after the new frames, and must not go earlier than that.
void main() {
  final t0 = DateTime(2026, 10, 21, 12);

  /// Ticks every 50 ms from [t0] until a verdict or [limit]; [at] gives the
  /// signals at a time (ms since t0), the new file loaded from [loadedFrom]
  /// (from the start without), playing from [playingFrom] (all along
  /// without). The verdict and when.
  (PictureLetGo?, int) run(
    PictureReleaseWatch w,
    ({bool frame, bool sized, bool decoded, double position}) Function(int ms)
    at, {
    int limit = 20000,
    int? loadedFrom,
    int? playingFrom,
  }) {
    for (var ms = 0; ms <= limit; ms += 50) {
      final s = at(ms);
      final why = w.tick(
        now: t0.add(Duration(milliseconds: ms)),
        frame: s.frame,
        sized: s.sized,
        decoded: s.decoded,
        position: s.position,
        loaded: loadedFrom == null || ms >= loadedFrom,
        playing: playingFrom == null || ms >= playingFrom,
      );
      if (why != null) return (why, ms);
    }
    return (null, limit);
  }

  test('Windows, a reopen: the old frame info reads, a gap, the new frames '
      '— let go 100 ms after the frame, as before', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (
        // stale until 100 ms, blank until 400 ms, the new frames from then
        frame: ms < 100 || ms >= 400,
        sized: true,
        decoded: ms < 100 || ms >= 380,
        // playing on from 120 s once the frames are there
        position: ms < 400 ? 120.0 : 120 + (ms - 400) / 1000,
      ),
    );
    expect(why, PictureLetGo.frame);
    expect(ms, 500);
  });

  test('the old frame info reading all along: not before 2 s', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (frame: true, sized: true, decoded: true, position: 30.0),
    );
    expect(why, PictureLetGo.frame);
    expect(ms, 2100);
  });

  test('the phone: no frame info ever, decoded and playing — let go by the '
      'playhead after a second of playing', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (
        frame: false,
        sized: true,
        decoded: ms >= 600,
        // the open emits 0, jumps to where it opened, then plays from 700 ms
        position: ms < 300 ? 0.0 : (ms < 700 ? 15.0 : 15 + (ms - 700) / 1000),
      ),
    );
    expect(why, PictureLetGo.playhead);
    expect(ms, 1700);
    expect(w.played, closeTo(1.0, 0.001));
  });

  test('the phone, a handover: the second player plays at once', () {
    final w = PictureReleaseWatch(opened: false, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (
        frame: false,
        sized: true,
        decoded: true,
        position: 200 + ms / 1000,
      ),
    );
    expect(why, PictureLetGo.playhead);
    expect(ms, 1000);
  });

  test('the frame first whenever there is one: the playhead never earlier', () {
    for (final opened in [true, false]) {
      final w = PictureReleaseWatch(opened: opened, start: t0);
      final (why, ms) = run(
        w,
        (ms) => (
          frame: ms >= 200,
          sized: true,
          decoded: ms >= 150,
          position: 10 + ms / 1000,
        ),
      );
      expect(why, PictureLetGo.frame, reason: 'opened: $opened');
      expect(ms, 300, reason: 'opened: $opened');
    }
  });

  test('playing with nothing decoded (a video track that broke off): the '
      'deadline, 3 s after the playhead began to move', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (
        frame: false,
        sized: true,
        decoded: false,
        position: ms < 500 ? 40.0 : 40 + (ms - 500) / 1000,
      ),
    );
    expect(why, PictureLetGo.deadline);
    // the first step is seen at 550 ms
    expect(ms, 3550);
  });

  test('a seek or the open jumping the playhead is not playing', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, _) = run(
      w,
      // jumps of 10 s every tick, decoded, no frame, paused otherwise
      (ms) => (
        frame: false,
        sized: true,
        decoded: false,
        position: ms / 5.0,
      ),
      limit: 10000,
    );
    expect(why, isNull);
    expect(w.played, 0);
  });

  test('paused: held whatever the signals say, until play', () {
    final w = PictureReleaseWatch(opened: true, start: t0);
    final (why, _) = run(
      w,
      // the frame info, the size and the video params all there
      (ms) => (frame: true, sized: true, decoded: true, position: 75.0),
      playingFrom: 1 << 30,
      limit: 60000,
    );
    expect(why, isNull);
  });

  test(
    'nothing decoded, paused: held (the network wait shows the picture)',
    () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, _) = run(
        w,
        (ms) => (frame: false, sized: true, decoded: false, position: 75.0),
        limit: 60000,
      );
      expect(why, isNull);
    },
  );

  test('a frame up but the page has no area for it: not by the frame', () {
    final w = PictureReleaseWatch(opened: false, start: t0);
    final (why, ms) = run(
      w,
      (ms) => (frame: true, sized: false, decoded: true, position: 50.0),
      limit: 5000,
    );
    // and nothing plays
    expect(why, isNull);
    expect(ms, 5000);
  });

  group('only the new file counts (review 2026-10-21)', () {
    test("the previous file's playhead read right after the open is not "
        'playing: from where the new file stood once loaded', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, ms) = run(
        w,
        // moving all along, the video params of the file before reading
        (ms) => (
          frame: false,
          sized: true,
          decoded: true,
          position: 100 + ms / 1000,
        ),
        loadedFrom: 1500,
      );
      expect(why, PictureLetGo.playhead);
      // a second of playing from 1.5 s, not from the open
      expect(ms, 2500);
    });

    test('the old frame info still readable right after the open, the old '
        'playhead moving: the frame, after the 2 s, not the playhead', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, ms) = run(
        w,
        (ms) => (
          frame: true,
          sized: true,
          decoded: true,
          position: 100 + ms / 1000,
        ),
        loadedFrom: 1500,
      );
      expect(why, PictureLetGo.frame);
      expect(ms, 2100);
    });

    test('the deadline counts from the first step once loaded', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, ms) = run(
        w,
        (ms) => (
          frame: false,
          sized: true,
          decoded: false,
          position: 100 + ms / 1000,
        ),
        loadedFrom: 2000,
      );
      expect(why, PictureLetGo.deadline);
      expect(ms, 5050);
    });

    test('never loaded: held, whatever the playhead does', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, _) = run(
        w,
        (ms) => (
          frame: false,
          sized: true,
          decoded: true,
          position: 100 + ms / 1000,
        ),
        loadedFrom: 1 << 30,
        limit: 15000,
      );
      expect(why, isNull);
      expect(w.played, 0);
    });
  });

  group('a paused reopen (self-test 2026-10-21)', () {
    // Windows, a quality switch while paused: mpv says a frame is up from
    // 1100 ms (picture type "B"), sized and decoded, and the texture stays
    // black until play; played from 5 s
    ({bool frame, bool sized, bool decoded, double position}) paused(
      int ms,
    ) => (
      frame: ms >= 1100,
      sized: ms >= 1100,
      decoded: ms >= 900,
      position: ms < 5000 ? 42.0 : 42 + (ms - 5000) / 1000,
    );

    test('held while paused, then the frame once it plays', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      expect(
        run(w, paused, loadedFrom: 600, playingFrom: 5000),
        (PictureLetGo.frame, 5100),
      );
    });

    test('the frame first when it comes while playing', () {
      final w = PictureReleaseWatch(opened: true, start: t0);
      final (why, ms) = run(
        w,
        (ms) => (
          frame: ms >= 300,
          sized: true,
          decoded: ms >= 300,
          position: 10 + ms / 1000,
        ),
      );
      expect(why, PictureLetGo.frame);
      expect(ms, 400);
    });
  });
}
