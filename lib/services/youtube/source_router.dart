/// The router, and the per-source health state that makes a fallback safe.
///
/// Its job is to make sure a fall-through to another source happens for
/// cause (b) — our IP is blocked — or after the direct source has failed
/// transiently again and again, and for nothing else (user 2026-10-19: keep
/// the transient fall-through, and say it is one). The video pages put
/// [YtInvidiousSource] (the registry's https instances, in turn) in the
/// fallback slot; every other page leaves it empty.
///
/// ## The routing rule, cause by cause
///
/// ```
/// ok                  -> return; clear the streaks
/// contentUnavailable  -> return. DO NOT try another source: it is anonymous
///                        too and hits the same wall, so trying it only
///                        doubles the latency of an error.
///                        …unless suspectStreak >= 3, which converts it to
///                        clientBroken (see below).
/// ipBlocked           -> put THIS source on cooldown, continue to the next.
///                        ← fall-through 1
/// transient           -> retry the SAME source with backoff, up to 3 times
///                        in a row (the streak runs across calls and pages,
///                        and ends with any answer that is not (c)). Still
///                        (c): continue to the next source, with no
///                        cooldown. ← fall-through 2: the video id goes to
///                        the fallback because YouTube did not answer, not
///                        because it refused. The fallback itself is not
///                        retried here: it walks its own instances
///                        ([YtInvidiousSource.triesPerVideo]).
/// clientBroken        -> return the error LOUDLY. No fall-through, ever.
/// ```
///
/// Two gates on the (b) path, both measured:
///
///  * a **bot-check must survive a freshly minted `visitorData`** before it
///    counts — handled inside [YtDirectSource], which is why the router only
///    ever sees the confirmed form;
///  * a **single 429 condemns the call, not the source.** Measured: a 429 on
///    the caption-translation endpoint arrived while the player endpoint kept
///    answering 200 *in the same second*. A client that flips the whole source
///    over on one 429 would have fallen back while YouTube was cheerfully
///    serving it everything else. So a cooldown requires
///    [confirmBlockOnSecondSignal] consecutive (b) verdicts.
library;

import 'dart:async';

import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_classifier.dart' show YtSignals;
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

/// How many consecutive suspect-(a) responses mean the client, not the videos.
///
/// A generic "unavailable" on a video whose `videoDetails` still came back is,
/// per response, indistinguishable from a dead video — and is exactly what a
/// stale client identity produces for EVERY video (measured: the WEB identity,
/// 8/8 healthy videos). One is (a). A run of them is (d).
///
/// 3 is a **threshold, not a measurement**: a user who genuinely opens three
/// dead videos in a row gets one wrong diagnosis, while a client identity
/// YouTube retired overnight is caught within a handful of taps.
const int ytSuspectStreakIsBroken = 3;

/// How many consecutive (b) verdicts a source needs before it goes on
/// cooldown. See the library doc: one 429 is a scoped rate limit, not a block.
const int confirmBlockOnSecondSignal = 2;

/// Cooldown after successive confirmed blocks. Doubling-ish, and **capped**.
///
/// The cap is the point: an app that permanently relocates to a third party
/// because of one bad afternoon has stopped being a direct client. A
/// successful probe clears the cooldown early and resets the ladder.
///
/// **This ladder is a designed guess, not a measurement.** No real IP block was
/// provoked (deliberately — it would have cost the user's home IP for an
/// unknown period), so nothing is known about a real block's duration. The one
/// 429 observed carried no `Retry-After`.
const List<Duration> ytCooldownLadder = [
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(hours: 1),
  Duration(hours: 6),
];

/// Retry backoff for (c). Multiplied by the streak count.
const Duration ytTransientBackoffStep = Duration(milliseconds: 400);

/// How many times in a row a (c) is retried on the same source before the
/// router moves on to the next one (the fallback, where there is one).
const int ytTransientRetryLimit = 3;

/// What the router remembers about one source.
class YtSourceHealth {
  /// When this source may be used again. Set ONLY by a confirmed (b).
  DateTime? cooldownUntil;

  /// Consecutive (b) verdicts not yet promoted to a cooldown.
  int blockSignalStreak = 0;

  /// How many cooldowns this source has served: the index into the ladder.
  int cooldownStep = 0;

  /// Consecutive (c) failures, across calls: drives the retry backoff, and
  /// at [ytTransientRetryLimit] the next (c) moves on at once. Any answer
  /// that is not (c) ends it — the source is answering.
  int transientStreak = 0;

  /// Consecutive suspect-(a) responses. See [ytSuspectStreakIsBroken].
  int suspectStreak = 0;

  /// Consecutive (d) failures. Never triggers a switch — it triggers a loud
  /// error, because switching here would hide a broken client behind a third
  /// party for however long nobody notices.
  int brokenStreak = 0;

  /// The last verdict, for the UI's "why did it switch?" line.
  YtVerdict? last;

  bool availableAt(DateTime now) =>
      cooldownUntil == null || !now.isBefore(cooldownUntil!);

