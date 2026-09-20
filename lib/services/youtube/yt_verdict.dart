/// The four-way failure taxonomy every YouTube response is reduced to.
///
/// This is the core of the design: the routing rule above it is trivial, and
/// gets the safety property only because the classification is honest. See
/// `research/youtube-direct-spike.md` §6.
library;

enum YtCause {
  /// Everything parsed and is usable.
  ok,

  /// (a) The video will not play for ANY anonymous client, here or anywhere:
  /// deleted, private, age-gated, members-only, geo-blocked, terminated.
  ///
  /// → show the reason. Do NOT fall back: a fallback source is anonymous too
  /// and hits the same wall, so trying it only doubles the latency of an error.
  contentUnavailable,

  /// (b) OUR egress IP is rate-limited, challenged or blocked. The request
  /// shape is fine; the same request from another network would work.
  ///
  /// → **the only cause that may trigger a fallback.**
  ipBlocked,

  /// (c) Transient: DNS/TCP/TLS failure, timeout, 5xx, truncated body.
  ///
  /// → retry the SAME source with backoff. Never switch on the first one.
  transient,

  /// (d) YouTube changed something and our request or parse shape is now wrong.
  ///
  /// → MUST NOT fall back. Falling back here hides a broken client behind a
  /// third party and we would ship the breakage for however long nobody files
  /// a bug.
  clientBroken,
}

/// A [YtCause] together with the evidence it was derived from.
///
/// [signal] is a short stable token (`playability:age-gate`, `rpc-error:
/// NOT_FOUND`, `sabr-only`, …) designed to be pasteable into a bug report and
/// greppable in this source tree. [detail] is free text for humans.
class YtVerdict {
  const YtVerdict(
    this.cause,
    this.signal, [
    this.detail = '',
    this.suspectClient = false,
  ]);

  final YtCause cause;
  final String signal;
  final String detail;

  /// The verdict is the best single-response reading, but a competing cause is
  /// live.
  ///
  /// Set on (a) verdicts whose only evidence is a GENERIC "unavailable" on a
  /// video whose `videoDetails` still came back intact. Measured 2026-09-20:
  /// the WEB identity returns exactly that for 8/8 perfectly healthy videos,
  /// while a genuinely dead id returns `status=ERROR` with NO `videoDetails`.
  /// One such response is indistinguishable from a dead video; a *run* of them
  /// is (d). [YtSourceRouter] promotes a streak of these to
  /// [YtCause.clientBroken].
  final bool suspectClient;

  bool get isOk => cause == YtCause.ok;

  static const YtVerdict ok = YtVerdict(YtCause.ok, 'ok');

  @override
  String toString() =>
      '${cause.name}<$signal>'
      '${detail.isEmpty ? '' : ' :: $detail'}'
      '${suspectClient ? ' [suspect]' : ''}';
}

/// A value plus the verdict that produced (or blocked) it.
class YtResult<T> {
  const YtResult(this.value, this.verdict);

  const YtResult.ok(T this.value) : verdict = YtVerdict.ok;

  const YtResult.failed(this.verdict) : value = null;

  final T? value;
  final YtVerdict verdict;

  bool get ok => verdict.cause == YtCause.ok && value != null;

  /// Re-wrap a failure as a different value type, so a failed step can be
  /// propagated without a cast.
  YtResult<R> castFailure<R>() => YtResult<R>.failed(verdict);

  @override
  String toString() => ok ? 'ok($value)' : 'failed($verdict)';
}
