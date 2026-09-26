/// LibrePili: one job at a time, from "this video has no subtitles" to a
/// subtitle track.
///
/// The pipeline is extract → detect → transcribe, and every step can be
/// abandoned: the user can leave the page, the models may be missing, and a
/// video whose speech turns out to be in the app's own language is dropped
/// rather than transcribed (see [AsrMode.foreign]).
///
/// A job is no longer one pass from the first second to the last
/// (research/chunked-transcription-design-2026-09-25.md). It is a session
/// of runs: one from where the viewer is, a new one where they jump to if
/// nothing is known there, the same one paused when it is far enough ahead
/// and resumed when they catch up (see asr_schedule.dart), with the text of
/// all of them kept by time (see [TranscriptStore]) and joined at seams of
/// whole segments (see transcript_seams.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:PiliPlus/services/asr/transcript_seams.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

enum AsrStage {
  idle,
  models,
  extracting,
  transcribing,

  /// Alive but not recognising: far enough ahead of the viewer, or waiting
  /// for a seek (research/chunked-transcription-design-2026-09-25.md, 4.5).
  /// Neither finished nor failed: the track stays and translation goes on.
  standby,
  done,
  failed,
}

class AsrState {
  const AsrState({
    required this.stage,
    this.progress,
    this.message,
    this.language,
  });

  const AsrState.idle() : this(stage: AsrStage.idle);

  final AsrStage stage;

  /// 0..1 where it is known, null where it is not.
  final double? progress;
  final String? message;
  final String? language;

  bool get isBusy =>
      stage == AsrStage.models ||
      stage == AsrStage.extracting ||
      stage == AsrStage.transcribing;

  String get label => switch (stage) {
    AsrStage.idle => '',
    AsrStage.models => message ?? '准备模型',
    AsrStage.extracting => '提取音频',
    AsrStage.transcribing => '识别中',
    AsrStage.standby => message ?? '已暂停',
    AsrStage.done => '已完成',
    AsrStage.failed => message ?? '失败',
  };
}

/// Where a session's source is decoded from, asked again at every run: a
/// signed stream URL expires, and a run started an hour into viewing needs
/// the one the page has now. [expired] means the last one was refused
/// (HTTP 403). Null keeps the one the session was started with.
typedef AsrSourceRefresh = Future<String?> Function({bool expired});

/// One recorded seam, for the probes (V3): where it is and what was done.
typedef AsrSeamRecord = Map<String, Object?>;

/// A run in progress: its extraction, its share of the store, and where it
/// stands against the text already there.
class _Run {
  _Run({
    required this.serial,
    required this.store,
    required this.target,
    required this.extractFrom,
    required this.clean,
    required this.pcmPath,
  });

  final int serial;
  final TranscriptRun store;

  /// Where it was started for, and where its audio starts.
  final double target;
  final double extractFrom;

  /// Nothing at its start was cut (the media's start, or exactly where
  /// known text ends): every segment is kept.
  final bool clean;
  final String pcmPath;

  /// The recogniser's id for it, once handed over.
  int? id;
  Future<AsrExtractResult>? extraction;

  /// Set once its extraction has ended, however; and whether that was at
  /// the end of the media.
  var extractionOver = false;
  var reachedEnd = false;
  var paused = false;
  var ended = false;

  /// How far it is decided (see [AsrProgressUpdate.settled]).
  late double frontier = extractFrom;

  /// Wall time of the last progress, and where it was then: the pace.
  DateTime? progressAt;
  double progressDone = 0;

  /// Since when it has been (re)started, waiting for its first segment:
  /// the restart cost.
  DateTime? waitingSince = DateTime.now();

  /// Running into known text (design 4.3, end): the join being made and
  /// where that text begins.
  SeamJoin? join;
  double? joinFrom;

  /// Only where the run cannot be stopped and another started (a source
  /// that cannot seek): after a join, its segments are dropped until the
  /// known stretch it ran into is behind it.
  double? skipUntil;

  String get cancelPath => '$pcmPath.cancel';
  String get pausePath => AsrAudioExtractor.pauseFileFor(pcmPath);
}

/// One transcription, tied to one video page.
class AsrSession {
  AsrSession._(
    this.key, {
    this.seekable = true,
    double? Function()? playhead,
    double? Function()? duration,
    this.refreshSource,
  }) : _playheadOf = playhead,
       _durationOf = duration;

  /// A session with no job behind it, for widget tests.
  @visibleForTesting
  factory AsrSession.debugFor(String key) = AsrSession._;

  /// Usually the cid: one job per part, which is the granularity subtitles
  /// have anyway.
  final String key;

  /// Whether the source can be started from a position. Where it cannot —
  /// a bilibili durl/FLV fallback, an Android `content://` document read
  /// once through `fdclose://` — the session is one run from 0 to the end,
  /// as every session used to be; it can still pause.
  bool seekable;

  final double? Function()? _playheadOf;
  final double? Function()? _durationOf;

  /// See [AsrSourceRefresh].
  final AsrSourceRefresh? refreshSource;

  final state = const AsrState.idle().obs;

