/// LibrePili: stop on-device inference before Android stops the app.
///
/// A foreground app is among the last things the low-memory killer takes.
/// Background playback is covered too: audio_service holds a mediaPlayback
/// foreground service while it plays. The gap is "paused, then switched
/// away": `androidStopForegroundOnPause` drops that service, the app becomes
/// a cached process (oom_score_adj ≥ 900), and while it holds a recogniser —
/// and later a 1–3 GB translation model — it is the process the killer most
/// wants to reclaim. Nobody is watching at that point either, so the work is
/// worth nothing.
///
/// The app previously had no memory-pressure handling at all.
///
/// Translation is stopped the same way, first: it holds the larger model.
///
/// Measured context, 2026-09-23 (research/translation-bench-2026-09-23.md):
/// on a 6 GB Pixel 4 XL, a translation model and SenseVoice running together
/// pushed the system past its low watermark and background apps were killed.
/// The test processes were launched from adb at oom_score_adj −1000 and so
/// could not themselves be killed; an app process has no such protection.
library;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Why on-device work was stopped, as shown to the user.
enum ModelStopReason {
  memoryPressure('内存不足，已停止转录', '内存不足，已停止翻译'),
  background('应用已切到后台，已停止转录', '应用已切到后台，已停止翻译');

  const ModelStopReason(this.message, this.translationMessage);
  final String message;
  final String translationMessage;
}

/// Whether running on-device work should be stopped, and why.
///
/// Memory pressure stops it anywhere. Going to the background stops it only
/// on mobile, only in [AppLifecycleState.paused] — picture-in-picture is
/// [AppLifecycleState.inactive] and keeps running — and only while nothing is
/// playing, since playback keeps its foreground service.
@visibleForTesting
ModelStopReason? shouldStopOnDeviceWork({
  required bool memoryPressure,
  required AppLifecycleState? lifecycle,
  required bool playing,
  required bool mobile,
}) {
  if (memoryPressure) return ModelStopReason.memoryPressure;
  if (mobile && lifecycle == AppLifecycleState.paused && !playing) {
    return ModelStopReason.background;
  }
  return null;
}

class OnDeviceModelGuard with WidgetsBindingObserver {
  OnDeviceModelGuard._();

  static OnDeviceModelGuard? _installed;

  static void install() {
    if (_installed != null) return;
    WidgetsBinding.instance.addObserver(_installed = OnDeviceModelGuard._());
  }

  @override
  void didHaveMemoryPressure() => _apply(memoryPressure: true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _apply(lifecycle: state);

  void _apply({bool memoryPressure = false, AppLifecycleState? lifecycle}) {
    // lazily registered and never created means nothing can be running, and
    // finding it here would create it for no reason
    bool live<S>() => Get.isRegistered<S>() && !Get.isPrepared<S>();
    final asr = live<AsrService>() && AsrService.to.isBusy;
    final translation =
        live<TranslationService>() && TranslationService.to.isBusy;
    if (!asr && !translation) return;
    final reason = shouldStopOnDeviceWork(
      memoryPressure: memoryPressure,
      lifecycle: lifecycle,
      playing: PlPlayerController.instance?.playerStatus.isPlaying ?? false,
      mobile: PlatformUtils.isMobile,
    );
    if (reason == null) return;
    if (kDebugMode) debugPrint('asr: stopping — ${reason.name}');
    // the translation first: it holds the larger model, and it reads the
    // transcript, which is about to stop growing
    if (translation) {
      TranslationService.to.stop(reason: reason.translationMessage);
    }
    if (asr) AsrService.to.stop(reason: reason.message);
  }
}
