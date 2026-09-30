/// LibrePili: the models page's performance test — how fast this device
/// runs the on-device models, alone and together, in about a minute.
///
/// The question it answers is the one noisy-speech §18 ran into on a Pixel
/// 6 Pro: translation shares the CPU with transcription, and beside it runs
/// at about a third of its speed alone (reply 8.4–9.6 → 2.9 tok/s, §18.1).
/// A test of the translation model alone would overstate what the viewer
/// gets about threefold, so the line that decides the advice is translated
/// while SenseVoice decodes speech over and over, as it does while the
/// transcript races ahead of the viewer.
///
/// Only installed models are tested; nothing is downloaded for the test.
/// For a model that is not installed there is no estimate either: the one
/// cross-model ratio on record (Hy-MT2 ≈1.3–1.5× Gemma's speed beside
/// SenseVoice, translation-bench 1B) comes from one phone under a different
/// load, and Gemma 4 E2B's per-layer embeddings keep its speed from
/// following its file size — a number shown as this device's would be made
/// up. The advice names the model to try, and the test can be run again
/// once it is downloaded.
///
/// Both run in this process, each with its own threads, exactly as the app
/// runs them: the recogniser with Pref.asrThreads (half the cores), llama.cpp
/// with LlamaTranslationEngine's (four on phones, its own choice on
/// desktops), through the same AsrTranscriber and LlamaTranslationEngine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/model_bench/bench_advice.dart';
import 'package:PiliPlus/services/translate/llama_engine.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart' as win32;

/// Where the test is: a fraction of the whole and what it is doing.
typedef ModelBenchProgress = ({double fraction, String label});

/// The speech the recognisers are timed on.
///
/// Real speech, not silence or noise: the VAD passes silence over without
/// decoding it, so a silent clip would time the VAD alone. 20 s of John
/// Greenman reading the Gettysburg Address for LibriVox — from "Four score
/// and seven years ago" — cut from
/// https://archive.org/details/gettysburg_johng_librivox (23.0–43.0 s of
/// gettysburg_address.mp3), 16 kHz mono AAC at 32 kbit/s, 84 KB — AAC
/// because it is what bilibili serves, so every libmpv build here decodes
/// it; an Ogg Opus copy decoded to nothing on the Windows build. LibriVox
/// recordings are dedicated to the public domain (the item's licence is
/// creativecommons.org/licenses/publicdomain), and the text is Lincoln's,
/// 1863. English, so both SenseVoice and the English model read it; details
/// in research/model-bench-2026-09-29.md.
const benchSpeechAsset = 'assets/bench/speech_en.m4a';

/// What each model is asked to translate: two sentences of a video's
/// speech, about 13 s of it spoken — 45 prompt tokens with the prompt's
/// wording, close to the 4 a media-second a unit needs (noisy-speech
/// §18.1). Shorter than a full unit (the paragraph --translate-probe adds)
/// so that beside transcription on a Pixel 6 Pro, reading at 9 tok/s, the
/// prompt is read within the window with time left to time the reply.
const benchLine =
    "I want to be upfront about this, because I don't want you to get the "
    'wrong idea of what the experience actually felt like. It looked packed '
    "in real time, but the pace really wasn't that fast.";

class ModelBench with WidgetsBindingObserver {
  ModelBench({
    this.asrStore,
    this.translationStore,
    this.translationFile,
    this.onProgress,
    this.stopInBackground = true,
  });

  /// Where the models are looked for; the app's own stores by default.
  final AsrModelStore? asrStore;
  final AsrModelStore? translationStore;

  /// A GGUF to test besides the installed ones: the self-test's
  /// `--translate-model`, since a phone test build has no models of its own.
  final String? translationFile;
  final ValueChanged<ModelBenchProgress>? onProgress;

  /// Whether going to the background stops the test (the page's run: a
  /// phone in the background is throttled and the numbers would mean
  /// nothing). The self-test keeps going.
  final bool stopInBackground;

  /// How long each recogniser is timed alone. At least one pass of the
  /// clip whatever this says: 20 s at 10× is 2 s on a Pixel 6 Pro.
  static const asrWindow = Duration(seconds: 4);

  /// A first short line after loading, not timed: it pages the model's
  /// weights in, which the first unit of a real session pays once.
  static const warmUpWindow = Duration(seconds: 3);

  /// How long the line gets alone, and beside transcription. A reply still
  /// being written when the window closes is cut short; its rate so far is
  /// what is kept. Beside transcription, a Pixel 6 Pro would read the
  /// prompt in about 5 s and write ~20 reply tokens in the rest.
  static const aloneWindow = Duration(seconds: 6);
  static const concurrentWindow = Duration(seconds: 12);

