/// LibrePili: stop on-device inference before Android stops the app.
///
/// A foreground app is among the last things the low-memory killer takes.
/// Background playback is covered too: audio_service holds a mediaPlayback
/// foreground service while it plays, so neither going to the background nor
/// the memory warning that comes with it (below) stops work then. The gap is
/// "paused, then switched away": `androidStopForegroundOnPause` drops that
/// service, the app becomes a cached process (oom_score_adj ≥ 900), and
/// while it holds a recogniser — and later a 1–3 GB translation model — it is
/// the process the killer most wants to reclaim. Nobody is watching at that
/// point either, so the work is worth nothing.
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

/// Whether the app is out of view: nobody would see a video started now.
/// [AppLifecycleState.inactive] is not — it is picture-in-picture on
/// Android, and on desktop a window that has only lost focus. Nor is
/// [AppLifecycleState.hidden], a minimised desktop window: the player's own
/// background pause covers only [AppLifecycleState.paused] and
/// [AppLifecycleState.detached], and a video minimised without the gate goes
/// on playing. An unknown [state] counts as in view.
bool isAppAway(AppLifecycleState? state) => switch (state) {
  AppLifecycleState.paused || AppLifecycleState.detached => true,
  _ => false,
};

/// Whether running on-device work should be stopped, and why.
///
/// Memory pressure stops it in the foreground. Going to the background stops
/// it only on mobile, only in [AppLifecycleState.paused] — picture-in-picture
/// is [AppLifecycleState.inactive] and keeps running — and only while nothing
/// is playing, since playback keeps its foreground service.
///
/// Flutter's Android embedding reports every trim level from RUNNING_LOW up
/// as memory pressure, TRIM_MEMORY_UI_HIDDEN included — and that one arrives
/// each time the app's UI is hidden. So on mobile, a warning while the app is
/// not [AppLifecycleState.resumed] is read as going to the background, with
/// the same exemption for playback. An unknown [lifecycle] counts as the
/// foreground.
///
/// The foreground case rests on the system sending the RUNNING_* levels at
/// all. Newer Android versions (API 34 on) may no longer deliver them to
/// apps — not checked against the platform source here — and then only
/// UI_HIDDEN and the background levels arrive, which the rule above reads
/// as going away: memory pressure in the foreground would go unnoticed.
@visibleForTesting
ModelStopReason? shouldStopOnDeviceWork({
  required bool memoryPressure,
  required AppLifecycleState? lifecycle,
  required bool playing,
  required bool mobile,
}) {
  final away =
      mobile && lifecycle != null && lifecycle != AppLifecycleState.resumed;
  if (memoryPressure) {
    if (!away) return ModelStopReason.memoryPressure;
    return playing ? null : ModelStopReason.background;
  }
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
  void didHaveMemoryPressure() => _apply(
    memoryPressure: true,
    lifecycle: WidgetsBinding.instance.lifecycleState,
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _watchPlayback(state);
    _apply(lifecycle: state);
  }

  Worker? _playback;

  /// Away while something plays, nothing is stopped — and pausing it from
  /// the notification afterwards, or reaching its end, brings no lifecycle
  /// change and not necessarily a memory warning, while the foreground
  /// service that protected the work goes. So the player is watched while
  /// away, and the same check made again when it stops.
  void _watchPlayback(AppLifecycleState state) {
    _playback?.dispose();
    _playback = null;
    if (state == AppLifecycleState.resumed) return;
    final player = PlPlayerController.instance;
    if (player == null) return;
    _playback = ever<PlayerStatus>(player.playerStatus, (status) {
      if (status.isPlaying) return;
      _apply(lifecycle: WidgetsBinding.instance.lifecycleState);
    });
  }

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
