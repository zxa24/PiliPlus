/// LibrePili: YouTube's part of the downloads (feature-logs/
/// download-platforms design §3.1, stage-2 plan §3). Not a part of the
/// service's library: what it may do to the service goes through the
/// handle it is built with ([DownloadHost]) and the service's public
/// methods (`addDownload`, `restartWith`).
///
/// Stage 2b: the record, the list, the cover, the new-download guard and
/// the offline open. The start's resolve / transport / merge come with 2d
/// and 2e (plan §7); until then a YouTube entry's start fails as a play URL
/// the queue retries.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
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

  static final _name = RegExp(r'^(\d+)-(\d+)(?:\.([0-9a-f]{12}))?(\.drc)?$');

  /// The pin a folder name alone gives (its `stream.json` unreadable): the
  /// audio track by its digest. Null: not a stream folder's name.
  static YtFormatPin? pinOf(String dirName) {
    final m = _name.firstMatch(dirName);
    if (m == null) return null;
    return YtFormatPin(
      videoItag: int.parse(m[1]!),
      audioItag: int.parse(m[2]!),
      audioTrackDigest: m[3],
      drc: m[4] != null,
    );
  }

  /// [video] and [audio] are the pair of the folder [dirName], by its name
  /// alone: the audio track compared by digest.
  static bool matches(String dirName, YtFormat video, YtFormat audio) {
    final m = _name.firstMatch(dirName);
    if (m == null) return false;
    return video.itag == int.parse(m[1]!) &&
        audio.itag == int.parse(m[2]!) &&
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
  recordExists('该视频已有下载记录，请重新进入缓存页');

  const YtCreateResult(this.message);
  final String message;
}

final class YtDownloadPlatform implements DownloadPlatform {
  YtDownloadPlatform(this._host);

  // ignore: unused_field
  final DownloadHost _host;

  // Tests only: stand-ins for what this adapter reaches out to (null: the
  // real call).

  /// In place of [SmartDialog.showToast].
  @visibleForTesting
  static void Function(String msg)? toastForTest;

  /// In place of [LocalPlayer.open].
  @visibleForTesting
  static Future<bool> Function(String path)? openLocalForTest;

  /// In place of a new [HttpClient] (the cover; later the transfers too).
  @visibleForTesting
  static HttpClient Function()? httpClientForTest;

  @override
  String get id => YtDownloadEntry.platformId;

  @override
  String get recordFile => YtDownloadEntry.recordFile;

  @override
  DownloadEntry parse(Map<String, dynamic> json) =>
      YtDownloadEntry.fromJson(json);

  /// `entry.librepili.json` through `<file>.tmp` + rename, as bilibili's
  /// `entry.json` (a folder deleted meanwhile is not made again).
  @override
  Future<void> save(DownloadEntry entry) async {
    if (!Directory(entry.entryDirPath).existsSync()) return;
    final file = File(path.join(entry.entryDirPath, recordFile));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode((entry as YtDownloadEntry).toJson()),
      flush: true,
    );
    await _replaceWith(tmp, file.path);
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

  // ------------------------------------------------- the start (2d, 2e)

  @override
  bool streamsComplete(DownloadEntry entry) => false;

  @override
  Future<DownloadPlan> resolve(DownloadEntry entry) async =>
      throw const DownloadResolveFailure(
        DownloadFailure.other,
        'YouTube streams: not in this build yet',
      );

  @override
  String? streamKey(DownloadPlan plan) => null;

  @override
  Future<String?> readStreamKey(DownloadEntry entry) async => null;

  /// The streams' identity is the transfer's (`stream.json`).
  @override
  Future<void> writeStreamKey(DownloadEntry entry, DownloadPlan plan) async {}

  @override
  Future<void> transport(
    DownloadEntry entry,
    DownloadPlan? plan,
    int gen,
  ) async {}

  @override
  bool get playUrlFailuresAreNetwork => false;

  /// The extras (description, subtitles, comments) come with stage 4: a
  /// completed download keeps `extras_pending` until then (§10-7 Q2 c).
  @override
  bool get extrasEnabled => extrasEnabledForTest;

  /// Tests only: stage 4's switch turned on (AC-E).
  @visibleForTesting
  static bool extrasEnabledForTest = false;

  @override
  void beforeRetry(DownloadEntry entry, DownloadFailure? kind) {}

  @override
  ({(int, int) video, (int, int)? audio, int? mediaGuess, bool? expectAudio})
  initialBytes(DownloadEntry entry) => (
    video: (0, 0),
    audio: (0, 0),
    mediaGuess: null,
    expectAudio: null,
  );

  @override
  Future<DownloadMergeResult> merge(
    DownloadEntry entry,
    DownloadExport export,
  ) async =>
      (output: null, inputs: const <String>[], damaged: true, corrupt: false);

  @override
  DownloadFailure classify(Object error) => switch (error) {
    DownloadResolveFailure(:final kind) => kind,
    _ => DownloadFailure.other,
  };

  // ------------------------------------------------------------ the cover

  /// `cover.jpg` in the entry folder: from the image cache, else fetched
  /// over a bare [HttpClient] with every hop checked ([YtCheckedHops]) —
  /// never through the app's Dio (no bilibili headers). Only `*.ytimg.com`.
  /// A failure does not stop the video.
  @override
  Future<bool> cover(DownloadEntry entry) async {
    entry as YtDownloadEntry;
    final file = File(path.join(entry.entryDirPath, PathUtils.coverName));
    try {
      if (file.existsSync()) return true;
      final uri = Uri.tryParse(entry.cover);
      if (uri == null || !isYtImageHost(uri)) return false;
      try {
        final cached = (await CacheManager.manager.getFileFromCache(
          entry.cover,
        ))?.file;
        if (cached != null) {
          await cached.copy(file.path);
          return true;
        }
      } catch (_) {
        // no image cache (a test, a cleared cache): fetched
      }
      final client = (httpClientForTest ?? HttpClient.new)()
        ..idleTimeout = const Duration(seconds: 30);
      try {
        final (_, response) = await YtCheckedHops(client).send(
          'GET',
          uri,
          timeout: const Duration(seconds: 30),
        );
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>().catchError((_) {});
          return false;
        }
        final part = File('${file.path}.part');
        final sink = part.openWrite();
        try {
          await response.timeout(const Duration(seconds: 30)).pipe(sink);
        } catch (_) {
          await part.delete().catchError((_) => part);
          rethrow;
        }
        await part.rename(file.path);
        return true;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
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

  /// 「切换为下载 720p」 comes with 2f.
  @override
  DownloadFailureAction? failureAction(DownloadEntry entry) => null;

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

  /// The watch history is the user's, not the download's: nothing.
  @override
  Future<void> onDeleted(List<DownloadEntry> entries) async {}

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
    // false: added meanwhile (a second tap while the first was writing)
    return await service.addDownload(
          newEntry(detail, maxHeight, now ?? DateTime.now(), root),
        )
        ? YtCreateResult.added
        : YtCreateResult.queued;
  }
}