  /// The planned length of each step, for the progress bar only.
  static const _prepareSeconds = 1.0;
  static const _asrSeconds = 5.0;
  static const _englishSeconds = 9.0;
  static const _translationLoadSeconds = 4.0;

  String? _stopped;
  LlamaTranslationEngine? _engine;
  final _recognisers = <_Recogniser>{};

  /// Stops the test; [run] returns what it had, marked interrupted.
  void cancel([String reason = '已取消']) {
    if (_stopped != null) return;
    _stopped = reason;
    _engine?.cancel();
    for (final r in _recognisers) {
      r.stop();
    }
  }

  bool get _cancelled => _stopped != null;

  @override
  void didHaveMemoryPressure() {
    // Android reports hiding the UI as memory pressure too (model_guard):
    // away, it is the background, not memory
    final state = WidgetsBinding.instance.lifecycleState;
    if (PlatformUtils.isMobile &&
        state != null &&
        state != AppLifecycleState.resumed) {
      if (stopInBackground) cancel('应用切到了后台');
      return;
    }
    _pressure = true;
    cancel('系统报告内存不足');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (stopInBackground &&
        PlatformUtils.isMobile &&
        state == AppLifecycleState.paused) {
      cancel('应用切到了后台');
    }
  }

  var _pressure = false;

  /// Something else holding the models: the numbers would be shared with
  /// it, and loading a second copy is the memory the guard is there for.
  static String? busyReason() {
    bool live<S>() => Get.isRegistered<S>() && !Get.isPrepared<S>();
    if (live<AsrService>() && AsrService.to.holdsModels) {
      return '正在转录，请先关闭字幕转录或退出视频后再测试';
    }
    if (live<TranslationService>() && TranslationService.to.isBusy) {
      return '正在翻译，请先停止翻译后再测试';
    }
    return null;
  }

