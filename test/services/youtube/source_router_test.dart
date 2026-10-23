import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_test_support.dart';

const _ok = YtVerdict.ok;
const _dead = YtVerdict(
  YtCause.contentUnavailable,
  'playability:error',
  'This video is unavailable',
);
const _suspect = YtVerdict(
  YtCause.contentUnavailable,
  'playability:unplayable-generic',
  'Video unavailable',
  true,
);

/// The two-signal kind: one 429 was measured scoped to one endpoint.
const _blocked = YtVerdict(
  YtCause.ipBlocked,
  'http-429',
  'explicit rate limit',
);

/// The kind the direct source has already confirmed itself.
const _walled = YtVerdict(
  YtCause.ipBlocked,
  YtSignals.botCheckConfirmed,
  'bot wall persisted across a freshly minted visitorData',
);
const _transient = YtVerdict(YtCause.transient, 'http-503', '5xx');
const _broken = YtVerdict(
  YtCause.clientBroken,
  'rpc-error:NOT_FOUND',
  '404 Requested entity was not found.',
);

/// A router whose clock and sleep are under the test's control, so cooldowns
/// and backoff are asserted rather than waited for.
class _Harness {
  _Harness({
    required List<YtVerdict> directScript,
    List<YtVerdict>? fallbackScript,
    YtSourceMode mode = YtSourceMode.auto,
    YtVerdict directProbe = _ok,
  }) : direct = ScriptedYtSource(
         'direct',
         directScript,
         probeVerdict: directProbe,
       ),
       fallback = fallbackScript == null
           ? null
           : ScriptedYtSource('spy', fallbackScript) {
    router = YtSourceRouter(
      direct,
      fallback: fallback,
      mode: mode,
      clock: () => now,
      sleep: (d) async => slept.add(d),
    );
  }

  final ScriptedYtSource direct;
  final ScriptedYtSource? fallback;
  late final YtSourceRouter router;

  DateTime now = DateTime.utc(2026, 9, 20, 12);
  final List<Duration> slept = [];

  Future<YtRoutedResult<YtStreamPair>> call() =>
      router.run((s) => s.streams('dQw4w9WgXcQ'));
}

