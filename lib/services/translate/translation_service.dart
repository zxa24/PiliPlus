/// LibrePili: one translation at a time, and the model it runs on.
///
/// A translation follows a transcript ([AsrSession]) and is tied to the same
/// page. Only one runs at once — a second model resident alongside the first
/// is 2.8 GB of mapped file the phone does not have.
library;

import 'dart:io';

import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
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

  /// Whether [spoken] should be translated without being asked.
  bool shouldAutoStart(String? spoken) =>
      Pref.translateAsked &&
      Pref.translateMode == TranslateMode.auto &&
      modelReady &&
      needed(spoken);

  /// Starts translating [asr], replacing whatever was running.
  ///
  /// [position] is where playback is, in seconds: translation follows the
  /// viewer, not the recogniser.
  Future<TranslationSession> start({
    required AsrSession asr,
    required double Function() position,
  }) async {
    await stop();
    final file = store.fileOf(model, model.files.first).path;
    final session = TranslationSession(
      transcript: (
        segments: () => asr.segments,
        cues: () => asr.cues,
        complete: () => asr.state.value.stage == AsrStage.done,
      ),
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
  Future<void> stop({String? reason}) async {
    final session = _current;
    _current = null;
    _download?.cancel();
    _download = null;
    if (session == null) return;
    if (reason != null && session.isRunning) session.fail(reason);
    await session.dispose();
  }

  @visibleForTesting
  void debugAdopt(TranslationSession session) => _current = session;
}