  Future<ModelBenchResult> run() async {
    final clock = Stopwatch()..start();
    final asrStore = this.asrStore ?? AsrService.to.store;
    final translationStore =
        this.translationStore ?? TranslationService.to.store;
    final translationSupported = TranslationService.supported;
    final threads = Pref.asrThreads;

    // what will be tested, so the progress bar knows the plan
    final asrInstalled = asrStore.isReady;
    final englishInstalled = asrInstalled && asrStore.isEnglishReady;
    final models = <({String id, String label, String file})>[];
    final notInstalled = <String>[];
    if (translationSupported) {
      for (final model in TranslationModelCatalog.all) {
        if (translationStore.isInstalled(model)) {
          models.add((
            id: model.id,
            label: model.label,
            file: translationStore.fileOf(model, model.files.first).path,
          ));
        } else {
          notInstalled.add(model.label);
        }
      }
      if (translationFile case final file? when File(file).existsSync()) {
        final name = path.basename(file);
        final known = TranslationModelCatalog.all
            .where((m) => m.files.first.name == name)
            .firstOrNull;
        if (known != null) notInstalled.remove(known.label);
        models
          ..removeWhere((m) => m.id == known?.id)
          ..add((
            id: known?.id ?? name,
            label: known?.label ?? name,
            file: file,
          ));
      }
    }
    final perModel =
        _translationLoadSeconds +
        (warmUpWindow + aloneWindow + concurrentWindow).inMilliseconds / 1000;
    final steps = <double>[
      _prepareSeconds,
      if (englishInstalled) _englishSeconds,
      if (asrInstalled) _asrSeconds,
      if (asrInstalled)
        for (final _ in models) perModel,
    ];
    final planned = steps.fold(0.0, (a, b) => a + b);
    var step = -1;
    var stepLabel = '';
    var stepClock = Stopwatch();
    void begin(String label) {
      step++;
      stepLabel = label;
      stepClock = Stopwatch()..start();
      _report(steps, planned, step, stepLabel, stepClock);
    }

    // memory: before anything is loaded, then sampled until the end
    final totalMb = _totalMemoryMb();
    final availableAtStart = _availableMemoryMb();
    final rssAtStart = ProcessInfo.currentRss ~/ (1 << 20);
    var peakRss = rssAtStart;
    var minAvailable = availableAtStart;
    var ticks = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final rss = ProcessInfo.currentRss ~/ (1 << 20);
      if (rss > peakRss) peakRss = rss;
      // reading the system's figure is a file read or a syscall: once a
      // second is enough
      if (++ticks % 4 == 0) {
        final available = _availableMemoryMb();
        if (available != null &&
            (minAvailable == null || available < minAvailable!)) {
          minAvailable = available;
        }
      }
      if (step >= 0) _report(steps, planned, step, stepLabel, stepClock);
    });

    BenchAsrSpeed? senseVoice;
    BenchAsrSpeed? english;
    double? clipSeconds;
    final translations = <BenchTranslation>[];
    String? error;
    final work = Directory(path.join(tmpDirPath, 'model_bench'));

    ModelBenchResult result() => ModelBenchResult(
      at: DateTime.now(),
      platform: Platform.operatingSystem,
      cores: Platform.numberOfProcessors,
      asrThreads: threads,
      llamaThreads: PlatformUtils.isMobile ? 4 : 0,
      repacks: LlamaTranslationEngine.repacks,
      clipSeconds: clipSeconds,
      senseVoice: senseVoice,
      english: english,
      englishInstalled: englishInstalled,
      asrInstalled: asrInstalled,
      translationSupported: translationSupported,
      translations: translations,
      notInstalled: notInstalled,
      memory: BenchMemory(
        totalMb: totalMb,
        availableAtStartMb: availableAtStart,
        minAvailableMb: minAvailable,
        rssAtStartMb: rssAtStart,
        peakRssMb: peakRss,
        pressure: _pressure,
      ),
      interrupted: _stopped,
      error: error,
    );

    if (busyReason() case final busy?) {
      sampler.cancel();
      error = busy;
      return result();
    }

    WidgetsBinding.instance.addObserver(this);
    _Recogniser? recogniser;
    try {
      if (!asrInstalled) return result();

      begin('准备语音样本');
      final clip = File(path.join(work.path, 'speech_en.m4a'));
      await clip.parent.create(recursive: true);
      await clip.writeAsBytes(
        (await rootBundle.load(benchSpeechAsset)).buffer.asUint8List(),
      );
      final pcm = path.join(work.path, 'speech_en.pcm');
      final audio = await AsrAudioExtractor.extract(
        source: clip.path,
        output: pcm,
        timeout: const Duration(seconds: 30),
      );
      clipSeconds = audio.durationSeconds;
      if (clipSeconds <= 0) throw StateError('语音样本解码失败');
      if (_cancelled) return result();

      final sense = (
        modelPath: asrStore
            .fileOf(
              AsrModelCatalog.senseVoice,
              AsrModelCatalog.senseVoice.files[0],
            )
            .path,
        tokensPath: asrStore
            .fileOf(
              AsrModelCatalog.senseVoice,
              AsrModelCatalog.senseVoice.files[1],
            )
            .path,
        vadPath: asrStore
            .fileOf(AsrModelCatalog.vad, AsrModelCatalog.vad.files.first)
            .path,
        threads: threads,
        language: '',
        // the segmenters only place line breaks in Chinese and Japanese
        // text; the clip is English
        japaneseSegmenter: null,
        chineseSegmenter: null,
        itn: true,
        english: null,
        englishFirst: false,
      );

      // the English model first, and gone before SenseVoice loads: in a
      // session one replaces the other (both resident only for the 3–5 s
      // of a switch, noisy-speech §16)
      if (englishInstalled) {
        begin('测试英语识别模型');
        final parakeet = AsrModelCatalog.parakeet;
        String file(int i) => asrStore.fileOf(parakeet, parakeet.files[i]).path;
        final englishModels = asrModelsWithEnglish(sense, (
          encoder: file(0),
          decoder: file(1),
          joiner: file(2),
          tokens: file(3),
        ), first: true);
        final r = await _Recogniser.open(englishModels, pcm, clipSeconds);
        _recognisers.add(r);
        try {
          english = await r.time(asrWindow);
        } finally {
          _recognisers.remove(r);
          await r.close();
        }
        if (_cancelled) return result();
      }

      begin('测试语音转录');
      recogniser = await _Recogniser.open(sense, pcm, clipSeconds);
      _recognisers.add(recogniser);
      senseVoice = await recogniser.time(asrWindow);
      if (_cancelled) return result();

      for (final model in models) {
        begin('测试翻译：${model.label}');
        translations.add(
          await _translation(model, recogniser, asrAlone: senseVoice?.speed),
        );
        if (_cancelled) return result();
      }
      return result();
    } catch (e, s) {
      EventLog.add('bench', 'failed: $e');
      debugPrint('model bench: $e\n$s');
      error = '测试出错：$e';
      return result();
    } finally {
      sampler.cancel();
      WidgetsBinding.instance.removeObserver(this);
      if (recogniser != null) {
        _recognisers.remove(recogniser);
        await recogniser.close();
      }
      // the clip and its PCM: nothing of the test stays behind
      try {
        if (work.existsSync()) await work.delete(recursive: true);
      } catch (_) {}
      EventLog.add(
        'bench',
        'done in ${clock.elapsedMilliseconds} ms'
            '${_stopped == null ? '' : ', interrupted: $_stopped'}',
      );
    }
  }

  void _report(
    List<double> steps,
    double planned,
    int step,
    String label,
    Stopwatch stepClock,
  ) {
    final callback = onProgress;
    if (callback == null || planned <= 0) return;
    final before = steps.take(step).fold(0.0, (a, b) => a + b);
    final within = (stepClock.elapsedMilliseconds / 1000 / steps[step]).clamp(
      0.0,
      0.95,
    );
    callback((
      fraction: ((before + within * steps[step]) / planned).clamp(0.0, 1.0),
      label: label,
    ));
  }

  /// One translation model: loaded, warmed up, the line alone, then the
  /// line again while [recogniser] decodes the clip in a loop.
  Future<BenchTranslation> _translation(
    ({String id, String label, String file}) model,
    _Recogniser recogniser, {
    double? asrAlone,
  }) async {
    int? loadMs;
    BenchTokenRates? alone;
    BenchTokenRates? concurrent;
    BenchAsrSpeed? beside;
    try {
      final loadClock = Stopwatch()..start();
      final engine = _engine = await LlamaTranslationEngine.load(model.file);
      loadMs = loadClock.elapsedMilliseconds;
      try {
        if (_cancelled) throw const _Stopped();
        await _complete(engine, 'Hello, everyone.', warmUpWindow);
        if (_cancelled) throw const _Stopped();
        alone = await _complete(engine, benchLine, aloneWindow);
        if (_cancelled) throw const _Stopped();
        final loop = recogniser.loop();
        try {
          final start = recogniser.decoded;
          final clock = Stopwatch()..start();
          concurrent = await _complete(engine, benchLine, concurrentWindow);
          beside = BenchAsrSpeed(
            mediaSeconds: recogniser.decoded - start,
            wallMs: clock.elapsedMilliseconds,
          );
        } finally {
          await recogniser.endLoop(loop);
        }
      } finally {
        _engine = null;
        await engine.dispose();
      }
    } on _Stopped {
      // what was measured before the stop is kept
    } catch (e) {
      return BenchTranslation(
        modelId: model.id,
        label: model.label,
        loadMs: loadMs,
        alone: alone,
        asrAloneSpeed: asrAlone,
        error: '$e',
      );
    }
    return BenchTranslation(
      modelId: model.id,
      label: model.label,
      loadMs: loadMs,
      alone: alone,
      asrAloneSpeed: asrAlone,
      concurrent: _cancelled ? null : concurrent,
      asrBeside: _cancelled ? null : beside,
    );
  }

  /// [text] translated into Chinese, cut off after [window]; the engine's
  /// own figures for it.
  Future<BenchTokenRates?> _complete(
    LlamaTranslationEngine engine,
    String text,
    Duration window,
  ) async {
    engine.lastStats = null;
    // cancelling stops the reply between tokens; a prompt still being read
    // is read to the end first (llamadart checks the flag per reply token)
    final cut = Timer(window, engine.cancel);
    try {
      await engine.complete(translationPrompt(text, target: 'zh'));
    } finally {
      cut.cancel();
    }
    return switch (engine.lastStats) {
      final s? => BenchTokenRates(
        promptTokens: s.promptTokens,
        replyTokens: s.replyTokens,
        firstMs: s.firstMs,
        totalMs: s.totalMs,
      ),
      null => null,
    };
  }

  /// The machine's physical memory, in MB, where it can be read.
  static int? _totalMemoryMb() => _memory().total;

  /// What the system could still give without swapping, in MB: Linux's
  /// MemAvailable (page cache it can drop included), Windows'
  /// ullAvailPhys.
  static int? _availableMemoryMb() => _memory().available;

  static ({int? total, int? available}) _memory() {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final lines = File('/proc/meminfo').readAsLinesSync();
        int? kb(String key) => switch (lines
            .where((l) => l.startsWith('$key:'))
            .firstOrNull) {
          final line? => int.tryParse(line.replaceAll(RegExp('[^0-9]'), '')),
          null => null,
        };
        return (
          total: switch (kb('MemTotal')) {
            final v? => v ~/ 1024,
            null => null,
          },
          available: switch (kb('MemAvailable')) {
            final v? => v ~/ 1024,
            null => null,
          },
        );
      }
      if (Platform.isWindows) {
        final status = calloc<win32.MEMORYSTATUSEX>();
        try {
          status.ref.dwLength = sizeOf<win32.MEMORYSTATUSEX>();
          if (!win32.GlobalMemoryStatusEx(status).value) {
            return (total: null, available: null);
          }
          return (
            total: status.ref.ullTotalPhys ~/ (1 << 20),
            available: status.ref.ullAvailPhys ~/ (1 << 20),
          );
        } finally {
          calloc.free(status);
        }
      }
    } catch (_) {}
    return (total: null, available: null);
  }

  /// The last result, if one was stored.
  static ModelBenchResult? get last {
    final stored = Pref.modelBench;
    if (stored == null) return null;
    try {
      return ModelBenchResult.fromJson(jsonDecode(stored));
    } catch (_) {
      return null;
    }
  }

  /// Kept as JSON text: one value, whatever shape later versions give it.
  static Future<void> remember(ModelBenchResult result) => GStorage.setting.put(
    SettingBoxKey.modelBench,
    jsonEncode(result.toJson()),
  );
}

