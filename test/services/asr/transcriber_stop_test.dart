/// The protocol of the transcription isolate, without the native models.
///
/// One isolate per session: runs are messages to it, stopping a run is a
/// flag, and the isolate leaves through its own `finally` (where the
/// recogniser is freed) only when the session closes — never killed unless
/// a decode does not return, since a killed isolate never runs it.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

/// [AsrModels.modelPath] carries a file the fake engine writes when freed,
/// so the test can see that its `finally` ran; [AsrModels.vadPath] one it
/// writes each time it is loaded.
AsrModels _models(String freed, [String loaded = '']) => (
  modelPath: freed,
  tokensPath: '',
  vadPath: loaded,
  threads: 1,
  language: '',
  japaneseSegmenter: null,
  chineseSegmenter: null,
  itn: false,
);

/// Behaves like the real engine: a blocking loop that checks the flags
/// between windows and sends a segment per window, at the run's offset.
/// A run over a path ending in `.short` ends by itself after three windows,
/// as a run does that reaches the end of its audio.
class _FakeEngine implements AsrEngine {
  _FakeEngine(this.models) {
    if (models.vadPath.isNotEmpty) {
      File(models.vadPath).writeAsStringSync('x', mode: FileMode.append);
    }
  }
  final AsrModels models;

  @override
  bool run(
    AsrRunRequest request, {
    required bool Function() stopping,
    required bool Function() paused,
    required void Function(Map<String, Object?>) send,
  }) {
    final short = request.pcmPath.endsWith('.short');
    var i = 0;
    while (!stopping()) {
      while (paused() && !stopping()) {
        sleep(const Duration(milliseconds: 2));
      }
      if (stopping()) break;
      send({
        'type': 'segment',
        'start': request.offset + i,
        'duration': 1.0,
        'lang': 'en',
        'weight': 3,
      });
      send({
        'type': 'progress',
        'done': request.offset + i + 1.0,
        'total': request.offset + 100.0,
      });
      i++;
      if (short && i == 3) return true;
      sleep(const Duration(milliseconds: 5));
    }
    return false;
  }

  @override
  void free() => File(models.modelPath).writeAsStringSync('freed');
}

void _fake(AsrIsolateArgs args) => asrServe(args, _FakeEngine.new);

/// A decode that never returns.
class _StuckEngine extends _FakeEngine {
  _StuckEngine(super.models);

  @override
  bool run(
    AsrRunRequest request, {
    required bool Function() stopping,
    required bool Function() paused,
    required void Function(Map<String, Object?>) send,
  }) {
    var i = 0;
    while (true) {
      i++;
      if (i < 0) break;
    }
    return false;
  }
}