  /// What has been recognised, kept by time (see [TranscriptStore]).
  final transcript = TranscriptStore();

  /// Every cue so far, in time order. Listened to for "there is new text".
  RxList<AsrCue> get cues => transcript.cues;

  /// Stretches the VAD called speech, in time order. Translation cuts its
  /// units along them; they are also the only way to tell a gap that is
  /// silence from a gap where speech was recognised into nothing.
  List<TranscriptSegment> get segments => transcript.segments;

  /// Transcription speed and restart cost as measured (design 12, V8).
  final pace = AsrPace();

  /// How much running ahead the device allows; read at the start, kept
  /// current while running, and settable for the self-test.
  AsrPower power = PlatformUtils.isDesktop
      ? AsrPower.unlimited
      : AsrPower.battery;

  /// Set by the self-test to hold [power] where it put it.
  bool debugPowerFixed = false;

  /// The session-wide language vote (design 4.1).
  final _vote = AsrLanguageVote();

  AsrTranscriber? _transcriber;
  Future<AsrTranscriber>? _opening;
  StreamSubscription<AsrEvent>? _events;
  AsrCancelToken? _download;
  var _closed = false;

  // what every run decodes, and how
  String _source = '';
  String? _referer;
  String? _userAgent;
  bool _auto = false;
  AsrModels? _models;

  _Run? _run;
  var _starting = false;

  /// Which [_startRun] call [_starting] belongs to: one that hands over to
  /// another must not clear it under the other's feet.
  var _startToken = 0;
  Timer? _ticker;
  var _serials = 0;

  /// Runs started, for the probes (V5: a seek back into known text starts
  /// none).
  int get runCount => _serials;

  /// Pauses and resumes so far, for the probes.
  var pauses = 0;
  var resumes = 0;

  /// What the seams did, for the probes (V3).
  final debugSeams = <AsrSeamRecord>[];

  /// The end of the media, learned from a run that reached it, when the
  /// page gives no duration.
  double? _mediaEnd;

  /// Where the viewer was at the last tick, and when; and the last time
  /// they jumped rather than played on.
  double _playhead = 0;
  DateTime? _playheadAt;
  var _lastJump = DateTime.fromMillisecondsSinceEpoch(0);

  /// Runs the recogniser has finished with, by id: their PCM can go.
  final _runEnds = <int, Completer<void>>{};

  /// No new run before this, after one failed.
  DateTime? _backoffUntil;

  /// Stopped by the model guard: nothing runs until [resume].
  var _suspended = false;

  /// Seconds of audio decoded so far, for the "提取音频 Ns" label.
  double _extracted = 0;

  /// Whether this session has decided the media is its language already.
  var _gaveUp = false;

  bool get isRunning => state.value.isBusy;

  /// The recogniser is loaded, or a run or a model download is going:
  /// memory the model guard should take back when the app is away.
  bool get holdsModels =>
      !_closed &&
      (_transcriber != null || _opening != null || _run != null || isRunning);

  /// A VTT the existing subtitle path can take as `memory://` data.
  String get vtt => cues.toVtt();

  /// The media's length: the page's player's, or where a run found it end.
  double? get duration {
    // where the audio really ends, once a run has read it there: a video's
    // length can run a little past its audio's, and asking for a run there
    // would find nothing to decode, again and again
    final end = _mediaEnd;
    if (end != null) return end;
    final given = _durationOf?.call();
    return given != null && given > 0 ? given : null;
  }

  /// Seconds of the media the transcript covers.
  double get coveredSeconds =>
      transcript.covered.fold(0.0, (sum, s) => sum + (s.to - s.from));

  void _set(AsrState value) {
    if (!_closed) state.value = value;
  }

  @visibleForTesting
  void debugSet(AsrState value) => _set(value);

  /// The recogniser behind this session, for the self-test's leak probe
  /// (`--asr-leak`) to see how its isolate ended. Nothing else reads it.
  AsrTranscriber? get debugTranscriber => _transcriber;

  Future<void> dispose() async {
    _closed = true;
    _ticker?.cancel();
    _download?.cancel();
    final run = _run;
    if (run != null) _endRun(run);
    final transcriber = _transcriber;
    _transcriber = null;
    transcriber?.close();
    await _events?.cancel();
  }

  /// The model guard's stop (design 4.4): the run ends and the recogniser
  /// is let go of — the memory is what the guard is for — but the text so
  /// far stays, and so does the track. [resume] carries on from there.
  void suspend(String reason) {
    if (_closed || _suspended) return;
    _suspended = true;
    final run = _run;
    if (run != null) _endRun(run);
    _closeRecogniser();
    _download?.cancel();
    if (state.value.stage != AsrStage.done &&
        state.value.stage != AsrStage.failed &&
        state.value.stage != AsrStage.idle) {
      _set(
        AsrState(
          stage: AsrStage.standby,
          message: reason,
          language: state.value.language,
          progress: state.value.progress,
        ),
      );
    }
  }

  /// After [suspend]: runs start again as the viewer needs them.
  void resume() {
    if (_closed || !_suspended) return;
    _suspended = false;
    if (_models != null) _tick();
  }

  bool get isSuspended => _suspended;

