/// LibrePili: run the recogniser over extracted PCM, on a background isolate.
///
/// A 20-second speech segment costs roughly two seconds of arm64 CPU, so none
/// of this can touch the UI isolate. Cues are streamed out as they are decoded
/// rather than returned at the end: a subtitle that appears for the part
/// already watched is worth more than a complete one that arrives later.
///
/// One isolate per session, with the models loaded once
/// (research/chunked-transcription-design-2026-09-25.md, 4.1): a session
/// makes several runs — from where the viewer starts, from where they jump
/// to — and each is a message to the same isolate, not a new one loading
/// the VAD and SenseVoice again. Stopping a run is a flag the isolate reads
/// between windows; the isolate itself is never killed, except as a last
/// resort when a decode does not return.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:budoux_dart/budoux.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

sealed class AsrEvent {
  const AsrEvent();
}

class AsrCuesEvent extends AsrEvent {
  const AsrCuesEvent(this.cues, {this.run = 0});
  final List<AsrCue> cues;
  final int run;
}

class AsrProgressUpdate extends AsrEvent {
  const AsrProgressUpdate(
    this.done,
    this.total, {
    this.run = 0,
    double? settled,
  }) : settled = settled ?? done;

  /// Where the recogniser has got to in the media, in seconds (the run's
  /// offset included).
  final double done;

  /// How much audio is on disk for the run, as a media position.
  final double total;
  final int run;

  /// How far everything is decided: before it, all speech has been sent
  /// as segments. Behind [done] while the VAD is inside speech.
  final double settled;
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
    this.run = 0,
    this.language = '',
    this.weight = 0,
  });

  /// In media time: the run's offset is included.
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

  /// Which run it came from.
  final int run;

  /// The language SenseVoice tagged it with (`zh`, `en`, …), or empty; and
  /// how much it counts in the vote (see [AsrLanguageVote]).
  final String language;
  final int weight;
}

/// A run is over: it reached the end of the audio ([eof]), or was stopped.
class AsrRunEndEvent extends AsrEvent {
  const AsrRunEndEvent(this.run, {required this.eof, required this.played});
  final int run;
  final bool eof;

  /// Where it got to, as a media position.
  final double played;
}

class AsrErrorEvent extends AsrEvent {
  const AsrErrorEvent(this.message, {this.run});
  final String message;
  final int? run;
}

/// Which language the speech is in, by how much of it there is rather than
/// by whichever segment happened to come first.
///
/// A Japanese video opening with two seconds of noise was recognised as
/// 'The.' and reported as English — and the 外语自动转录 policy then makes
/// its decision, including whether to stop, on that. Kept per session, not
/// per run (design 4.1): a run that starts on music or on a quote in another
/// language adds its little weight to everything before it instead of
/// starting a vote of its own. Once one language clearly has it, the answer
/// is fixed.
class AsrLanguageVote {
  final _weights = <String, int>{};
  String? _winner;
  var _fixed = false;

  /// The leader so far, or null before any tagged speech.
  String? get winner => _winner;

  /// The answer will not change any more.
  bool get fixed => _fixed;

  /// Enough text for the answer to stand: about two sentences of it.
  static const confident = 200;

  /// Adds a segment tagged [language], weighted by [weight] (its text length
  /// plus one, so a long stretch outvotes a stray word). Returns the new
  /// winner when it changed.
  String? add(String language, int weight) {
    if (_fixed || language.isEmpty) return null;
    _weights[language] = (_weights[language] ?? 0) + weight;
    final best = _weights.entries.reduce((a, b) => b.value > a.value ? b : a);
    final total = _weights.values.fold(0, (a, b) => a + b);
    if (best.value >= confident && best.value * 4 >= total * 3) _fixed = true;
    if (best.key == _winner) return null;
    return _winner = best.key;
  }
}

