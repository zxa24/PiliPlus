/// LibrePili: one job at a time, from "this video has no subtitles" to a
/// subtitle track.
///
/// The pipeline is extract → detect → transcribe, and every step can be
/// abandoned: the user can leave the page, the models may be missing, and a
/// video whose speech turns out to be in the app's own language is dropped
/// rather than transcribed (see [AsrMode.foreign]).
library;

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/pcm_reader.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

enum AsrStage { idle, models, extracting, transcribing, done, failed }

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
    AsrStage.done => '已完成',
    AsrStage.failed => message ?? '失败',
  };
}

/// One transcription, tied to one video page.
class AsrSession {
  AsrSession._(this.key);

  /// A session with no job behind it, for widget tests.
  @visibleForTesting
  factory AsrSession.debugFor(String key) = AsrSession._;

  /// Usually the cid: one job per part, which is the granularity subtitles
  /// have anyway.
  final String key;

  final state = const AsrState.idle().obs;
  final cues = <AsrCue>[].obs;

  /// Stretches the VAD called speech. Diagnostic only — nothing in the UI
  /// reads it — but it is the only way to tell a gap that is silence from a
  /// gap where speech was recognised into nothing.
  final segments = <({double start, double duration})>[];

  AsrTranscriber? _transcriber;
  StreamSubscription<AsrEvent>? _events;
  AsrCancelToken? _download;
  String? _pcmPath;
  var _closed = false;

  /// Seconds of audio decoded so far, for the "提取音频 Ns" label.
  double _extracted = 0;

  /// Touching this file tells the decoder isolate to stop. It cannot be
  /// killed outright without leaking the mpv context it holds, and it no
  /// longer ends on its own when the page closes.
  String get _cancelPath => '${_pcmPath ?? ''}.cancel';

  bool get isRunning => state.value.isBusy;

  /// A VTT the existing subtitle path can take as `memory://` data.
  String get vtt => cues.toVtt();

  void _set(AsrState value) {
    if (!_closed) state.value = value;
  }

  @visibleForTesting
  void debugSet(AsrState value) => _set(value);

  Future<void> dispose() async {
    _closed = true;
    _download?.cancel();
    _transcriber?.stop();
    await _events?.cancel();
    final pcm = _pcmPath;
    if (pcm != null) {
      // ask the decoder to stop before taking the file away, so it does not
      // keep writing to a handle whose name is gone
      try {
        File(_cancelPath).writeAsStringSync('1');
      } catch (_) {}
    }
    _pcmPath = null;
    if (pcm != null) {
      await _deleteScratch(pcm);
    }
  }

