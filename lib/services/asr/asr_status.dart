/// LibrePili: how far an on-device transcript is known, in the words the
/// subtitle menu shows (research/chunked-transcription-design-2026-09-25.md,
/// P4).
///
/// A transcript used to grow from the start to the end, and 生成中 said all
/// there was to say. Made from where the viewer is, it is stretches with
/// gaps between, paused when far enough ahead. The menu keeps it short
/// (research/subtitle-switch-design-2026-09-26.md, 9): 生成中 while it is,
/// and — paused ahead, which read like a fault as 已暂停 — how far the
/// subtitles are ready.
library;

import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';

/// [seconds] as the player shows a time: `m:ss`, or `h:mm:ss` from an hour.
String formatMediaTime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = total ~/ 3600;
  final m = total % 3600 ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// The menu's word on a transcript that is under way or waiting, or null
/// where the stage says nothing about coverage (models, failure, idle).
///
/// - the whole media known: 已全部生成
/// - paused ahead of the viewer: 字幕已就绪至 12:30 (where the stretch the
///   viewer is in ends), or the reason it was stopped for (the app went
///   to the background, a run failed)
/// - switched off and wound down (see [AsrSession.windDown]):
///   已关闭（已生成到 12:30）, or 已关闭（已生成 3 段，共 25:10）
/// - running: 生成中
String? asrCoverageLabel({
  required AsrStage stage,
  String? message,
  required List<TimeSpan> covered,
  required double? duration,
  required double playhead,
}) {
  if (stage == AsrStage.done) return '已全部生成';
  if (stage != AsrStage.extracting &&
      stage != AsrStage.transcribing &&
      stage != AsrStage.standby) {
    return null;
  }
  if (duration != null && isCoveredWhole(covered, duration)) {
    return '已全部生成';
  }
  if (stage == AsrStage.standby) {
    // switched off, and stopped where it was going: what it made stays
    if (message == asrWoundDownMessage) {
      final made = _madeSoFar(covered);
      return made == null ? message! : '$message（$made）';
    }
    if (message != null) return message;
    final end = coveredEndOf(covered, playhead);
    return end - playhead >= 1 ? '字幕已就绪至 ${formatMediaTime(end)}' : '已暂停';
  }
  return '生成中';
}

/// 已生成到 12:30, or 已生成 3 段，共 25:10; null for nothing yet.
String? _madeSoFar(List<TimeSpan> covered) {
  // a stretch under a second is a run that has only just started
  final stretches = [
    for (final span in covered)
      if (span.to - span.from >= 1) span,
  ];
  if (stretches.isEmpty) return null;
  if (stretches.length == 1) {
    return '已生成到 ${formatMediaTime(stretches.single.to)}';
  }
  final total = stretches.fold(0.0, (sum, s) => sum + (s.to - s.from));
  return '已生成 ${stretches.length} 段，共 ${formatMediaTime(total)}';
}