class _Stopped implements Exception {
  const _Stopped();
}

/// One recogniser over the clip, pass after pass.
class _Recogniser {
  _Recogniser._(this._transcriber, this._pcm, this._clipSeconds, this.loadMs) {
    _events = _transcriber.events.listen((event) {
      switch (event) {
        case AsrProgressUpdate(:final done, :final run) when run == _run:
          _done = done;
        case AsrRunEndEvent(:final run) when run == _run:
          _passes++;
          _done = 0;
          _runEnd?.complete();
          _runEnd = null;
        case AsrErrorEvent(:final message):
          _error = message;
          _runEnd?.complete();
          _runEnd = null;
        default:
      }
    });
  }

  static Future<_Recogniser> open(
    AsrModels models,
    String pcm,
    double clipSeconds,
  ) async {
    final clock = Stopwatch()..start();
    final transcriber = await AsrTranscriber.open(models);
    try {
      await transcriber.ready.timeout(const Duration(seconds: 30));
    } catch (_) {
      transcriber.close();
      rethrow;
    }
    return _Recogniser._(
      transcriber,
      pcm,
      clipSeconds,
      clock.elapsedMilliseconds,
    );
  }

  final AsrTranscriber _transcriber;
  late final StreamSubscription<AsrEvent> _events;
  final String _pcm;
  final double _clipSeconds;
  final int loadMs;
  var _run = 0;
  var _passes = 0;
  var _done = 0.0;
  Completer<void>? _runEnd;
  String? _error;
  var _stopped = false;

