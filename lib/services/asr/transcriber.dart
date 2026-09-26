/// LibrePili: run the recogniser over extracted PCM, on a background isolate.
///
/// A 20-second speech segment costs roughly two seconds of arm64 CPU, so none
/// of this can touch the UI isolate. Cues are streamed out as they are decoded
/// rather than returned at the end: a subtitle that appears for the part
/// already watched is worth more than a complete one that arrives later.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:budoux_dart/budoux.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Where the recogniser has got to, in seconds of audio.
typedef AsrProgressEvent = ({double done, double total});

sealed class AsrEvent {
  const AsrEvent();
}

class AsrCuesEvent extends AsrEvent {
  const AsrCuesEvent(this.cues);
  final List<AsrCue> cues;
}

class AsrProgressUpdate extends AsrEvent {
  const AsrProgressUpdate(this.done, this.total);
  final double done;
  final double total;
}

class AsrLanguageEvent extends AsrEvent {
  const AsrLanguageEvent(this.language);

  /// What SenseVoice reported, e.g. `zh`, `en`, `ja`, `ko`, `yue`.
  final String language;
}

/// One stretch the VAD decided was speech.
///
/// Reported so that "the video has long stretches with no subtitle" can be
/// answered: a hole the VAD also saw as silence is silence, and a hole
/// inside a segment is speech that produced no cue. Without both, the two
/// are indistinguishable.
class AsrSegmentEvent extends AsrEvent {
  const AsrSegmentEvent(
    this.start,
    this.duration, {
    this.tokens = const [],
    this.times = const [],
    this.cues = const [],
  });
  final double start;
  final double duration;

  /// The recogniser's raw pieces for this segment. Diagnostic only.
  final List<String> tokens;

  /// When each of [tokens] starts, relative to the segment. Diagnostic
  /// only: where the speaker pauses, for studying where lines should break.
  final List<double> times;

  /// The cues this segment produced, carried with it so a reader never holds
  /// a segment without its text, or text without the segment it belongs to:
  /// translation settles units on segments, and assigns a cue to the last
  /// segment known (see buildTranslationUnits). The same cues also arrive
  /// just before, as an [AsrCuesEvent], for listeners that only want text.
  final List<AsrCue> cues;
}

class AsrErrorEvent extends AsrEvent {
  const AsrErrorEvent(this.message);
  final String message;
}

typedef AsrJob = ({
  String pcmPath,
  String modelPath,
  String tokensPath,
  String vadPath,
  int threads,

  /// Empty lets SenseVoice detect; otherwise it is forced (`zh`/`en`/…).
  String language,

  /// Whether [pcmPath] is still being written. True means transcription runs
  /// alongside extraction instead of after it, which is what lets the first
  /// cues appear seconds into a video rather than after the whole audio has
  /// been pulled.
  bool follow,

  /// BudouX's Japanese model as JSON, or null. Read on the UI isolate — an
  /// asset bundle is not reachable from here — and passed in as text.
  String? japaneseSegmenter,

  /// BudouX's Simplified Chinese model as JSON, or null; see
  /// [japaneseSegmenter]. Chinese marks no words either, and without it a
  /// line past the width cap was cut wherever the cap fell: 14% of the
  /// breaks in a real transcript split a word (鱼 / 卵, 生态平 / 衡).
  String? chineseSegmenter,

  /// SenseVoice's inverse text normalisation (twenty -> 20, spoken
  /// punctuation -> marks). On in the app; a switch here so its side effects
  /// can be measured.
  bool itn,
});

/// What the transcription isolate is started with.
typedef AsrIsolateArgs = ({AsrJob job, SendPort send, int stopFlag});

/// Whether the owner has asked the isolate to stop.
///
/// A byte of native memory rather than a message: the isolate spends its
/// whole life in a blocking loop over the decoder and never returns to its
/// event loop, so a message sent to it would only be read once it had
/// finished anyway. Reading one byte per 512-sample window costs nothing.
bool asrStopRequested(int stopFlag) =>
    Pointer<Uint8>.fromAddress(stopFlag).value != 0;

class AsrTranscriber {
  AsrTranscriber._(
    this._isolate,
    this._port,
    this._stopFlag,
    this._grace,
    this.events,
  );

  final Isolate _isolate;
  final ReceivePort _port;
  final Stream<AsrEvent> events;

  /// Freed only once the isolate has exited: until then it may still read it.
  final Pointer<Uint8> _stopFlag;
  final Duration _grace;
  final _exited = Completer<void>();
  Timer? _killTimer;
  var _stopped = false;
  var _killed = false;

  /// How long a stopped isolate gets to wind down before it is killed.
  ///
  /// It checks the flag between windows and between segments, so it is
  /// normally out within one segment's decode (~2 s of arm64 CPU for the
  /// 20 s maximum). This is only the net under a decode that never returns.
  static const stopGrace = Duration(seconds: 10);

