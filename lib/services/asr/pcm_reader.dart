/// LibrePili: feeds a headerless 16-bit PCM file to the VAD in fixed windows.
///
/// Streamed rather than loaded: two hours of 16 kHz mono is 230 MB as float32,
/// which is not something to hold on a phone.
library;

import 'dart:io';
import 'dart:typed_data';

/// Samples per window. Silero's VAD wants exactly this many each time.
const asrVadWindow = 512;

class PcmWindowReader {
  PcmWindowReader(String path)
    : _file = File(path).openSync(),
      _length = File(path).lengthSync();

  /// How much of the file is read at a time.
  static const _blockBytes = 1 << 16;

  final RandomAccessFile _file;
  final int _length;
  var _samplesRead = 0;

  double get durationSeconds => _length / 2 / 16000;

  int get samplesRead => _samplesRead;

  /// Little-endian signed 16-bit samples, scaled to -1..1, in windows of
  /// [asrVadWindow].
  ///
  /// The bytes are decoded by hand rather than through `Int16List.sublistView`
  /// because a read is not guaranteed to stop on a sample boundary: one that
  /// returns an odd number of bytes made the view constructor throw
  /// ("The number of bytes to view must be a multiple of 2"), the isolate
  /// caught it, and transcription produced nothing at all with no visible
  /// error. A sample split across two reads is now carried over instead.
  ///
  /// The last window is zero-padded to the full size rather than emitted
  /// short: a short window is not what the VAD expects, and dropping the tail
  /// would lose up to 32 ms of speech.
  Iterable<Float32List> windows() sync* {
    var window = Float32List(asrVadWindow);
    var filled = 0;
    var stray = -1;

    while (true) {
      final bytes = _file.readSync(_blockBytes);
      if (bytes.isEmpty) break;
      var i = 0;
      if (stray >= 0) {
        window[filled++] = _scale(stray | (bytes[0] << 8));
        stray = -1;
        i = 1;
        if (filled == asrVadWindow) {
          _samplesRead += asrVadWindow;
          yield window;
          window = Float32List(asrVadWindow);
          filled = 0;
        }
      }
      for (; i + 1 < bytes.length; i += 2) {
        window[filled++] = _scale(bytes[i] | (bytes[i + 1] << 8));
        if (filled == asrVadWindow) {
          _samplesRead += asrVadWindow;
          yield window;
          window = Float32List(asrVadWindow);
          filled = 0;
        }
      }
      if (i < bytes.length) stray = bytes[i];
    }

    if (filled > 0) {
      _samplesRead += filled;
      // the rest of the window is already zero
      yield window;
    }
  }

  static double _scale(int unsigned) => unsigned.toSigned(16) / 32768.0;

  void close() => _file.closeSync();
}
