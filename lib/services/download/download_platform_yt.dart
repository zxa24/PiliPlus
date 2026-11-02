/// LibrePili: YouTube's part of the downloads (feature-logs/
/// download-platforms design §3.1, stage-2 plan §3). Not a part of the
/// service's library: what it may do to the service goes through the
/// handle it is built with ([DownloadHost]) and the service's public
/// methods (`addDownload`, `restartWith`).
///
/// Stage 2b: the record, the list, the cover, the new-download guard and
/// the offline open; 2e: the start (resolve, the pair transfer, the merge),
/// its failures and the 720p switch.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/youtube/direct_source.dart';
import 'package:PiliPlus/services/youtube/invidious_source.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_quality_tier.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_transfer_errors.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

/// The name of a YouTube download's stream folder, its streams' identity
/// (stage-2 plan §3.3, design §2.2 p4#6): `<videoItag>-<audioItag>`, then
/// `.` and [ytAudioTrackDigest] of the audio track when it has one, then
/// `.drc` for DRC audio. The digest keeps track ids apart that a cleaned
/// up name would not (`en:4`, `en_4`); a DRC and a plain 140 are two.
abstract final class YtStreamTag {
  /// The folder name of [video] and [audio].
  static String of(YtFormat video, YtFormat audio) {
    final track = ytAudioTrackDigest(audio.audioTrackId);
    return '${video.itag}-${audio.itag}'
        '${track == null ? '' : '.$track'}'
        '${audio.isDrc ? '.drc' : ''}';
  }

  /// The pin a folder name alone gives (its `stream.json` unreadable): the
  /// audio track by its digest. Null: not a stream folder's name (or an
  /// itag no int holds).
  static YtFormatPin? pinOf(String dirName) {
    final m = YtDownloadEntry.streamTagPattern.firstMatch(dirName);
    if (m == null) return null;
    final video = int.tryParse(m[1]!);
    final audio = int.tryParse(m[2]!);
    if (video == null || audio == null) return null;
    return YtFormatPin(
      videoItag: video,
      audioItag: audio,
      audioTrackDigest: m[3],
      drc: m[4] != null,
    );
  }

  /// [video] and [audio] are the pair of the folder [dirName], by its name
  /// alone: the audio track compared by digest.
  static bool matches(String dirName, YtFormat video, YtFormat audio) {
    final m = YtDownloadEntry.streamTagPattern.firstMatch(dirName);
    if (m == null) return false;
    return video.itag == int.tryParse(m[1]!) &&
        audio.itag == int.tryParse(m[2]!) &&
        ytAudioTrackDigest(audio.audioTrackId) == m[3] &&
        audio.isDrc == (m[4] != null);
  }
}

/// What is on disk for a video before a new download of it is made
/// ([YtDownloadPlatform.checkExisting], plan §3.2 「新建」).
sealed class YtExisting {
  const YtExisting();
}

/// No record: a new one may be made (a folder of streams alone is reused).
final class YtNoRecord extends YtExisting {
  const YtNoRecord();
}

/// A readable record of this video id.
final class YtRecordExists extends YtExisting {
  const YtRecordExists();
}

/// A readable record of an id that differs only in letter case (the
/// folder names do not tell them apart on Windows / macOS).
final class YtCaseConflict extends YtExisting {
  const YtCaseConflict(this.otherId);
  final String otherId;
}

/// A record this build cannot read (or of a platform it does not know).
final class YtUnreadable extends YtExisting {
  const YtUnreadable(this.folder);
  final String folder;
}

/// What a new download from the panel came to, with what the panel says.
enum YtCreateResult {
  added('已加入下载队列'),
  queued('已在下载队列中'),
  done('已下载'),
  caseConflict('已有一个仅大小写不同的 YouTube 下载'),
  unreadable('已存在无法读取的下载'),
  recordExists('该视频已有下载记录，请重新进入缓存页'),
  failed('下载记录写入失败，请检查下载目录');

  const YtCreateResult(this.message);
  final String message;
}

/// What a YouTube resolve found (stage-2 plan §3.3).
final class YtPlan implements DownloadPlan {
  const YtPlan({
    required this.pair,
    required this.streamTag,
    required this.streamSource,
    required this.qualityLabel,
    required this.mediaGuess,
  });

  final YtStreamPair pair;

  @override
  final String streamTag;

  /// The source that gave the pair (`direct` / `invidious`).
  final String streamSource;

  /// The picked format's own label (`720p60`), else its tier's.
  final String qualityLabel;

  @override
  final int? mediaGuess;

  @override
  bool get expectAudio => true;
}

/// What a pair transfer is built from.
typedef YtTransferSpec = ({
  String videoId,
  String source,
  String streamDir,
  YtStreamSpec video,
  YtStreamSpec audio,
});