/// What the recogniser loads once per session.
typedef AsrModels = ({
  String modelPath,
  String tokensPath,
  String vadPath,
  int threads,

  /// Empty lets SenseVoice detect; otherwise it is forced (`zh`/`en`/…).
  String language,

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

/// One transcription over one file, the way it was before runs: kept for
/// the self-test probes that drive the recogniser alone.
typedef AsrJob = ({
  String pcmPath,
  String modelPath,
  String tokensPath,
  String vadPath,
  int threads,
  String language,

  /// Whether [pcmPath] is still being written. True means transcription runs
  /// alongside extraction instead of after it, which is what lets the first
  /// cues appear seconds into a video rather than after the whole audio has
  /// been pulled.
  bool follow,
  String? japaneseSegmenter,
  String? chineseSegmenter,
  bool itn,
});

/// One run, as sent to the isolate.
typedef AsrRunRequest = ({
  int id,
  String pcmPath,

  /// Where in the media the PCM starts: added to every time the run reports.
  double offset,
  bool follow,
});

/// What the transcription isolate is started with.
typedef AsrIsolateArgs = ({AsrModels models, SendPort send, int flags});

/// The three words of native memory the owner and the isolate share.
///
/// Native memory rather than messages: the isolate spends a run in a
/// blocking loop over the decoder and never returns to its event loop
/// meanwhile, so a message would only be read once the run was over.
/// Reading a word per 512-sample window costs nothing.
///
/// - [_wanted]: the id of the run allowed to go on. A run whose id is not
///   here stops; setting it to 0 stops whatever runs. A run message that
///   arrives after its run was already given up finds another id here and
///   is skipped — the race a plain stop flag, reset at each run's start,
///   would lose.
/// - [_paused]: non-zero holds the run between windows.
/// - [_closing]: the session is over; the isolate frees and leaves.
const _wanted = 0;
const _paused = 1;
const _closing = 2;

int _flag(int flags, int which) => Pointer<Int32>.fromAddress(flags)[which];

/// Whether [run] may go on.
bool asrRunWanted(int flags, int run) =>
    _flag(flags, _wanted) == run && _flag(flags, _closing) == 0;

/// Whether the owner has asked the current run to wait.
bool asrRunPaused(int flags) => _flag(flags, _paused) != 0;

/// Whether the session is over.
bool asrClosing(int flags) => _flag(flags, _closing) != 0;

/// The recogniser as the isolate uses it; the real one wraps sherpa-onnx,
/// a test's sends what it likes.
abstract class AsrEngine {
  /// Runs [request] to its end, sending its segments and progress, and
  /// returns whether it reached the end of the audio. Checks [stopping]
  /// between windows and waits while [paused].
  bool run(
    AsrRunRequest request, {
    required bool Function() stopping,
    required bool Function() paused,
    required void Function(Map<String, Object?>) send,
  });

  /// Frees the native objects. sherpa_onnx has no finalisers: anything not
  /// freed here is lost for the life of the process.
  void free();
}

/// The isolate body around an [AsrEngine]: loads it, answers run messages
/// one after another, and frees it on the way out — every way out.
Future<void> asrServe(
  AsrIsolateArgs args,
  AsrEngine Function(AsrModels) load,
) async {
  final send = args.send;
  final flags = args.flags;
  final inbox = ReceivePort();
  AsrEngine? engine;
  try {
    engine = load(args.models);
    // loading the models takes a while; the session may be over already
    if (asrClosing(flags)) return;
    send.send({'type': 'ready', 'port': inbox.sendPort});
    await for (final message in inbox) {
      if (message is! Map) continue;
      if (message['type'] == 'close' || asrClosing(flags)) break;
      if (message['type'] != 'run') continue;
      final request = (
        id: message['id'] as int,
        pcmPath: message['pcm'] as String,
        offset: (message['offset'] as num).toDouble(),
        follow: message['follow'] as bool,
      );
      final id = request.id;
      bool stopping() => !asrRunWanted(flags, id);
      var eof = false;
      var played = request.offset;
      if (!stopping()) {
        try {
          eof = engine.run(
            request,
            stopping: stopping,
            paused: () => asrRunPaused(flags),
            send: (event) {
              if (event['type'] == 'progress') {
                played = event['done'] as double;
              }
              send.send({...event, 'run': id});
            },
          );
        } catch (e) {
          send.send({'type': 'error', 'message': e.toString(), 'run': id});
        }
      }
      send.send({
        'type': 'runEnd',
        'run': id,
        'eof': eof && !stopping(),
        'played': played,
      });
      if (asrClosing(flags)) break;
    }
  } catch (e) {
    send.send({'type': 'error', 'message': e.toString()});
  } finally {
    inbox.close();
    engine?.free();
    send.send({'type': 'done'});
  }
}

class AsrTranscriber {
  AsrTranscriber._(this._isolate, this._port, this._flags, this._grace);

  final Isolate _isolate;
  final ReceivePort _port;
  final _events = StreamController<AsrEvent>.broadcast();

  /// Everything the isolate reports, run after run, until [close].
  Stream<AsrEvent> get events => _events.stream;

  /// Freed only once the isolate has exited: until then it may still read it.
  final Pointer<Int32> _flags;
  final Duration _grace;
  final _exited = Completer<void>();
  final _ready = Completer<void>();
  SendPort? _inbox;
  final _queued = <Map<String, Object?>>[];
  Timer? _killTimer;
  var _closed = false;
  var _killed = false;
  var _nextRun = 1;

  /// How long a closed isolate gets to wind down before it is killed.
  ///
  /// It checks the flags between windows and between segments, so it is
  /// normally out within one segment's decode (~2 s of arm64 CPU for the
  /// 20 s maximum). This is only the net under a decode that never returns.
  static const stopGrace = Duration(seconds: 10);

  /// Completes when the isolate is gone — by itself after a [close], or
  /// killed after [stopGrace]. Not something the UI waits on: a close
  /// returns at once and this completes in the background.
  Future<void> get exited => _exited.future;

  /// Completes once the models are loaded; with an error if they could not
  /// be.
  Future<void> get ready => _ready.future;

  /// Whether the isolate had to be killed, and so leaked the recogniser's
  /// native memory (sherpa_onnx has no finalisers).
  bool get killed => _killed;

  bool get isClosed => _closed;

  /// Loads the models on a new isolate; runs are started with [run].
  static Future<AsrTranscriber> open(AsrModels models) => spawn(_entry, models);

  /// One transcription of [job], as before runs: the isolate closes once
  /// the run is over, and [events] ends with it.
  static Future<AsrTranscriber> start(AsrJob job) async {
    final transcriber = await open((
      modelPath: job.modelPath,
      tokensPath: job.tokensPath,
      vadPath: job.vadPath,
      threads: job.threads,
      language: job.language,
      japaneseSegmenter: job.japaneseSegmenter,
      chineseSegmenter: job.chineseSegmenter,
      itn: job.itn,
    ));
    transcriber.events
        .firstWhere(
          (e) => e is AsrRunEndEvent,
          orElse: () => const AsrErrorEvent(''),
        )
        .then((_) => transcriber.close(), onError: (_) {});
    transcriber.run(pcmPath: job.pcmPath, offset: 0, follow: job.follow);
    return transcriber;
  }

  /// [open] with the isolate body given, so the protocol can be tested
  /// without the native models.
  @visibleForTesting
  static Future<AsrTranscriber> spawn(
    void Function(AsrIsolateArgs) entry,
    AsrModels models, {
    Duration grace = stopGrace,
  }) async {
    final port = ReceivePort();
    final exit = ReceivePort();
    final flags = calloc<Int32>(3);
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        entry,
        (models: models, send: port.sendPort, flags: flags.address),
        onExit: exit.sendPort,
      );
    } catch (_) {
      port.close();
      exit.close();
      calloc.free(flags);
      rethrow;
    }
    final transcriber = AsrTranscriber._(isolate, port, flags, grace);
    port.listen(transcriber._receive, onDone: transcriber._finishEvents);
    exit.first.then((_) {
      exit.close();
      transcriber
        .._killTimer?.cancel()
        .._port.close()
        .._finishEvents();
      calloc.free(flags);
      if (!transcriber._ready.isCompleted) {
        transcriber._ready.completeError(
          StateError('recogniser exited before it was ready'),
        );
      }
      transcriber._exited.complete();
    });
    return transcriber;
  }

  void _finishEvents() {
    if (!_events.isClosed) _events.close();
  }

  void _receive(Object? message) {
    if (message is! Map) return;
    final run = message['run'] as int? ?? 0;
    switch (message) {
      case {'type': 'ready', 'port': final SendPort inbox}:
        _inbox = inbox;
        for (final queued in _queued) {
          inbox.send(queued);
        }
        _queued.clear();
        if (!_ready.isCompleted) _ready.complete();
      case {
        'type': 'progress',
        'done': final double d,
        'total': final double t,
      }:
        _add(
          AsrProgressUpdate(
            d,
            t,
            run: run,
            settled: (message['settled'] as num?)?.toDouble(),
          ),
        );
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
        if (cues.isNotEmpty) _add(AsrCuesEvent(cues, run: run));
        _add(
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
            run: run,
            language: message['lang'] as String? ?? '',
            weight: message['weight'] as int? ?? 0,
          ),
        );
      case {'type': 'runEnd'}:
        _add(
          AsrRunEndEvent(
            run,
            eof: message['eof'] as bool? ?? false,
            played: (message['played'] as num?)?.toDouble() ?? 0,
          ),
        );
      case {'type': 'error', 'message': final String text}:
        if (!_ready.isCompleted) _ready.completeError(StateError(text));
        _add(AsrErrorEvent(text, run: message['run'] as int?));
      case {'type': 'done'}:
        _port.close();
        _finishEvents();
    }
  }

  void _add(AsrEvent event) {
    if (!_closed && !_events.isClosed) _events.add(event);
  }

  void _send(Map<String, Object?> message) {
    final inbox = _inbox;
    if (inbox == null) {
      _queued.add(message);
    } else {
      inbox.send(message);
    }
  }

  /// Starts a run over [pcmPath] — which begins at [offset] in the media —
  /// and returns its id. Whatever run was going is stopped: one run at a
  /// time. Its events carry the id; a run is over with its
  /// [AsrRunEndEvent].
  int run({
    required String pcmPath,
    required double offset,
    bool follow = true,
  }) {
    if (_closed) throw StateError('recogniser closed');
    final id = _nextRun++;
    _flags[_paused] = 0;
    _flags[_wanted] = id;
    _send({
      'type': 'run',
      'id': id,
      'pcm': pcmPath,
      'offset': offset,
      'follow': follow,
    });
    return id;
  }

  /// Stops the run in progress, if any; returns at once. It ends within a
  /// window or a segment, with its [AsrRunEndEvent].
  void stopRun() {
    if (_closed) return;
    _flags[_wanted] = 0;
    _flags[_paused] = 0;
  }

  /// Holds the run in progress between windows, or lets it go on.
  void pause(bool paused) {
    if (_closed) return;
    _flags[_paused] = paused ? 1 : 0;
  }

  /// Ends the session's recogniser, and returns at once.
  ///
  /// Nothing more is delivered on [events] after this. The isolate is asked
  /// to leave rather than killed: a killed isolate never runs its `finally`,
  /// and that `finally` is what frees the recogniser and the VAD — measured
  /// at ~330 MB of native memory lost per stop on desktop before this
  /// (V0, research/chunked-transcription-design-2026-09-25.md). It winds
  /// down in the background within about one segment; see [exited].
  void close() {
    if (_closed) return;
    _closed = true;
    _finishEvents();
    if (_exited.isCompleted) return;
    _flags[_closing] = 1;
    _flags[_wanted] = 0;
    _flags[_paused] = 0;
    _inbox?.send({'type': 'close'});
    _killTimer = Timer(_grace, () {
      if (_exited.isCompleted) return;
      // still leaks, as every stop used to; a decode that does not return
      // must still not keep a CPU busy for a job nobody wants
      _killed = true;
      if (kDebugMode) debugPrint('asr: isolate did not stop, killing it');
      _isolate.kill(priority: Isolate.immediate);
    });
  }

  /// [close], by its old name.
  void stop() => close();

  static void _entry(AsrIsolateArgs args) => asrServe(args, _SherpaEngine.new);
}