  Duration cooldownLeft(DateTime now) {
    final until = cooldownUntil;
    if (until == null || !now.isBefore(until)) return Duration.zero;
    return until.difference(now);
  }

  void clearCooldown() {
    cooldownUntil = null;
    cooldownStep = 0;
    blockSignalStreak = 0;
  }

  @override
  String toString() =>
      'YtSourceHealth(cooldownUntil: $cooldownUntil, step: $cooldownStep, '
      'block: $blockSignalStreak, transient: $transientStreak, '
      'suspect: $suspectStreak, broken: $brokenStreak)';
}

/// What the user picked in the (later) source switch.
enum YtSourceMode {
  /// Direct first; another source only after a confirmed (b).
  auto,

  /// Never contact anything but YouTube. A confirmed (b) surfaces as an error
  /// that names the alternative rather than switching silently.
  directOnly,

  /// Never contact YouTube.
  fallbackOnly,
}

/// The result of a routed call: what came back, and who answered.
class YtRoutedResult<T> {
  const YtRoutedResult(this.result, this.source);

  final YtResult<T> result;
  final YouTubeVideoSource? source;

  bool get ok => result.ok;
  T? get value => result.value;
  YtVerdict get verdict => result.verdict;

  @override
  String toString() => 'YtRoutedResult(${source?.id ?? 'none'}: $result)';
}

class YtSourceRouter {
  YtSourceRouter(
    this.direct, {
    this.fallback,
    this.mode = YtSourceMode.auto,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    Map<String, YtSourceHealth>? health,
  }) : health = health ?? {},
       _now = clock ?? DateTime.now,
       _sleep = sleep ?? _realSleep;

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// The primary source. Never null.
  final YouTubeVideoSource direct;

  /// The second source: [YtInvidiousSource] on the video pages, null
  /// elsewhere (search, channels and comments are the direct source's calls).
  final YouTubeVideoSource? fallback;

  YtSourceMode mode;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  /// Per source. Its own unless one is passed in: the video pages pass
  /// [sharedHealth], so a cooldown found on one video holds on the next
  /// rather than every page asking the walled source again first.
  final Map<String, YtSourceHealth> health;

  /// What the video pages share.
  static final Map<String, YtSourceHealth> sharedHealth = {};

  /// Set while auto mode is serving from the fallback, so the UI can say so
  /// and the user can see it was not their choice. A silent switch is how a
  /// broken client stays broken.
  String? activeOverrideReason;

  /// Why the last [run] left the direct source for the fallback:
  /// [YtCause.ipBlocked] for a confirmed block or the cooldown one left,
  /// [YtCause.transient] when YouTube did not answer; null when it did not
  /// leave it. The page words its toast and its failure by this: a timeout
  /// is not a refusal.
  YtCause? fellThroughFor;

  YtSourceHealth healthOf(String sourceId) =>
      health.putIfAbsent(sourceId, YtSourceHealth.new);

  /// The order sources are tried in, given the mode and the cooldowns.
  List<YouTubeVideoSource> sourceOrder() {
    switch (mode) {
      case YtSourceMode.directOnly:
        return [direct];
      case YtSourceMode.fallbackOnly:
        return [?fallback];
      case YtSourceMode.auto:
        final f = fallback;
        if (f == null) return [direct];
        return healthOf(direct.id).availableAt(_now())
            ? [direct, f]
            : [f, direct];
    }
  }

