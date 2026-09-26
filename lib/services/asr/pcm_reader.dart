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
  PcmWindowReader(
    String path, {
    this.follow = false,
    this.idleTimeout = const Duration(seconds: 90),
    this.stopped,
    this.held,
  }) : _path = path,
       _file = File(path).openSync();

  /// How much of the file is read at a time.
  static const _blockBytes = 1 << 16;

  /// How long to wait between checks for more data in [follow] mode.
  static const _pollInterval = Duration(milliseconds: 100);

  /// The file the extractor writes when it has finished (or given up).
  ///
  /// A plain file rather than a message because the writer and the reader are
  /// different isolates and a growing file is the only thing they share. It
  /// is written *after* the decoder is torn down, so once it exists every
  /// byte has been flushed — an empty read past it really is the end.
  static String doneMarkerFor(String pcmPath) => '$pcmPath.done';

  final String _path;
  final RandomAccessFile _file;

  /// Whether the file is still being written.
  ///
  /// Without this the reader stops at whatever the file happened to hold when
  /// it was opened. That is correct for a finished extraction and silently
  /// wrong for one still running: the rest of the audio is never transcribed,
  /// and nothing reports an error — the run just ends early.
  final bool follow;

  /// How long to keep waiting for bytes that never come. A decoder that dies
  /// without writing its marker must not wedge the reader forever.
  final Duration idleTimeout;

  /// Whether the reader's owner has given up on it. Checked while waiting
  /// for more data in [follow] mode: a stopped job's extractor is cancelled
  /// and its files deleted, so otherwise the wait could only end at
  /// [idleTimeout], with the recogniser held all the while.
  final bool Function()? stopped;

  /// Whether the owner is holding the run: its extraction is paused too, so
  /// no bytes coming meanwhile is expected, and does not count toward
  /// [idleTimeout]. Without this a run paused while the reader waited was
  /// taken, 90 s later, for a decoder that had died — and ended as if the
  /// audio had.
  final bool Function()? held;

  var _samplesRead = 0;

  /// Seconds of audio on disk so far. In [follow] mode this grows as the
  /// extractor writes, so a progress total computed from it is a lower bound
  /// rather than the final length.
  double get durationSeconds {
    try {
      return File(_path).lengthSync() / 2 / 16000;
    } catch (_) {
      return _samplesRead / 16000;
    }
  }

  int get samplesRead => _samplesRead;

  bool get _extractionFinished => File(doneMarkerFor(_path)).existsSync();

  /// Blocks until there is more to read, and answers whether there is.
  ///
  /// Synchronous on purpose: this runs on the transcription isolate, whose
  /// whole job is a blocking loop over the decoder.
  bool _waitForMore() {
    if (!follow) return false;
    var deadline = DateTime.now().add(idleTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (stopped?.call() ?? false) return false;
      if (held?.call() ?? false) {
        deadline = DateTime.now().add(idleTimeout);
      }
      // read the flag first: if extraction finished *during* the sleep, the
      // bytes it wrote are already on disk and one more read gets them
      final finished = _extractionFinished;
      if (_file.positionSync() < File(_path).lengthSync()) return true;
      if (finished) return false;
      sleep(_pollInterval);
    }
    return false;
  }

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
      var bytes = _file.readSync(_blockBytes);
      if (bytes.isEmpty) {
        if (!_waitForMore()) break;
        bytes = _file.readSync(_blockBytes);
        if (bytes.isEmpty) break;
      }
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