void main() {
  group('ok', () {
    test('answers from direct and never touches the fallback', () async {
      final h = _Harness(directScript: [_ok], fallbackScript: [_ok]);
      final r = await h.call();
      expect(r.ok, isTrue);
      expect(r.source!.id, 'direct');
      expect(h.fallback!.calls, 0, reason: 'the spy must be untouched');
      expect(h.router.activeOverrideReason, isNull);
    });

    test('clears every streak', () async {
      final h = _Harness(directScript: [_transient, _ok]);
      await h.call();
      final health = h.router.healthOf('direct');
      expect(health.transientStreak, 0);
      expect(health.brokenStreak, 0);
      expect(health.suspectStreak, 0);
      expect(health.blockSignalStreak, 0);
    });
  });

  group('contentUnavailable — (a) never falls through', () {
    test('a dead video is returned as-is; the spy is untouched', () async {
      final h = _Harness(directScript: [_dead], fallbackScript: [_ok]);
      final r = await h.call();
      expect(r.verdict.cause, YtCause.contentUnavailable);
      expect(h.fallback!.calls, 0);
      expect(h.router.healthOf('direct').cooldownUntil, isNull);
    });

    test('a NON-suspect (a) does not accumulate a suspect streak', () async {
      final h = _Harness(directScript: [_dead]);
      await h.call();
      await h.call();
      await h.call();
      await h.call();
      expect(h.router.healthOf('direct').suspectStreak, 0);
      expect(h.direct.calls, 4);
    });

    // The population-level discriminator: one generic "unavailable" on a video
    // whose metadata came back is (a); a RUN of them means our identity is
    // stale, which is (d).
    test('three suspect (a) responses are promoted to clientBroken', () async {
      final h = _Harness(directScript: [_suspect], fallbackScript: [_ok]);

      final first = await h.call();
      expect(first.verdict.cause, YtCause.contentUnavailable);
      expect(h.router.healthOf('direct').suspectStreak, 1);

      final second = await h.call();
      expect(second.verdict.cause, YtCause.contentUnavailable);
      expect(h.router.healthOf('direct').suspectStreak, 2);

      final third = await h.call();
      expect(third.verdict.cause, YtCause.clientBroken);
      expect(third.verdict.signal, 'generic-unavailable-streak');
      expect(third.verdict.detail, contains('client identity is stale'));

      // (d) is NEVER a fall-through.
      expect(h.fallback!.calls, 0);
      expect(h.router.healthOf('direct').cooldownUntil, isNull);
    });

    test('a non-suspect result in between resets the streak', () async {
      final h = _Harness(directScript: [_suspect, _suspect, _dead, _suspect]);
      await h.call();
      await h.call();
      await h.call();
      final r = await h.call();
      expect(r.verdict.cause, YtCause.contentUnavailable);
      expect(h.router.healthOf('direct').suspectStreak, 1);
    });
  });

  group(
    'ipBlocked — (b) is the only fall-through, and only when confirmed',
    () {
      test('ONE (b) condemns the call, not the source', () async {
        final h = _Harness(
          directScript: [_blocked, _ok],
          fallbackScript: [_ok],
        );
        final r = await h.call();
        expect(r.verdict.cause, YtCause.ipBlocked);
        expect(
          h.fallback!.calls,
          0,
          reason: 'a single 429 was measured to be scoped to one endpoint',
        );
        expect(h.router.healthOf('direct').cooldownUntil, isNull);
        expect(h.router.healthOf('direct').blockSignalStreak, 1);
      });

      test(
        'a bot wall confirmed by the source falls through at once',
        () async {
          // 2026-10-12: waiting for a second one failed the first video of
          // every page, each page having a router of its own
          final h = _Harness(directScript: [_walled], fallbackScript: [_ok]);
          final r = await h.call();
          expect(r.ok, isTrue);
          expect(r.source!.id, 'spy');
          expect(
            h.router.healthOf('direct').cooldownUntil,
            h.now.add(const Duration(minutes: 5)),
          );
          // the cooldown holds: the next call goes to the fallback first
          await h.call();
          expect(h.direct.calls, 1);
          expect(h.fallback!.calls, 2);
        },
      );

      test('health passed in is shared between routers', () async {
        final shared = <String, YtSourceHealth>{};
        final direct = ScriptedYtSource('direct', [_walled]);
        final spy = ScriptedYtSource('spy', [_ok]);
        await YtSourceRouter(
          direct,
          fallback: spy,
          health: shared,
        ).run((s) => s.streams('dQw4w9WgXcQ'));
        final second = YtSourceRouter(direct, fallback: spy, health: shared);
        expect(second.sourceOrder().first.id, 'spy');
        expect(
          YtSourceRouter(direct, fallback: spy).sourceOrder().first.id,
          'direct',
        );
      });

      test('the shared cooldowns, kept for the next launch', () async {
        addTearDown(() {
          YtSourceRouter.sharedHealth.clear();
          YtSourceRouter.onSharedCooldown = null;
        });
        final now = DateTime.utc(2026, 10, 22, 20);
        var saved = 0;
        YtSourceRouter.onSharedCooldown = () => saved++;
        final direct = ScriptedYtSource('direct', [_walled]);
        final spy = ScriptedYtSource('spy', [_ok]);
        await YtSourceRouter(
          direct,
          fallback: spy,
          health: YtSourceRouter.sharedHealth,
          clock: () => now,
        ).run((s) => s.streams('dQw4w9WgXcQ'));
        expect(saved, 1);
        final kept = YtSourceRouter.sharedCooldowns(now: now);
        expect((kept['direct']! as Map)['step'], 1);

        // a router of its own health tells nobody
        await YtSourceRouter(
          ScriptedYtSource('direct', [_walled]),
          fallback: spy,
          clock: () => now,
        ).run((s) => s.streams('dQw4w9WgXcQ'));
        expect(saved, 1);

        // the next launch, a minute on: straight to the fallback
        YtSourceRouter.sharedHealth.clear();
        YtSourceRouter.restoreSharedCooldowns(
          kept,
          now: now.add(const Duration(minutes: 1)),
        );
        expect(
          YtSourceRouter(
            direct,
            fallback: spy,
            health: YtSourceRouter.sharedHealth,
            clock: () => now.add(const Duration(minutes: 1)),
          ).sourceOrder().first.id,
          'spy',
        );

        // past the cooldown: nothing back, the ladder from its foot
        YtSourceRouter.sharedHealth.clear();
        YtSourceRouter.restoreSharedCooldowns(
          kept,
          now: now.add(const Duration(minutes: 6)),
        );
        expect(YtSourceRouter.sharedHealth, isEmpty);
      });

      test('a SECOND (b) sets the cooldown and falls through', () async {
        final h = _Harness(directScript: [_blocked], fallbackScript: [_ok]);
        await h.call();
        final r = await h.call();

        expect(r.ok, isTrue);
        expect(r.source!.id, 'spy');
        expect(h.fallback!.calls, 1);
        final health = h.router.healthOf('direct');
        expect(health.cooldownUntil, h.now.add(const Duration(minutes: 5)));
        expect(h.router.activeOverrideReason, isNotNull);
      });

      test('the cooldown ladder climbs and then caps', () async {
        final h = _Harness(directScript: [_blocked], fallbackScript: [_ok]);
        final health = h.router.healthOf('direct');

        for (final expected in [
          const Duration(minutes: 5),
          const Duration(minutes: 15),
          const Duration(hours: 1),
          const Duration(hours: 6),
          const Duration(hours: 6), // capped
          const Duration(hours: 6),
        ]) {
          // Expire the previous cooldown so direct is tried again.
          h.now = h.now.add(const Duration(days: 1));
          await h.call(); // first (b): condemns the call
          await h.call(); // second (b): cooldown
          expect(health.cooldownUntil, h.now.add(expected));
        }
      });

      test(
        'a cooled-down direct source is skipped while an alternative exists',
        () async {
          final h = _Harness(directScript: [_blocked], fallbackScript: [_ok]);
          await h.call();
          await h.call();
          final callsSoFar = h.direct.calls;

          final r = await h.call();
          expect(r.source!.id, 'spy');
          expect(h.direct.calls, callsSoFar, reason: 'direct was not retried');
        },
      );

      test(
        'with NO fallback configured, (b) is surfaced rather than swallowed',
        () async {
          final h = _Harness(directScript: [_blocked]);
          await h.call();
          final r = await h.call();
          expect(r.verdict.cause, YtCause.ipBlocked);
          expect(r.source!.id, 'direct');
          // Only source: it is still used after the cooldown is set, because
          // refusing to try at all would be worse than trying.
          final third = await h.call();
          expect(third.verdict.cause, YtCause.ipBlocked);
          expect(h.direct.calls, 3);
        },
      );

      test('the cooldown expires on its own', () async {
        final h = _Harness(
          directScript: [_blocked, _blocked, _ok],
          fallbackScript: [_ok],
        );
        await h.call();
        await h.call();
        expect(h.router.directIsAvailable, isFalse);

        h.now = h.now.add(const Duration(minutes: 6));
        expect(h.router.directIsAvailable, isTrue);
        final r = await h.call();
        expect(r.source!.id, 'direct');
        expect(h.router.activeOverrideReason, isNull);
      });

      test(
        'a successful probe clears the cooldown early AND resets the ladder',
        () async {
          final h = _Harness(directScript: [_blocked], fallbackScript: [_ok]);
          await h.call();
          await h.call();
          expect(h.router.directIsAvailable, isFalse);

          expect(await h.router.retryDirectNow(), isTrue);
          expect(h.direct.probes, 1);
          expect(h.router.directIsAvailable, isTrue);
          expect(h.router.activeOverrideReason, isNull);
          expect(h.router.healthOf('direct').cooldownStep, 0);

          // The ladder restarts at 5 minutes, not at 15.
          await h.call();
          await h.call();
          expect(
            h.router.healthOf('direct').cooldownUntil,
            h.now.add(const Duration(minutes: 5)),
          );
        },
      );

      test('a failed probe leaves the cooldown in place', () async {
        final h = _Harness(
          directScript: [_blocked],
          fallbackScript: [_ok],
          directProbe: _blocked,
        );
        await h.call();
        await h.call();
        expect(await h.router.retryDirectNow(), isFalse);
        expect(h.router.directIsAvailable, isFalse);
      });
    },
  );

  group('transient — (c) retries the same source, then moves on', () {
    test(
      'a retry that succeeds returns without touching the fallback',
      () async {
        final h = _Harness(
          directScript: [_transient, _ok],
          fallbackScript: [_ok],
        );
        final r = await h.call();
        expect(r.ok, isTrue);
        expect(r.source!.id, 'direct');
        expect(h.direct.calls, 2);
        expect(h.fallback!.calls, 0);
        expect(h.slept, [const Duration(milliseconds: 400)]);
      },
    );

    test(
      'backoff grows with the streak and stops at the retry limit',
      () async {
        final h = _Harness(directScript: [_transient]);
        await h.call();
        expect(h.direct.calls, 1 + ytTransientRetryLimit);
        expect(h.slept, const [
          Duration(milliseconds: 400),
          Duration(milliseconds: 800),
          Duration(milliseconds: 1200),
        ]);
      },
    );

    test('a (c) NEVER sets a cooldown', () async {
      final h = _Harness(directScript: [_transient], fallbackScript: [_ok]);
      await h.call();
      expect(h.router.healthOf('direct').cooldownUntil, isNull);
      expect(h.router.healthOf('direct').blockSignalStreak, 0);
    });

    test('exhausted retries do move on to the fallback', () async {
      final h = _Harness(directScript: [_transient], fallbackScript: [_ok]);
      final r = await h.call();
      expect(r.source!.id, 'spy');
      expect(h.fallback!.calls, 1);
    });

    test(
      'the fall-through records a transient failure, not a cooldown',
      () async {
        final h = _Harness(directScript: [_transient], fallbackScript: [_ok]);
        await h.call();
        expect(h.router.fellThroughFor, YtCause.transient);
        expect(h.router.activeOverrideReason, contains('failed transiently'));
        expect(h.router.activeOverrideReason, contains('http-503'));
        expect(h.router.activeOverrideReason, isNot(contains('cooldown')));
      },
    );

    test('a block records ipBlocked as the reason it left', () async {
      final h = _Harness(directScript: [_walled], fallbackScript: [_ok]);
      await h.call();
      expect(h.router.fellThroughFor, YtCause.ipBlocked);
      // and a later call, on the fallback because of the cooldown
      await h.call();
      expect(h.router.fellThroughFor, YtCause.ipBlocked);
    });

    test('an answer from direct leaves nothing recorded', () async {
      final h = _Harness(directScript: [_ok], fallbackScript: [_ok]);
      await h.call();
      expect(h.router.fellThroughFor, isNull);
    });

    test('the fallback is not retried: it walks its own instances', () async {
      final h = _Harness(
        directScript: [_transient],
        fallbackScript: [_transient],
      );
      final r = await h.call();
      expect(r.verdict.cause, YtCause.transient);
      expect(h.fallback!.calls, 1);
      expect(h.direct.calls, 1 + ytTransientRetryLimit);
    });

    test('fallbackOnly does not retry the fallback either', () async {
      final h = _Harness(
        directScript: [_ok],
        fallbackScript: [_transient],
        mode: YtSourceMode.fallbackOnly,
      );
      await h.call();
      expect(h.fallback!.calls, 1);
      expect(h.slept, isEmpty);
    });

    test('a decisive answer after the streak ends it', () async {
      final h = _Harness(
        directScript: [
          ...List.filled(1 + ytTransientRetryLimit, _transient),
          _dead,
          _transient,
          _ok,
        ],
        fallbackScript: [_ok],
      );
      await h.call(); // four (c), on to the fallback
      expect(h.router.healthOf('direct').transientStreak, 3);
      await h.call(); // a dead video: the source answers
      expect(h.router.healthOf('direct').transientStreak, 0);
      final r = await h.call(); // (c) retried again, not sent on at once
      expect(r.source!.id, 'direct');
      expect(r.ok, isTrue);
    });

    test('a retry that turns decisive stops the walk there', () async {
      final h = _Harness(
        directScript: [_transient, _dead],
        fallbackScript: [_ok],
      );
      final r = await h.call();
      expect(r.verdict.cause, YtCause.contentUnavailable);
      expect(h.fallback!.calls, 0);
    });

    test('a block a retry meets is handled as a first one would be', () async {
      final h = _Harness(
        directScript: [_transient, _walled],
        fallbackScript: [_ok],
      );
      final r = await h.call();
      expect(r.ok, isTrue);
      expect(r.source!.id, 'spy');
      expect(h.fallback!.calls, 1);
      expect(h.router.healthOf('direct').cooldownUntil, isNotNull);
      expect(h.router.healthOf('direct').transientStreak, 0);
      expect(h.router.fellThroughFor, YtCause.ipBlocked);
    });

    test('a (d) a retry meets is counted as one', () async {
      final h = _Harness(
        directScript: [_transient, _broken],
        fallbackScript: [_ok],
      );
      final r = await h.call();
      expect(r.verdict.cause, YtCause.clientBroken);
      expect(h.fallback!.calls, 0);
      expect(h.router.healthOf('direct').brokenStreak, 1);
    });
  });

  group('clientBroken — (d) is loud and never falls through', () {
    test(
      'a retired client version is surfaced, not hidden behind the spy',
      () async {
        final h = _Harness(directScript: [_broken], fallbackScript: [_ok]);
        final r = await h.call();
        expect(r.verdict.cause, YtCause.clientBroken);
        expect(r.verdict.signal, 'rpc-error:NOT_FOUND');
        expect(
          h.fallback!.calls,
          0,
          reason: 'THE property this design exists for',
        );
        expect(h.router.healthOf('direct').cooldownUntil, isNull);
        expect(h.router.healthOf('direct').brokenStreak, 1);
      },
    );

    test(
      'repeated (d) keeps failing loudly rather than degrading to a switch',
      () async {
        final h = _Harness(directScript: [_broken], fallbackScript: [_ok]);
        for (var i = 0; i < 5; i++) {
          final r = await h.call();
          expect(r.verdict.cause, YtCause.clientBroken);
        }
        expect(h.fallback!.calls, 0);
        expect(h.router.healthOf('direct').brokenStreak, 5);
      },
    );
  });

  group('modes', () {
    test('directOnly never contacts the fallback, even when blocked', () async {
      final h = _Harness(
        directScript: [_blocked],
        fallbackScript: [_ok],
        mode: YtSourceMode.directOnly,
      );
      await h.call();
      final r = await h.call();
      expect(r.verdict.cause, YtCause.ipBlocked);
      expect(h.fallback!.calls, 0);
    });

    test('fallbackOnly never contacts YouTube', () async {
      final h = _Harness(
        directScript: [_ok],
        fallbackScript: [_ok],
        mode: YtSourceMode.fallbackOnly,
      );
      final r = await h.call();
      expect(r.source!.id, 'spy');
      expect(h.direct.calls, 0);
    });

    test(
      'fallbackOnly with no fallback configured reports no-source',
      () async {
        final h = _Harness(
          directScript: [_ok],
          mode: YtSourceMode.fallbackOnly,
        );
        final r = await h.call();
        expect(r.ok, isFalse);
        expect(r.verdict.signal, 'no-source');
        expect(h.direct.calls, 0);
      },
    );

    test('auto with no fallback is just direct', () {
      final h = _Harness(directScript: [_ok]);
      expect(h.router.sourceOrder().map((s) => s.id), ['direct']);
    });
  });

  test('diagnostics are pasteable and name the last verdict', () async {
    final h = _Harness(directScript: [_broken]);
    await h.call();
    final text = h.router.diagnostics();
    expect(text, contains('mode=auto'));
    expect(text, contains('direct:'));
    expect(text, contains('rpc-error:NOT_FOUND'));
    expect(text, contains('broken=1'));
  });

  test(
    'YtVerdict.toString carries cause, signal, detail and the suspect flag',
    () {
      expect(
        _broken.toString(),
        'clientBroken<rpc-error:NOT_FOUND> :: '
        '404 Requested entity was not found.',
      );
      expect(_suspect.toString(), endsWith('[suspect]'));
      expect(YtVerdict.ok.toString(), 'ok<ok>');
    },
  );
}
