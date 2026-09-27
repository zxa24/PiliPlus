/// LibrePili: the subtitle menu as rows, before any widget (research/
/// subtitle-switch-design-2026-09-26.md, 9): by language first, where it
/// comes from second.
///
///     选择会用于所有视频
///     关闭字幕
///     原文 · 日语              [本机] [平台]
///     中文      生成中 ◌        [本机]
///     英语                     [本机] [平台]
///     其他语言…
///     更多字幕轨…
///
/// Each language row carries an icon per source that can supply it: the
/// device's, and the platform's — only when the video has a track in that
/// language. The name uses the default source; an icon, that source for
/// this video only. Both pages, and the command-line reader, build it here.
library;

import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/asr_status.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';

/// Where a subtitle stands, in the few words the menu has room for.
class SubtitleStatus {
  const SubtitleStatus(this.text, {this.busy = false, this.error = false});

  final String text;

  /// Under way: shown with a spinner.
  final bool busy;

  /// Something the viewer has to act on: a failure (tap to retry).
  final bool error;

  @override
  bool operator ==(Object other) =>
      other is SubtitleStatus &&
      other.text == text &&
      other.busy == busy &&
      other.error == error;

  @override
  int get hashCode => Object.hash(text, busy, error);

  @override
  String toString() =>
      'SubtitleStatus($text${busy ? ', busy' : ''}${error ? ', error' : ''})';
}

/// The status of the transcript (the 原文 row), from its session's [state]
/// — null with none — and how far it reaches. [modelsMissing]: nothing
/// runs, and it could not start without a download.
SubtitleStatus? transcriptStatus({
  required AsrState? state,
  required List<TimeSpan> covered,
  required double? duration,
  required double playhead,
  bool modelsMissing = false,
}) {
  if (state == null) {
    return modelsMissing ? const SubtitleStatus('需要下载模型') : null;
  }
  switch (state.stage) {
    case AsrStage.models:
      return SubtitleStatus(state.message ?? '准备模型', busy: true);
    case AsrStage.failed:
      return const SubtitleStatus('失败，点击重试', error: true);
    case AsrStage.idle:
      return null;
    case _:
  }
  final label = asrCoverageLabel(
    stage: state.stage,
    message: state.message,
    covered: covered,
    duration: duration,
    playhead: playhead,
  );
  if (label == null) return null;
  return SubtitleStatus(
    label,
    busy:
        state.stage == AsrStage.extracting ||
        state.stage == AsrStage.transcribing,
  );
}

/// The status of a translation (a language row), from its [state], and
/// the transcript's ([transcript]) it may wait on: a translation resting
/// while the transcript is paused far enough ahead is ready as far as the
/// transcript is.
SubtitleStatus? translationStatus({
  required TranslationState state,
  SubtitleStatus? transcript,
}) => switch (state.stage) {
  TranslationStage.loading => SubtitleStatus(
    state.message ?? '准备模型',
    busy: true,
  ),
  TranslationStage.translating => const SubtitleStatus('生成中', busy: true),
  TranslationStage.waiting =>
    transcript != null && !transcript.busy && !transcript.error
        ? transcript
        : const SubtitleStatus('生成中', busy: true),
  TranslationStage.paused => const SubtitleStatus('已暂停'),
  TranslationStage.done => const SubtitleStatus('已全部生成'),
  TranslationStage.failed => const SubtitleStatus('失败，点击重试', error: true),
  TranslationStage.idle => null,
};

/// The major languages the speech is in, by how much of it each takes:
/// those with at least a fifth, two at most. Segments tagged with nothing
/// do not count, and a stray mistagged one is too short to.
List<String> spokenLanguages(
  Iterable<({String language, double duration})> segments,
) {
  final totals = <String, double>{};
  var all = 0.0;
  for (final s in segments) {
    final language = captionLanguage(s.language);
    if (language.isEmpty || s.duration <= 0) continue;
    // Cantonese is Chinese to the viewer (see isSameMajorLanguage)
    final key = language == 'yue' ? 'zh' : language;
    totals[key] = (totals[key] ?? 0) + s.duration;
    all += s.duration;
  }
  if (all <= 0) return const [];
  final ranked = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [
    for (final (i, e) in ranked.indexed)
      if (i < 2 && (i == 0 || e.value >= all * 0.2)) e.key,
  ];
}

/// The languages spoken in a video: as its transcript tags them, or,
/// before there is one, the language of the platform's own transcript.
List<String> spokenOf(AsrSession? session, List<PlatformTrack> tracks) {
  final heard = spokenLanguages([
    for (final s in session?.transcript.segments ?? const <TranscriptSegment>[])
      (language: s.language, duration: s.duration),
  ]);
  if (heard.isNotEmpty) return heard;
  for (final t in tracks) {
    if (t.kind == PlatformTrackKind.generated) {
      final language = captionLanguage(t.language);
      if (language.isNotEmpty) return [language == 'yue' ? 'zh' : language];
    }
  }
  return const [];
}

