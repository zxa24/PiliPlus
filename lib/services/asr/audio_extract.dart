/// LibrePili: get 16 kHz mono PCM out of whatever the player is playing,
/// without ffmpeg and without downloading the video a second time.
///
/// A hidden second libmpv instance decodes with `vid=no` straight into a raw
/// file. Measured: 212 s of audio in 0.28 s on the PC and 0.84 s on a Pixel
/// 4 XL, and over the network it pulls the audio stream only (5.4 MB for a
/// 3.5-minute clip, the video stream contributing ~262 KB of headers).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/mpv_ffi.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// What the recogniser wants: SenseVoice and Silero VAD are both 16 kHz mono.
const asrSampleRate = 16000;

/// Bytes per second of the extracted stream (s16le mono).
const asrBytesPerSecond = asrSampleRate * 2;

class AsrExtractException implements Exception {
  const AsrExtractException(this.message);
  final String message;
  @override
  String toString() => 'AsrExtractException: $message';
}

typedef AsrExtractResult = ({String path, double durationSeconds});

/// Arguments crossing the isolate boundary: everything here must be a plain
/// value.
typedef _ExtractArgs = ({
  String source,
  String output,
  String? referer,
  String? userAgent,
  int timeoutSeconds,
  String? cancelPath,
  double? startSeconds,
});

abstract final class AsrAudioExtractor {
  /// Where a run started at a position records where it really landed.
  static String landingFileFor(String output) => '$output.landing.json';