  /// Completes when the isolate is gone — by itself after a [stop], or
  /// killed after [stopGrace]. Not something the UI waits on: a stop returns
  /// at once and this completes in the background.
  Future<void> get exited => _exited.future;

  /// Whether the isolate had to be killed, and so leaked the recogniser's
  /// native memory (sherpa_onnx has no finalisers).
  bool get killed => _killed;

  /// Starts transcription and returns immediately; consume [events].
  static Future<AsrTranscriber> start(AsrJob job) => spawn(_run, job);

  /// [start] with the isolate body given, so the stop protocol can be tested
  /// without the native models.
  @visibleForTesting
  static Future<AsrTranscriber> spawn(
    void Function(AsrIsolateArgs) entry,
    AsrJob job, {
    Duration grace = stopGrace,
  }) async {
    final port = ReceivePort();
    final exit = ReceivePort();
    final flag = calloc<Uint8>();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        entry,
        (job: job, send: port.sendPort, stopFlag: flag.address),
        onExit: exit.sendPort,
      );
    } catch (_) {
      port.close();
      exit.close();
      calloc.free(flag);
      rethrow;
    }
    final controller = StreamController<AsrEvent>.broadcast();
    port.listen((message) {
      switch (message) {
        case {'type': 'progress', 'done': final double d, 'total': final double t}:
          controller.add(AsrProgressUpdate(d, t));
        case {'type': 'language', 'language': final String lang}:
          controller.add(AsrLanguageEvent(lang));
        case {
          'type': 'segment',
          'start': final double start,
          'duration': final double duration,
        }:
          final cues = switch (message) {
            {'cues': final List raw} => [
              for (final cue in raw.cast<Map>())
                AsrCue(
                  from: cue['from'] as double,
                  to: cue['to'] as double,
                  content: cue['content'] as String,
                ),
            ],
            _ => const <AsrCue>[],
          };
          if (cues.isNotEmpty) controller.add(AsrCuesEvent(cues));
          controller.add(
            AsrSegmentEvent(
              start,
              duration,
              tokens: switch (message) {
                {'tokens': final List raw} => raw.cast<String>(),
                _ => const [],
              },
              times: switch (message) {
                {'times': final List raw} => [
                  for (final t in raw) (t as num).toDouble(),
                ],
                _ => const [],
              },
              cues: cues,
            ),
          );
        case {'type': 'error', 'message': final String message}:
          controller.add(AsrErrorEvent(message));
        case {'type': 'done'}:
          controller.close();
          port.close();
      }
    },
    // a stopped job's port is closed before its isolate sends 'done'; close
    // on the port itself so the caller's `await` for completion cannot hang
    onDone: controller.close);
    final transcriber = AsrTranscriber._(
      isolate,
      port,
      flag,
      grace,
      controller.stream,
    );
    exit.first.then((_) {
      exit.close();
      transcriber._killTimer?.cancel();
      calloc.free(flag);
      transcriber._exited.complete();
    });
    return transcriber;
  }

  /// Abandons the job, and returns at once.
  ///
  /// Nothing more is delivered on [events] after this. The isolate is asked
  /// to stop rather than killed: a killed isolate never runs its `finally`,
  /// and that `finally` is what frees the recogniser and the VAD — measured
  /// at ~330 MB of native memory lost per stop on desktop before this
  /// (V0, research/chunked-transcription-design-2026-09-25.md). It winds
  /// down in the background within about one segment; see [exited].
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _port.close();
    if (_exited.isCompleted) return;
    _stopFlag.value = 1;
    _killTimer = Timer(_grace, () {
      if (_exited.isCompleted) return;
      // still leaks, as every stop used to; a decode that does not return
      // must still not keep a CPU busy for a job nobody wants
      _killed = true;
      if (kDebugMode) debugPrint('asr: isolate did not stop, killing it');
      _isolate.kill(priority: Isolate.immediate);
    });
  }

  /// The isolate entry point. Everything below runs off the UI thread.
  ///
  /// Every exit, a stop included, goes through the `finally` that frees the
  /// native objects: sherpa_onnx has no finalisers, so anything not freed
  /// there is lost for the life of the process.
  static void _run(AsrIsolateArgs args) {
    final send = args.send;
    final job = args.job;
    bool stopping() => asrStopRequested(args.stopFlag);
    sherpa.OfflineRecognizer? recognizer;
    sherpa.VoiceActivityDetector? vad;
    PcmWindowReader? reader;
    try {
      sherpa.initBindings();
      final budoux = job.japaneseSegmenter == null
          ? null
          : BudouX(job.japaneseSegmenter!);
      final budouxZh = job.chineseSegmenter == null
          ? null
          : BudouX(job.chineseSegmenter!);
      vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: job.vadPath,
            threshold: 0.5,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
            // a display cue is cut out of this by AsrCueBuilder
            maxSpeechDuration: 20,
          ),
          numThreads: 1,
        ),
        bufferSizeInSeconds: 60,
      );
      recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: job.modelPath,
              language: job.language,
              useInverseTextNormalization: job.itn,
            ),
            tokens: job.tokensPath,
            numThreads: job.threads,
          ),
        ),
      );
      // segment offsets are counted from the last reset, not from zero
      vad.reset();
      // loading the models takes a while; a stop may have come meanwhile
      if (stopping()) return;

      reader = PcmWindowReader(
        job.pcmPath,
        follow: job.follow,
        stopped: stopping,
      );
      // In follow mode the file is still growing, so this is a lower bound
      // that is re-read as the run goes; a progress bar computed from the
      // first value alone would sit at 100% for most of the job.
      var total = reader.durationSeconds;
      // Which language, decided by how much speech is in it rather than by
      // whichever segment happened to come first. A Japanese video opening
      // with two seconds of noise was recognised as 'The.' and reported as
      // English for the whole run — and the 外语自动转录 policy then makes
      // its decision, including whether to stop, on that.
      final languageWeight = <String, int>{};
      String? reportedLanguage;
      var lastProgress = 0.0;

      void drain() {
        // between segments too: a backlog of them is seconds of decoding
        while (!vad!.isEmpty() && !stopping()) {
          final segment = vad.front();
          final start = segment.start / asrSampleRate;
          final duration = segment.samples.length / asrSampleRate;
          final stream = recognizer!.createStream()
            ..acceptWaveform(
              samples: segment.samples,
              sampleRate: asrSampleRate,
            );
          recognizer.decode(stream);
          final result = recognizer.getResult(stream);
          stream.free();
          vad.pop();

          if (result.lang.isNotEmpty) {
            final lang = AsrCueBuilder.tagValue(result.lang);
            if (lang.isNotEmpty) {
              // weighted by text, so a long stretch outvotes a stray word
              languageWeight[lang] =
                  (languageWeight[lang] ?? 0) + result.text.length + 1;
              final winner = languageWeight.entries
                  .reduce((a, b) => b.value > a.value ? b : a)
                  .key;
              if (winner != reportedLanguage) {
                reportedLanguage = winner;
                send.send({'type': 'language', 'language': winner});
              }
            }
          }
          final tag = AsrCueBuilder.tagValue(result.lang);
          final japanese = tag == 'ja' || AsrCueBuilder.hasKana(result.text);
          final chinese = !japanese && (tag == 'zh' || tag == 'yue');
          final cues = AsrCueBuilder.fromSegment(
            segmenter: japanese
                ? budoux?.parse
                : (chinese ? budouxZh?.parse : null),
            planLines: chinese,
            offset: start,
            duration: duration,
            text: result.text,
            tokens: _tokens(result),
          );
          // One message with its cues: translation settles units on
          // segments, and a segment seen without its text — or text without
          // its segment, which is then counted as the previous one's — gets
          // a unit built and translated from the wrong words.
          send.send({
            'type': 'segment',
            'start': start,
            'duration': duration,
            // the raw pieces, for the probe only: how the recogniser marks a
            // word decides where a cue may end, and that cannot be guessed
            // from the joined text
            'tokens': [for (final t in _tokens(result)) t.text],
            'times': [for (final t in _tokens(result)) t.time],
            'cues': cues.toJson(),
          });
        }
      }

      for (final window in reader.windows()) {
        if (stopping()) return;
        vad.acceptWaveform(window);
        drain();
        final done = reader.samplesRead / asrSampleRate;
        if (done - lastProgress >= 1) {
          lastProgress = done;
          if (job.follow) total = reader.durationSeconds;
          send.send({'type': 'progress', 'done': done, 'total': total});
        }
      }
      // the reader also ends early when asked to stop; that is not the end
      // of the audio, and there is nobody left to send the tail to
      if (stopping()) return;
      // only once the reader has really ended: in follow mode it returns
      // when the extractor's marker appears, not at the first empty read
      vad.flush();
      drain();
      final played = reader.samplesRead / asrSampleRate;
      send.send({'type': 'progress', 'done': played, 'total': played});
    } catch (e) {
      send.send({'type': 'error', 'message': e.toString()});
    } finally {
      try {
        reader?.close();
      } catch (_) {}
      vad?.free();
      recognizer?.free();
      send.send({'type': 'done'});
    }
  }

  static List<AsrToken> _tokens(sherpa.OfflineRecognizerResult result) {
    final tokens = result.tokens;
    final timestamps = result.timestamps;
    if (tokens.isEmpty || timestamps.length != tokens.length) return const [];
    return [
      for (var i = 0; i < tokens.length; i++)
        (text: tokens[i], time: timestamps[i]),
    ];
  }
}
