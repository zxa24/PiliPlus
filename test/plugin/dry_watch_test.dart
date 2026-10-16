import 'package:PiliPlus/plugin/pl_player/dry_watch.dart';
import 'package:flutter_test/flutter_test.dart';

/// A track gone dry (the playhead running past what arrived) against an
/// open or a seek still waiting for its bytes (the playhead standing still).
void main() {
  List<DryVerdict> run(
    DryWatch w,
    List<(double, double)> ticks, {
    double duration = 894,
  }) => [
    for (final (pos, cache) in ticks)
      w.tick(position: pos, cacheEnd: cache, duration: duration),
  ];

  test('the playhead running past the cache is a dry track, on the second '
      'tick', () {
    final w = DryWatch();
    expect(run(w, [(10, 18), (11, 18), (19.5, 18), (20.5, 18)]), [
      DryVerdict.fine,
      DryVerdict.fine,
      DryVerdict.fine,
      DryVerdict.dry,
    ]);
  });

  test('2026-10-16: standing at the resume point while the cache fills is '
      'a load on its way', () {
    // BV1ea4y1J7d1 at 149 s: the cache crept up from the key frame
    final w = DryWatch();
    final verdicts = run(w, [
      (149, 144.0),
      (149, 144.6),
      (149, 145.3),
      (149, 146.0),
      (149, 146.5),
      (149, 147.3),
      (149, 148.1),
      (149, 149.6),
    ]);
    expect(verdicts, everyElement(DryVerdict.fine));
  });

  test('standing still with nothing arriving is given up on after '
      'stuckSeconds', () {
    final w = DryWatch(stuckSeconds: 10);
    final verdicts = run(w, [
      (149, 146.467),
      for (var i = 0; i < 10; i++) (149, 146.467),
    ]);
    expect(verdicts.sublist(0, 10), everyElement(DryVerdict.fine));
    expect(verdicts.last, DryVerdict.stuck);
  });

  test('standing there for slowSeconds, arriving all along, is too slow', () {
    // 2026-10-16 self-test, every host at 800 kbps: about 0.3 s of video a
    // second (0.2 here, so it is still behind on the twelfth)
    final w = DryWatch(slowSeconds: 12);
    final verdicts = run(w, [
      for (var i = 0; i < 12; i++) (149, 145.267 + i * 0.2),
    ]);
    expect(verdicts.sublist(0, 11), everyElement(DryVerdict.fine));
    expect(verdicts.last, DryVerdict.slow);
  });

  test('standing still, a cache short of the playhead by less than a second '
      'is short too', () {
    // 2026-10-16 self-test: stopped at 148.1 s under 149.0 s for 13 s
    final w = DryWatch(stuckSeconds: 10);
    final verdicts = run(w, [for (var i = 0; i < 11; i++) (149, 148.1)]);
    expect(verdicts.last, DryVerdict.stuck);
  });

  test('moving, the second of margin stands', () {
    final w = DryWatch();
    expect(
      run(w, [(148, 148), (148.5, 148), (149, 148.2), (149.5, 148.6)]),
      everyElement(DryVerdict.fine),
    );
  });

  test('a seek landing ahead of the cache and waiting there is a load, not '
      'a dry track', () {
    final w = DryWatch();
    expect(
      run(w, [(20, 40), (300, 40), (300, 296), (300, 297), (300, 298)]),
      everyElement(DryVerdict.fine),
    );
  });

  test('anything arriving starts the count over', () {
    final w = DryWatch(stuckSeconds: 3);
    expect(
      run(w, [
        (149, 146),
        (149, 146),
        (149, 146),
        (149, 146.2),
        (149, 146.2),
        (149, 146.2),
        (149, 146.2),
      ]),
      [
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.stuck,
      ],
    );
  });

  test('the grace skips ticks, and the next tick has nothing to compare '
      'with', () {
    final w = DryWatch()..grace();
    // three ticks not judged, then a first look, then the judgement
    expect(
      run(w, [(20, 10), (21, 10), (22, 10), (23, 10), (24, 10), (25, 10)]),
      [
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.fine,
        DryVerdict.dry,
      ],
    );
  });

  test('a skipped tick (buffering, paused) starts both counts over', () {
    final w = DryWatch(stuckSeconds: 2);
    run(w, [(149, 146), (149, 146)]);
    w.skip();
    expect(run(w, [(149, 146), (149, 146)]), [
      DryVerdict.fine,
      DryVerdict.fine,
    ]);
    expect(run(w, [(149, 146)]), [DryVerdict.stuck]);
  });

  test('ahead of the playhead, or at the end of the video, is fine', () {
    expect(DryWatch.behind(position: 10, cacheEnd: 30, duration: 60), isFalse);
    expect(DryWatch.behind(position: 10, cacheEnd: 9.5, duration: 60), isFalse);
    expect(DryWatch.behind(position: 59, cacheEnd: 50, duration: 60), isFalse);
    expect(DryWatch.behind(position: 10, cacheEnd: 8, duration: 60), isTrue);
    expect(DryWatch.behind(position: null, cacheEnd: 8, duration: 60), isFalse);
  });
}