  /// Decodes [source] — a URL, a plain path, or `fdclose://<fd>` — into raw
  /// signed 16-bit little-endian mono samples at [asrSampleRate].
  ///
  /// The file is *headerless* on purpose: mpv's `ao=pcm` writes a
  /// WAVE_FORMAT_EXTENSIBLE header (format tag `0xFFFE`) that sherpa-onnx's
  /// wave reader silently rejects — it returns `sampleRate == 0` and says
  /// nothing. Raw samples sidestep the whole question.
  ///
  /// Runs on its own isolate: the mpv event loop is a blocking poll and would
  /// otherwise stall the UI for the length of the extraction.
  static Future<AsrExtractResult> extract({
    required String source,
    required String output,
    String? referer,
    String? userAgent,
    Duration timeout = const Duration(minutes: 30),
    ValueChanged<double>? onSeconds,
    String? cancelPath,
    double? startSeconds,
  }) async {
    final file = File(output);
    if (file.existsSync()) await file.delete();
    await file.parent.create(recursive: true);
    // a marker left over from a previous run would stop this one immediately
    if (cancelPath != null) {
      final cancel = File(cancelPath);
      if (cancel.existsSync()) await cancel.delete();
    }
    final done = File(PcmWindowReader.doneMarkerFor(output));
    if (done.existsSync()) await done.delete();

    Timer? ticker;
    if (onSeconds != null) {
      // the isolate has nothing to report until it is done, but the output
      // file grows at a fixed rate, so its size *is* the progress
      ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        try {
          if (file.existsSync()) {
            onSeconds(file.lengthSync() / asrBytesPerSecond);
          }
        } catch (_) {}
      });
    }
    try {
      final args = (
        source: source,
        output: output,
        referer: referer,
        userAgent: userAgent,
        timeoutSeconds: timeout.inSeconds,
        cancelPath: cancelPath,
        startSeconds: startSeconds,
      );
      final bytes = await _spawn(args);
      if (bytes <= 0) {
        throw const AsrExtractException('没有解出音频');
      }
      return (path: output, durationSeconds: bytes / asrBytesPerSecond);
    } finally {
      ticker?.cancel();
      // Whatever happened — finished, failed, cancelled — a reader following
      // this file has to be told to stop waiting. Written here rather than
      // inside the isolate so it cannot be missed on the throwing paths, and
      // only once the isolate has returned, which is when the last bytes are
      // on disk.
      try {
        done.writeAsStringSync(
          file.existsSync() ? '${file.lengthSync()}' : '0',
        );
      } catch (_) {}
    }
  }

  /// Spawns the isolate from a scope that holds nothing but [args].
  ///
  /// `Isolate.run` sends the closure together with the whole context object
  /// of its enclosing scope, not only the variables it reads. Calling it
  /// directly from [extract] dragged that method's progress `Timer` along,
  /// and a Timer cannot cross an isolate boundary: every run failed before
  /// decoding started with "object is unsendable - Class: _Timer". It never
  /// showed on the desktop because the self-test passes no progress callback,
  /// so no Timer existed there.
  static Future<int> _spawn(_ExtractArgs args) =>
      Isolate.run(() => _extract(args));

  /// Runs entirely inside the spawned isolate.
  static int _extract(_ExtractArgs args) {
    final mpv = Mpv.open();
    final ctx = mpv.create();
    if (ctx == nullptr) throw const AsrExtractException('无法创建解码实例');
    try {
      final headers = [
        if (args.referer != null) 'Referer: ${args.referer}',
        if (args.userAgent != null) 'User-Agent: ${args.userAgent}',
      ];
      final options = {
        'vid': 'no',
        'sid': 'no',
        'ao': 'pcm',
        'ao-pcm-file': args.output,
        // raw samples, no RIFF header (see the doc comment above)
        'ao-pcm-waveheader': 'no',
        'audio-samplerate': '$asrSampleRate',
        'audio-channels': 'mono',
        'audio-format': 's16',
        // no `speed` override: the pcm AO is untimed already — the measured
        // run decoded 212 s in 0.28 s — and adding an untested option to a
        // verified configuration only risks changing the samples
        'keep-open': 'no',
        // from a position rather than the start (chunked transcription,
        // research/chunked-transcription-design-2026-09-25.md): an exact
        // seek, and where it really landed is measured, not assumed
        if (args.startSeconds case final start?) ...{
          'start': '$start',
          'hr-seek': 'yes',
        },
        'terminal': 'no',
        'msg-level': 'all=warn',
        if (headers.isNotEmpty) 'http-header-fields': headers.join(','),
      };
      for (final option in options.entries) {
        final rc = mpv.setOption(ctx, option.key, option.value);
        if (rc < 0 && kDebugMode) {
          debugPrint('asr: mpv option ${option.key} rejected ($rc)');
        }
      }
      if (mpv.initialize(ctx) < 0) {
        throw const AsrExtractException('解码实例初始化失败');
      }
      mpv.requestLogMessages(ctx, 'error');
      if (mpv.command(ctx, ['loadfile', args.source]) < 0) {
        throw const AsrExtractException('无法打开音频流');
      }

      final started = DateTime.now();
      final errors = <String>[];
      var ended = false;
      // when a start position was asked for: where decoding really began
      // and how long each step took, written next to the output
      final landing = <String, Object?>{'requested': args.startSeconds};
      final output = File(args.output);
      // Leaving the page has to stop the decode. It used to run to the end
      // regardless, which only wasted the tail of a download nobody was
      // waiting for; now that playback starts while this is still going, a
      // user who moves on would otherwise leave it pulling the whole stream.
      final cancel = args.cancelPath == null ? null : File(args.cancelPath!);
      while (DateTime.now().difference(started).inSeconds <
          args.timeoutSeconds) {
        if (cancel != null && cancel.existsSync()) break;
        final event = mpv.waitEvent(ctx, 0.1);
        switch (event.ref.eventId) {
          case MpvEventId.logMessage:
            final message = event.ref.data.cast<MpvLogMessage>();
            errors.add(message.ref.text.toDartString().trim());
          case MpvEventId.endFile:
            ended = true;
          case MpvEventId.shutdown:
            ended = true;
          case MpvEventId.playbackRestart:
            if (args.startSeconds != null && !landing.containsKey('audioPts')) {
              landing
                ..['restartMs'] = DateTime.now()
                    .difference(started)
                    .inMilliseconds
                ..['audioPts'] = double.tryParse(
                  mpv.property(ctx, 'audio-pts') ?? '',
                )
                ..['timePos'] = double.tryParse(
                  mpv.property(ctx, 'time-pos') ?? '',
                )
                ..['bytesAtRestart'] = output.existsSync()
                    ? output.lengthSync()
                    : 0;
            }
        }
        if (args.startSeconds != null &&
            !landing.containsKey('firstBytesMs') &&
            output.existsSync() &&
            output.lengthSync() > 0) {
          landing['firstBytesMs'] = DateTime.now()
              .difference(started)
              .inMilliseconds;
        }
        if (ended) break;
      }
      final size = File(args.output).existsSync()
          ? File(args.output).lengthSync()
          : 0;
      if (!ended && size == 0) {
        throw const AsrExtractException('音频提取超时');
      }
      if (size == 0 && errors.isNotEmpty) {
        throw AsrExtractException(errors.first);
      }
      if (args.startSeconds != null) {
        try {
          File(landingFileFor(args.output)).writeAsStringSync(
            jsonEncode(landing..['bytes'] = size),
          );
        } catch (_) {}
      }
      return size;
    } finally {
      mpv.destroy(ctx);
    }
  }
}
