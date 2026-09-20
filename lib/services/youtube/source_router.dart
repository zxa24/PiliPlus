/// The router, and the per-source health state that makes a fallback safe.
///
/// Its ONLY job is to make sure a fall-through to another source happens for
/// cause (b) — our IP is blocked — and for nothing else. The stage-1 fallback
/// slot is **empty**: [YtSourceRouter.fallback] is null until an Invidious
/// implementation exists. The routing rule is still live and still tested,
/// because the rule is the deliverable; the second source is not.
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
///                        ← the ONLY fall-through
/// transient           -> retry the SAME source with backoff, up to 3 times.
///                        Never sets a cooldown, never switches.
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

/// How many times a (c) is retried on the same source before moving on.
const int ytTransientRetryLimit = 3;

/// What the router remembers about one source.
class YtSourceHealth {
  /// When this source may be used again. Set ONLY by a confirmed (b).
  DateTime? cooldownUntil;

  /// Consecutive (b) verdicts not yet promoted to a cooldown.
  int blockSignalStreak = 0;

  /// How many cooldowns this source has served: the index into the ladder.
  int cooldownStep = 0;

  /// Consecutive (c) failures. Drives retry backoff, never a switch.
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
  }) : _now = clock ?? DateTime.now,
       _sleep = sleep ?? _realSleep;

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// The primary source. Never null.
  final YouTubeVideoSource direct;

  /// **The empty slot.** Stage 1 never sets this; an Invidious implementation
  /// goes here and nothing else has to change.
  final YouTubeVideoSource? fallback;

  YtSourceMode mode;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  final Map<String, YtSourceHealth> health = {};

  /// Set while auto mode is serving from the fallback, so the UI can say so
  /// and the user can see it was not their choice. A silent switch is how a
  /// broken client stays broken.
  String? activeOverrideReason;

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

  /// Run [call] against the first usable source, falling through ONLY on a
  /// confirmed (b).
  Future<YtRoutedResult<T>> run<T>(
    Future<YtResult<T>> Function(YouTubeVideoSource) call,
  ) async {
    final order = sourceOrder();
    YtResult<T>? last;
    YouTubeVideoSource? lastSource;

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
          } else {
            activeOverrideReason ??= 'direct source is on cooldown';
          }
          return YtRoutedResult(res, source);

        case YtCause.contentUnavailable:
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
          h.blockSignalStreak++;
          if (h.blockSignalStreak < confirmBlockOnSecondSignal) {
            // One (b) condemns the call, not the source. Surface it; the next
            // call decides whether this was a scoped rate limit or a wall.
            return YtRoutedResult(res, source);
          }
          _startCooldown(h);
          activeOverrideReason = res.verdict.detail.isEmpty
              ? res.verdict.signal
              : res.verdict.detail;
          continue; // ← the ONLY place a fall-through happens.

        case YtCause.transient:
          var retried = false;
          while (h.transientStreak < ytTransientRetryLimit) {
            h.transientStreak++;
            await _sleep(ytTransientBackoffStep * h.transientStreak);
            res = await call(source);
            h.last = res.verdict;
            last = res;
            retried = true;
            if (res.verdict.cause != YtCause.transient) break;
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
            return YtRoutedResult(res, source);
          }
          // Still transient after the retries: try the next source rather than
          // failing outright, but do NOT mark this one blocked.
          continue;

        case YtCause.clientBroken:
          h.brokenStreak++;
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
