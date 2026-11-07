/// A run that starts from 0 over text already known (a source that cannot
/// seek, after a suspend or with a cache) decodes the audio before it but
/// does not recognise it: the reader starts past it, and the run's times
/// count from where it starts.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

/// Little-endian s16 for [samples].
Uint8List _encode(List<int> samples) {
  final bytes = BytesBuilder();
  for (final sample in samples) {
    bytes
      ..addByte(sample & 0xFF)
      ..addByte((sample >> 8) & 0xFF);
  }
  return bytes.toBytes();
}

/// Samples whose value is their own index: whatever is read says where in
/// the file it came from.
List<int> _indexed(int from, int to) => [for (var i = from; i < to; i++) i];

/// Each sample read back as its index.
List<int> _indices(Iterable<Float32List> windows) => [
  for (final w in windows)
    for (final v in w) (v * 32768).round(),
];

AsrModels _models() => (
  modelPath: '',
  tokensPath: '',
  vadPath: '',
  threads: 1,
  language: '',
  japaneseSegmenter: null,
  chineseSegmenter: null,
  itn: false,
  english: null,
  englishFirst: false,
);

/// Wired as the real engine is: the reader starts where [asrRunStart]
/// says, and every time it reports is that start's offset plus samples
/// read. Each window is a segment whose weight is its first sample, which
/// is the index of that sample in the PCM.
class _ReadingEngine implements AsrEngine {
  _ReadingEngine(AsrModels _);

  @override
  bool run(
    AsrRunRequest request, {
    required bool Function() stopping,
    required bool Function() paused,
    required void Function(Map<String, Object?>) send,
  }) {
    final start = asrRunStart(request);
    final reader = PcmWindowReader(
      request.pcmPath,
      follow: request.follow,
      stopped: stopping,
      startSample: start.sample,
    );
    var at = 0;
    for (final window in reader.windows()) {
      if (stopping()) break;
      send({
        'type': 'segment',
        'start': start.offset + at / asrSampleRate,
        'duration': asrVadWindow / asrSampleRate,
        'weight': (window[0] * 32768).round(),
      });
      at += asrVadWindow;
    }
    reader.close();
    return !stopping();
  }

  @override
  void free() {}
}

void _reading(AsrIsolateArgs args) => asrServe(args, _ReadingEngine.new);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('asr_skip_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(List<int> samples) {
    final file = File('${dir.path}/run.pcm')
      ..writeAsBytesSync(_encode(samples));
    return file.path;
  }

  group('reader started past the start of the file', () {
    test('nothing before the start sample is read', () {
      final path = write(_indexed(0, 2000));
      final reader = PcmWindowReader(path, startSample: 700);
      final read = _indices(reader.windows());
      final samplesRead = reader.samplesRead;
      reader.close();
      // 1300 samples from 700: three windows, the last zero-padded
      expect(read.take(1300), _indexed(700, 2000));
      expect(read.skip(1300).every((v) => v == 0), isTrue);
      expect(samplesRead, 1300);
    });

    test('its length counts from the start sample', () {
      final path = write(_indexed(0, 32000));
      final reader = PcmWindowReader(path, startSample: 16000);
      expect(reader.durationSeconds, 1.0);
      reader.close();
    });

    test(
      'a file still short of the start is waited for, not given up',
      () async {
        // the decoder has to get through what is known first: it writes
        // short of the start for longer than the idle timeout, which must
        // not be taken for a decoder that died
        const window = asrVadWindow;
        const start = 4 * window;
        final path = write(_indexed(0, window));
        final file = File(path);
        final reading = Isolate.run(() {
          final reader = PcmWindowReader(
            path,
            follow: true,
            idleTimeout: const Duration(milliseconds: 300),
            startSample: start,
          );
          final read = _indices(reader.windows());
          reader.close();
          return read;
        });
        for (var i = 1; i < 7; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          file.writeAsBytesSync(
            _encode(_indexed(i * window, (i + 1) * window)),
            mode: FileMode.append,
          );
        }
        File(PcmWindowReader.doneMarkerFor(path)).writeAsStringSync('done eof');
        final read = await reading;
        expect(read, _indexed(start, 7 * window));
      },
    );
  });

  group('where a run starts', () {
    AsrRunRequest request(double offset, double skip) =>
        (id: 1, pcmPath: '', offset: offset, follow: false, skip: skip);

    test('no skip: the start of the PCM, at its offset', () {
      final start = asrRunStart(request(30, 0));
      expect(start.sample, 0);
      expect(start.offset, 30);
    });

    test('a skip: that many seconds in, on a whole sample', () {
      var start = asrRunStart(request(0, 600));
      expect(start.sample, 600 * asrSampleRate);
      expect(start.offset, 600);
      start = asrRunStart(request(5, 12.3456));
      expect(start.sample, 197530);
      // the time of the sample really read first, not the one asked for
      expect(start.offset, 5 + 197530 / asrSampleRate);
    });
  });

  test(
    'through the isolate: no audio before the skip is recognised, and '
    'times are where the audio is in the media',
    () async {
      // 2 s of audio; the first second is known
      final path = write(_indexed(0, 2 * asrSampleRate));
      final transcriber = await AsrTranscriber.spawn(_reading, _models());
      final segments = <AsrSegmentEvent>[];
      final sub = transcriber.events.listen((e) {
        if (e is AsrSegmentEvent) segments.add(e);
      });
      final run = transcriber.run(
        pcmPath: path,
        offset: 0,
        follow: false,
        skip: 1,
      );
      final end = await transcriber.events
          .firstWhere((e) => e is AsrRunEndEvent && e.run == run)
          .timeout(const Duration(seconds: 10));
      await sub.cancel();
      transcriber.close();
      await transcriber.exited.timeout(const Duration(seconds: 5));

      expect((end as AsrRunEndEvent).eof, isTrue);
      expect(segments, isNotEmpty);
      // not one window from before the skip reached the engine
      expect(segments.first.weight, asrSampleRate);
      expect(segments.first.start, 1.0);
      for (final s in segments) {
        expect(s.weight, greaterThanOrEqualTo(asrSampleRate));
        // each segment's time is that of the audio it came from
        expect(s.start * asrSampleRate, closeTo(s.weight, 1e-6));
      }
      // 1 s from the skip: 31.25 windows, the last one padded
      expect(segments, hasLength((asrSampleRate / asrVadWindow).ceil()));
    },
  );
}