void _stuck(AsrIsolateArgs args) => asrServe(args, _StuckEngine.new);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcriber_stop'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<T> first<T extends AsrEvent>(
    AsrTranscriber transcriber, [
    bool Function(T)? where,
  ]) => transcriber.events
      .where((e) => e is T && (where?.call(e) ?? true))
      .cast<T>()
      .first
      .timeout(const Duration(seconds: 5));

  test('runs are messages to one isolate, the models loaded once', () async {
    final loaded = '${dir.path}/loaded';
    final freed = '${dir.path}/freed';
    final transcriber = await AsrTranscriber.spawn(
      _fake,
      _models(freed, loaded),
    );
    final a = transcriber.run(pcmPath: 'a', offset: 0);
    final firstA = await first<AsrSegmentEvent>(transcriber);
    expect(firstA.run, a);
    expect(firstA.start, 0);

    // a second run stops the first, and its times carry its offset
    final ended = first<AsrRunEndEvent>(transcriber, (e) => e.run == a);
    final b = transcriber.run(pcmPath: 'b', offset: 600);
    final endA = await ended;
    expect(endA.eof, isFalse);
    final firstB = await first<AsrSegmentEvent>(
      transcriber,
      (e) => e.run == b,
    );
    expect(firstB.start, 600);

    // a run that reaches the end of its audio says so
    final c = transcriber.run(pcmPath: 'c.short', offset: 30);
    final endC = await first<AsrRunEndEvent>(transcriber, (e) => e.run == c);
    expect(endC.eof, isTrue);
    expect(endC.played, 33);

    expect(File(loaded).readAsStringSync(), 'x');
    expect(File(freed).existsSync(), isFalse);
    transcriber.close();
    await transcriber.exited.timeout(const Duration(seconds: 5));
    expect(transcriber.killed, isFalse);
    expect(File(freed).existsSync(), isTrue);
  });

  test('stopping a run is a flag: the isolate stays for the next', () async {
    final transcriber = await AsrTranscriber.spawn(
      _fake,
      _models('${dir.path}/freed'),
    );
    final a = transcriber.run(pcmPath: 'a', offset: 0);
    await first<AsrSegmentEvent>(transcriber);
    final clock = Stopwatch()..start();
    final ended = first<AsrRunEndEvent>(transcriber, (e) => e.run == a);
    transcriber.stopRun();
    // the caller is not held up by the wind-down
    expect(clock.elapsedMilliseconds, lessThan(50));
    await ended;
    var late = 0;
    final sub = transcriber.events.listen((e) {
      if (e is AsrSegmentEvent && e.run == a) late++;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(late, 0);
    // and the same isolate takes the next run
    final b = transcriber.run(pcmPath: 'b', offset: 10);
    final next = await first<AsrSegmentEvent>(transcriber, (e) => e.run == b);
    expect(next.start, 10);
    await sub.cancel();
    transcriber.close();
    await transcriber.exited.timeout(const Duration(seconds: 5));
    expect(transcriber.killed, isFalse);
  });

  test('a run stopped before the isolate reads it never starts', () async {
    final transcriber = await AsrTranscriber.spawn(
      _fake,
      _models('${dir.path}/freed'),
    );
    // queued before the models are loaded, and given up at once
    final a = transcriber.run(pcmPath: 'a', offset: 0);
    transcriber.stopRun();
    final end = await first<AsrRunEndEvent>(transcriber, (e) => e.run == a);
    expect(end.eof, isFalse);
    expect(end.played, 0);
    transcriber.close();
    await transcriber.exited.timeout(const Duration(seconds: 5));
  });

  test('a paused run waits, and goes on where it was', () async {
    final transcriber = await AsrTranscriber.spawn(
      _fake,
      _models('${dir.path}/freed'),
    );
    final starts = <double>[];
    final sub = transcriber.events.listen((e) {
      if (e is AsrSegmentEvent) starts.add(e.start);
    });
    transcriber.run(pcmPath: 'a', offset: 0);
    await first<AsrSegmentEvent>(transcriber);
    transcriber.pause(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final held = starts.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // at most the window under way when the flag was set
    expect(starts.length, held);
    transcriber.pause(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(starts.length, greaterThan(held));
    // no window skipped, none repeated: the same run carried on
    for (var i = 0; i < starts.length; i++) {
      expect(starts[i], i.toDouble());
    }
    await sub.cancel();
    transcriber.close();
    await transcriber.exited.timeout(const Duration(seconds: 5));
  });

  test(
    'closing a paused run lets the isolate leave through its finally',
    () async {
      final freed = '${dir.path}/freed';
      final transcriber = await AsrTranscriber.spawn(_fake, _models(freed));
      transcriber.run(pcmPath: 'a', offset: 0);
      await first<AsrSegmentEvent>(transcriber);
      transcriber.pause(true);
      var afterClose = 0;
      transcriber.events.listen((_) => afterClose++);
      transcriber.close();
      await transcriber.exited.timeout(const Duration(seconds: 5));
      expect(transcriber.killed, isFalse);
      expect(File(freed).existsSync(), isTrue);
      // nothing reaches a listener once closed, as when it was killed
      expect(afterClose, 0);
    },
  );

  test('an isolate that does not stop is killed after the grace', () async {
    final freed = '${dir.path}/freed';
    final transcriber = await AsrTranscriber.spawn(
      _stuck,
      _models(freed),
      grace: const Duration(milliseconds: 300),
    );
    transcriber.run(pcmPath: 'a', offset: 0);
    await transcriber.ready;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    transcriber.close();
    await transcriber.exited.timeout(const Duration(seconds: 5));
    expect(transcriber.killed, isTrue);
    // killed: the finally did not run — the leak this net still has
    expect(File(freed).existsSync(), isFalse);
  });

  test('one job runs once and closes, as before runs', () async {
    final freed = '${dir.path}/freed';
    final transcriber = await AsrTranscriber.spawn(_fake, _models(freed));
    transcriber
      ..events
          .firstWhere((e) => e is AsrRunEndEvent)
          .then((_) => transcriber.close())
      ..run(pcmPath: 'x.short', offset: 0, follow: false);
    final events = await transcriber.events.toList().timeout(
      const Duration(seconds: 5),
    );
    expect(events.whereType<AsrSegmentEvent>().length, 3);
    await transcriber.exited.timeout(const Duration(seconds: 5));
    transcriber
      ..close()
      ..close();
    expect(transcriber.killed, isFalse);
  });

  test('the language vote is the session\'s, and settles', () {
    final vote = AsrLanguageVote();
    // a noisy opening in the wrong language
    expect(vote.add('en', 6), 'en');
    expect(vote.add('ja', 30), 'ja');
    // another run starting on a quote in English does not flip it
    expect(vote.add('en', 20), isNull);
    expect(vote.winner, 'ja');
    for (var i = 0; i < 10; i++) {
      vote.add('ja', 30);
    }
    expect(vote.fixed, isTrue);
    // fixed: even a long stretch of something else no longer counts
    expect(vote.add('en', 1000), isNull);
    expect(vote.winner, 'ja');
  });

  test('a following reader stops waiting when told to', () async {
    final pcm = File('${dir.path}/empty.pcm')..writeAsBytesSync(const []);
    // on its own isolate, as in the app: the wait is a blocking sleep loop
    final clock = Stopwatch()..start();
    final windows = await Isolate.run(() {
      final started = DateTime.now();
      final reader = PcmWindowReader(
        pcm.path,
        follow: true,
        idleTimeout: const Duration(seconds: 30),
        stopped: () =>
            DateTime.now().difference(started) >
            const Duration(milliseconds: 300),
      );
      final count = reader.windows().length;
      reader.close();
      return count;
    });
    expect(windows, 0);
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('a held reader does not give up waiting', () async {
    final pcm = File('${dir.path}/held.pcm')..writeAsBytesSync(const []);
    final windows = await Isolate.run(() {
      final started = DateTime.now();
      bool after(int ms) =>
          DateTime.now().difference(started) > Duration(milliseconds: ms);
      final reader = PcmWindowReader(
        pcm.path,
        follow: true,
        idleTimeout: const Duration(milliseconds: 200),
        // held for 600 ms — three idle timeouts — then stopped
        held: () => !after(600),
        stopped: () => after(900),
      );
      final count = reader.windows().length;
      reader.close();
      return (count, DateTime.now().difference(started).inMilliseconds);
    });
    expect(windows.$1, 0);
    // it waited through the hold instead of ending at the first timeout
    expect(windows.$2, greaterThanOrEqualTo(600));
  });
}