  void _closeRecogniser() {
    final transcriber = _transcriber;
    _transcriber = null;
    _opening = null;
    _events?.cancel();
    _events = null;
    transcriber?.close();
  }

  // ---------------------------------------------------------------------
  // runs

  /// Starts the session proper, once the models are there.
  Future<void> _begin({
    required String source,
    String? referer,
    String? userAgent,
    required bool auto,
    required AsrModels models,
  }) async {
    _source = source;
    _referer = referer;
    _userAgent = userAgent;
    _auto = auto;
    _models = models;
    unawaited(_watchPower());
    _set(const AsrState(stage: AsrStage.extracting));
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    _tick();
  }

  Future<void> _watchPower() async {
    while (!_closed) {
      if (!debugPowerFixed) power = await readAsrPower();
      await Future.delayed(const Duration(minutes: 1));
    }
  }

  AsrLeadWindow get leadWindow => asrLeadWindow(
    speed: pace.speed,
    restartCost: pace.restartCost,
    power: power,
  );

  void _readPlayhead() {
    final now = DateTime.now();
    final p = _playheadOf?.call();
    if (p == null) return;
    final last = _playheadAt;
    if (last != null) {
      // playing on moves it by about the time gone by; more than that, or
      // back, is a jump
      final elapsed = now.difference(last).inMilliseconds / 1000;
      final moved = p - _playhead;
      if (moved < -1.5 || moved > elapsed * 2 + 2) _lastJump = now;
    }
    _playhead = p;
    _playheadAt = now;
  }

  void _tick() {
    if (_closed || _suspended || _starting || _models == null || _gaveUp) {
      return;
    }
    _readPlayhead();
    final run = _run;
    final media = duration;
    final covered = transcript.covered;
    final step = decideAsrStep(
      playhead: _playhead,
      duration: media,
      covered: covered,
      run: run == null
          ? null
          : (
              start: run.store.from,
              frontier: run.frontier > run.store.end
                  ? run.frontier
                  : run.store.end,
              paused: run.paused,
            ),
      lead: leadWindow,
      pace: pace,
    );
    if (!seekable) {
      _tickUnseekable(step, run);
      return;
    }
    // a join under way finishes first: what it holds back is text nobody
    // else has (the part of its segments before the known stretch)
    final joining = run != null && run.join != null;
    switch (step) {
      case AsrComplete():
        if (!joining) _complete();
      case AsrPause():
        if (run != null && !joining) _pause(run);
      case AsrResume():
        if (run != null) _resume(run);
      case AsrStartAt(:final at, :final adjacent):
        final backoff = _backoffUntil;
        if (backoff != null && DateTime.now().isBefore(backoff)) return;
        // a jump waits for the viewer to settle: dragging the seek bar is
        // many positions, and each would otherwise start a run
        if (!adjacent &&
            _serials > 0 &&
            DateTime.now().difference(_lastJump) < asrSeekDebounce) {
          return;
        }
        // the join a run is making finishes before anything replaces it:
        // otherwise what it holds is lost, and the gap stays
        if (joining && adjacent) return;
        // never the run already going from there
        if (run != null && (run.store.from - at).abs() < 1) return;
        unawaited(_startRun(at, adjacent: adjacent));
      case AsrKeep():
        break;
    }
    _updateState();
  }

  /// One run from 0 to the end, as before: only pausing and resuming.
  void _tickUnseekable(AsrStep step, _Run? run) {
    if (run == null) {
      if (_serials == 0) unawaited(_startRun(0, adjacent: false));
      if (_serials > 0 && _mediaEnd != null) _complete();
      return;
    }
    switch (step) {
      case AsrPause():
        _pause(run);
      case AsrResume():
        _resume(run);
      case _:
        // a jump elsewhere: this run is all there is; resume it if the
        // viewer is now ahead of what it knows
        if (run.paused && _playhead > run.frontier - leadWindow.low) {
          _resume(run);
        }
    }
    _updateState();
  }

  void _complete() {
    final run = _run;
    if (run != null) _endRun(run);
    // done: the recogniser has nothing left to do, and its models go
    _closeRecogniser();
    _ticker?.cancel();
    _set(
      AsrState(
        stage: AsrStage.done,
        progress: 1,
        language: state.value.language,
      ),
    );
  }

  void _updateState() {
    final stage = state.value.stage;
    if (stage == AsrStage.done ||
        stage == AsrStage.failed ||
        stage == AsrStage.idle && _serials > 0) {
      return;
    }
    final run = _run;
    final media = duration;
    final progress = media == null || media <= 0
        ? null
        : (coveredSeconds / media).clamp(0.0, 1.0);
    if (run != null && !run.paused) {
      // the first run's audio is still coming: 提取音频 as before
      if (run.id == null && stage == AsrStage.extracting) return;
      _set(
        AsrState(
          stage: AsrStage.transcribing,
          progress: progress,
          language: state.value.language,
        ),
      );
    } else if (!_starting) {
      _set(
        AsrState(
          stage: AsrStage.standby,
          progress: progress,
          language: state.value.language,
        ),
      );
    }
  }

