/// LibrePili: run the recogniser over extracted PCM, on a background isolate.
///
/// A 20-second speech segment costs roughly two seconds of arm64 CPU, so none
/// of this can touch the UI isolate. Cues are streamed out as they are decoded
/// rather than returned at the end: a subtitle that appears for the part
/// already watched is worth more than a complete one that arrives later.
library;

import 'dart:async';

import 'dart:isolate';


import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
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
  const AsrSegmentEvent(this.start, this.duration);
  final double start;
  final double duration;
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
});

class AsrTranscriber {
  AsrTranscriber._(this._isolate, this._port, this.events);

  final Isolate _isolate;
  final ReceivePort _port;
  final Stream<AsrEvent> events;
  var _stopped = false;

  /// Starts transcription and returns immediately; consume [events].
  static Future<AsrTranscriber> start(AsrJob job) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_run, (job: job, send: port.sendPort));
    final controller = StreamController<AsrEvent>.broadcast();
    port.listen((message) {
      switch (message) {
        case {'type': 'cues', 'cues': final List raw}:
          controller.add(
            AsrCuesEvent([
              for (final cue in raw.cast<Map>())
                AsrCue(
                  from: cue['from'] as double,
                  to: cue['to'] as double,
                  content: cue['content'] as String,
                ),
            ]),
          );
        case {'type': 'progress', 'done': final double d, 'total': final double t}:
          controller.add(AsrProgressUpdate(d, t));
        case {'type': 'language', 'language': final String lang}:
          controller.add(AsrLanguageEvent(lang));
        case {
          'type': 'segment',
          'start': final double start,
          'duration': final double duration,
        }:
          controller.add(AsrSegmentEvent(start, duration));
        case {'type': 'error', 'message': final String message}:
          controller.add(AsrErrorEvent(message));
        case {'type': 'done'}:
          controller.close();
          port.close();
      }
    },
    // a killed isolate never sends 'done'; close on the port itself so the
    // caller's `await` for completion cannot hang forever
    onDone: controller.close);
    return AsrTranscriber._(isolate, port, controller.stream);
  }

  /// Abandons the job. The models are freed with the isolate.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _isolate.kill(priority: Isolate.immediate);
    _port.close();
  }

  /// The isolate entry point. Everything below runs off the UI thread.
  static void _run(({AsrJob job, SendPort send}) args) {
    final send = args.send;
    final job = args.job;
    sherpa.OfflineRecognizer? recognizer;
    sherpa.VoiceActivityDetector? vad;
    try {
      sherpa.initBindings();
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
              useInverseTextNormalization: true,
            ),
            tokens: job.tokensPath,
            numThreads: job.threads,
          ),
        ),
      );
      // segment offsets are counted from the last reset, not from zero
      vad.reset();

      final reader = PcmWindowReader(job.pcmPath, follow: job.follow);
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
        while (!vad!.isEmpty()) {
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

          send.send({
            'type': 'segment',
            'start': start,
            'duration': duration,
          });
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
          final cues = AsrCueBuilder.fromSegment(
            offset: start,
            duration: duration,
            text: result.text,
            tokens: _tokens(result),
          );
          if (cues.isNotEmpty) {
            send.send({'type': 'cues', 'cues': cues.toJson()});
          }
        }
      }

      for (final window in reader.windows()) {
        vad.acceptWaveform(window);
        drain();
        final done = reader.samplesRead / asrSampleRate;
        if (done - lastProgress >= 1) {
          lastProgress = done;
          if (job.follow) total = reader.durationSeconds;
          send.send({'type': 'progress', 'done': done, 'total': total});
        }
      }
      // only once the reader has really ended: in follow mode it returns
      // when the extractor's marker appears, not at the first empty read
      vad.flush();
      drain();
      final played = reader.samplesRead / asrSampleRate;
      reader.close();
      send.send({'type': 'progress', 'done': played, 'total': played});
    } catch (e) {
      send.send({'type': 'error', 'message': e.toString()});
    } finally {
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