  /// The PCM and the two markers beside it.
  static Future<void> _deleteScratch(String pcm) async {
    for (final name in [
      pcm,
      PcmWindowReader.doneMarkerFor(pcm),
      '$pcm.cancel',
    ]) {
      try {
        final file = File(name);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
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
  Future<AsrSession> start({
    required String key,
    required String source,
    String? referer,
    String? userAgent,
    bool auto = false,
  }) async {
    await stop();
    final session = AsrSession._(key);
    _current = session;
    unawaited(_run(session, source, referer, userAgent, auto));
    return session;
  }

  AsrSession? sessionFor(String key) =>
      _current?.key == key ? _current : null;

  Future<void> stop() async {
    final session = _current;
    _current = null;
    await session?.dispose();
  }

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

      session._set(const AsrState(stage: AsrStage.extracting));
      final pcmPath = path.join(
        tmpDirPath,
        'asr',
        '${session.key}-${DateTime.now().millisecondsSinceEpoch}.pcm',
      );
      session._pcmPath = pcmPath;

      // Extraction is no longer awaited. It used to be, and the cost was the
      // whole file: nothing was recognised until every byte had been pulled,
      // which on a throttled CDN is minutes (googlevideo was measured at 2x
      // realtime — a one-hour video meant a half-hour wait for the first
      // subtitle). The recogniser now walks the file while it is still being
      // written, so the first cues arrive seconds in and the rest trail the
      // download.
      final extraction = AsrAudioExtractor.extract(
        source: source,
        output: pcmPath,
        referer: referer,
        userAgent: userAgent,
        cancelPath: session._cancelPath,
        onSeconds: (seconds) => session._extracted = seconds,
      );
      // a failure before any bytes exist must not be swallowed while we wait
      Object? extractError;
      unawaited(extraction.catchError((Object e) {
        extractError = e;
        return (path: pcmPath, durationSeconds: 0.0);
      }));

      // enough audio for the VAD to have something to chew on; below this the
      // recogniser would start, hit the end of the file and wait anyway
      const headStart = asrBytesPerSecond * 2;
      final file = File(pcmPath);
      while (!session._closed && extractError == null) {
        final size = file.existsSync() ? file.lengthSync() : 0;
        if (size >= headStart) break;
        if (File(PcmWindowReader.doneMarkerFor(pcmPath)).existsSync()) break;
        session._set(
          AsrState(
            stage: AsrStage.extracting,
            message: '提取音频 ${session._extracted.toStringAsFixed(0)}s',
          ),
        );
        await Future.delayed(const Duration(milliseconds: 150));
      }
      if (session._closed) return;
      if (extractError != null) throw extractError!;

      session._set(const AsrState(stage: AsrStage.transcribing, progress: 0));
      final transcriber = await AsrTranscriber.start((
        pcmPath: pcmPath,
        follow: true,
        japaneseSegmenter: await loadJapaneseSegmenter(),
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
      ));
      session._transcriber = transcriber;

      final completer = Completer<void>();
      session._events = transcriber.events.listen(
        (event) {
          switch (event) {
            case AsrCuesEvent(:final cues):
              session.cues.addAll(cues);
            case AsrSegmentEvent(:final start, :final duration):
              // kept so a caller can tell a silent stretch from speech that
              // produced nothing; the UI does not read it
              session.segments.add((start: start, duration: duration));
            case AsrProgressUpdate(:final done, :final total):
              session._set(
                AsrState(
                  stage: AsrStage.transcribing,
                  progress: total == 0 ? null : (done / total).clamp(0, 1),
                  language: session.state.value.language,
                ),
              );
            case AsrLanguageEvent(:final language):
              session._set(
                AsrState(
                  stage: session.state.value.stage,
                  progress: session.state.value.progress,
                  language: language,
                ),
              );
              // an automatic run only exists to help with speech the user
              // cannot follow; if it turns out to be their own language,
              // stop rather than spend the battery
              if (auto &&
                  Pref.asrMode == AsrMode.foreign &&
                  _isAppLanguage(language)) {
                if (kDebugMode) {
                  debugPrint('asr: $language is the app language, stopping');
                }
                transcriber.stop();
                session._set(const AsrState.idle());
                if (!completer.isCompleted) completer.complete();
              }
            case AsrErrorEvent(:final message):
              Utils.reportError('asr: $message');
              session._set(
                AsrState(stage: AsrStage.failed, message: message),
              );
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );
      await completer.future;
      // the decoder may still hold the file; its result also carries any
      // error that only surfaced at the end
      try {
        await extraction;
      } catch (e) {
        if (session.cues.isEmpty) rethrow;
        // some audio was transcribed: a failure in the tail is worth logging
        // but not worth throwing away what the user can already read
        Utils.reportError('asr: extraction ended early: $e');
      }
      if (session._closed) return;
      if (session.state.value.stage != AsrStage.failed &&
          session.state.value.stage != AsrStage.idle) {
        session._set(
          AsrState(
            stage: AsrStage.done,
            progress: 1,
            language: session.state.value.language,
          ),
        );
      }
    } on AsrCancelled {
      session._set(const AsrState.idle());
    } catch (e, stack) {
      // a transcription that fails silently is indistinguishable from one
      // that was never started: put it in the error log the user can read
      Utils.reportError('asr: $e', stack);
      session._set(AsrState(stage: AsrStage.failed, message: e.toString()));
    } finally {
      // the PCM is only needed while decoding; a two-hour video leaves
      // 230 MB behind otherwise
      final pcm = session._pcmPath;
      session._pcmPath = null;
      if (pcm != null) {
        await AsrSession._deleteScratch(pcm);
      }
    }
  }

  /// Compares at the "major language" level: `zh` covers zh-Hans, zh-Hant and
  /// yue, which is as fine as SenseVoice's own language ID is useful.
  ///
  /// The comparison is against the language the *app* is in, not the device's
  /// — the point is whether the user can follow the speech, and the app is
  /// what they chose to read. `Get.locale` is null until the app is
  /// translated (still a TODO), so the device locale stands in until then.
  static bool _isAppLanguage(String spoken) => isSameMajorLanguage(
    spoken,
    (Get.locale ?? Get.deviceLocale)?.languageCode ?? 'zh',
  );

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
    const chinese = {'zh', 'yue', 'cmn', 'zh-cn', 'zh-tw', 'zh-hans', 'zh-hant'};
    return chinese.contains(a) && chinese.contains(b);
  }
}