/// The 原文 row's name (decision ④): 原文 · 日语, 原文 · 日语/中文 for
/// speech in two, and 原文 alone before the language is known.
String originalLabel(List<String> languages) => languages.isEmpty
    ? '原文'
    : '原文 · ${languages.map(translationLanguageLabel).join('/')}';

/// What the menu marks for a video picked by hand from its own tracks
/// (更多字幕轨…), in place of a language row.
const pickedTrack = '#track';

/// One language row of the menu (see the library comment).
class SubtitleMenuRow {
  const SubtitleMenuRow({
    required this.code,
    required this.label,
    required this.checked,
    required this.device,
    required this.platform,
    this.active,
    this.status,
  });

  /// `asr` for the speech as it is, or a language.
  final String code;
  final String label;

  /// What this video shows, or is to show once it is made.
  final bool checked;

  /// Whether the device can make it, and the video has a platform track
  /// in it: an icon each.
  final bool device;
  final bool platform;

  /// The source on screen, for the row [checked]; null while nothing is.
  final SubtitleSourcePreference? active;
  final SubtitleStatus? status;

  Map<String, Object?> toJson() => {
    'code': code,
    'label': label,
    'checked': checked,
    'device': device,
    'platform': platform,
    'active': active?.name,
    'status': status?.text,
    'busy': status?.busy ?? false,
  };

  @override
  String toString() => 'SubtitleMenuRow(${toJson()})';
}

/// The language rows: 原文, then [languages] (the app's, those kept in the
/// menu, and one picked under 其他语言…), each with the sources that can
/// supply it. A row no source can supply is left out.
///
/// [picked] is what the video shows or is to show: null for off, `asr`, a
/// language, or [pickedTrack]; [active], the source on screen for it.
/// [canTranslate]: translation can run on this device at all.
List<SubtitleMenuRow> subtitleMenuRows({
  required String? picked,
  required SubtitleSourcePreference? active,
  required List<PlatformTrack> tracks,
  required bool canTranscribe,
  required bool canTranslate,
  required List<String> languages,
  required List<String> spoken,
  required SubtitleStatus? Function(String code) status,
}) {
  SubtitleMenuRow row(String code, String label, {required bool device}) {
    final checked = picked == code;
    return SubtitleMenuRow(
      code: code,
      label: label,
      checked: checked,
      device: device,
      platform: platformTrackFor(tracks, code) != null,
      active: checked ? active : null,
      status: status(code),
    );
  }

  return [
    row('asr', originalLabel(spoken), device: canTranscribe),
    for (final code in languages)
      row(
        code,
        translationLanguageLabel(code),
        device:
            canTranslate &&
            (canTranscribe || captionToTranslateFor(tracks, code) != null),
      ),
  ].where((r) => r.device || r.platform).toList();
}

/// What a page offers the subtitle menu. Both video pages implement it, and
/// the menu and the command-line reader read the same rows from it.
abstract interface class SubtitleMenuHost {
  /// The video's own tracks, and their names as the menu shows them.
  List<PlatformTrack> get platformTracks;
  List<String> get platformTrackNames;

  bool get canTranscribe;

  /// See [subtitleMenuRows].
  String? get menuPicked;
  SubtitleSourcePreference? get menuActive;

  /// The index among [platformTracks] of the one on screen, if any.
  int? get shownPlatformTrack;

  /// See [spokenLanguages]: of the transcript, or of the platform's.
  List<String> get spoken;

  SubtitleStatus? menuStatus(String code);

  /// A transcription exists for this video, running or not.
  bool get hasTranscription;
  int? captionToTranslateInto(String? into);
  bool hasTranslationInto(String into);

  OpenPlan planFor(String code, {SubtitleSourcePreference? via});
  Future<void> chooseOff();
  Future<void> chooseLanguage(
    String code,
    OpenPlan plan, {
    Future<bool> Function()? mayTranscribe,
  });
  Future<void> choosePlatformTrack(int index);
}

/// [SubtitleMenuHost]'s rows, for the languages [languages].
List<SubtitleMenuRow> menuRowsOf(
  SubtitleMenuHost host, {
  required bool canTranslate,
  required List<String> languages,
}) => subtitleMenuRows(
  picked: host.menuPicked,
  active: host.menuActive,
  tracks: host.platformTracks,
  canTranscribe: host.canTranscribe,
  canTranslate: canTranslate,
  languages: languages,
  spoken: host.spoken,
  status: host.menuStatus,
);

/// The languages listed by name: the app's, those kept in the menu
/// ([pinned]), and [current] — the one picked or being made — when it is
/// neither.
List<String> listedLanguages(String? current, List<String> pinned) => [
  AsrService.appLanguage,
  ...pinned,
  if (current != null &&
      current != 'asr' &&
      current != pickedTrack &&
      current != AsrService.appLanguage &&
      !pinned.contains(current))
    current,
];
