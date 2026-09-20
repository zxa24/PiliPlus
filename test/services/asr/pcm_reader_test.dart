import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes [samples] as little-endian s16 and returns the path, optionally
/// with a trailing half-sample — which is what a truncated extraction leaves
/// behind and what made the old reader throw.
String _write(Directory dir, List<int> samples, {bool trailingByte = false}) {
  final bytes = BytesBuilder();
  for (final sample in samples) {
    bytes
      ..addByte(sample & 0xFF)
      ..addByte((sample >> 8) & 0xFF);
  }
  if (trailingByte) bytes.addByte(0x7F);
  final file = File('${dir.path}/test.pcm')..writeAsBytesSync(bytes.toBytes());
  return file.path;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pcm_reader_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('decodes little-endian signed samples', () {
    final path = _write(dir, [0, 1, -1, 32767, -32768, 1000]);
    final reader = PcmWindowReader(path);
    final windows = reader.windows().toList();
    reader.close();

    expect(windows, hasLength(1));
    final window = windows.single;
    expect(window.length, asrVadWindow);
    expect(window[0], 0);
    expect(window[1], closeTo(1 / 32768, 1e-9));
    expect(window[2], closeTo(-1 / 32768, 1e-9));
    expect(window[3], closeTo(32767 / 32768, 1e-9));
    expect(window[4], -1.0);
    expect(window[5], closeTo(1000 / 32768, 1e-9));
    // the tail of a short file is zero-padded, not emitted short
    expect(window[6], 0);
  });

  test('splits into exact windows and loses nothing', () {
    final samples = [
      for (var i = 0; i < asrVadWindow * 3; i++) (i % 2000) - 1000,
    ];
    final path = _write(dir, samples);
    final reader = PcmWindowReader(path);
    final flat = <double>[
      for (final window in reader.windows()) ...window,
    ];
    reader.close();

    expect(flat, hasLength(samples.length));
    for (var i = 0; i < samples.length; i++) {
      expect(flat[i], closeTo(samples[i] / 32768, 1e-9), reason: 'at $i');
    }
  });

  test('a file that is not a whole number of windows pads the last one', () {
    final samples = [for (var i = 0; i < asrVadWindow + 7; i++) 100 + i];
    final path = _write(dir, samples);
    final reader = PcmWindowReader(path);
    final windows = reader.windows().toList();
    reader.close();

    expect(windows, hasLength(2));
    expect(windows.last.length, asrVadWindow);
    expect(windows.last[6], closeTo((100 + asrVadWindow + 6) / 32768, 1e-9));
    expect(windows.last[7], 0);
    expect(reader.samplesRead, samples.length);
  });

  test('a trailing half sample does not throw and is ignored', () {
    // the regression: `Int16List.sublistView` over an odd-length buffer threw
    // "The number of bytes to view must be a multiple of 2", the isolate
    // swallowed it, and transcription silently produced no subtitles at all
    final samples = [for (var i = 0; i < 1200; i++) i - 600];
    final path = _write(dir, samples, trailingByte: true);
    final reader = PcmWindowReader(path);
    final flat = <double>[
      for (final window in reader.windows()) ...window,
    ];
    reader.close();

    expect(flat.length, greaterThanOrEqualTo(samples.length));
    for (var i = 0; i < samples.length; i++) {
      expect(flat[i], closeTo(samples[i] / 32768, 1e-9), reason: 'at $i');
    }
  });

  test('crosses the 64 KiB read block without corrupting a sample', () {
    // a block boundary lands mid-sample for an odd number of samples per block
    final random = Random(7);
    final samples = [
      for (var i = 0; i < 70000; i++) random.nextInt(65536) - 32768,
    ];
    final path = _write(dir, samples);
    final reader = PcmWindowReader(path);
    final flat = <double>[
      for (final window in reader.windows()) ...window,
    ];
    reader.close();

    for (var i = 0; i < samples.length; i++) {
      expect(flat[i], closeTo(samples[i] / 32768, 1e-9), reason: 'at $i');
    }
  });

  test('an empty file yields nothing', () {
    final path = _write(dir, const []);
    final reader = PcmWindowReader(path);
    expect(reader.windows().toList(), isEmpty);
    expect(reader.durationSeconds, 0);
    reader.close();
  });
}
