/// LibrePili: one translation at a time, and the model it runs on.
///
/// A translation is of a transcript ([AsrSession]) or of a video's own
/// captions, and is tied to the page that started it. Only one runs at once
/// — a second model resident alongside the first is 2.8 GB of mapped file
/// the phone does not have.
library;

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

  bool get isBusy => _current?.isRunning ?? false;

  /// The language translations are made into: the app's.
  String get target => AsrService.appLanguage;

  /// Whether a transcript in [spoken] needs translating at all.
  bool needed(String? spoken) =>
      spoken != null &&
      spoken.isNotEmpty &&
      !AsrService.isSameMajorLanguage(spoken, target);

  /// Whether the user chose automatic translation and it can run now.
  bool get shouldAutoTranslate =>
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
    final started = _starting.then((_) => _startNow(transcript, position));
    _starting = started.then((_) {}, onError: (_) {});
    return started;
  }

  Future<TranslationSession> _startNow(
    TranscriptView transcript,
    double Function() position,
  ) async {
    // the page whose translation this replaces has to hear it ended
    await stop(reason: '已被另一个翻译取代');
    await _disposing;
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
    _current = session;
    session.start();
    return session;
  }

  /// Ends the current translation. With a [reason] it is marked failed first,
  /// so the page hears why (see [AsrService.stop]).
  ///
  /// With [only], nothing happens unless that is the current translation: a
  /// page stopping its own must not stop another page's that replaced it.
  Future<void> stop({String? reason, TranslationSession? only}) async {
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
