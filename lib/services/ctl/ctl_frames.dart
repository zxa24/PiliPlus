/// LibrePili: how often Flutter draws, how long its frames take, and who
/// asks it to draw — for the command-line reader's `/frames` and
/// `POST /control/trace-frames` (feature-logs/linux-4k-perf: on Linux a
/// still window kept drawing empty frames, 构建 0 ms, until something
/// broke the run).
///
/// Counts only while the reader serves ([start] / [stop]); off, the hooks
/// in [ScaledWidgetsFlutterBinding] cost one bool test. The callers' stacks
/// are taken only during a trace (seconds asked for, at most two minutes):
/// a stack per frame asked for is not free.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

abstract final class CtlFrames {
  static bool _on = false;

  /// Whether anything is counted; the binding's hooks test this first.
  static bool get isOn => _on;

  static final _clock = Stopwatch();
  static int get _now => _clock.elapsedMilliseconds;

  /// How far back the counts go, in ms.
  static const _keepMs = 60 * 1000;

  /// When (ms on [_clock]) each frame began.
  static final _begins = ListQueue<int>();

  /// When a frame was asked for while none was pending: the asks that make
  /// a frame. scheduleFrame called with one already pending is not counted.
  static final _requests = ListQueue<int>();
  static final _forced = ListQueue<int>();

  /// When the window's metrics (size, pixel ratio…) changed: each makes a
  /// frame of its own, asked for or not.
  static final _metrics = ListQueue<int>();

  static final _timings = ListQueue<_Timing>();

  static int? _traceUntil;
  static var _traced = 0;
  static var _untracedKinds = 0;
  static final _stacks = <String, int>{};
  static const _maxStacks = 200;

