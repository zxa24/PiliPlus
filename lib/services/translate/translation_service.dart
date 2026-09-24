/// LibrePili: one translation at a time, and the model it runs on.
///
/// A translation is of a transcript ([AsrSession]) or of a video's own
/// captions, and is tied to the page that started it. Only one runs at once
/// — a second model resident alongside the first is up to 2.8 GB of mapped
/// file the phone does not have.
library;

import 'dart:ffi' show IntPtr, sizeOf;
import 'dart:io';

import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/llama_engine.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

class TranslationService extends GetxService {
  static TranslationService get to => Get.find<TranslationService>();

  /// Whether translation can run here at all. llama.cpp is built only for
  /// 64-bit processes — the armeabi-v7a APK carries none of it — and a
  /// 32-bit process could not map a model of 1–3 GB anyway. Everything that
  /// offers translation, or starts it by itself, checks this.
  static final bool supported = sizeOf<IntPtr>() == 8;

  /// Same store as the recogniser's models, its own directory.
  final store = AsrModelStore(
    root: Directory(path.join(appSupportDirPath, 'translate')),
  );

  TranslationSession? _current;
  AsrCancelToken? _download;

  /// Starts run one after another. Two overlapping ones would each stop the
  /// other's predecessor and then both run, the loser with a model loaded
  /// that nothing refers to any more.
  Future<void> _starting = Future.value();

  /// Sessions stopped but still releasing their model. [stop] forgets a
  /// session before it is disposed, so a start must wait for this too, or it
  /// loads a second model while the first is still resident.
  Future<void> _disposing = Future.value();

  AsrModel get model => TranslationModelCatalog.byId(Pref.translateModel);

  bool get modelReady => store.isInstalled(model);

  int get downloadSize => modelReady ? 0 : model.totalSize;

  /// Starts asked for and not yet running: queued behind [_starting], or
  /// waiting for their predecessor to let go of its model.
  var _pending = 0;

  /// Bumped by a stop of everything — memory, the background, the model
  /// being deleted — so a start asked for before it does not go on to load
  /// the model after it. [_stopReason] is what that start reports.
  var _stops = 0;
  String? _stopReason;

  bool get isBusy => _pending > 0 || (_current?.isRunning ?? false);

  /// The language translations are made into: the app's.
  String get target => AsrService.appLanguage;

  /// Whether a transcript in [spoken] needs translating at all.
  bool needed(String? spoken) =>
      spoken != null &&
      spoken.isNotEmpty &&
      !AsrService.isSameMajorLanguage(spoken, target);

  /// Whether the user chose automatic translation and it can run now.
  bool get shouldAutoTranslate =>
      supported &&
      Pref.translateAsked &&
      Pref.translateMode == TranslateMode.auto &&
      modelReady;

  /// Whether [spoken] should be translated without being asked.
  bool shouldAutoStart(String? spoken) => shouldAutoTranslate && needed(spoken);

  /// Starts translating [asr], replacing whatever was running.
  ///
  /// [position] is where playback is, in seconds: translation follows the
  /// viewer, not the recogniser.
  Future<TranslationSession> start({
    required AsrSession asr,
    required double Function() position,
  }) => _start(
    transcriptView(
      segments: () => asr.segments,
      cues: () => asr.cues,
      complete: () => asr.state.value.stage == AsrStage.done,
    ),
    position,
  );

  /// Starts translating a video's own captions, all known up front.
  Future<TranslationSession> startCaptions({
    required List<AsrCue> cues,
    required double Function() position,
  }) {
    final units = buildCaptionUnits(cues);
    return _start(
      (units: () => units, cues: () => cues, complete: () => true),
      position,
    );
  }

  Future<TranslationSession> _start(
    TranscriptView transcript,
    double Function() position,
  ) {
    final stops = _stops;
    _pending++;
    final started = _starting.then(
      (_) => _startNow(transcript, position, stops),
    );
    _starting = started.then((_) {}, onError: (_) {});
    return started;
  }

  Future<TranslationSession> _startNow(
    TranscriptView transcript,
    double Function() position,
    int stops,
  ) async {
    try {
      // the page whose translation this replaces has to hear it ended
      await _stop(reason: '已被另一个翻译取代');
      await _disposing;
      return _create(transcript, position, stopped: stops != _stops);
    } finally {
      _pending--;
    }
  }

  TranslationSession _create(
    TranscriptView transcript,
    double Function() position, {
    required bool stopped,
  }) {
    // read once: a change of model in settings mid-start must not load one
    // file while checking and downloading another
    final model = this.model;
    final file = store.fileOf(model, model.files.first).path;
    final session = TranslationSession(
      transcript: transcript,
      position: position,
      engine: (report) async {
        if (!store.isInstalled(model)) {
          final token = _download = AsrCancelToken();
          await store.ensure(
            model,
            token: token,
            onProgress: (p) => report(
              p.verifying
                  ? '校验模型'
                  : '下载模型 ${p.total == 0 ? '' : '${(p.received * 100 ~/ p.total)}%'}',
            ),
          );
          _download = null;
        }
        report('加载模型');
        return LlamaTranslationEngine.load(file);
      },
      target: target,
    );
    if (stopped) {
      // stopped before it began: nothing is loaded, and its page hears why
      // as it would have had it been running
      session.fail(_stopReason ?? '');
      return session;
    }
    _current = session;
    session.start();
    return session;
  }

  /// Ends the current translation. With a [reason] it is marked failed first,
  /// so the page hears why (see [AsrService.stop]).
  ///
  /// With [only], nothing happens unless that is the current translation: a
  /// page stopping its own must not stop another page's that replaced it.
  ///
  /// Without [only] it reaches starts not yet running as well, and waits
  /// until every stopped session has let go of the model file.
  Future<void> stop({String? reason, TranslationSession? only}) async {
    if (only == null) {
      _stops++;
      _stopReason = reason;
    }
    await _stop(reason: reason, only: only);
    // one replaced earlier may still have the file mapped, and the model
    // being deleted is one of the reasons to stop everything
    if (only == null) await _disposing;
  }

  Future<void> _stop({String? reason, TranslationSession? only}) async {
    final session = _current;
    if (only != null && session != only) return;
    _current = null;
    _download?.cancel();
    _download = null;
    if (session == null) return;
    if (reason != null && session.isRunning) session.fail(reason);
    final disposed = session.dispose();
    final before = _disposing;
    _disposing = Future.wait([before, disposed]).then((_) {}, onError: (_) {});
    await disposed;
  }

  @visibleForTesting
  void debugAdopt(TranslationSession session) => _current = session;
}