final class YtDownloadPlatform implements DownloadPlatform {
  YtDownloadPlatform(this._host);

  final DownloadHost _host;

  // Tests only: stand-ins for what this adapter reaches out to (null: the
  // real call).

  /// In place of [SmartDialog.showToast].
  @visibleForTesting
  static void Function(String msg)? toastForTest;

  /// In place of [LocalPlayer.open].
  @visibleForTesting
  static Future<bool> Function(String path)? openLocalForTest;

  /// In place of a new [HttpClient] (the cover and the transfers).
  @visibleForTesting
  static HttpClient Function()? httpClientForTest;

  @override
  String get id => YtDownloadEntry.platformId;

  @override
  String get recordFile => YtDownloadEntry.recordFile;

  @override
  DownloadEntry parse(Map<String, dynamic> json) =>
      YtDownloadEntry.fromJson(json);

  /// The record, or its `.tmp` alone: the list reads either (review 2bc:
  /// the orphan check must not take a folder the list would show for one).
  @override
  bool hasRecord(DownloadEntry entry) {
    final file = File(path.join(entry.entryDirPath, recordFile));
    return file.existsSync() || File('${file.path}.tmp').existsSync();
  }

  /// `entry.librepili.json` through `<file>.tmp` + rename, as bilibili's
  /// `entry.json` (a folder deleted meanwhile is not made again).
  ///
  /// The list may have read this record from its `.tmp` (a save cut before
  /// its rename, or a record that does not read): writing the `.tmp` now
  /// would truncate the only readable copy, so that copy becomes the record
  /// first, and a save cut now still leaves it (review 2bc).
  @override
  Future<void> save(DownloadEntry entry) async {
    if (!Directory(entry.entryDirPath).existsSync()) return;
    final file = File(path.join(entry.entryDirPath, recordFile));
    final tmp = File('${file.path}.tmp');
    if (tmp.existsSync() && !_readable(file)) {
      await _replaceWith(tmp, file.path);
    }
    await tmp.writeAsString(
      jsonEncode((entry as YtDownloadEntry).toJson()),
      flush: true,
    );
    await _replaceWith(tmp, file.path);
  }

  /// [file] is there and reads as a record (a JSON object).
  static bool _readable(File file) {
    try {
      return jsonDecode(file.readAsStringSync()) is Map;
    } catch (_) {
      return false;
    }
  }