  /// Run [call] against the first usable source, falling through on a
  /// confirmed (b) or on a (c) the retries did not clear (see the library
  /// doc).
  Future<YtRoutedResult<T>> run<T>(
    Future<YtResult<T>> Function(YouTubeVideoSource) call,
  ) async {
    final order = sourceOrder();
    YtResult<T>? last;
    YouTubeVideoSource? lastSource;
    // what this call's own fall-through was for, when it had one
    String? fellThrough;
    // the direct source behind the fallback: only a block puts it there
    fellThroughFor =
        mode == YtSourceMode.auto &&
            order.length > 1 &&
            order.first.id != direct.id
        ? YtCause.ipBlocked
        : null;

    for (final source in order) {
      final h = healthOf(source.id);
      // Skip a cooled-down source only when there is somewhere else to go.
      if (!h.availableAt(_now()) && order.length > 1) continue;

      var res = await call(source);
      h.last = res.verdict;
      last = res;
      lastSource = source;

      switch (res.verdict.cause) {
        case YtCause.ok:
          h
            ..transientStreak = 0
            ..brokenStreak = 0
            ..suspectStreak = 0
            ..blockSignalStreak = 0;
          if (source.id == direct.id) {
            activeOverrideReason = null;
          } else if (fellThrough != null) {
            activeOverrideReason = fellThrough;
          } else {
            activeOverrideReason ??= 'direct source is on cooldown';
          }
          return YtRoutedResult(res, source);

        case YtCause.contentUnavailable:
          h.transientStreak = 0;
          if (res.verdict.suspectClient) {
            h.suspectStreak++;
            if (h.suspectStreak >= ytSuspectStreakIsBroken) {
              h.brokenStreak++;
              return YtRoutedResult(
                YtResult<T>.failed(
                  YtVerdict(
                    YtCause.clientBroken,
                    'generic-unavailable-streak',
                    '${h.suspectStreak} consecutive generic "unavailable" '
                        'responses on videos that still returned videoDetails '
                        '— our client identity is stale',
                  ),
                ),
                source,
              );
            }
          } else {
            h.suspectStreak = 0;
          }
          // (a): do NOT try another source.
          return YtRoutedResult(res, source);

        case YtCause.ipBlocked:
          h
            ..transientStreak = 0
            ..blockSignalStreak += 1;
          // A bot wall the direct source has already asked about twice (the
          // second time with a fresh visitorData) is confirmed as it comes:
          // the 429 the two-signal rule is for came from one endpoint while
          // the others answered, and that is not this. Waiting for a second
          // one here failed the first video every page opened with.
          final confirmed =
              res.verdict.signal == YtSignals.botCheckConfirmed ||
              h.blockSignalStreak >= confirmBlockOnSecondSignal;
          if (!confirmed) {
            // One (b) condemns the call, not the source. Surface it; the next
            // call decides whether this was a scoped rate limit or a wall.
            return YtRoutedResult(res, source);
          }
          _startCooldown(h);
          activeOverrideReason = fellThrough = res.verdict.detail.isEmpty
              ? res.verdict.signal
              : res.verdict.detail;
          if (source.id == direct.id) fellThroughFor = YtCause.ipBlocked;
          continue; // ← fall-through 1

        case YtCause.transient:
          if (source.id == fallback?.id) {
            // the fallback walks its instances itself: retried here, a video
            // that failed walked up to 16 of them, at 10-20 s each, before
            // the page said so (audit 2026-10-19). Its (c) is its answer
            h.transientStreak++;
            continue;
          }
          var retried = false;
          // the (c) answers this call had
          var failures = 1;
          while (h.transientStreak < ytTransientRetryLimit) {
            h.transientStreak++;
            await _sleep(ytTransientBackoffStep * h.transientStreak);
            res = await call(source);
            h.last = res.verdict;
            last = res;
            retried = true;
            if (res.verdict.cause != YtCause.transient) break;
            failures++;
          }
          if (res.verdict.cause == YtCause.ok) {
            h.transientStreak = 0;
            activeOverrideReason = source.id == direct.id
                ? null
                : activeOverrideReason;
            return YtRoutedResult(res, source);
          }
          if (retried && res.verdict.cause != YtCause.transient) {
            // The retry produced a different, decisive verdict. Do not keep
            // walking the list on a stale (c).
            h.transientStreak = 0;
            return YtRoutedResult(res, source);
          }
          // Still transient after the retries: try the next source rather than
          // failing outright, but do NOT mark this one blocked. What is
          // recorded says so: YouTube did not answer, it did not refuse.
          if (source.id == direct.id) {
            fellThrough =
                'direct source failed transiently ($failures× this call, '
                '${h.transientStreak} retries in a row; last: ${res.verdict.signal})';
            fellThroughFor = YtCause.transient;
          }
          continue; // ← fall-through 2

        case YtCause.clientBroken:
          h
            ..transientStreak = 0
            ..brokenStreak += 1;
          // Deliberately NOT a fall-through. Surface it.
          return YtRoutedResult(res, source);
      }
    }

    return YtRoutedResult(
      last ??
          const YtResult<Never>.failed(
            YtVerdict(
              YtCause.transient,
              'no-source',
              'every source is on cooldown or none is configured',
            ),
          ).castFailure<T>(),
      lastSource,
    );
  }

  void _startCooldown(YtSourceHealth h) {
    final step = h.cooldownStep < ytCooldownLadder.length
        ? h.cooldownStep
        : ytCooldownLadder.length - 1;
    h
      ..cooldownUntil = _now().add(ytCooldownLadder[step])
      ..cooldownStep = h.cooldownStep + 1
      ..blockSignalStreak = 0;
  }

  /// Whether the direct source may be used right now.
  bool get directIsAvailable => healthOf(direct.id).availableAt(_now());

  /// Probe the direct source; a success clears its cooldown early and resets
  /// the ladder. Cheap by contract — see [YouTubeVideoSource.probe].
  Future<bool> retryDirectNow() async {
    final v = await direct.probe();
    if (v.cause != YtCause.ok) return false;
    healthOf(direct.id).clearCooldown();
    activeOverrideReason = null;
    return true;
  }

  /// A one-line, pasteable diagnostic of every source's state.
  String diagnostics() {
    final now = _now();
    final lines = <String>[
      'mode=${mode.name} override=${activeOverrideReason ?? '-'}',
    ];
    for (final entry in health.entries) {
      final h = entry.value;
      lines.add(
        '${entry.key}: last=${h.last ?? '-'} '
        'cooldown=${h.cooldownLeft(now)} step=${h.cooldownStep} '
        'transient=${h.transientStreak} suspect=${h.suspectStreak} '
        'broken=${h.brokenStreak}',
      );
    }
    return lines.join('\n');
  }
}
