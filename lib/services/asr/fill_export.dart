/// LibrePili: saving an on-device subtitle that has gaps in it
/// (research/chunked-transcription-design-2026-09-25.md, 11.4 and 13).
///
/// A transcript made from where the viewer is covers stretches, not the
/// whole media. Saving it as it is would save a subtitle with holes; the
/// user chose instead that the save fills them first — a dialog shows how
/// far that has got, and can be sent to the background, where the save
/// finishes by itself once the text is whole. Cancelling saves nothing and
/// puts the session back on its lead rule.
///
/// This is the flow alone, with the session behind a [FillTarget]; the
/// dialog is fill_export_dialog.dart.
library;

import 'dart:async';

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// What a save waits on: a transcript, or a translation of one.
abstract interface class FillTarget {
  /// 0..1, how much of it is there.
  double get progress;

  /// Nothing is missing: the save can go ahead.
  bool get isComplete;

  /// Why it never will be (the session failed or was stopped), or null.
  String? get failure;

  /// Fill every gap, whatever the viewer does, until [release].
  void hold();

  /// Back to the lead rule.
  void release();
}

enum FillPhase {
  /// The dialog is up.
  filling,

  /// Sent to the background: the save happens when the text is whole.
  background,

  /// Whole, and handed to the save.
  saved,

  /// Given up by the user, or with the page.
  cancelled,

  /// The session ended without the text being whole.
  failed,
}

class FillExport {
  FillExport(
    this.target, {
    required this.save,
    this.poll = const Duration(milliseconds: 500),
  });

  final FillTarget target;

  /// The save the user asked for; [background] when it finishes after the
  /// dialog was sent away (it then says so itself, as feedback on the
  /// user's own action).
  final Future<void> Function({required bool background}) save;
  final Duration poll;

  final phase = FillPhase.filling.obs;

  /// Shown in the dialog; never goes back, whatever the target reports (a
  /// translation's share can dip as new units appear).
  final progress = 0.0.obs;

  /// Why it failed, once [phase] is [FillPhase.failed].
  String? failure;

  Timer? _timer;
  final _done = Completer<void>();
  var _held = false;

  /// Settles once the flow has ended, however.
  Future<void> get done => _done.future;

  bool get isOver =>
      phase.value == FillPhase.saved ||
      phase.value == FillPhase.cancelled ||
      phase.value == FillPhase.failed;

  /// Whether nothing needs waiting for: the caller saves at once, as before.
  static bool needed(FillTarget? target) =>
      target != null && !target.isComplete && target.failure == null;

  /// Starts filling. The caller shows the dialog while [phase] is
  /// [FillPhase.filling].
  void start() {
    if (_held || isOver) return;
    _held = true;
    target.hold();
    _check();
    if (!isOver) _timer = Timer.periodic(poll, (_) => _check());
  }

  /// 放到后台继续: the dialog goes, the filling goes on.
  void toBackground() {
    if (phase.value == FillPhase.filling) phase.value = FillPhase.background;
  }

  /// 取消, or the page going: nothing is saved, and the lead rule is back.
  void cancel() {
    if (isOver) return;
    _finish(FillPhase.cancelled);
  }

  void _check() {
    if (isOver) return;
    final failed = target.failure;
    if (failed != null) {
      failure = failed;
      _finish(FillPhase.failed);
      return;
    }
    final now = target.progress.clamp(0.0, 1.0);
    if (now > progress.value) progress.value = now;
    if (!target.isComplete) return;
    progress.value = 1;
    final background = phase.value == FillPhase.background;
    _finish(FillPhase.saved);
    unawaited(_save(background));
  }

  Future<void> _save(bool background) async {
    // the save reports its own outcome (StorageUtils toasts it)
    try {
      await save(background: background);
    } catch (e, s) {
      if (kDebugMode) debugPrint('fill export: save failed: $e\n$s');
    }
  }

  void _finish(FillPhase to) {
    _timer?.cancel();
    _timer = null;
    if (_held) {
      _held = false;
      target.release();
    }
    phase.value = to;
    if (!_done.isCompleted) _done.complete();
  }
}

/// A transcript as a [FillTarget].
class TranscriptFillTarget implements FillTarget {
  TranscriptFillTarget(this.session, {this.alive});

  final AsrSession session;

  /// Whether the page still has this session: a part switch or a restart
  /// lets go of it, and it will never be whole then.
  final bool Function()? alive;

  @override
  double get progress {
    if (session.state.value.stage == AsrStage.done) return 1;
    final media = session.duration;
    if (media == null || media <= 0) return 0;
    return (session.coveredSeconds / media).clamp(0.0, 1.0);
  }

  @override
  bool get isComplete => session.state.value.stage == AsrStage.done;

  @override
  String? get failure {
    if (alive?.call() == false) return '转录已停止';
    final state = session.state.value;
    return switch (state.stage) {
      AsrStage.failed => state.message ?? '转录失败',
      // gave up (the speech is in the app's language) or was stopped
      AsrStage.idle when session.runCount > 0 => '转录已停止',
      _ => null,
    };
  }

  @override
  void hold() => session.requestFullCoverage();

  @override
  void release() => session.endFullCoverage();
}

/// A translation of a transcript as a [FillTarget]: the transcript whole
/// first, then every unit of it translated.
class TranslationFillTarget implements FillTarget {
  TranslationFillTarget(this.session, {this.transcript, this.alive});

  final TranslationSession session;

  /// The transcript it translates, when it is one still being made.
  final TranscriptFillTarget? transcript;
  final bool Function()? alive;

  @override
  double get progress {
    final asr = transcript;
    final translated = session.settledShare;
    return asr == null ? translated : (asr.progress + translated) / 2;
  }

  @override
  bool get isComplete =>
      (transcript?.isComplete ?? true) && session.translatedAll;

  @override
  String? get failure {
    if (alive?.call() == false) return '翻译已停止';
    final asr = transcript?.failure;
    if (asr != null) return asr;
    final state = session.state.value;
    if (state.stage == TranslationStage.failed) {
      return state.message ?? '翻译失败';
    }
    return null;
  }

  @override
  void hold() {
    transcript?.hold();
    session.requestFullCoverage();
  }

  @override
  void release() {
    transcript?.release();
    session.endFullCoverage();
  }
}
