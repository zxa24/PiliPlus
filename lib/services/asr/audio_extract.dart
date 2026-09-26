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

/// [reachedEnd]: decoding stopped at the end of the media, rather than
/// being cancelled or cut short by an error.
typedef AsrExtractResult = ({
  String path,
  double durationSeconds,
  bool reachedEnd,
});

/// What the extraction isolate hands back.
typedef _ExtractOutcome = ({int bytes, bool reachedEnd});

/// Arguments crossing the isolate boundary: everything here must be a plain
/// value.
typedef _ExtractArgs = ({
  String source,
  String output,
  String? referer,
  String? userAgent,
  int timeoutSeconds,
  String? cancelPath,
  String? pausePath,
  double? startSeconds,
});

abstract final class AsrAudioExtractor {
  /// Where a run started at a position records where it really landed.
  static String landingFileFor(String output) => '$output.landing.json';

  /// While this file exists, decoding is paused and — the demuxer's
  /// read-ahead being capped — nothing more is downloaded (design 4.4: a
  /// run far enough ahead of the viewer pauses instead of stopping).
  static String pauseFileFor(String output) => '$output.pause';

  /// Whether [message] (an extraction error) is the server refusing the
  /// URL — a signed stream URL that has expired, which a fresh URL fixes.
  static bool isForbidden(Object message) =>
      RegExp(r'\b403\b|Forbidden').hasMatch(message.toString());

  /// How far the landing a run measured may be off the position it asked
  /// for before the run is not trusted (design 14: starts measured
  /// sample-accurate by cross-correlation, while this estimate itself reads
  /// 60–110 ms late; half a second off means the seek went wrong).
  static const landingTolerance = 0.5;

  /// How much audio may be on disk when the restart is read for the
  /// estimate to mean anything. `audio-pts` is read when the event loop gets
  /// to the event, and decoding is untimed: from a local file mpv had
  /// written 18 s by then while `audio-pts` still read the start, and the
  /// estimate put a sample-accurate start 18 s early. Over the network P0
  /// saw about 4 s.
  static const landingReadable = 6 * asrBytesPerSecond;

  /// How far a run from [requested] seconds landed off it, as estimated
  /// from [landing] (the file [landingFileFor] names), or null when it
  /// cannot tell — including when decoding had run too far ahead of the
  /// event for the estimate to hold (see [landingReadable]).
  static double? landingError(Map<String, Object?> landing, double requested) {
    final pts = landing['audioPts'];
    final bytes = landing['bytesAtRestart'];
    if (pts is! num || bytes is! num) return null;
    if (bytes > landingReadable) return null;
    final landed = pts - bytes / asrBytesPerSecond;
    return landed - requested;
  }

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
    Duration timeout = const Duration(minutes: 2),
    ValueChanged<double>? onSeconds,
    String? cancelPath,
    String? pausePath,
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
    if (pausePath != null) {
      final pause = File(pausePath);
      if (pause.existsSync()) await pause.delete();
    }

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
        pausePath: pausePath,
        startSeconds: startSeconds,
      );
      final outcome = await _spawn(args);
      if (outcome.bytes <= 0) {
        throw const AsrExtractException('没有解出音频');
      }
      return (
        path: output,
        durationSeconds: outcome.bytes / asrBytesPerSecond,
        reachedEnd: outcome.reachedEnd,
      );
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
  static Future<_ExtractOutcome> _spawn(_ExtractArgs args) =>
      Isolate.run(() => _extract(args));

  /// Runs entirely inside the spawned isolate.
  static _ExtractOutcome _extract(_ExtractArgs args) {
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
        // A paused run must stop downloading too: the demuxer otherwise
        // reads ahead into its cache — up to 150 MiB by default — while
        // nothing decodes. 2 MiB is about two minutes of the audio streams
        // used here; decoding is untimed, so while it runs it drains this
        // as fast as the network fills it and the cap costs nothing. Not
        // set for local files, which download nothing.
        if (args.pausePath != null && _isNetwork(args.source))
          'demuxer-max-bytes': '2MiB',
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
      var reachedEnd = false;
      // The timeout is for a decode making no progress, not for one that is
      // slow or paused: a run can now last as long as the viewer watches,
      // paused for most of it. It used to cap the whole extraction at 30
      // minutes, after which the rest of a long video was silently dropped.
      var lastGrowth = started;
      var lastSize = 0;
      var paused = false;
      final pause = args.pausePath == null ? null : File(args.pausePath!);
      // when a start position was asked for: where decoding really began
      // and how long each step took, written next to the output
      final landing = <String, Object?>{'requested': args.startSeconds};
      final output = File(args.output);
      // Leaving the page has to stop the decode. It used to run to the end
      // regardless, which only wasted the tail of a download nobody was
      // waiting for; now that playback starts while this is still going, a
      // user who moves on would otherwise leave it pulling the whole stream.
      final cancel = args.cancelPath == null ? null : File(args.cancelPath!);
      while (DateTime.now().difference(lastGrowth).inSeconds <
          args.timeoutSeconds) {
        if (cancel != null && cancel.existsSync()) break;
        if (pause != null) {
          final wanted = pause.existsSync();
          if (wanted != paused) {
            paused = wanted;
            mpv.setProperty(ctx, 'pause', paused ? 'yes' : 'no');
          }
        }
        final event = mpv.waitEvent(ctx, 0.1);
        switch (event.ref.eventId) {
          case MpvEventId.logMessage:
            final message = event.ref.data.cast<MpvLogMessage>();
            errors.add(message.ref.text.toDartString().trim());
          case MpvEventId.endFile:
            ended = true;
            final data = event.ref.data;
            reachedEnd =
                data != nullptr &&
                data.cast<MpvEndFile>().ref.reason == MpvEndFileReason.eof;
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
              // at once, not only at the end: the session checks where the
              // run landed before it trusts the run's first segments
              try {
                File(
                  landingFileFor(args.output),
                ).writeAsStringSync(jsonEncode(landing));
              } catch (_) {}
            }
        }
        final size = output.existsSync() ? output.lengthSync() : 0;
        if (size != lastSize || paused) {
          lastSize = size;
          lastGrowth = DateTime.now();
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
        // the refusal, when there is one: it is what tells an expired URL
        // (fetch a new one) from a stream that is broken (see isForbidden)
        throw AsrExtractException(
          errors.firstWhere(isForbidden, orElse: () => errors.first),
        );
      }
      if (args.startSeconds != null) {
        try {
          File(landingFileFor(args.output)).writeAsStringSync(
            jsonEncode(landing..['bytes'] = size),
          );
        } catch (_) {}
      }
      return (bytes: size, reachedEnd: reachedEnd);
    } finally {
      mpv.destroy(ctx);
    }
  }

  static bool _isNetwork(String source) =>
      source.startsWith('http://') || source.startsWith('https://');
}