  void _pause(_Run run) {
    if (run.paused || run.ended) return;
    run.paused = true;
    pauses++;
    _transcriber?.pause(true);
    try {
      File(run.pausePath).writeAsStringSync('1');
    } catch (_) {}
    if (kDebugMode) {
      debugPrint('asr: run ${run.serial} paused at ${run.frontier}');
    }
  }

  void _resume(_Run run) {
    if (!run.paused || run.ended) return;
    run
      ..paused = false
      ..progressAt = null
      ..waitingSince = DateTime.now();
    resumes++;
    try {
      final file = File(run.pausePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    _transcriber?.pause(false);
  }

  Future<AsrTranscriber> _recogniser() {
    final open = _transcriber;
    if (open != null) return Future.value(open);
    return _opening ??= () async {
      final transcriber = await AsrTranscriber.open(_models!);
      if (_closed || _suspended) {
        transcriber.close();
        throw const AsrCancelled();
      }
      _transcriber = transcriber;
      _opening = null;
      _events = transcriber.events.listen(_onEvent);
      return transcriber;
    }();
  }

  /// Starts a run for [at]: from [asrPreRoll] before it, or — [adjacent],
  /// or near enough the end of known text — exactly where that text ends.
  Future<void> _startRun(double at, {required bool adjacent}) async {
    if (_starting || _closed) return;
    _starting = true;
    final token = ++_startToken;
    final first = _serials == 0;
    try {
      final previous = _run;
      if (previous != null) _endRun(previous);
      double extractFrom;
      var clean = true;
      var target = at;
      if (!seekable || at <= asrPreRoll + 0.5) {
        // from the start of the media: no seek at all, as every run used to
        extractFrom = 0;
        target = 0;
      } else if (adjacent) {
        extractFrom = at;
      } else {
        // known text ending within the pre-roll: start exactly there
        final edge = transcript.covered
            .where((s) => s.to <= at + 0.25 && s.to >= at - asrPreRoll)
            .map((s) => s.to)
            .fold<double?>(null, (a, b) => a == null || b > a ? b : a);
        if (edge != null) {
          extractFrom = edge;
          target = edge;
        } else {
          extractFrom = at - asrPreRoll;
          clean = false;
        }
      }
      final serial = ++_serials;
      final pcmPath = path.join(
        tmpDirPath,
        'asr',
        '$key-${DateTime.now().millisecondsSinceEpoch}-r$serial.pcm',
      );
      final run = _Run(
        serial: serial,
        store: transcript.startRun(clean ? extractFrom : target),
        target: target,
        extractFrom: extractFrom,
        clean: clean,
        pcmPath: pcmPath,
      );
      _run = run;
      debugSeams.add({
        'kind': 'start',
        'run': serial,
        'target': target,
        'extractFrom': extractFrom,
        'clean': clean,
        'requested': at,
      });
      if (kDebugMode) {
        debugPrint(
          'asr: run $serial for $at from $extractFrom (clean: $clean)',
        );
      }

      var source = _source;
      if (!first && refreshSource != null) {
        source = await refreshSource!() ?? source;
      }
      if (_closed || run.ended) return;
      Object? error = await _extract(run, source);
      if (error != null &&
          AsrAudioExtractor.isForbidden(error) &&
          refreshSource != null) {
        // an expired signed URL: once more with a fresh one
        source = await refreshSource!(expired: true) ?? source;
        if (_closed || run.ended) return;
        error = await _extract(run, source);
      }
      if (_closed || run.ended) return;
      if (error != null) {
        _runFailed(run, error);
        return;
      }
      if (!run.clean && !_landedWell(run)) {
        // the seek went wrong: this source is not trusted to start from a
        // position again, and the session goes on as one run from 0
        seekable = false;
        _endRun(run);
        _starting = false;
        unawaited(_startRun(0, adjacent: false));
        return;
      }
      final transcriber = await _recogniser();
      if (_closed || run.ended) return;
      run
        ..waitingSince = DateTime.now()
        ..id = transcriber.run(
          pcmPath: pcmPath,
          offset: extractFrom,
        );
      _updateState();
    } on AsrCancelled {
      // closed or suspended meanwhile
    } catch (e, stack) {
      Utils.reportError('asr: $e', stack);
      final run = _run;
      if (run != null) _runFailed(run, e);
    } finally {
      if (_startToken == token) _starting = false;
    }
  }

  /// Starts [run]'s extraction and waits for enough audio to recognise;
  /// returns the error when it fails before that.
  Future<Object?> _extract(_Run run, String source) async {
    run.extractionOver = false;
    final extraction = AsrAudioExtractor.extract(
      source: source,
      output: run.pcmPath,
      referer: _referer,
      userAgent: _userAgent,
      cancelPath: run.cancelPath,
      pausePath: run.pausePath,
      startSeconds: run.extractFrom > 0 ? run.extractFrom : null,
      onSeconds: (seconds) => _extracted = seconds,
    );
    run.extraction = extraction;
    // Extraction is not awaited: recognition walks the file while it is
    // still being written, so the first cues arrive seconds in and the rest
    // trail the download (a whole googlevideo file at 2x realtime used to
    // mean a half-hour wait for the first subtitle of an hour's video).
    Object? extractError;
    unawaited(
      extraction.then(
        (result) => run
          ..extractionOver = true
          ..reachedEnd = result.reachedEnd,
        onError: (Object e) {
          run.extractionOver = true;
          extractError = e;
        },
      ),
    );
    // enough audio for the VAD to have something to chew on; below this the
    // recogniser would start, hit the end of the file and wait anyway
    const headStart = asrBytesPerSecond * 2;
    final file = File(run.pcmPath);
    final first = run.serial == 1;
    while (!_closed && !run.ended && extractError == null) {
      final size = file.existsSync() ? file.lengthSync() : 0;
      if (size >= headStart) break;
      if (File(PcmWindowReader.doneMarkerFor(run.pcmPath)).existsSync()) {
        break;
      }
      if (first) {
        _set(
          AsrState(
            stage: AsrStage.extracting,
            message: '提取音频 ${_extracted.toStringAsFixed(0)}s',
          ),
        );
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    // a done marker with the error not yet delivered
    if (extractError == null && run.extractionOver) {
      await Future<void>.delayed(Duration.zero);
    }
    return extractError;
  }

  /// Whether a run started from a position landed where it asked (the
  /// per-run guard of design 4.3: reject more than half a second off).
  bool _landedWell(_Run run) {
    final file = File(AsrAudioExtractor.landingFileFor(run.pcmPath));
    try {
      if (!file.existsSync()) return true;
      final landing = jsonDecode(file.readAsStringSync());
      if (landing is! Map<String, Object?>) return true;
      final error = AsrAudioExtractor.landingError(landing, run.extractFrom);
      debugSeams.lastWhere((s) => s['run'] == run.serial)
        ..['landingError'] = error
        ..['landingBytes'] = landing['bytesAtRestart'];
      return error == null || error.abs() <= AsrAudioExtractor.landingTolerance;
    } catch (_) {
      return true;
    }
  }

  void _runFailed(_Run run, Object error) {
    _endRun(run);
    Utils.reportError('asr: $error');
    if (transcript.segments.isEmpty && transcript.cues.isEmpty) {
      // nothing at all: the session has failed, as a single run used to
      _set(AsrState(stage: AsrStage.failed, message: error.toString()));
      _ticker?.cancel();
      return;
    }
    // one run failing is not the session failing (design 4.5): that
    // stretch is tried again a little later
    _backoffUntil = DateTime.now().add(const Duration(seconds: 20));
    _set(
      AsrState(
        stage: AsrStage.standby,
        message: '部分转录失败，稍后重试',
        language: state.value.language,
        progress: state.value.progress,
      ),
    );
  }

  /// Ends [run]: its recognition and extraction stop, its newest segment
  /// settles, and its scratch files go once nothing holds them.
  void _endRun(_Run run) {
    if (run.ended) return;
    run.ended = true;
    if (identical(_run, run)) _run = null;
    final id = run.id;
    final transcriber = _transcriber;
    if (id != null && transcriber != null) transcriber.stopRun();
    try {
      File(run.cancelPath).writeAsStringSync('1');
    } catch (_) {}
    // whatever a join was holding duplicated text already there
    run
      ..join = null
      ..store.finish();
    unawaited(_deleteScratchWhenFree(run, transcriber));
  }

  /// [_deleteScratch] once the recogniser and the decoder have let go of
  /// the run's PCM.
  ///
  /// A stopped recogniser is no longer killed but asked to stop, and it
  /// holds the file open until it has; on Windows a file that is open
  /// cannot be deleted, and the attempt fails silently here. (While it was
  /// killed instead, every stop on Windows left the whole PCM behind in the
  /// temp directory — 20 of 20 in the V0 run, 16 MB each for an 8-minute
  /// video.)
  Future<void> _deleteScratchWhenFree(
    _Run run,
    AsrTranscriber? transcriber,
  ) async {
    try {
      await run.extraction;
    } catch (_) {}
    final id = run.id;
    if (id != null && transcriber != null && !transcriber.isClosed) {
      // its end arrives within a window or a segment
      await (_runEnds[id] ??= Completer<void>()).future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
      _runEnds.remove(id);
    } else if (transcriber != null) {
      await transcriber.exited.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    }
    await _deleteScratch(run.pcmPath);
  }

  /// The PCM and the markers beside it.
  static Future<void> _deleteScratch(String pcm) async {
    for (final name in [
      pcm,
      PcmWindowReader.doneMarkerFor(pcm),
      '$pcm.cancel',
      AsrAudioExtractor.pauseFileFor(pcm),
      AsrAudioExtractor.landingFileFor(pcm),
    ]) {
      try {
        final file = File(name);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
  }

  _Run? _runOf(int id) {
    final run = _run;
    return run != null && run.id == id && !run.ended ? run : null;
  }

  void _onEvent(AsrEvent event) {
    if (_closed) return;
    switch (event) {
      case AsrCuesEvent():
        // the same cues come with their segment, next
        break;
      case AsrSegmentEvent():
        _countVote(event);
        final run = _runOf(event.run);
        if (run != null) _onSegment(run, event);
      case AsrProgressUpdate():
        final run = _runOf(event.run);
        if (run != null) _onProgress(run, event);
      case AsrRunEndEvent(:final run, :final eof, :final played):
        final ended = _runEnds[run] ??= Completer<void>();
        if (!ended.isCompleted) ended.complete();
        final current = _runOf(run);
        if (current == null) return;
        if (eof) {
          unawaited(_reachedEnd(current, played));
          return;
        }
        _endRun(current);
        _tick();
      case AsrErrorEvent(:final message, :final run):
        final current = run == null ? _run : _runOf(run);
        // not tied to a run: the recogniser itself failed (its models
        // would not load), and is gone
        if (run == null) _closeRecogniser();
        if (current != null) {
          _runFailed(current, message);
        } else {
          Utils.reportError('asr: $message');
        }
    }
  }

  /// [run]'s recogniser read its audio to the end. The end of the media —
  /// and so how far the transcript can reach — if its extraction got
  /// there; a download cut short otherwise, tried again from there later.
  Future<void> _reachedEnd(_Run run, double played) async {
    try {
      await run.extraction;
    } catch (_) {}
    if (_closed || run.ended) return;
    if (run.join == null) transcript.advance(run.store, played);
    if (run.reachedEnd || !seekable) {
      // (a source that cannot seek cannot try again: what it got is all)
      _mediaEnd = played;
      debugSeams.add({'kind': 'end', 'run': run.serial, 'at': played});
      _endRun(run);
    } else {
      _runFailed(
        run,
        AsrExtractException('音频在 ${played.toStringAsFixed(0)}s 处中断'),
      );
    }
    _tick();
  }

  void _countVote(AsrSegmentEvent event) {
    final winner = _vote.add(event.language, event.weight);
    if (winner == null) return;
    _set(
      AsrState(
        stage: state.value.stage,
        progress: state.value.progress,
        message: state.value.message,
        language: winner,
      ),
    );
    // an automatic run only exists to help with speech the user cannot
    // follow; if it turns out to be their own language, stop rather than
    // spend the battery
    if (_auto &&
        Pref.asrMode == AsrMode.foreign &&
        AsrService._isAppLanguage(winner)) {
      if (kDebugMode) debugPrint('asr: $winner is the app language, stopping');
      _gaveUp = true;
      final run = _run;
      if (run != null) _endRun(run);
      _closeRecogniser();
      _ticker?.cancel();
      _set(const AsrState.idle());
    }
  }

  void _onProgress(_Run run, AsrProgressUpdate event) {
    final now = DateTime.now();
    final last = run.progressAt;
    if (last != null && !run.paused) {
      pace.addProgress(
        event.done - run.progressDone,
        now.difference(last).inMilliseconds / 1000,
      );
    }
    run
      ..progressAt = run.paused ? null : now
      ..progressDone = event.done;
    if (event.settled > run.frontier) run.frontier = event.settled;
    if (run.skipUntil != null) return;
    final joinFrom = run.joinFrom ?? _nextKnown(run);
    final reach = joinFrom == null
        ? run.frontier
        : (run.frontier < joinFrom ? run.frontier : joinFrom);
    // before the target the pre-roll is not the run's to claim
    if (reach > run.store.start) transcript.advance(run.store, reach);
    _updateState();
  }

  /// Where the next known stretch after [run] begins: text another run
  /// already has, that this one will run into.
  double? _nextKnown(_Run run) {
    double? next;
    for (final other in transcript.runs) {
      if (identical(other, run.store)) continue;
      if (other.segments.isEmpty && other.end <= other.start) continue;
      final from = other.from;
      if (from <= run.store.start + 0.25) continue;
      if (next == null || from < next) next = from;
    }
    return next;
  }

  void _onSegment(_Run run, AsrSegmentEvent event) {
    final waiting = run.waitingSince;
    if (waiting != null) {
      pace.addRestart(DateTime.now().difference(waiting).inMilliseconds / 1000);
      run.waitingSince = null;
    }
    final segment = (
      start: event.start,
      duration: event.duration,
      cues: event.cues,
    );
    final end = event.start + event.duration;
    final skip = run.skipUntil;
    if (skip != null) {
      if (event.start < skip - seamTolerance) return;
      run.skipUntil = null;
    }
    final join = run.join;
    if (join != null) {
      final commit = join.offer(segment);
      if (commit != null) _commitJoin(run, commit);
      return;
    }
    if (!keepAtRunStart(
      start: event.start,
      duration: event.duration,
      target: run.target,
      extractFrom: run.extractFrom,
      clean: run.clean,
    )) {
      debugSeams.lastWhere((s) => s['run'] == run.serial)['dropped'] = [
        event.start,
        end,
        event.cues.map((c) => c.content).join(),
      ];
      return;
    }
    final next = _nextKnown(run);
    if (next != null && end > next + seamTolerance) {
      // into text already known: held back until the join can be made
      final old = [
        for (final s in transcript.segments)
          if (s.run != run.store.id &&
              s.start >= next - 0.25 &&
              s.start < next + seamMaxOverlap + 40)
            (start: s.start, duration: s.duration),
      ];
      run
        ..join = SeamJoin(old, from: next)
        ..joinFrom = next;
      final commit = run.join!.offer(segment);
      if (commit != null) _commitJoin(run, commit);
      return;
    }
    transcript.addSegment(run.store, event.start, event.duration, event.cues);
  }

  /// The join is made: the old segments the new run's overlap go, whole,
  /// and the new run's take their place (design 4.3, end). The run has
  /// then done its part — what follows is known — and ends; where the
  /// source cannot seek, it goes on but drops what it recognises until
  /// the known stretch is behind it.
  void _commitJoin(_Run run, SeamCommit commit) {
    final joinFrom = run.joinFrom!;
    final removed = <List<double>>[];
    transcript.replace(run.store, commit.segments, (s) {
      final goes =
          s.run != run.store.id &&
          s.start >= joinFrom - 0.25 &&
          SeamJoin.replaces(commit, s.start, s.start + s.duration);
      if (goes) removed.add([s.start, s.start + s.duration]);
      return goes;
    });
    debugSeams.add({
      'kind': 'join',
      'run': run.serial,
      'joinFrom': joinFrom,
      'until': commit.until,
      'held': [
        for (final s in commit.segments) [s.start, s.start + s.duration],
      ],
      'removed': removed,
    });
    run
      ..join = null
      ..joinFrom = null;
    if (seekable) {
      _endRun(run);
      _tick();
    } else {
      run.skipUntil = transcript.coveredEnd(commit.until);
    }
  }
}

/// How far the device lets transcription run ahead (design 12): unlimited
/// on a desktop or on a charger, only as far as needed on battery, and
/// less still in battery saver or under 20 %.
Future<AsrPower> readAsrPower() async {
  if (!PlatformUtils.isMobile) return AsrPower.unlimited;
  try {
    final battery = Battery();
    final state = await battery.batteryState;
    if (state == BatteryState.charging || state == BatteryState.full) {
      return AsrPower.unlimited;
    }
    if (await battery.isInBatterySaveMode) return AsrPower.saver;
    if (await battery.batteryLevel < 20) return AsrPower.saver;
    return AsrPower.battery;
  } catch (_) {
    return AsrPower.battery;
  }
}

/// BudouX's Japanese phrase model, or null if it cannot be read — in which
/// case Japanese simply breaks the way it always did.
Future<String?> loadJapaneseSegmenter() async {
  try {
    return await rootBundle.loadString(
      'packages/budoux_dart/models/ja.json',
    );
  } catch (_) {
    return null;
  }
}

/// BudouX's Simplified Chinese phrase model, or null; see
/// [loadJapaneseSegmenter].
Future<String?> loadChineseSegmenter() async {
  try {
    return await rootBundle.loadString(
      'packages/budoux_dart/models/zh-hans.json',
    );
  } catch (_) {
    return null;
  }
}

class AsrService extends GetxService {
  static AsrService get to => Get.find<AsrService>();

  final store = AsrModelStore();

  AsrSession? _current;

  /// True when both models are on disk and a job can start without a download.
  bool get modelsReady => store.isReady;

  int get downloadSize => AsrModelCatalog.required
      .where((model) => !store.isInstalled(model))
      .fold(0, (sum, model) => sum + model.totalSize);

  /// Whether a video with no subtitles should be transcribed without asking.
  bool shouldAutoStart({required bool hasSubtitles}) {
    if (hasSubtitles || !Pref.asrAsked) return false;
    return Pref.asrMode != AsrMode.manual && modelsReady;
  }

  /// Starts (or restarts) transcription for [key].
  ///
  /// [source] is what libmpv should decode — the audio stream URL for an
  /// online video, the file for a local one. Passing the audio stream alone
  /// rather than the player's `edl://` avoids pulling video-stream headers.
  ///
  /// [playhead] and [duration] are the page's player's position and length
  /// in seconds (null where not known — another page has the player, say);
  /// without them the session runs from 0 to the end. [seekable] false
  /// keeps it to that one run whatever the viewer does (a source that
  /// cannot be started from a position). [refresh] is asked for the source
  /// at every later run (see [AsrSourceRefresh]).
  Future<AsrSession> start({
    required String key,
    required String source,
    String? referer,
    String? userAgent,
    bool auto = false,
    bool seekable = true,
    double? Function()? playhead,
    double? Function()? duration,
    AsrSourceRefresh? refresh,
    AsrPower? power,
  }) async {
    // one job at a time: a job another page still has is failed, not merely
    // closed, so that page hears it is gone (see [stop])
    await stop(reason: '已被另一个视频的转录取代');
    final session = AsrSession._(
      key,
      seekable: seekable,
      playhead: playhead,
      duration: duration,
      refreshSource: refresh,
    );
    if (power != null) {
      session
        ..power = power
        ..debugPowerFixed = true;
    }
    _current = session;
    unawaited(_run(session, source, referer, userAgent, auto));
    return session;
  }

  AsrSession? sessionFor(String key) => _current?.key == key ? _current : null;

  /// Whether a job is running right now.
  bool get isBusy => _current?.isRunning ?? false;

  /// Whether a job holds the recogniser's memory, running or paused.
  bool get holdsModels => _current?.holdsModels ?? false;

  /// Ends the current job.
  ///
  /// With a [reason], the session is marked failed with it *before* being
  /// closed: a closed session no longer reports state, so without this the
  /// page would never hear that its job ended — its loading gate would sit
  /// out the full cap and the subtitle menu would keep showing progress for
  /// a job that is gone. Failed, the page does what it does for any failure:
  /// closes the gate, says why, offers a retry.
  ///
  /// With [only], nothing happens unless that is the current job: a page
  /// tearing its own down late must not stop another page's that replaced it.
  Future<void> stop({String? reason, AsrSession? only}) async {
    final session = _current;
    if (only != null && session != only) return;
    _current = null;
    if (reason != null && session != null && session.isRunning) {
      session._set(AsrState(stage: AsrStage.failed, message: reason));
    }
    await session?.dispose();
  }

  /// The model guard's stop: the current job's run ends and its recogniser
  /// is let go of, but its transcript stays (see [AsrSession.suspend]).
  void suspend(String reason) => _current?.suspend(reason);

  /// The app is back: a suspended job carries on.
  void resume() => _current?.resume();

  @visibleForTesting
  void debugAdopt(AsrSession session) => _current = session;

  Future<void> _run(
    AsrSession session,
    String source,
    String? referer,
    String? userAgent,
    bool auto,
  ) async {
    try {
      if (!store.isReady) {
        final token = AsrCancelToken();
        session
          .._download = token
          .._set(const AsrState(stage: AsrStage.models));
        await store.ensureAll(
          token: token,
          onProgress: (p) => session._set(
            AsrState(
              stage: AsrStage.models,
              progress: p.total == 0 ? null : p.received / p.total,
              message: p.verifying ? '校验 ${p.label}' : '下载 ${p.label}',
            ),
          ),
        );
        session._download = null;
      }
      if (session._closed) return;
      // at once, before anything is awaited: a caller waiting for the job
      // to stop being busy must not find it idle in between
      session._set(const AsrState(stage: AsrStage.extracting));
      await session._begin(
        source: source,
        referer: referer,
        userAgent: userAgent,
        auto: auto,
        models: (
          japaneseSegmenter: await loadJapaneseSegmenter(),
          chineseSegmenter: await loadChineseSegmenter(),
          itn: true,
          modelPath: store
              .fileOf(
                AsrModelCatalog.senseVoice,
                AsrModelCatalog.senseVoice.files[0],
              )
              .path,
          tokensPath: store
              .fileOf(
                AsrModelCatalog.senseVoice,
                AsrModelCatalog.senseVoice.files[1],
              )
              .path,
          vadPath: store
              .fileOf(AsrModelCatalog.vad, AsrModelCatalog.vad.files.first)
              .path,
          threads: Pref.asrThreads,
          language: Pref.asrLanguage,
        ),
      );
    } on AsrCancelled {
      session._set(const AsrState.idle());
    } catch (e, stack) {
      // a transcription that fails silently is indistinguishable from one
      // that was never started: put it in the error log the user can read
      Utils.reportError('asr: $e', stack);
      session._set(AsrState(stage: AsrStage.failed, message: e.toString()));
    }
  }

  /// Compares at the "major language" level: `zh` covers zh-Hans, zh-Hant and
  /// yue, which is as fine as SenseVoice's own language ID is useful.
  ///
  /// The comparison is against the language the *app* is in, not the device's
  /// — the point is whether the user can follow the speech, and the app is
  /// what they chose to read. That is `Get.locale`, which GetMaterialApp
  /// sets from the locale main.dart gives it — fixed to Chinese, the one
  /// language the interface is written in. Before it is set, Chinese too:
  /// the device's locale is not what the app displays, and a Chinese-UI user
  /// on an English phone would have Chinese captions translated to English.
  static bool _isAppLanguage(String spoken) =>
      isSameMajorLanguage(spoken, appLanguage);

  /// The language the app is in, as a major language code (`zh`, `en`, …).
  /// Also what translation translates into.
  static String get appLanguage => Get.locale?.languageCode ?? 'zh';

  /// True when [spoken] and [appLanguage] are the same language at the level
  /// a viewer cares about.
  ///
  /// Cantonese and Mandarin count as one here: SenseVoice reports `yue` for
  /// plenty of Mandarin speech with an accent, and transcribing a video for
  /// someone who already understands it is worse than not transcribing it.
  /// Finer distinctions (zh-Hans vs zh-Hant) are deliberately not made.
  ///
  /// Public because the caption-compare probe needs the same notion when it
  /// decides which track is a fair baseline.
  static bool isSameMajorLanguage(String spoken, String appLanguage) {
    final a = spoken.trim().toLowerCase();
    final b = appLanguage.trim().toLowerCase();
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    const chinese = {
      'zh',
      'yue',
      'cmn',
      'zh-cn',
      'zh-tw',
      'zh-hans',
      'zh-hant',
    };
    return chinese.contains(a) && chinese.contains(b);
  }
}