  static void start() {
    if (_on) return;
    _on = true;
    _clock
      ..reset()
      ..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void stop() {
    if (!_on) return;
    _on = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _clock.stop();
    for (final q in [_begins, _requests, _forced, _metrics]) {
      q.clear();
    }
    _timings.clear();
    _traceUntil = null;
    _stacks.clear();
    _traced = 0;
    _untracedKinds = 0;
  }

  static void _push(ListQueue<int> q, int at) {
    q.add(at);
    while (q.isNotEmpty && q.first < at - _keepMs) {
      q.removeFirst();
    }
  }

  // ------------------------------------------------- the binding's hooks

  /// [makesFrame]: none was pending and frames are enabled, so this call
  /// is the one that asks the engine for a frame.
  static void onScheduleFrame(bool makesFrame) {
    if (!_on || !makesFrame) return;
    final now = _now;
    _push(_requests, now);
    if (_traceUntil case final until? when now <= until) _noteStack();
  }

  static void onForcedFrame(bool makesFrame) {
    if (!_on || !makesFrame) return;
    final now = _now;
    _push(_forced, now);
    if (_traceUntil case final until? when now <= until) _noteStack();
  }

  static void onBeginFrame() {
    if (_on) _push(_begins, _now);
  }

  static void onMetricsChanged() {
    if (_on) _push(_metrics, _now);
  }

  static void _onTimings(List<ui.FrameTiming> timings) {
    final now = _now;
    for (final t in timings) {
      int us(ui.FramePhase from, ui.FramePhase to) =>
          t.timestampInMicroseconds(to) - t.timestampInMicroseconds(from);
      _timings.add(
        _Timing(
          at: now,
          totalUs: t.totalSpan.inMicroseconds,
          buildUs: t.buildDuration.inMicroseconds,
          rasterUs: t.rasterDuration.inMicroseconds,
          lagUs: us(ui.FramePhase.vsyncStart, ui.FramePhase.buildStart),
          queueUs: us(ui.FramePhase.buildFinish, ui.FramePhase.rasterStart),
        ),
      );
    }
    while (_timings.isNotEmpty && _timings.first.at < now - _keepMs) {
      _timings.removeFirst();
    }
  }

  /// The caller's stack, less this class and the binding's override, the
  /// same stacks counted together.
  static void _noteStack() {
    final lines = StackTrace.current
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .skipWhile(
          (l) =>
              l.contains('CtlFrames') ||
              l.contains('ScaledWidgetsFlutterBinding.schedule'),
        )
        .take(16)
        // `#3      Foo.bar (package:…)`: the frame number differs between
        // two otherwise equal stacks
        .map((l) => l.replaceFirst(RegExp(r'^#\d+\s+'), ''))
        .join('\n');
    _traced++;
    final known = _stacks[lines];
    if (known != null) {
      _stacks[lines] = known + 1;
    } else if (_stacks.length < _maxStacks) {
      _stacks[lines] = 1;
    } else {
      _untracedKinds++;
    }
  }

  /// Takes the stack of every frame asked for, from now for [seconds]
  /// (1–120); the stacks of an earlier trace are dropped.
  static Map<String, Object?> trace(int seconds) {
    if (!_on) throw StateError('not counting: the reader is not serving');
    final s = seconds.clamp(1, 120);
    _stacks.clear();
    _traced = 0;
    _untracedKinds = 0;
    _traceUntil = _now + s * 1000;
    return {'tracing': true, 'seconds': s};
  }

  // ---------------------------------------------------------------- report

  static double _ms(int us) => (us / 100).roundToDouble() / 10;

  static Map<String, Object?> _spread(List<int> us) {
    if (us.isEmpty) return const {'count': 0};
    final sorted = [...us]..sort();
    int at(double q) =>
        sorted[math.min(sorted.length - 1, (q * sorted.length).floor())];
    return {
      'count': sorted.length,
      'p50': _ms(at(0.5)),
      'p90': _ms(at(0.9)),
      'max': _ms(sorted.last),
      'over100ms': sorted.where((v) => v > 100000).length,
    };
  }

  /// `/frames?seconds=N` (1–60, 5 by default): the last N seconds.
  static Object? endpoint(Uri uri) {
    final seconds = (int.tryParse(uri.queryParameters['seconds'] ?? '') ?? 5)
        .clamp(1, 60);
    final now = _now;
    final from = now - seconds * 1000;
    int count(ListQueue<int> q) => q.where((t) => t >= from).length;
    // timings come in batches about once a second: the window is widened
    // by one second so a batch on its edge is not lost
    final timings = _timings.where((t) => t.at >= from - 1000).toList();
    final frames = count(_begins);
    final binding = SchedulerBinding.instance;
    final view = RendererBinding.instance.renderViews.firstOrNull;
    final flutterView = view?.flutterView;
    final until = _traceUntil;
    final stacks = _stacks.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'counting': _on,
      'seconds': seconds,
      'frames': frames,
      'fps': (frames / seconds * 10).roundToDouble() / 10,
      'lastFrameAgoMs': _begins.isEmpty ? null : now - _begins.last,
      // asks that made a frame: by scheduleFrame (animations, setState,
      // markNeedsPaint…) or scheduleForcedFrame; and window metrics changes
      'requested': count(_requests),
      'forced': count(_forced),
      'metricsChanged': count(_metrics),
      // now: animation tickers waiting for the next frame, a frame pending
      'transientCallbacks': binding.transientCallbackCount,
      'frameScheduled': binding.hasScheduledFrame,
      'lifecycle': binding.lifecycleState?.name,
      'view': flutterView == null
          ? null
          : {
              'physicalWidth': flutterView.physicalSize.width,
              'physicalHeight': flutterView.physicalSize.height,
              'devicePixelRatio': flutterView.devicePixelRatio,
              'logicalWidth': view!.size.width,
              'logicalHeight': view.size.height,
            },
      'timingsMs': {
        'total': _spread([for (final t in timings) t.totalUs]),
        'build': _spread([for (final t in timings) t.buildUs]),
        'raster': _spread([for (final t in timings) t.rasterUs]),
        // from the vsync to the build's start: the UI thread busy elsewhere
        'startLag': _spread([for (final t in timings) t.lagUs]),
        // from the build's end to the raster's start: an earlier frame
        // still rastering
        'queue': _spread([for (final t in timings) t.queueUs]),
      },
      'trace': {
        'running': until != null && now <= until,
        'endsInMs': until == null ? null : math.max(0, until - now),
        'samples': _traced,
        'kinds': _stacks.length,
        'kindsNotKept': _untracedKinds,
        'top': [
          for (final e in stacks.take(10))
            {'count': e.value, 'stack': e.key.split('\n')},
        ],
      },
    };
  }
}

final class _Timing {
  const _Timing({
    required this.at,
    required this.totalUs,
    required this.buildUs,
    required this.rasterUs,
    required this.lagUs,
    required this.queueUs,
  });

  /// ms on [CtlFrames._clock] when it was reported.
  final int at;
  final int totalUs;
  final int buildUs;
  final int rasterUs;
  final int lagUs;
  final int queueUs;
}
