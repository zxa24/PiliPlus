/// LibrePili: what the command-line reader ([CtlServer]) is shown, as JSON
/// values: the parts that need no page to build, so they can be tested on
/// their own. The pages themselves are read in `ctl_app.dart`.
///
/// Never in here: cookies, tokens, account data, request headers, or a full
/// stream URL — its query string carries the keys; hosts only.
library;

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/fill_export.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// The host of [url] alone, or null when it is not a network URL (a local
/// file, an `edl://` string, nothing).
String? ctlHostOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.host.isEmpty ? null : uri.host;
}

/// Seconds, rounded to tenths: enough to follow, short to read. Null for
/// none, and for no bound (JSON has no infinity).
double? _s(double? seconds) => seconds == null || !seconds.isFinite
    ? null
    : (seconds * 10).roundToDouble() / 10;

/// A transcription session, or null when there is none.
Map<String, Object?>? ctlAsrJson(AsrSession? session) {
  if (session == null) return null;
  final state = session.state.value;
  final lead = session.leadWindow;
  return {
    'stage': state.stage.name,
    'label': state.label,
    'message': state.message,
    'progress': state.progress,
    'language': state.language,
    'covered': [
      for (final span in session.transcript.covered)
        [_s(span.from), _s(span.to)],
    ],
    'coveredSeconds': _s(session.coveredSeconds),
    'duration': _s(session.duration),
    'cues': session.cues.length,
    'runCount': session.runCount,
    'hasEnded': session.hasEnded,
    'suspended': session.isSuspended,
    'fullCoverageRequested': session.fullCoverageRequested,
    'leadWindow': {
      'low': _s(lead.low),
      'high': _s(lead.high),
      'pauses': lead.pauses,
    },
  };
}

/// A page's translation track: whether one is asked for or running, into
/// what, and how far.
Map<String, Object?> ctlTranslationJson(TranslationTrack track) =>
    ctlTranslationFields(
      active: track.isActive,
      into: track.into,
      session: track.session.value,
    );

Map<String, Object?> ctlTranslationFields({
  required bool active,
  String? into,
  TranslationSession? session,
}) {
  final state = session?.state.value;
  final units = session?.units ?? const [];
  return {
    'active': active,
    'into': into,
    // asked for, and its session not made yet (models, a fetch…)
    'starting': active && session == null,
    'stage': state?.stage.name,
    'message': state?.message,
    'unitsDone': session == null
        ? null
        : units.where(session.results.settles).length,
    'unitsTotal': session == null ? null : units.length,
  };
}

/// A save waiting for its on-device subtitle to be whole, or null.
Map<String, Object?>? ctlFillExportJson(FillExport? flow) => flow == null
    ? null
    : {
        'phase': flow.phase.value.name,
        'progress': flow.progress.value,
        'over': flow.isOver,
      };

/// Preferences shown by `/settings`: those that decide how videos play,
/// how subtitles are made and translated, and how the network is used.
/// Stored values only: a key that was never set is null (its default).
///
/// Nothing here may name an account, a cookie, a token, a proxy address or
/// anything a person typed about themselves; [_secretLooking] refuses such
/// a key even if one is added here by mistake.
const ctlSettingKeys = [
  // playback
  SettingBoxKey.defaultVideoQa,
  SettingBoxKey.defaultVideoQaCellular,
  SettingBoxKey.defaultAudioQa,
  SettingBoxKey.defaultAudioQaCellular,
  SettingBoxKey.autoPlayEnable,
  SettingBoxKey.preferCodecs,
  SettingBoxKey.preferCodecsCellular,
  SettingBoxKey.enableHA,
  SettingBoxKey.hardwareDecoding,
  SettingBoxKey.videoSync,
  SettingBoxKey.audioOutput,
  SettingBoxKey.bufferSize,
  SettingBoxKey.bufferSec,
  SettingBoxKey.av1Hardware,
  SettingBoxKey.av1Software,
  SettingBoxKey.audioNormalization,
  SettingBoxKey.superResolutionType,
  SettingBoxKey.preInitPlayer,
  SettingBoxKey.continuePlayingPart,
  SettingBoxKey.platformMode,
  // CDN and network
  SettingBoxKey.CDNService,
  SettingBoxKey.disableAudioCDN,
  SettingBoxKey.cdnSpeedTest,
  SettingBoxKey.enableSystemProxy,
  SettingBoxKey.enableHttp2,
  SettingBoxKey.retryCount,
  SettingBoxKey.retryDelay,
  SettingBoxKey.badCertificateCallback,
  // subtitles
  SettingBoxKey.subtitleFontScale,
  SettingBoxKey.subtitleFontScaleFS,
  SettingBoxKey.dlSaveSubtitle,
  // transcription and translation
  SettingBoxKey.subtitleChoice,
  SettingBoxKey.subtitleSource,
  SettingBoxKey.asrLanguage,
  SettingBoxKey.asrThreads,
  SettingBoxKey.translateModel,
  SettingBoxKey.translateDual,
  SettingBoxKey.translatePinnedLanguages,
  // YouTube
  SettingBoxKey.ytRegion,
  SettingBoxKey.ytLanguage,
  // this reader, and the error log
  SettingBoxKey.ctlServer,
  SettingBoxKey.enableLog,
];

final _secretLooking = RegExp(
  r'cookie|token|secret|passw|auth|credential|session|csrf|access|account|'
  r'login|user|mid$|key$|proxyHost|proxyPort|host$|email|phone',
  caseSensitive: false,
);

/// [keys] read through [read], less anything that looks like it could hold
/// a secret: a key whose name does, or a value that is not a plain setting
/// (a map, a long string, a URL — shown as its host).
Map<String, Object?> ctlSettingsJson(
  Object? Function(String key) read, {
  Iterable<String> keys = ctlSettingKeys,
}) {
  Object? plain(Object? value) => switch (value) {
    null || bool() || num() => value,
    Enum(:final name) => name,
    String() when value.contains('://') => ctlHostOf(value) ?? '(url)',
    String() when value.length > 200 => '(${value.length} chars)',
    String() => value,
    Iterable() => [for (final v in value.take(50)) plain(v)],
    _ => '(${value.runtimeType})',
  };
  return {
    for (final key in keys)
      if (!_secretLooking.hasMatch(key)) key: plain(read(key)),
  };
}
