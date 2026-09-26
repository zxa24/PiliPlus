/// The stop protocol of the transcription isolate, without the native
/// models: a stopped isolate must leave through its own `finally` (where the
/// recogniser is freed), not be killed — a killed isolate never runs it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

AsrJob _job(String marker) => (
  pcmPath: marker,
  modelPath: '',
  tokensPath: '',
  vadPath: '',
  threads: 1,
  language: '',
  follow: false,
  japaneseSegmenter: null,
  chineseSegmenter: null,
  itn: false,
);

/// Behaves like the real body: a blocking loop that checks the flag between
/// windows, sends a segment per window, and cleans up in `finally` — which
/// here writes [AsrJob.pcmPath] so the test can see that it ran.
void _cooperative(AsrIsolateArgs args) {
  try {
    while (!asrStopRequested(args.stopFlag)) {
      args.send.send({'type': 'segment', 'start': 0.0, 'duration': 1.0});
      sleep(const Duration(milliseconds: 5));
    }
  } finally {
    File(args.job.pcmPath).writeAsStringSync('freed');
    args.send.send({'type': 'done'});
  }
}

/// A decode that never returns.
void _stuck(AsrIsolateArgs args) {
  try {
    var i = 0;
    while (true) {
      i++;
      if (i < 0) break;
    }
  } finally {
    File(args.job.pcmPath).writeAsStringSync('freed');
  }
}

/// Finishes on its own, the way a job that reaches the end of the audio does.
void _finishes(AsrIsolateArgs args) {
  args.send.send({'type': 'progress', 'done': 1.0, 'total': 1.0});
  args.send.send({'type': 'done'});
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcriber_stop'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a stop lets the isolate leave through its finally', () async {
    final marker = '${dir.path}/freed';
    final transcriber = await AsrTranscriber.spawn(_cooperative, _job(marker));
    final first = Completer<void>();
    var afterStop = 0;
    var stopped = false;
    final closed = Completer<void>();
    transcriber.events.listen(
      (event) {
        if (stopped) afterStop++;
        if (!first.isCompleted) first.complete();
      },
      onDone: closed.complete,
    );
    await first.future;

    final clock = Stopwatch()..start();
    transcriber.stop();
    stopped = true;
    // the caller is not held up by the wind-down
    expect(clock.elapsedMilliseconds, lessThan(50));

    await transcriber.exited.timeout(const Duration(seconds: 5));
    await closed.future.timeout(const Duration(seconds: 1));
    expect(transcriber.killed, isFalse);
    expect(File(marker).existsSync(), isTrue);
    // nothing reaches the listener once stopped, as when it was killed
    expect(afterStop, 0);
  });

  test('an isolate that does not stop is killed after the grace', () async {
    final marker = '${dir.path}/freed';
    final transcriber = await AsrTranscriber.spawn(
      _stuck,
      _job(marker),
      grace: const Duration(milliseconds: 300),
    );
    await Future.delayed(const Duration(milliseconds: 100));
    transcriber.stop();
    await transcriber.exited.timeout(const Duration(seconds: 5));
    expect(transcriber.killed, isTrue);
    // killed: the finally did not run — the leak this net still has
    expect(File(marker).existsSync(), isFalse);
  });

  test('a job that finished needs no stop, and a late stop is harmless', () async {
    final transcriber = await AsrTranscriber.spawn(
      _finishes,
      _job('${dir.path}/unused'),
    );
    final events = await transcriber.events.toList().timeout(
      const Duration(seconds: 5),
    );
    expect(events.single, isA<AsrProgressUpdate>());
    await transcriber.exited.timeout(const Duration(seconds: 5));
    transcriber
      ..stop()
      ..stop();
    expect(transcriber.killed, isFalse);
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
}