/// The recogniser proper. Everything here runs off the UI thread.
class _SherpaEngine implements AsrEngine {
  _SherpaEngine(AsrModels models) : _models = models {
    sherpa.initBindings();
    _budoux = models.japaneseSegmenter == null
        ? null
        : BudouX(models.japaneseSegmenter!);
    _budouxZh = models.chineseSegmenter == null
        ? null
        : BudouX(models.chineseSegmenter!);
    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: models.vadPath,
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
    try {
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: models.modelPath,
              language: models.language,
              useInverseTextNormalization: models.itn,
            ),
            tokens: models.tokensPath,
            numThreads: models.threads,
          ),
        ),
      );
    } catch (_) {
      _vad.free();
      rethrow;
    }
  }

  final AsrModels _models;
  BudouX? _budoux;
  BudouX? _budouxZh;
  late final sherpa.VoiceActivityDetector _vad;
  late final sherpa.OfflineRecognizer _recognizer;

  /// How far behind the read position the VAD may still open a segment
  /// once it reports no speech: its minimum speech length plus padding.
  static const _undecided = 1.0;

  @override
  bool run(
    AsrRunRequest request, {
    required bool Function() stopping,
    required bool Function() paused,
    required void Function(Map<String, Object?>) send,
  }) {
    final vad = _vad;
    final recognizer = _recognizer;
    final offset = request.offset;
    // segment offsets are counted from the last reset: from this run's
    // start, which is [offset] in the media
    vad.reset();
    final reader = PcmWindowReader(
      request.pcmPath,
      follow: request.follow,
      stopped: stopping,
      held: paused,
    );
    try {
      // In follow mode the file is still growing, so this is a lower bound
      // that is re-read as the run goes; a progress bar computed from the
      // first value alone would sit at 100% for most of the job.
      var total = reader.durationSeconds;
      var lastProgress = 0.0;
      var settled = offset;

      void drain() {
        // between segments too: a backlog of them is seconds of decoding
        while (!vad.isEmpty() && !stopping()) {
          final segment = vad.front();
          final start = offset + segment.start / asrSampleRate;
          final duration = segment.samples.length / asrSampleRate;
          final stream = recognizer.createStream()
            ..acceptWaveform(
              samples: segment.samples,
              sampleRate: asrSampleRate,
            );
          recognizer.decode(stream);
          final result = recognizer.getResult(stream);
          stream.free();
          vad.pop();

          final tag = AsrCueBuilder.tagValue(result.lang);
          final japanese = tag == 'ja' || AsrCueBuilder.hasKana(result.text);
          final chinese = !japanese && (tag == 'zh' || tag == 'yue');
          final tokens = _tokens(result);
          final cues = AsrCueBuilder.fromSegment(
            segmenter: japanese
                ? _budoux?.parse
                : (chinese ? _budouxZh?.parse : null),
            planLines: chinese,
            offset: start,
            duration: duration,
            text: result.text,
            tokens: tokens,
          );
          // One message with its cues: translation settles units on
          // segments, and a segment seen without its text — or text without
          // its segment, which is then counted as the previous one's — gets
          // a unit built and translated from the wrong words.
          send({
            'type': 'segment',
            'start': start,
            'duration': duration,
            // the raw pieces, for the probe only: how the recogniser marks a
            // word decides where a cue may end, and that cannot be guessed
            // from the joined text
            'tokens': [for (final t in tokens) t.text],
            'times': [for (final t in tokens) t.time],
            'cues': cues.toJson(),
            // the language vote is the session's (see AsrLanguageVote);
            // weighted by text, so a long stretch outvotes a stray word
            'lang': result.lang.isEmpty ? '' : tag,
            'weight': result.text.length + 1,
          });
          if (start + duration > settled) settled = start + duration;
        }
      }

      for (final window in reader.windows()) {
        if (stopping()) return false;
        while (paused() && !stopping()) {
          sleep(const Duration(milliseconds: 50));
        }
        if (stopping()) return false;
        vad.acceptWaveform(window);
        drain();
        final done = reader.samplesRead / asrSampleRate;
        if (done - lastProgress >= 1) {
          lastProgress = done;
          if (request.follow) total = reader.durationSeconds;
          if (!vad.isDetected()) {
            final quiet = offset + done - _undecided;
            if (quiet > settled) settled = quiet;
          }
          send({
            'type': 'progress',
            'done': offset + done,
            'total': offset + total,
            'settled': settled,
          });
        }
      }
      // the reader also ends early when asked to stop; that is not the end
      // of the audio, and there is nobody left to send the tail to
      if (stopping()) return false;
      // only once the reader has really ended: in follow mode it returns
      // when the extractor's marker appears, not at the first empty read
      vad.flush();
      drain();
      final played = offset + reader.samplesRead / asrSampleRate;
      send({
        'type': 'progress',
        'done': played,
        'total': played,
        'settled': played,
      });
      return true;
    } finally {
      try {
        reader.close();
      } catch (_) {}
    }
  }

  @override
  void free() {
    _vad.free();
    _recognizer.free();
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

  @override
  String toString() => '_SherpaEngine(${_models.modelPath})';
}
