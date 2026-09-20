/// LibrePili: run the recogniser over extracted PCM, on a background isolate.
///
/// A 20-second speech segment costs roughly two seconds of arm64 CPU, so none
/// of this can touch the UI isolate. Cues are streamed out as they are decoded
/// rather than returned at the end: a subtitle that appears for the part
/// already watched is worth more than a complete one that arrives later.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
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

      final reader = _PcmReader(job.pcmPath);
      final total = reader.durationSeconds;
      var reportedLanguage = false;
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

          if (!reportedLanguage && result.lang.isNotEmpty) {
            reportedLanguage = true;
            send.send({
              'type': 'language',
              'language': AsrCueBuilder.tagValue(result.lang),
            });
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
        final done = reader.positionSeconds;
        if (done - lastProgress >= 1) {
          lastProgress = done;
          send.send({'type': 'progress', 'done': done, 'total': total});
        }
      }
      vad.flush();
      drain();
      reader.close();
      send.send({'type': 'progress', 'done': total, 'total': total});
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

/// Streams the headerless s16le file in VAD-sized windows so a two-hour video
/// never has to be in memory at once (it would be 230 MB of float32).
class _PcmReader {
  _PcmReader(String path)
    : _file = File(path).openSync(),
      _length = File(path).lengthSync();

  static const _window = 512;
  static const _blockSamples = 1 << 15;

  final RandomAccessFile _file;
  final int _length;
  var _samplesRead = 0;

  double get durationSeconds => _length / 2 / asrSampleRate;

  double get positionSeconds => _samplesRead / asrSampleRate;

  Iterable<Float32List> windows() sync* {
    final carry = Float32List(_window);
    var carried = 0;
    while (true) {
      final bytes = _file.readSync(_blockSamples * 2);
      if (bytes.isEmpty) break;
      final samples = Int16List.sublistView(
        Uint8List.fromList(bytes),
        0,
        bytes.length ~/ 2,
      );
      var offset = 0;
      while (offset < samples.length) {
        if (carried > 0 || samples.length - offset < _window) {
          final take = (_window - carried).clamp(0, samples.length - offset);
          for (var i = 0; i < take; i++) {
            carry[carried + i] = samples[offset + i] / 32768.0;
          }
          carried += take;
          offset += take;
          if (carried == _window) {
            _samplesRead += _window;
            carried = 0;
            yield Float32List.fromList(carry);
          }
        } else {
          final window = Float32List(_window);
          for (var i = 0; i < _window; i++) {
            window[i] = samples[offset + i] / 32768.0;
          }
          offset += _window;
          _samplesRead += _window;
          yield window;
        }
      }
    }
    if (carried > 0) {
      _samplesRead += carried;
      yield Float32List.sublistView(carry, 0, carried);
    }
  }

  void close() => _file.closeSync();
}