  /// Media-seconds decoded so far, over every pass.
  double get decoded => _passes * _clipSeconds + _done;

  /// One pass over the clip.
  Future<void> _pass() {
    final end = _runEnd = Completer<void>();
    _run = _transcriber.run(pcmPath: _pcm, offset: 0, follow: false);
    return end.future;
  }

  /// Passes for at least [window] and at least one, or until [stop]ped.
  Future<BenchAsrSpeed?> time(Duration window) async {
    final clock = Stopwatch()..start();
    final start = decoded;
    do {
      await _pass();
      if (_error case final error?) throw StateError(error);
    } while (!_stopped && clock.elapsed < window);
    if (_stopped) return null;
    return BenchAsrSpeed(
      mediaSeconds: decoded - start,
      wallMs: clock.elapsedMilliseconds,
      loadMs: loadMs,
    );
  }

  bool _looping = false;

  /// Passes one after another until [endLoop].
  Future<void> loop() async {
    _looping = true;
    while (_looping && !_stopped) {
      await _pass();
      if (_error != null) return;
    }
  }

  Future<void> endLoop(Future<void> loop) async {
    _looping = false;
    _transcriber.stopRun();
    await loop.timeout(AsrTranscriber.stopGrace, onTimeout: () {});
  }

  void stop() {
    _stopped = true;
    _looping = false;
    _transcriber.stopRun();
    // the pass waited on ends here rather than on a run end that a stuck
    // isolate might never send
    _runEnd?.complete();
    _runEnd = null;
  }

  /// Ends the recogniser and waits until its memory is given back, so the
  /// next model is not loaded on top of it.
  Future<void> close() async {
    _stopped = true;
    _runEnd?.complete();
    _runEnd = null;
    await _events.cancel();
    _transcriber.close();
    await _transcriber.exited.timeout(
      AsrTranscriber.stopGrace + const Duration(seconds: 1),
      onTimeout: () {},
    );
  }
}