  /// Renames [tmp] over [target], again a few times while Windows refuses
  /// it (another program has [target] open), as bilibili's save does.
  static Future<void> _replaceWith(File tmp, String target) async {
    for (var wait = 50; ; wait *= 2) {
      try {
        await tmp.rename(target);
        return;
      } on FileSystemException {
        if (wait > 800) rethrow;
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
  }

  @override
  Future<void> prepare(DownloadEntry entry, DownloadReport report) async {}

  // ------------------------------------------------------------ the start

  /// Both streams of the current stream folder are whole by their
  /// `stream.json` (design §2.3): no resolve, no cover, the transfer
  /// reports them complete without a request.
  @override
  bool streamsComplete(DownloadEntry entry) {
    final dir = _streamDir(entry as YtDownloadEntry);
    if (dir == null) return false;
    final ids = readYtStreamIds(dir);
    final video = ids?.video;
    final audio = ids?.audio;
    // the transfer's own rule (review 2e): what it would take as whole
    // without a request, nothing it would start from 0
    return video != null &&
        audio != null &&
        YtPairTransfer.wholeOnDisk(dir, 'video', video, audio) &&
        YtPairTransfer.wholeOnDisk(dir, 'audio', video, audio);
  }

  /// The current stream folder (`main/<stream_tag>`); null: none yet.
  static String? _streamDir(YtDownloadEntry entry) {
    final tag = entry.streamTag;
    return tag == null ? null : path.join(entry.entryDirPath, tag);
  }

  /// Each stream on its own (design §2.3 p4#4): its bytes on disk and its
  /// total in `stream.json` (0: not known); both streams always.
  @override
  ({(int, int) video, (int, int)? audio, int? mediaGuess, bool? expectAudio})
  initialBytes(DownloadEntry entry) {
    final dir = _streamDir(entry as YtDownloadEntry);
    if (dir == null) {
      return (video: (0, 0), audio: (0, 0), mediaGuess: 0, expectAudio: true);
    }
    final ids = readYtStreamIds(dir);
    // called before the start's own failure handling: never throws (a
    // stream it cannot measure counts as 0, review 2e)
    (int, int) of(String stream, YtStreamId? id) {
      var onDisk = 0;
      try {
        final file = File(path.join(dir, '$stream.m4s'));
        if (file.existsSync()) onDisk = file.lengthSync();
      } catch (_) {}
      return (onDisk, id?.bytes ?? 0);
    }

    final video = of('video', ids?.video);
    final audio = of('audio', ids?.audio);
    return (
      video: video,
      audio: audio,
      mediaGuess: video.$2 + audio.$2,
      expectAudio: true,
    );
  }

  /// The routers a resolve asks (stage-2 plan §3.3): [own] false is the
  /// one the video pages share (built anew for each resolve, so a mode set
  /// after launch holds), true this download's own, which asks the other
  /// source when the pinned pair or the tier is not offered. [health] is
  /// the table it keeps its sources' health in.
  @visibleForTesting
  static YtSourceRouter Function(
    YtSourceMode mode, {
    required bool own,
    required Map<String, YtSourceHealth> health,
  })?
  routerForTest;

  /// In place of [YtInvidiousSource.playbackFailed].
  @visibleForTesting
  static void Function(String videoId)? playbackFailedForTest;

  /// In place of a [YtPairTransfer] (a test gets the service's callbacks).
  @visibleForTesting
  static DownloadTransfer Function(
    YtTransferSpec spec,
    DownloadTransferReport report,
  )?
  newTransferForTest;

  /// In place of the remux (a test's streams are not MP4).
  @visibleForTesting
  static Future<void> Function(List<String> inputs, String output)?
  remuxForTest;

  YtDirectSource? _direct;

  /// Each download's own router's health (never [YtSourceRouter.
  /// sharedHealth]), dropped when the download completes or is deleted.
  final _ownHealth = <DownloadKey, Map<String, YtSourceHealth>>{};

  /// Tests only: the downloads that hold their own router health.
  @visibleForTesting
  Iterable<DownloadKey> get ownHealthForTest => _ownHealth.keys;

  YtSourceRouter _router(
    YtSourceMode mode, {
    required bool own,
    required Map<String, YtSourceHealth> health,
  }) {
    if (routerForTest case final make?) {
      return make(mode, own: own, health: health);
    }
    YtSourceStore.load();
    YtInvidiousSource.log ??= (line) => EventLog.add('invidious', line);
    return YtSourceRouter(
      _direct ??= YtDirectSource.create(),
      fallback: YtInvidiousSource.shared,
      mode: mode,
      health: health,
    );
  }

  /// The pair this start downloads (stage-2 plan §3.3). Nothing of the
  /// entry is changed and nothing saved: what it found goes into the entry
  /// in [transport], once the service has let the start go on.
  @override
  Future<DownloadPlan> resolve(DownloadEntry entry) async {
    entry as YtDownloadEntry;
    final id = entry.videoId;
    final mode = YtSourceStore.debugMode;
    final play = _router(
      mode,
      own: false,
      health: YtSourceRouter.sharedHealth,
    );
    final detail = await play.run((s) async => _definite(await s.detail(id)));
    if (!detail.ok) throw _failed(detail.verdict);
    _checkLive(detail);
    final pin = _pinOf(entry);
    final preference = YtFormatPreference.mp4Download(
      entry.maxHeight,
      exactHeight: entry.maxHeight,
      pin: pin,
      preferNonDrc: true,
    );
    var streams = await play.run(
      (s) => s.streams(id, preference: preference),
    );
    if (!streams.ok && streams.verdict.signal == 'no-pinned-pair') {
      streams =
          await _askOther(entry, streams.source?.id, mode, preference) ??
          (throw DownloadResolveFailure(
            DownloadFailure.qualityUnavailable,
            // what was not on offer: the pair whose bytes are on disk, or
            // the tier (review 2e)
            '${pin != null ? 'the pair on disk ($pin)' : 'tier ${entry.maxHeight}'} '
            'not offered (${streams.verdict.signal})',
          ));
    }
    if (!streams.ok) throw _failed(streams.verdict);
    final pair = streams.value!;
    final video = pair.video;
    final audio = pair.audio;
    // the sources pick from their formats: a pair without them is theirs
    // to fix, not a video to give up on
    if (video == null || audio == null) {
      throw const DownloadResolveFailure(
        DownloadFailure.other,
        'a pair without its formats',
      );
    }
    final tier = ytQualityTier(video.width ?? 0, video.height ?? 0);
    return YtPlan(
      pair: pair,
      streamTag: YtStreamTag.of(video, audio),
      streamSource: pair.sourceId,
      qualityLabel: video.qualityLabel ?? '${tier}p',
      mediaGuess: _guess(video, audio, entry.durationMs),
    );
  }

  static const _directId = 'direct';

  /// An upcoming video's refusal (`live_stream_offline`) is a statement
  /// about the video, not a sign of a stale client: the classifier marks
  /// it suspect when `videoDetails` came back, and a router's run of such
  /// verdicts would turn it into `clientBroken` before this download read
  /// it (design §10-5 item 3, review 2e). Taken as definite here, in this
  /// download's own call, before the router sees it; the shared classifier
  /// and router are as they were.
  static YtResult<YtVideoDetail> _definite(YtResult<YtVideoDetail> r) {
    final v = r.verdict;
    if (r.ok ||
        !v.suspectClient ||
        !v.signal.startsWith('playability:live_stream_offline')) {
      return r;
    }
    return YtResult.failed(YtVerdict(v.cause, v.signal, v.detail));
  }

  /// A live or upcoming video, by the direct source's answer only:
  /// Invidious does not tell (§10-5 4 b).
  static void _checkLive(YtRoutedResult<YtVideoDetail> detail) {
    if (detail.source?.id == _directId && (detail.value?.liveNow ?? false)) {
      throw const DownloadResolveFailure(
        DownloadFailure.noFormat,
        'live or upcoming',
      );
    }
  }

  /// This download's own router on the source that did not have the pair
  /// (§10-7 Q4 d): its own health table, nothing set aside. Null: it had
  /// none either, or may not be asked — the direct source in a cooldown of
  /// the shared table (read only), or a single-source mode (`--yt-source`:
  /// one source only).
  Future<YtRoutedResult<YtStreamPair>?> _askOther(
    YtDownloadEntry entry,
    String? asked,
    YtSourceMode mode,
    YtFormatPreference preference,
  ) async {
    if (mode != YtSourceMode.auto || asked == null) return null;
    final otherIsDirect = asked != _directId;
    if (otherIsDirect &&
        !(YtSourceRouter.sharedHealth[_directId]?.availableAt(
              DateTime.now(),
            ) ??
            true)) {
      return null;
    }
    final own = _router(
      otherIsDirect ? YtSourceMode.directOnly : YtSourceMode.fallbackOnly,
      own: true,
      health: _ownHealth.putIfAbsent(entry.key, () => {}),
    );
    try {
      // the pair's own source says whether it is live (review 2e): the
      // shared detail may have been another source's
      if (otherIsDirect) {
        final detail = await own.run(
          (s) async => _definite(await s.detail(entry.videoId)),
        );
        if (!detail.ok) return null;
        _checkLive(detail);
      }
      final r = await own.run(
        (s) => s.streams(entry.videoId, preference: preference),
      );
      return r.ok ? r : null;
    } finally {
      // deleted meanwhile: its own health goes with it (review 2e)
      if (!Directory(entry.entryDirPath).existsSync()) {
        _ownHealth.remove(entry.key);
      }
    }
  }

  /// The pair the bytes on disk are of (design §4.1): from the current
  /// stream folder's `stream.json`; from its name alone when that does not
  /// read. Null: no bytes there, so nothing to keep to.
  static YtFormatPin? _pinOf(YtDownloadEntry entry) {
    final dir = _streamDir(entry);
    if (dir == null) return null;
    bool has(String stream) {
      final f = File(path.join(dir, '$stream.m4s'));
      return f.existsSync() && f.lengthSync() > 0;
    }

    if (!has('video') && !has('audio')) return null;
    final byName = YtStreamTag.pinOf(path.basename(dir));
    if (byName == null) return null;
    final ids = readYtStreamIds(dir);
    final video = ids?.video;
    final audio = ids?.audio;
    // the identity read, of this folder's pair: its own track id and DRC
    // mark (the folder name says the same of both)
    if (video != null &&
        audio != null &&
        video.itag == byName.videoItag &&
        audio.itag == byName.audioItag &&
        ytAudioTrackDigest(audio.track) == byName.audioTrackDigest &&
        audio.drc == byName.drc) {
      return YtFormatPin(
        videoItag: video.itag,
        audioItag: audio.itag,
        audioTrackId: audio.track,
        drc: audio.drc,
      );
    }
    return byName;
  }

  /// Both streams' size: their lengths, else their bitrates over the
  /// duration (design §3.1).
  static int? _guess(YtFormat video, YtFormat audio, int durationMs) {
    if ((video.contentLength, audio.contentLength) case (
      final v?,
      final a?,
    )) {
      return v + a;
    }
    final rate = video.bitrate + audio.bitrate;
    if (rate <= 0 || durationMs <= 0) return null;
    return rate * durationMs ~/ 8000;
  }

  /// A failed answer of a source as a start's failure (stage-2 plan §3.3
  /// 「失败的归类」): the cause first, then the signal.
  static DownloadResolveFailure _failed(YtVerdict verdict) {
    final signal = verdict.signal;
    final kind = switch (verdict.cause) {
      _ when signal == 'invidious:live' => DownloadFailure.noFormat,
      _ when signal.startsWith('playability:live_stream_offline') =>
        DownloadFailure.noFormat,
      YtCause.contentUnavailable when signal == 'no-playable-pair' =>
        DownloadFailure.noFormat,
      YtCause.transient || YtCause.ipBlocked => DownloadFailure.network,
      _ => DownloadFailure.other,
    };
    return DownloadResolveFailure(kind, '${verdict.cause.name}<$signal>');
  }

  @override
  String? streamKey(DownloadPlan plan) => null;

  @override
  Future<String?> readStreamKey(DownloadEntry entry) async => null;

  /// The streams' identity is the transfer's (`stream.json`).
  @override
  Future<void> writeStreamKey(DownloadEntry entry, DownloadPlan plan) async {}

  /// The pair transfer, through the handle. What the resolve found is
  /// written into the entry only when the service takes the transfer (the
  /// start still the current one), and saved when it changed. [plan] null
  /// (both streams whole): built from `stream.json`, with no address — it
  /// asks for nothing.
  @override
  Future<void> transport(
    DownloadEntry entry,
    DownloadPlan? plan,
    int gen,
  ) async {
    entry as YtDownloadEntry;
    final YtTransferSpec spec;
    if (plan == null) {
      final dir = _streamDir(entry);
      final ids = dir == null ? null : readYtStreamIds(dir);
      final video = ids?.video;
      final audio = ids?.audio;
      if (dir == null || video == null || audio == null) {
        throw const DownloadResolveFailure(
          DownloadFailure.other,
          'the streams are no longer whole',
        );
      }
      spec = (
        videoId: entry.videoId,
        source: entry.streamSource ?? _directId,
        streamDir: dir,
        video: (url: '', id: video),
        audio: (url: '', id: audio),
      );
    } else {
      plan as YtPlan;
      final pair = plan.pair;
      spec = (
        videoId: entry.videoId,
        source: plan.streamSource,
        streamDir: path.join(entry.entryDirPath, plan.streamTag),
        video: (
          url: pair.videoUrl,
          id: YtStreamId.of(pair.video!, pair.videoUrl),
        ),
        audio: (
          url: pair.audioUrl,
          id: YtStreamId.of(pair.audio!, pair.audioUrl),
        ),
      );
    }
    var changed = false;
    final transfer = _host.attach(gen, entry, (report) {
      if (plan is YtPlan) {
        changed =
            entry.streamTag != plan.streamTag ||
            entry.streamSource != plan.streamSource ||
            entry.quality != plan.qualityLabel;
        entry
          ..streamTag = plan.streamTag
          ..streamSource = plan.streamSource
          ..quality = plan.qualityLabel;
      }
      return (newTransferForTest ?? _newTransfer)(spec, report);
    });
    // what the start found is the record's once the transfer is taken,
    // whatever start comes next (review 2e): not bound to this generation
    if (transfer != null && changed) await _host.saveTaken(entry);
  }

  DownloadTransfer _newTransfer(
    YtTransferSpec spec,
    DownloadTransferReport report,
  ) => YtPairTransfer(
    videoId: spec.videoId,
    source: spec.source,
    streamDir: spec.streamDir,
    video: spec.video,
    audio: spec.audio,
    report: report,
    httpClient: httpClientForTest,
  );

  @override
  bool get playUrlFailuresAreNetwork => false;

  /// The extras (description, subtitles, comments) come with stage 4: a
  /// completed download keeps `extras_pending` until then (§10-7 Q2 c).
  @override
  bool get extrasEnabled => extrasEnabledForTest;

  /// Tests only: stage 4's switch turned on (AC-E).
  @visibleForTesting
  static bool extrasEnabledForTest = false;

  /// A refusal of an Invidious address: that instance set aside and the
  /// video's addresses forgotten before the retry asks again (design §4.3
  /// p2#1). A quality not on offer: nothing — each resolve asks the other
  /// source itself.
  @override
  void beforeRetry(DownloadEntry entry, DownloadFailure? kind) {
    entry as YtDownloadEntry;
    if (kind == DownloadFailure.refused &&
        entry.streamSource == YtInvidiousSource.shared.id) {
      (playbackFailedForTest ?? YtInvidiousSource.shared.playbackFailed)(
        entry.videoId,
      );
    }
  }

  /// `main/<stream_tag>/video.m4s` and `audio.m4s` into one mp4 in the
  /// export folder [export] claims (stage-2 plan §3.5).
  @override
  Future<DownloadMergeResult> merge(
    DownloadEntry entry,
    DownloadExport export,
  ) async {
    entry as YtDownloadEntry;
    final dir = path.join(entry.entryDirPath, entry.streamTypeTag);
    final inputs = [
      path.join(dir, 'video.m4s'),
      path.join(dir, 'audio.m4s'),
    ];
    String? output;
    try {
      output = await export.claim();
      final out = output;
      await (remuxForTest ?? _remux)(inputs, out);
      entry.mergedPath = out;
      _ownHealth.remove(entry.key);
      return (output: out, inputs: inputs, damaged: false, corrupt: false);
    } catch (e) {
      if (output != null) await export.failed(output);
      // damaged bytes (out of the remuxer) or a missing / unreadable
      // stream: not complete; bytes damaged at their full size are removed
      // and downloaded again by the caller (as bilibili's dash streams)
      final damaged =
          e is FormatException || e is RangeError || e is FileSystemException;
      final corrupt = e is FormatException || e is RangeError;
      entry.status = DownloadStatus.failMerge;
      if (!corrupt) {
        (toastForTest ?? SmartDialog.showToast)(
          damaged ? '音视频文件丢失或无法读取，可稍后重新开始该下载' : '合并音视频失败，已保留分离的音视频文件',
        );
      }
      EventLog.add('download', '${entry.logLabel}: merge failed: $e');
      // not damaged: the download is complete (no export): its own health
      // goes, as on a merge that worked (review 2e)
      if (!damaged) _ownHealth.remove(entry.key);
      return (output: null, inputs: inputs, damaged: damaged, corrupt: corrupt);
    } finally {
      if (output != null) export.release(output);
    }
  }

  // static, so the isolate's closure takes only its two arguments
  static Future<void> _remux(List<String> inputs, String output) =>
      Isolate.run(() => Mp4Remuxer.remux(inputs: inputs, output: output));

  /// Design §4.3's table: the transfer's own types say what they are; a
  /// resolve's failure carries its kind.
  @override
  DownloadFailure classify(Object error) {
    final cause = error is YtTransferError ? error.cause : error;
    return switch (cause) {
      DownloadResolveFailure(:final kind) => kind,
      YtHttpStatus(refused: true) => DownloadFailure.refused,
      // 429 / 5xx: retried within the transfer; once it gave up, not the
      // network (its budget is spent) nor a refusal
      YtHttpStatus() => DownloadFailure.other,
      YtRangeError() => DownloadFailure.range,
      _ when ytNetworkFailure(cause) => DownloadFailure.network,
      _ => DownloadFailure.other,
    };
  }

  // ------------------------------------------------------------ the cover

  /// What a cover may take (review 2bc): its bytes, and its time — the
  /// redirects, a failed answer's body and the body itself included.
  @visibleForTesting
  static int coverMaxBytes = 4 << 20;
  @visibleForTesting
  static Duration coverDeadline = const Duration(seconds: 60);

  /// Tests only: in place of the image cache's lookup.
  @visibleForTesting
  static Future<File?> Function(String url)? coverCacheForTest;

  /// `cover.jpg` in the entry folder: from the image cache, else fetched
  /// over a bare [HttpClient] with every hop checked ([YtCheckedHops]) —
  /// never through the app's Dio (no bilibili headers). `*.ytimg.com`
  /// only, on every hop: a redirect elsewhere is refused before it is
  /// opened. Written as `cover.jpg.part` and renamed, from the cache too,
  /// so a `cover.jpg` is always whole; a `.part` left by a failure is
  /// removed. A failure does not stop the video.
  @override
  Future<bool> cover(DownloadEntry entry) async {
    entry as YtDownloadEntry;
    final file = File(path.join(entry.entryDirPath, PathUtils.coverName));
    if (file.existsSync()) return true;
    final uri = Uri.tryParse(entry.cover);
    if (uri == null || !isYtImageHost(uri)) return false;
    final part = File('${file.path}.part');
    try {
      if (await _coverFromCache(entry.cover, part) ||
          await _fetchCover(uri, part)) {
        await part.rename(file.path);
        return true;
      }
    } catch (_) {
      // not saved: the video goes on without it
    }
    await part.tryDel();
    return false;
  }

  /// The image cache's copy of [url] into [part]; false: none there (or no
  /// image cache: a test, a cleared cache).
  static Future<bool> _coverFromCache(String url, File part) async {
    final File? cached;
    try {
      cached = await (coverCacheForTest ?? _imageCache)(url);
    } catch (_) {
      return false;
    }
    if (cached == null) return false;
    await cached.copy(part.path);
    return true;
  }

  static Future<File?> _imageCache(String url) async =>
      (await CacheManager.manager.getFileFromCache(url))?.file;

  /// [uri] fetched into [part]: at most [coverMaxBytes], within
  /// [coverDeadline] in all (the client is closed when it runs out, which
  /// ends whatever is still being read); false: not a 200.
  static Future<bool> _fetchCover(Uri uri, File part) async {
    final client = (httpClientForTest ?? HttpClient.new)()
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 30);
    final deadline = Timer(coverDeadline, () => client.close(force: true));
    try {
      final (_, response) = await YtCheckedHops(client).send(
        'GET',
        uri,
        timeout: const Duration(seconds: 30),
        allow: isYtImageHost,
        drainTimeout: const Duration(seconds: 10),
        // the lookup and the connection too (review 2d)
        connectTimeout: const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response
            .drain<void>()
            .timeout(const Duration(seconds: 10))
            .catchError((_) {});
        return false;
      }
      final sink = part.openWrite();
      var bytes = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes += chunk.length;
          if (bytes > coverMaxBytes) {
            throw const FileSystemException('cover over its byte cap');
          }
          sink.add(chunk);
        }
      } finally {
        // closed before a failed .part is removed (Windows keeps an open one)
        await sink.close();
      }
      return true;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  /// A YouTube thumbnail host (`i.ytimg.com`, `i9.ytimg.com` ...).
  static bool isYtImageHost(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'ytimg.com' || uri.host.endsWith('.ytimg.com'));

  // --------------------------------------------------------- the export

  @override
  ({String name, String suffix}) exportName(DownloadEntry entry) =>
      (name: entry.title, suffix: entry.qualityLabel ?? '');

  @override
  Future<Map<String, Object?>> extras({
    required DownloadEntry entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async => const {};

  @override
  Map<String, int> extrasPlan() => const {};

  @override
  SubtitleCacheKey transcriptKey(DownloadEntry entry) =>
      SubtitleCacheKey.youtube((entry as YtDownloadEntry).videoId);

  @override
  String transcriptSessionKey(DownloadEntry entry) =>
      'download:yt:${(entry as YtDownloadEntry).videoId}';

  // ------------------------------------------------------------ the list

  @override
  int? groupBadge(DownloadEntry entry) => null;

  @override
  ({DownloadTitleLine first, List<DownloadTitleLine> more}) titleLines(
    DownloadEntry entry,
    bool showTitle,
  ) => (first: (text: entry.title, maxLines: 2), more: const []);

  @override
  String? platformBadge(DownloadEntry entry) => 'YouTube';

  /// 「切换为下载 720p」 (stage-2 plan §4.2): on a download whose tier is
  /// not on offer and whose retries are spent. [DownloadFailureAction.apply]
  /// only changes the entry in memory — tier 720, no stream folder (so no
  /// pin), its label — the page then calls `restartWith`. The old folder is
  /// left until the download completes.
  @override
  DownloadFailureAction? failureAction(DownloadEntry entry) =>
      entry.status == DownloadStatus.failQuality && entry.gaveUp
      ? (
          label: '切换为下载 720p',
          apply: (entry) => (entry as YtDownloadEntry)
            ..maxHeight = 720
            ..streamTag = null
            ..quality = '720p',
        )
      : null;

  /// Thumbnails are landscape.
  @override
  bool? coverCacheWidth(DownloadEntry entry) => false;

  /// The saved `cover.jpg` only: nothing is fetched for the list (a
  /// placeholder without it).
  @override
  ({File? file, String? network}) localCover(DownloadEntry entry) {
    final cover = File(path.join(entry.entryDirPath, PathUtils.coverName));
    return (file: cover.existsSync() ? cover : null, network: null);
  }

  /// The watch history's own (watched online or offline alike).
  @override
  ({int positionMs, bool finished})? progressOf(DownloadEntry entry) {
    final part = LocalHistory.get(
      LocalHistory.ytKey((entry as YtDownloadEntry).videoId),
    )?.parts[LocalHistory.ytPart];
    if (part == null) return null;
    return (positionMs: part.progress, finished: part.finished);
  }

  @override
  List<DownloadMenuItem> menu(DownloadEntry entry) => const [];

  @override
  List<DownloadMenuItem> groupMenu(List<DownloadEntry> entries) => const [];

  /// 打开在线页, 打开频道.
  @override
  Widget actions(DownloadEntry entry, ColorScheme colorScheme) {
    entry as YtDownloadEntry;
    return SizedBox(
      width: 29,
      height: 29,
      child: PopupMenuButton(
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        icon: Icon(
          Icons.more_vert_outlined,
          color: colorScheme.outline,
          size: 18,
        ),
        itemBuilder: (_) => [
          PopupMenuItem(
            height: 38,
            child: const Text('打开在线页', style: TextStyle(fontSize: 13)),
            onTap: () =>
                Get.toNamed('/ytVideo', parameters: {'id': entry.videoId}),
          ),
          if (entry.channelId.isNotEmpty)
            PopupMenuItem(
              height: 38,
              child: const Text('打开频道', style: TextStyle(fontSize: 13)),
              onTap: () => Get.toNamed(
                '/ytChannel',
                parameters: {'id': entry.channelId},
              ),
            ),
        ],
      ),
    );
  }

  /// The watch history is the user's, not the download's: left. Each
  /// download's own router health goes with it.
  @override
  Future<void> onDeleted(List<DownloadEntry> entries) async {
    for (final entry in entries) {
      _ownHealth.remove(entry.key);
    }
  }

  /// Stage 2: the exported file, as a local file (§10-7 Q1 b); a merge that
  /// failed left no file to play. Stage 3's offline page takes over.
  @override
  Future<void> openOffline(DownloadEntry entry) async {
    final merged = entry.mergedPath;
    if (merged == null) {
      (toastForTest ?? SmartDialog.showToast)(
        '该视频合并失败，无法播放',
      );
      return;
    }
    await (openLocalForTest ?? LocalPlayer.open)(merged);
  }

  // -------------------------------------------------- a new download

  /// What is in `<root>/yt_<videoId>/main/` already: a record there (or a
  /// misplaced `entry.json`) means no new one is made, nothing is written
  /// or cleaned up (plan §3.2 「新建」, design §2.2).
  static YtExisting checkExisting(String root, String videoId) {
    final dir = path.join(root, 'yt_$videoId', 'main');
    final record = File(path.join(dir, YtDownloadEntry.recordFile));
    final tmp = File('${record.path}.tmp');
    final bili = File(path.join(dir, 'entry.json'));
    if (!record.existsSync() && !tmp.existsSync() && !bili.existsSync()) {
      return const YtNoRecord();
    }
    YtDownloadEntry? read(File f) {
      try {
        return YtDownloadEntry.fromJson(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
        );
      } catch (_) {
        return null;
      }
    }

    final entry =
        (record.existsSync() ? read(record) : null) ??
        (tmp.existsSync() ? read(tmp) : null);
    if (entry == null) return YtUnreadable(dir);
    // byte for byte: ids differ in case where the folder names do not
    if (entry.videoId != videoId) return YtCaseConflict(entry.videoId);
    return const YtRecordExists();
  }

  /// A new entry for [detail] at quality tier [maxHeight], its folders in
  /// [root] (not made yet).
  static YtDownloadEntry newEntry(
    YtVideoDetail detail,
    int maxHeight,
    DateTime now,
    String root,
  ) {
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final page = path.join(root, 'yt_${detail.videoId}');
    return YtDownloadEntry(
        videoId: detail.videoId,
        title: detail.title,
        channel: detail.author,
        channelId: detail.channelId,
        cover: detail.bestThumbnail?.url ?? '',
        durationMs: detail.duration.inMilliseconds,
        maxHeight: maxHeight,
        quality: '${maxHeight}p',
        timeCreateStamp: seconds,
        timeUpdateStamp: seconds,
      )
      ..pageDirPath = page
      ..entryDirPath = path.join(page, 'main');
  }

  /// The panel's 「下载」 (plan §3.2 「新建」): after the list is read, by
  /// key in the queue and the list, then by the folder on disk; a new entry
  /// only when there is no record. [unreadable] gets the folder of an
  /// unreadable record (the panel names it).
  static Future<YtCreateResult> create(
    DownloadService service,
    YtVideoDetail detail,
    int maxHeight, {
    DateTime? now,
    void Function(String folder)? unreadable,
  }) async {
    // not before the list is read: a complete record would be made a new
    // (incomplete) one
    await service.waitForInitialization;
    final key = 'yt:${detail.videoId}';
    if (service.downloadList.any((e) => e.key == key)) {
      return YtCreateResult.done;
    }
    if (service.waitDownloadQueue.any((e) => e.key == key)) {
      return YtCreateResult.queued;
    }
    final root = downloadPath;
    // a first tap still writing this record (or one of an id that differs
    // only in case, the same folder on Windows): its .tmp is not read
    if (service.isAdding(path.join(root, 'yt_${detail.videoId}', 'main'))) {
      return YtCreateResult.queued;
    }
    switch (checkExisting(root, detail.videoId)) {
      case YtRecordExists():
        return YtCreateResult.recordExists;
      case YtCaseConflict():
        return YtCreateResult.caseConflict;
      case YtUnreadable(:final folder):
        unreadable?.call(folder);
        return YtCreateResult.unreadable;
      case YtNoRecord():
        break;
    }
    return switch (await service.addDownload(
      newEntry(detail, maxHeight, now ?? DateTime.now(), root),
    )) {
      DownloadAddResult.added => YtCreateResult.added,
      // added meanwhile (a second tap while the first was writing)
      DownloadAddResult.present => YtCreateResult.queued,
      // the record not written: its leftovers removed, nothing queued
      DownloadAddResult.failed => YtCreateResult.failed,
    };
  }
}
