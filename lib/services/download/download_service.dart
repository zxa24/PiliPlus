import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io'
    show
        Directory,
        File,
        FileMode,
        FileSystemEntity,
        FileSystemException,
        Platform;
import 'dart:isolate' show Isolate;
import 'dart:math' as math;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/download_keepalive.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/download/download_transcripts.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' show ColorScheme, Widget;
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

part 'download_platform_bili.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService with WidgetsBindingObserver {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  static const _maxDanmakuConcurrency = 4;

  /// Stream folder of [entry]. [BiliDownloadEntryInfo.typeTag] is nullable
  /// (an `entry.json` written by another client may have no `type_tag`) and
  /// `path.join` drops a null part, so joining it directly would give the
  /// entry folder itself — which is deleted recursively below.
  static String _streamDirPath(DownloadEntry entry) =>
      path.join(entry.entryDirPath, entry.streamTypeTag);

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<DownloadEntry>();
  final downloadList = <DownloadEntry>[];

  /// Entries whose video is complete (they are in [downloadList] too) while
  /// their extras — comments, subtitles, ... — are still being saved: they
  /// are listed as downloading until then.
  final extrasQueue = RxList<DownloadEntry>();

  bool isSavingExtras(DownloadEntry entry) =>
      extrasQueue.any((e) => e.key == entry.key);

  DownloadKey? _curKey;

  /// The key of the current download (its name from when it was a cid).
  DownloadKey? get curCid => _curKey;
  final curDownload = Rxn<DownloadEntry>();

  late final _bili = _BiliPlatform(this);

  /// What [entry]'s platform does its own way (design §3.1).
  DownloadPlatform platformOf(DownloadEntry entry) => switch (entry.platform) {
    BiliDownloadEntryInfo.platformId => _bili,
    final other => throw StateError('unknown download platform $other'),
  };
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value case final entry?) {
      entry.status = status;
      curDownload.refresh();
      entry.progress.statusChanged();
      if (status.isFailed) _retryLater(entry, status);
    }
  }

  /// LibrePili: a failed download is started again on its own (user
  /// 2026-10-23 「加一个自动重试下载失败的」), after these waits. Each start
  /// asks for a new play URL (an old one expires, a CDN host may be the
  /// trouble) and resumes from the bytes on disk; within one start the
  /// transfer itself already tries [DownloadManager]'s attempts.
  static const _retryWaits = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 90),
  ];

  /// Tests only: in place of [_retryWaits] (a test does not wait 10 s).
  @visibleForTesting
  static List<Duration>? retryWaitsForTest;

  /// Retries made per entry since its download last got anywhere: like the
  /// transfer's own budget, a retry that saved more bytes is not failing,
  /// and the count starts over.
  final _retries = <DownloadKey, int>{};

  /// Bytes on disk per entry when it last failed.
  final _retryBytes = <DownloadKey, int>{};

  /// Entries whose damaged streams were downloaded again: once per start by
  /// the user (the same damage again is not fixed by another 400 MB).
  final _redownloaded = <DownloadKey>{};

  void _forgetRetries(DownloadKey key) {
    _retries.remove(key);
    _retryBytes.remove(key);
    _redownloaded.remove(key);
  }

  int _bytesOnDisk(DownloadEntry entry) {
    var bytes = 0;
    try {
      final dir = Directory(_streamDirPath(entry));
      if (!dir.existsSync()) return 0;
      for (final f in dir.listSync()) {
        if (f is File &&
            !f.path.endsWith('.json') &&
            !f.path.endsWith('.size')) {
          bytes += f.lengthSync();
        }
      }
    } catch (_) {}
    return bytes;
  }

  void _retryLater(DownloadEntry entry, DownloadStatus status) {
    // off screen (Android): started again once the app is back, see
    // [_resumeFailedAway]
    if (_away) return;
    final key = entry.key;
    if (status == DownloadStatus.failMerge) {
      // only damaged streams that were removed are worth a start again; the
      // bytes it downloads anew are not progress against the budget below
      if (entry.downloadedBytes != 0 || !_redownloaded.add(key)) {
        _gaveUp(entry, status, 'merge');
        return;
      }
    } else {
      final bytes = _bytesOnDisk(entry);
      if (bytes > (_retryBytes[key] ?? -1)) _retries[key] = 0;
      _retryBytes[key] = bytes;
    }
    final retryWaits = retryWaitsForTest ?? _retryWaits;
    final made = _retries[key] ?? 0;
    if (made >= retryWaits.length) {
      _gaveUp(entry, status, '${retryWaits.length} retries');
      return;
    }
    _retries[key] = made + 1;
    final wait = retryWaits[made];
    EventLog.add(
      'download',
      '${entry.logLabel}: ${status.name} (${lastError ?? '-'}), '
          'again in ${wait.inSeconds} s (${made + 1}/${retryWaits.length})',
    );
    entry.status = DownloadStatus.retryWait;
    curDownload.refresh();
    entry.progress.statusChanged();
    // a pause, a delete or another start meanwhile bumps the generation
    final gen = _startGen;
    Timer(wait, () {
      if (gen != _startGen ||
          curDownload.value?.key != key ||
          entry.status != DownloadStatus.retryWait) {
        return;
      }
      startDownload(entry, retry: true);
    });
  }

  /// No more retries: it stays failed for the user, and the queue goes on
  /// with the downloads waiting behind it.
  void _gaveUp(DownloadEntry entry, DownloadStatus status, String why) {
    EventLog.add(
      'download',
      '${entry.logLabel}: ${status.name} (${lastError ?? '-'}), '
          'no more retries ($why)',
    );
    _retries.remove(entry.key);
    _retryBytes.remove(entry.key);
    final gen = _startGen;
    // after the failing start has unwound
    scheduleMicrotask(() {
      if (gen == _startGen && curDownload.value?.key == entry.key) {
        nextDownload();
      }
    });
  }

  DownloadManager? _downloadManager;
  DownloadManager? _audioDownloadManager;

  /// Bumped by every start, pause and delete: a start still fetching the
  /// danmaku or the play URL when it is paused or deleted has no managers
  /// to cancel yet, and must not go on writing and starting transfers once
  /// its awaits return.
  int _startGen = 0;

  late Future<void> _initialization;

  /// The download list read. Awaited by the download pages and the video
  /// page: the service is in use from then on ([_releaseExtras]).
  Future<void> get waitForInitialization {
    _releaseExtras();
    return _initialization;
  }

  /// Created at start-up by [startInBackground]: only the list, the
  /// transcripts and the subtitle hook run then. Extras an earlier run left
  /// unsaved need requests: they wait in [_heldExtras] until the download
  /// UI or a download action first uses the service, as before it was
  /// created at start-up.
  bool _holdExtras = false;
  final _heldExtras = <DownloadEntry>[];
  static bool _startingInBackground = false;

  /// For the app's start: the background transcription of finished
  /// downloads carries on after a restart, and a transcript made while
  /// watching is written beside the download, without waiting for a
  /// download page to create the service.
  static void startInBackground() {
    _startingInBackground = true;
    try {
      Get.find<DownloadService>();
    } finally {
      _startingInBackground = false;
    }
  }

  void _releaseExtras() {
    if (!_holdExtras) return;
    _holdExtras = false;
    final held = [..._heldExtras];
    _heldExtras.clear();
    held.forEach(_resumeExtras);
  }

  /// Finished downloads transcribed to their end in the background, and
  /// how far each has got.
  late final transcripts = DownloadTranscripts(
    entries: () => downloadList,
    save: _saveEntry,
    platformOf: platformOf,
  );

  @override
  void onInit() {
    super.onInit();
    _holdExtras = _startingInBackground;
    initDownloadList();
    SubtitleCache.onSaved = _keepTranscript;
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _keepAliveWorkers = [
        ever(curDownload, (_) => _syncKeepAlive()),
        ever(extrasQueue, (_) => _syncKeepAlive()),
      ];
    }
  }

  @override
  void onClose() {
    if (SubtitleCache.onSaved == _keepTranscript) SubtitleCache.onSaved = null;
    transcripts.dispose();
    if (Platform.isAndroid) WidgetsBinding.instance.removeObserver(this);
    for (final worker in _keepAliveWorkers) {
      worker.dispose();
    }
    keepAlive.update(null, visible: !_away);
    super.onClose();
  }

  /// LibrePili (Android): the queue keeps the network with the app off
  /// screen (user 2026-10-19, D8 C; see [DownloadKeepAlive]). Its
  /// notification's 「暂停」 pauses the running download.
  late final keepAlive = DownloadKeepAlive(
    onPause: () {
      final entry = curDownload.value;
      // a merge cannot be paused (and the job is already gone): it finishes,
      // but the queue does not carry on after it
      if (entry != null && _mergingKeys.contains(entry.key)) {
        _pauseAfterMergeKey = entry.key;
      } else if (entry?.status.isDownloading ?? false) {
        cancelDownload(isDelete: false, downloadNext: false);
      }
    },
  );
  var _keepAliveWorkers = <Worker>[];

  /// The app is off screen (Android): a job cannot be had then, and a
  /// download the network failed meanwhile is started again on the return.
  bool _away = false;

  /// Downloads that failed for the network while [_away].
  final _failedAway = <DownloadKey>{};

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_away) return;
        _away = false;
        keepAlive.resumed();
        _syncKeepAlive();
        _resumeFailedAway();
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        _away = true;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _syncKeepAlive() => keepAlive.update(_keepAliveState, visible: !_away);

  @visibleForTesting
  DownloadKeepAliveState? get keepAliveStateForTest => _keepAliveState;

  /// What the job's notification shows; null while nothing downloads.
  DownloadKeepAliveState? get _keepAliveState {
    final entry = curDownload.value;
    if (entry != null && entry.status.isDownloading) {
      final progress = entry.progress;
      final received = progress.mediaReceived;
      final total = progress.mediaTotal;
      final size = total > 0
          ? '${CacheManager.formatSize(received)} / '
                '${CacheManager.formatSize(total)}'
          : CacheManager.formatSize(received);
      final more = waitDownloadQueue.where((e) => e.key != entry.key).length;
      return (
        title: entry.showTitle,
        text:
            '${entry.status.message} · $size'
            '${more > 0 ? ' · 还有 $more 个' : ''}',
        received: received,
        total: total,
      );
    }
    // comments, subtitles ... saved after a video: requests too
    if (!_holdExtras && extrasQueue.isNotEmpty) {
      return (
        title: extrasQueue.first.showTitle,
        text: DownloadStatus.savingExtras.message,
        received: 0,
        total: 0,
      );
    }
    return null;
  }

  /// A download stopped by the network while the app was off screen (no
  /// job to be had, or the system took it back): the queue stops on a
  /// failure and waits for the user, so it is started again once the app is
  /// back — once per return, not a retry loop: one that fails again with
  /// the app on screen stays failed (user 2026-10-19, D8 C).
  void _noteFailure(Object error, {bool playUrl = false}) {
    if (!_away) return;
    final entry = curDownload.value;
    if (entry == null) return;
    // the play URL's request gives no error to tell the network by
    if (!playUrl &&
        platformOf(entry).classify(error) != DownloadFailure.network) {
      return;
    }
    _failedAway.add(entry.key);
  }

  void _resumeFailedAway() {
    if (_failedAway.isEmpty) return;
    final keys = {..._failedAway};
    _failedAway.clear();
    // started meanwhile (the user's tap, a notification)
    if (curDownload.value?.status.isDownloading ?? false) return;
    for (final entry in waitDownloadQueue) {
      if (keys.contains(entry.key) &&
          const {
            DownloadStatus.failDownload,
            DownloadStatus.failDownloadAudio,
            DownloadStatus.failPlayUrl,
          }.contains(entry.status)) {
        EventLog.add(
          'download',
          '${entry.logLabel}: failed off screen (${entry.status.name}), '
              'started again',
        );
        startDownload(entry);
        return;
      }
    }
  }

  /// The transcript of a part kept by the subtitle cache: how far it got,
  /// for the list, and — with the subtitles, when those are saved — written
  /// beside each finished download of that part (see [TranscriptFiles]).
  void _keepTranscript(SubtitleCacheEntry entry) {
    final id = entry.key.id;
    for (final download in downloadList) {
      if (!download.isCompleted ||
          platformOf(download).transcriptKey(download).id != id) {
        continue;
      }
      final merged = download.mergedPath;
      if (merged == null || !File(merged).existsSync()) continue;
      transcripts.kept(entry, download);
      if (Pref.dlSaveSubtitle) unawaited(TranscriptFiles.write(entry, merged));
    }
  }

  void initDownloadList() {
    _initialization = _readDownloadList();
  }

  /// The download folder changed: the running transfer (it writes into the
  /// old folder) is paused, and the list and queue are re-read from the new
  /// folder.
  void reloadDownloadList() {
    _releaseExtras();
    _initialization = () async {
      await _initialization;
      await cancelDownload(isDelete: false, downloadNext: false);
      // a merge still in progress completes its entry on its own
      if (!_mergingKeys.contains(_curKey)) {
        _curKey = null;
        curDownload.value = null;
      }
      await _readDownloadList();
      // the list page still shows entries of the old root until it reloads,
      // and the re-read queue is all "waiting": start it again (a merge left
      // running keeps its entry, it calls [nextDownload] when it is done)
      flagNotifier.refresh();
      if (curDownload.value == null) nextDownload();
    }();
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    waitDownloadQueue.clear();
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir));
      }
    }
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
    // how far the transcripts beside them got, then the ones still to do
    unawaited(transcripts.readKnown().whenComplete(transcripts.kick));
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<DownloadEntry>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <DownloadEntry>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    // one folder that cannot be listed (permissions, a broken link) must
    // not hide the downloads in the folders after it
    try {
      await for (final entryDir in pageDir.list()) {
        if (entryDir is Directory) {
          final entryFile = File(path.join(entryDir.path, _entryFile));
          final tmpFile = File('${entryFile.path}.tmp');
          if (entryFile.existsSync() || tmpFile.existsSync()) {
            try {
              // a write interrupted before the rename leaves the previous
              // (complete) entry.json in place; only a file torn by an older
              // build needs the .tmp copy
              String entryJson;
              try {
                entryJson = await entryFile.readAsString();
                jsonDecode(entryJson);
              } catch (_) {
                entryJson = await tmpFile.readAsString();
              }
              final platform = _bili;
              final entry = platform.parse(jsonDecode(entryJson))
                ..pageDirPath = pageDir.path
                ..entryDirPath = entryDir.path;
              if (entry.isCompleted) {
                result.add(entry);
                // the app closed while they were being saved
                if (entry.extrasPending) _resumeExtras(entry);
              } else {
                final (:video, :audio) = platform.initialBytes(entry);
                entry.progress
                  ..planExtras(platform.extrasPlan())
                  ..video(video.$1, video.$2);
                if (audio != null) entry.progress.audio(audio.$1, audio.$2);
                waitDownloadQueue.add(entry..status = DownloadStatus.wait);
              }
            } catch (e) {
              // a record this build cannot read: left out of the list, its
              // files stay on disk
              lastError = 'entry.json (${entryDir.path}): $e';
              debugPrint('skipped download entry: $lastError');
            }
          }
        }
      }
    } catch (e) {
      lastError = 'download folder (${pageDir.path}): $e';
      debugPrint('skipped download folder: $lastError');
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
    _releaseExtras();
    final cid = page.cid!;
    if (downloadList.indexWhere(
          (e) => e is BiliDownloadEntryInfo && e.cid == cid,
        ) !=
        -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere(
          (e) => e is BiliDownloadEntryInfo && e.cid == cid,
        ) !=
        -1) {
      return;
    }
    final pageData = PageInfo(
      cid: cid,
      page: page.page!,
      from: page.from,
      part: page.part,
      vid: page.vid,
      hasAlias: false,
      tid: 0,
      width: 0,
      height: 0,
      rotate: 0,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: videoDetail?.title ?? videoArc!.title,
    );
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: videoDetail?.title ?? videoArc!.title!,
      typeTag: videoQuality.code.toString(),
      cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
      preferedVideoQuality: videoQuality.code,
      qualityPithyDescription: videoQuality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: (page.duration ?? 0) * 1000,
      danmakuCount:
          videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: videoDetail?.aid ?? videoArc!.aid!,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: videoDetail?.bvid ?? videoArc!.bvid!,
      ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
      ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
      pageData: pageData,
    );
    _createDownload(entry);
  }

  void downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
  ) {
    _releaseExtras();
    final cid = episode.cid!;
    if (downloadList.indexWhere(
          (e) => e is BiliDownloadEntryInfo && e.cid == cid,
        ) !=
        -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere(
          (e) => e is BiliDownloadEntryInfo && e.cid == cid,
        ) !=
        -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(
      avId: episode.aid!,
      cid: cid,
    );
    final ep = EpInfo(
      avId: source.avId,
      page: index,
      danmaku: source.cid,
      cover: episode.cover!.http2https,
      episodeId: episode.id!,
      index: episode.title!,
      indexTitle: episode.longTitle ?? '',
      showTitle: episode.showTitle,
      from: episode.from ?? 'bangumi',
      seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
      width: 0,
      height: 0,
      rotate: 0,
      link: episode.link ?? '',
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      sortIndex: index,
    );
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
      typeTag: quality.code.toString(),
      cover: episode.cover!.http2https,
      preferedVideoQuality: quality.code,
      qualityPithyDescription: quality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli:
          (episode.duration ?? 0) *
          (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
      danmakuCount: pgcItem.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      spid: 0,
      seasonId: pgcItem.seasonId!.toString(),
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      avid: source.avId,
      ep: ep,
      source: source,
      ownerId: pgcItem.upInfo?.mid,
      ownerName: pgcItem.upInfo?.uname,
      pageData: null,
    );
    _createDownload(entry);
  }

  Future<void> _createDownload(BiliDownloadEntryInfo entry) async {
    final entryDir = await _getDownloadEntryDir(entry);
    final entryJsonFile = File(path.join(entryDir.path, _entryFile));
    await entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
    waitDownloadQueue.add(entry);
    if (curDownload.value?.status.isDownloading != true) {
      startDownload(entry);
    }
  }

  Future<Directory> _getDownloadEntryDir(BiliDownloadEntryInfo entry) async {
    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }
    final root = await _getDownloadPath();
    // an export made before exports avoided internal names (e.g. a title
    // "114514") may already occupy this video's page folder: move it aside
    // so the download is not created inside it (and deleting the download
    // cannot take the export with it)
    final page = Directory(path.join(root, dirName));
    if (page.existsSync() &&
        _isOldExport(page) &&
        // already holds downloads (made before this guard): leave it, the
        // deletion guard keeps the export's files
        !page.listSync().any(
          (e) =>
              e is Directory &&
              File(path.join(e.path, _entryFile)).existsSync(),
        )) {
      var aside = exportFolderName(dirName);
      for (var i = 2; Directory(path.join(root, aside)).existsSync(); i++) {
        aside = '${exportFolderName(dirName)} ($i)';
      }
      final moved = path.join(root, aside);
      try {
        await page.rename(moved);
        // the download that exported it still points at the old place
        for (final e in downloadList) {
          if (e.mergedPath case final merged?
              when path.isWithin(page.path, merged)) {
            e.mergedPath = path.join(
              moved,
              path.relative(merged, from: page.path),
            );
            await _saveEntry(e);
          }
        }
      } on FileSystemException catch (e) {
        // e.g. Windows: a file in it is open (the export is playing). The
        // download goes inside it then; the deletion guards on both sides
        // keep the export's files and the download apart.
        if (kDebugMode) debugPrint('cannot move export aside: $e');
      }
    }
    final pageDir = Directory(path.join(root, dirName, pageDirName));
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// [retry]: started again by [_retryLater]; any other start is the
  /// user's (or the queue's) and its retries count from nothing.
  Future<void> startDownload(
    DownloadEntry entry, {
    bool retry = false,
  }) {
    _releaseExtras();
    if (!retry) _forgetRetries(entry.key);
    // already finished downloading; the merge completes it
    if (_mergingKeys.contains(entry.key)) return Future.value();
    final gen = ++_startGen;
    return _lock.synchronized(() async {
      // paused, deleted or started again while waiting for the lock
      if (gen != _startGen) return;
      await _downloadManager?.cancel(isDelete: false);
      await _audioDownloadManager?.cancel(isDelete: false);
      _downloadManager = null;
      _audioDownloadManager = null;
      if (curDownload.value case final curEntry?) {
        if (curEntry.status.isDownloading) {
          curEntry.status = DownloadStatus.pause;
        }
      }

      _curKey = entry.key;
      curDownload.value = entry;
      waitDownloadQueue.refresh();
      await _startDownload(entry, gen);
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    _releaseExtras();
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) {
      return false;
    }
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      final gen = _startGen;
      try {
        if (!isUpdate) {
          _updateCurStatus(DownloadStatus.getDanmaku);
        }
        // unknown duration: at least the first segment
        final seg = math.max(
          (entry.totalTimeMilli / DmUtils.segLength).ceil(),
          1,
        );

        // the first segment alone, then the rest a few at a time
        final rounds = 1 + ((seg - 1) / _maxDanmakuConcurrency).ceil();
        var round = 0;
        void reported() {
          if (isUpdate) return;
          entry.progress.danmaku(round, rounds);
          curDownload.refresh();
        }

        reported();
        final danmaku = (await DmGrpc.dmSegMobile(
          cid: cid,
          segmentIndex: 1,
        )).data;
        round++;
        reported();
        for (var start = 2; start <= seg; start += _maxDanmakuConcurrency) {
          final end = start + _maxDanmakuConcurrency - 1;
          final responses = await Future.wait([
            for (var index = start; index <= seg && index <= end; index++)
              DmGrpc.dmSegMobile(cid: cid, segmentIndex: index),
          ]);
          for (final response in responses) {
            danmaku.elems.addAll(response.data.elems);
          }
          responses.clear();
          round++;
          reported();
        }
        // through `.tmp` + rename: "更新弹幕" rewrites it under a playing
        // (or later killed) app, and a torn file would lose the old danmaku
        final tmp = File('${danmakuFile.path}.tmp');
        await tmp.writeAsBytes(danmaku.writeToBuffer(), flush: true);
        await tmp.rename(danmakuFile.path);

        return true;
      } catch (e) {
        // not over the pause of a start that was fetching it
        if (!isUpdate && gen == _startGen) {
          _updateCurStatus(DownloadStatus.failDanmaku);
        }
        if (kDebugMode) (toastForTest ?? SmartDialog.showToast)(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<void> _startDownload(DownloadEntry entry, int gen) async {
    final platform = platformOf(entry);
    final (:video, :audio) = platform.initialBytes(entry);
    entry.progress
      ..restart()
      ..planExtras(platform.extrasPlan())
      // until the play URL tells: about 2 Mbps
      ..mediaGuess = entry.totalTimeMilli * 250
      ..video(video.$1, video.$2);
    if (audio != null) entry.progress.audio(audio.$1, audio.$2);
    try {
      // the danmaku (bilibili) is optional: a failed fetch must not block
      // the video (it can be fetched again later with "update danmaku")
      await platform.prepare(entry, (
        status: (status) {
          if (gen == _startGen) _updateCurStatus(status);
        },
        progress: (done, total) {
          if (gen != _startGen) return;
          entry.progress.danmaku(done, total);
          curDownload.refresh();
        },
      ));
      if (gen != _startGen) return;

      _updateCurStatus(DownloadStatus.getPlayUrl);

      await platform.start(entry, gen);
    } catch (e) {
      if (gen == _startGen) {
        _noteFailure(e, playUrl: true);
        _updateCurStatus(DownloadStatus.failPlayUrl);
      }
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
  }

  /// `entry.json` saves in flight, per entry folder.
  final _entrySaves = <String, Future<void>>{};

  /// Saves `entry.json`. Most call sites do not await this (a size change,
  /// a pause, the completion point), and two of them overlapping would
  /// write and rename the same `entry.json.tmp` at once — exactly the torn
  /// file the tmp+rename is there to prevent. Saves for one folder are
  /// therefore chained: they run one after another, each serialising the
  /// entry when its turn comes (so the last one writes the newest state,
  /// nothing is lost), and the returned future completes once this call's
  /// state is on disk.
  Future<void> _saveEntry(DownloadEntry entry) {
    final dir = entry.entryDirPath;
    final save = (_entrySaves[dir] ?? Future<void>.value()).then(
      (_) => platformOf(entry).save(entry),
    );
    // a failed save must not stall the ones behind it
    final chained = _entrySaves[dir] = save.catchError((Object e) {
      EventLog.add('download', 'entry record not saved: $e');
    });
    chained.whenComplete(() {
      if (identical(_entrySaves[dir], chained)) _entrySaves.remove(dir);
    });
    return save;
  }

  /// Until the saves of [entry]'s record under way are on disk: a delete
  /// waits for them, or on Windows the folder stays (a file being written
  /// cannot be removed, and the delete's error is swallowed by `tryDel`).
  Future<void> _savesDone(DownloadEntry entry) =>
      _entrySaves[entry.entryDirPath] ?? Future<void>.value();

  /// Tests only: an entry saved the way the downloads save it.
  @visibleForTesting
  Future<void> saveEntryForTest(BiliDownloadEntryInfo entry) =>
      _saveEntry(entry);

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      // the size is known from the response headers, also when the transfer
      // resumed at an offset; an unknown size (-1) is never recorded
      if (total > 0 && entry.totalBytes != total) {
        _saveEntry(entry..totalBytes = total);
      }
      entry
        ..downloadedBytes = progress
        ..status = DownloadStatus.downloading
        ..progress.video(progress, total);
      curDownload.refresh();
    }
  }

  void _onAudioReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      entry.progress.audio(progress, total);
      curDownload.refresh();
    }
  }

  /// Last download error (diagnostics: self test, logs).
  String? lastError;

  void _onDone([Object? error]) {
    if (error != null) {
      lastError = 'video: $error';
      debugPrint('download failed: $lastError');
    }
    if (error != null) {
      _noteFailure(error);
      // the entry has failed: stop the audio stream too (its bytes are kept
      // for the resume), instead of letting it download and retry on its own
      _audioDownloadManager?.cancel(isDelete: false);
      _updateCurStatus(_downloadManager?.status ?? DownloadStatus.pause);
      return;
    }
    curDownload.value?.progress.videoDone();

    final status = switch (_audioDownloadManager?.status) {
      DownloadStatus.downloading => DownloadStatus.audioDownloading,
      DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
      _ => _downloadManager?.status ?? DownloadStatus.pause,
    };
    _updateCurStatus(status);

    if (curDownload.value case final curEntryInfo?) {
      if (status == DownloadStatus.completed) {
        curEntryInfo.downloadedBytes = curEntryInfo.totalBytes;
        _completeDownload();
      } else {
        // audio still running / failed, or paused: the counters must keep
        // saying what is on disk, or the entry shows a full progress bar
        // after a restart although a stream is missing
        _saveEntry(curEntryInfo);
      }
    }
  }

  void _onAudioDone([Object? error]) {
    if (error != null) {
      lastError = 'audio: $error';
      debugPrint('download failed: $lastError');
      _noteFailure(error);
    }
    if (error == null) curDownload.value?.progress.audioDone();
    if (_downloadManager?.status == DownloadStatus.completed) {
      if (error == null) {
        _completeDownload();
      } else {
        final status = _audioDownloadManager?.status ?? DownloadStatus.pause;
        _updateCurStatus(
          status == DownloadStatus.failDownload
              ? DownloadStatus.failDownloadAudio
              : status,
        );
      }
    }
  }

  Future<void> _completeDownload() async {
    final entry = curDownload.value;
    // the video and audio callbacks can both get here: one merge per entry
    if (entry == null || _mergingKeys.contains(entry.key)) {
      return;
    }
    _downloadManager = null;
    _audioDownloadManager = null;
    entry.downloadedBytes = entry.totalBytes;
    final key = entry.key;
    _mergingKeys.add(key);
    _mergeDeletedKeys.remove(key);
    _updateCurStatus(DownloadStatus.merging);
    // its type is bilibili's
    if (entry is BiliDownloadEntryInfo) {
      if (selfTestBeforeMerge case final hook?) await hook(entry);
    }
    final (:output, :inputs, :damaged, :corrupt) = await platformOf(
      entry,
    ).merge(entry);
    _mergingKeys.remove(key);
    final pauseNext = _pauseAfterMergeKey == key;
    if (pauseNext) _pauseAfterMergeKey = null;
    if (!damaged && output != null) entry.progress.mergeDone();
    final deleted = _mergeDeletedKeys.remove(key);
    if (deleted || !Directory(entry.entryDirPath).existsSync()) {
      // deleted while merging (the merge may have kept files open, so the
      // delete may not have removed everything)
      await _deleteMerged(entry);
      await _savesDone(entry);
      await Directory(entry.entryDirPath).tryDel(recursive: true);
      waitDownloadQueue.remove(entry);
      if (curDownload.value == null && !pauseNext) nextDownload();
      return;
    }
    if (damaged) {
      // segments still damaged / missing: not complete. Stays in the queue
      // as failed; starting it again fetches a fresh play URL and merges
      // again.
      if (corrupt) {
        // LibrePili: dash bytes damaged at their full size (a bad transfer
        // left one in the user's queue that failed the same way on every
        // start, user 2026-10-23 1A): removed, so the start again downloads
        // them anew instead of merging the same bytes
        for (final input in inputs) {
          await File(input).tryDel();
          await File('$input.size').tryDel();
        }
        entry.downloadedBytes = 0;
        entry.progress.video(0, entry.totalBytes);
        EventLog.add('download', '${entry.logLabel}: damaged streams removed');
        // as [_retryLater] decides: once per start by the user
        (toastForTest ?? SmartDialog.showToast)(
          _away || _redownloaded.contains(key)
              ? '音视频文件再次损坏，已删除，可稍后重新开始该下载'
              : '音视频文件已损坏，将重新下载',
        );
      }
      await _saveEntry(entry);
      if (curDownload.value?.key == key) {
        _updateCurStatus(DownloadStatus.failMerge);
      }
      return;
    }
    // segments that had no common MP4 mapping were kept apart: record the
    // other parts, [mergedPath] alone plays only the first of them
    final parts = output == null ? const <String>[] : _exportedParts(output);
    // (completion is recorded before the stream files are removed, so a
    // crash here cannot turn the entry back into an incomplete one)
    entry
      ..mergedParts = parts.length > 1 ? parts.sublist(1) : null
      ..isCompleted = true
      // comments / subtitles etc. are saved after the video (see below)
      ..extrasPending = output != null;
    await _saveEntry(entry);
    if (output != null) {
      for (final input in inputs) {
        await File(input).tryDel();
      }
      if (Platform.isAndroid) {
        for (final part in parts) {
          await _scanMedia(part);
        }
      }
    }
    await _delStaleStreamDirs(entry);
    // still listed as downloading while its extras are saved (added before
    // it leaves the queue, so the list never shows it missing)
    if (output != null) {
      extrasQueue.add(entry..status = DownloadStatus.extrasWait);
    } else {
      entry.progress.complete();
    }
    waitDownloadQueue.remove(entry);
    // the download folder can change while a merge runs (the merge is left
    // to finish): the list was re-read from the new root, so an entry of the
    // old one must not join it — deleting it later would remove a folder
    // outside the configured root
    if (path.isWithin(downloadPath, entry.entryDirPath)) {
      downloadList.insert(0, entry);
    }
    flagNotifier.refresh();
    if (curDownload.value?.key == entry.key) {
      _curKey = null;
      curDownload.value = null;
      if (!pauseNext) nextDownload();
    }
    if (output != null) {
      // the transcript only needs the video file: it does not wait for the
      // extras either (its files and entry.json are written one at a time
      // with theirs)
      unawaited(transcripts.finished(entry));
      // comments / subtitles etc. can take many requests: do not hold the
      // queue for them
      _queueExtras(entry, output);
    }
  }

  /// Saves the extras of [entry] that an earlier run did not finish.
  void _resumeExtras(DownloadEntry entry) {
    if (_holdExtras) {
      _heldExtras.add(entry);
      return;
    }
    final merged = entry.mergedPath;
    if (_extrasJobs.containsKey(entry.key)) return;
    if (merged == null || !File(merged).existsSync()) {
      // the video was moved or deleted: nothing to save them next to
      _saveEntry(entry..extrasPending = false);
      return;
    }
    entry.progress
      ..planExtras(platformOf(entry).extrasPlan())
      ..video(1, 1)
      ..mergeDone();
    extrasQueue.add(entry..status = DownloadStatus.extrasWait);
    _queueExtras(entry, merged);
  }

  /// Removes the stream folders of qualities this entry no longer uses.
  /// They are kept while the download runs (a re-resolve to another quality
  /// must not throw away a nearly finished transfer, see [_startDownload]),
  /// so this runs once the entry is complete.
  static Future<void> _delStaleStreamDirs(DownloadEntry entry) async {
    final keep = entry.streamTypeTag;
    try {
      await for (final dir in Directory(entry.entryDirPath).list()) {
        if (dir is Directory && path.basename(dir.path) != keep) {
          await dir.tryDel(recursive: true);
        }
      }
    } catch (_) {}
  }

  /// Extras exports run one at a time (each can be hundreds of requests).
  Future<void> _extrasQueue = Future.value();

  /// Pending or running extras export per entry.
  final _extrasJobs = <DownloadKey, Future<void>>{};

  /// Entries whose export must stop (entry deleted).
  final _extrasCancelled = <DownloadKey>{};

  /// The entry whose export is running now.
  DownloadKey? _extrasRunningKey;

  /// The extras export of [key], if one is pending or running.
  Future<void>? extrasDone(DownloadKey key) => _extrasJobs[key];

  void _queueExtras(DownloadEntry entry, String output) {
    final key = entry.key;
    _extrasCancelled.remove(key);
    final job = _extrasQueue = _extrasQueue.then((_) async {
      if (_extrasCancelled.contains(key)) return;
      _extrasRunningKey = key;
      entry.status = DownloadStatus.savingExtras;
      extrasQueue.refresh();
      try {
        await platformOf(entry).extras(
          entry: entry,
          folder: path.dirname(output),
          base: path.basenameWithoutExtension(output),
          cancelled: () => _extrasCancelled.contains(key),
          progress: entry.progress,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('download extras: $e');
      } finally {
        _extrasRunningKey = null;
      }
      if (_extrasCancelled.contains(key)) return;
      entry
        ..extrasPending = false
        ..status = DownloadStatus.completed
        ..progress.complete();
      // its folder may be gone meanwhile (download folder changed and the
      // old one removed): nothing to record then
      if (Directory(entry.entryDirPath).existsSync()) {
        await _saveEntry(entry);
        // one merged by a version that marked it for its transcript only
        // here (the app closed while its extras were saved): marked now
        if (!entry.transcriptPending && transcripts.progress[key] == null) {
          unawaited(transcripts.finished(entry));
        }
      }
      extrasQueue.remove(entry);
      flagNotifier.refresh();
    });
    _extrasJobs[key] = job;
    job.whenComplete(() {
      if (identical(_extrasJobs[key], job)) {
        _extrasJobs.remove(key);
        _extrasCancelled.remove(key);
      }
    });
  }

  /// Stops the extras export of a deleted entry; a running one is awaited so
  /// it cannot write into (or recreate) a folder that is being removed.
  Future<void> _cancelExtras(DownloadKey key) async {
    await transcripts.forget(key);
    extrasQueue.removeWhere((e) => e.key == key);
    if (!_extrasJobs.containsKey(key)) return;
    _extrasCancelled.add(key);
    if (_extrasRunningKey == key) await _extrasJobs[key];
  }

  /// The entries being merged (a deleted entry's merge can overlap the next
  /// one's); pause/start requests for them are ignored.
  final _mergingKeys = <DownloadKey>{};

  /// Self test only: runs on the downloaded streams before they are merged
  /// (`--download-queue` damages them there, as a bad transfer would).
  /// Bilibili entries only.
  static Future<void> Function(BiliDownloadEntryInfo entry)?
  selfTestBeforeMerge;

  // Tests only: stand-ins for what a download reaches out to (null: the
  // real call). They let a test run the queue on a temporary folder with no
  // network, no transfer and no remux.

  /// In place of [DownloadHttp.getVideoUrl].
  @visibleForTesting
  static Future<BiliDownloadMediaInfo> Function({
    required BiliDownloadEntryInfo entry,
    SourceInfo? source,
    PageInfo? pageData,
    EpInfo? ep,
  })?
  getVideoUrlForTest;

  /// In place of the [DownloadManager] constructor (video, audio and each
  /// durl segment).
  @visibleForTesting
  static DownloadManager Function({
    required String url,
    List<String> backupUrls,
    required String path,
    required void Function(int, int)? onReceiveProgress,
    required void Function([Object? error]) onDone,
    int expectedTotal,
  })?
  newManagerForTest;

  /// In place of bilibili's merge, all of it: one that succeeds sets
  /// [BiliDownloadEntryInfo.mergedPath] itself, as that merge does.
  @visibleForTesting
  static Future<
    ({String? output, List<String> inputs, bool damaged, bool corrupt})
  >
  Function(BiliDownloadEntryInfo entry)?
  mergeForTest;

  /// In place of [DownloadExtras.export].
  @visibleForTesting
  static Future<Map<String, Object?>> Function({
    required BiliDownloadEntryInfo entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  })?
  exportExtrasForTest;

  /// In place of [SmartDialog.showToast].
  @visibleForTesting
  static void Function(String msg)? toastForTest;

  /// The entry being merged when the notification's 「暂停」 was tapped:
  /// the next download is not started after its merge.
  DownloadKey? _pauseAfterMergeKey;

  /// Entries deleted while they were being merged.
  final _mergeDeletedKeys = <DownloadKey>{};

  /// Segment re-downloads in flight, by cid. Kept apart from the queue's
  /// [_downloadManager]: the merge runs outside [_lock], so the queue may
  /// start another entry meanwhile and must neither cancel nor replace it.
  /// Deleting the entry cancels it.
  final _repairManagers = <int, DownloadManager>{};

  /// [output] and, when segments were kept apart, its other parts
  /// (`<base>.2.flv`, ...).
  static List<String> _exportedParts(String output) {
    final base = RegExp.escape(path.basenameWithoutExtension(output));
    final part = RegExp('^$base\\.\\d+\\.\\w+\$');
    return [
      output,
      for (final f in Directory(path.dirname(output)).listSync())
        if (f is File && part.hasMatch(path.basename(f.path))) f.path,
    ];
  }

  static const _mediaChannel = MethodChannel('librepili/media');

  /// Adds the file to the Android media library so galleries and video
  /// players list it (files written by path are not indexed automatically).
  static Future<void> _scanMedia(String path) async {
    try {
      await _mediaChannel.invokeMethod<String>('scanFile', {
        'path': path,
        'mimeType': path.endsWith('.flv')
            ? 'video/x-flv'
            : path.endsWith('.ts')
            ? 'video/mp2t'
            : path.endsWith('.bin')
            ? 'application/octet-stream'
            : 'video/mp4',
      });
    } catch (e) {
      if (kDebugMode) debugPrint('media scan failed: $e');
    }
  }

  /// Whether [file] lives in its own per-video folder (named like the file),
  /// as opposed to the older flat layout.
  static bool _isOwnFolder(String file) =>
      path.basename(path.dirname(file)) == path.basenameWithoutExtension(file);

  Future<void> _deleteMerged(DownloadEntry entry) async {
    if (entry.mergedPath case final merged?) {
      if (_isOwnFolder(merged)) {
        final folder = Directory(path.dirname(merged));
        final contents = folder.existsSync()
            ? folder.listSync()
            : const <FileSystemEntity>[];
        bool isDownload(FileSystemEntity e) =>
            e is Directory && File(path.join(e.path, _entryFile)).existsSync();
        if (contents.any(isDownload)) {
          // also a page folder holding downloads (made before exports
          // avoided internal names): remove only the export's own files
          for (final e in contents) {
            if (!isDownload(e)) await e.tryDel(recursive: true);
          }
        } else {
          await folder.tryDel(recursive: true);
        }
      } else {
        await File(merged).tryDel();
      }
    }
  }

  /// Where complete videos are written. Android: the public
  /// `Download/<app name>` folder so galleries and file managers see them;
  /// elsewhere: the (user-configurable) download folder.
  static Future<String> _exportDir() async {
    // the self test exports into its own download folder
    if (Platform.isAndroid && !isSelfTestProfile) {
      // downloadPath is `<storage root>/Android/data/<package>/files/download`
      final i = downloadPath.indexOf('/Android/data/');
      if (i != -1 &&
          (DeviceUtils.sdkInt >= 30 ||
              await Permission.storage.request().isGranted)) {
        final dir = Directory(
          path.join(
            downloadPath.substring(0, i),
            'Download',
            Constants.appName,
          ),
        );
        try {
          await dir.create(recursive: true);
          return dir.path;
        } catch (e) {
          if (kDebugMode) debugPrint('public download dir error: $e');
        }
      }
    }
    return _getDownloadPath();
  }

  /// [_exportDir] and [_scanMedia] for the YouTube downloader: its files go
  /// where these do, not into the app-private folder on Android.
  static Future<String> exportDir() => _exportDir();
  static Future<void> scanMedia(String path) => _scanMedia(path);

  static final _illegalFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]');

  /// Export folders a merge is currently writing into.
  static final _mergeFolders = <String>{};

  /// Names of the internal page folders in the download root: `<avid>` and
  /// `s_<seasonId>` (case-insensitive: Windows folder names are).
  static final _internalPageName = RegExp(r'^(s_)?\d+$', caseSensitive: false);

  /// On desktop exports share the download root with the internal page
  /// folders, so an export named like one (a title such as "114514") would
  /// be the same directory as that video's download. Such names get a
  /// suffix; no internal folder is ever named like the result.
  @visibleForTesting
  static String exportFolderName(String name) =>
      _internalPageName.hasMatch(name) ? '$name (视频)' : name;

  /// Internal page folders hold only entry folders; a folder with files at
  /// its top level is an export (or the user's own) that happens to carry
  /// the page folder's name.
  static bool _isForeignFolder(Directory dir) => dir.listSync().any(
    (e) => e is File && !_isOsClutter(path.basename(e.path)),
  );

  /// Whether [dir] is an export of this app (not just a folder with files
  /// that happens to be named like an avid / season, which may be the
  /// user's own): it holds `<its name>.<ext>`, the video, or the download
  /// record ([DownloadExtras.infoName]).
  static bool _isOldExport(Directory dir) {
    final name = path.basename(dir.path);
    return dir.listSync().any((e) {
      if (e is! File) return false;
      final file = path.basename(e.path);
      return file == DownloadExtras.infoName ||
          path.basenameWithoutExtension(file) == name;
    });
  }

  /// Files the OS / file managers drop into folders on their own.
  static bool _isOsClutter(String name) {
    final lower = name.toLowerCase();
    return name.startsWith('.') || // .DS_Store, ._*, .nomedia ...
        lower == 'desktop.ini' ||
        lower == 'thumbs.db' ||
        lower == 'ehthumbs.db';
  }

  Future<String> _exportFilePath(DownloadEntry entry) async {
    final dir = await _exportDir();
    final name = _exportName(platformOf(entry).exportName(entry));
    // one folder per video: the mp4 plus danmaku / subtitles / comments
    // a folder holding only a half-written `.part` (app killed mid-merge) is
    // left over from an earlier attempt: reuse it instead of orphaning it
    // (not one another merge is writing into right now)
    bool isLeftover(Directory d) =>
        !_mergeFolders.contains(d.path) &&
        d.listSync().every((e) => e is File && e.path.endsWith('.part'));
    var base = name;
    for (
      var i = 2;
      Directory(path.join(dir, base)).existsSync() &&
          !isLeftover(Directory(path.join(dir, base)));
      i++
    ) {
      base = '$name ($i)';
    }
    final folder = Directory(path.join(dir, base));
    // claimed before the first await, so an overlapping merge with the same
    // name cannot pick (and write into) the same folder
    _mergeFolders.add(folder.path);
    try {
      if (folder.existsSync()) {
        for (final part in folder.listSync()) {
          await File(part.path).tryDel();
        }
      }
      await folder.create(recursive: true);
    } catch (_) {
      _mergeFolders.remove(folder.path);
      rethrow;
    }
    return path.join(folder.path, '$base.mp4');
  }

  @visibleForTesting
  static String exportNameForTest(BiliDownloadEntryInfo entry) =>
      _exportName(_BiliPlatform._exportNameOf(entry));

  /// The export's folder and file name (without the extension, and before
  /// a ` (n)` that keeps it apart from another), from the platform's title
  /// part and quality ([DownloadPlatform.exportName]).
  static String _exportName(({String name, String suffix}) parts) {
    var name = parts.name
        .replaceAll(_illegalFileChars, '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // cut by code point (never half an emoji); the name is used twice in
    // the path (folder and file), so keep it short for Windows' 260 limit
    if (name.runes.length > 80) {
      name = String.fromCharCodes(name.runes.take(80)).trim();
    }
    if (parts.suffix.isNotEmpty) {
      name += ' [${parts.suffix.replaceAll(_illegalFileChars, '_')}]';
    }
    return exportFolderName(name);
  }

  void nextDownload() {
    // LibrePili: past the failed ones (user 2026-10-23 2A): they already had
    // their retries, and one whose streams are damaged failed again on every
    // start — after each other download completed. They wait for the user.
    final next = waitDownloadQueue.firstWhereOrNull(
      (e) => !e.status.isFailed && e.key != curDownload.value?.key,
    );
    if (next != null) startDownload(next);
  }

  Future<void> deleteDownload({
    required DownloadEntry entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
    // the exported video folder is the user's own copy: kept unless asked
    bool deleteExported = false,
  }) async {
    _releaseExtras();
    if (removeList) {
      downloadList.remove(entry);
    }
    if (removeQueue) {
      waitDownloadQueue.remove(entry);
    }
    if (_mergingKeys.contains(entry.key)) {
      _mergeDeletedKeys.add(entry.key);
    }
    // bilibili's segment repair
    if (entry is BiliDownloadEntryInfo) {
      await _repairManagers[entry.cid]?.cancel(isDelete: true);
    }
    if (curDownload.value?.key == entry.key) {
      await cancelDownload(
        isDelete: true,
        downloadNext: downloadNext,
      );
    }
    await _cancelExtras(entry.key);
    if (deleteExported) await _deleteMerged(entry);
    await _savesDone(entry);
    final downloadDir = Directory(entry.pageDirPath);
    // the download folder may have changed since this entry was listed: a
    // path outside the configured root is not ours to remove
    if (downloadDir.existsSync() &&
        path.isWithin(downloadPath, entry.entryDirPath)) {
      // a page folder that is also an export folder (made before exports
      // avoided internal names) keeps the export's files
      if (!await downloadDir.lengthGte(2) && !_isForeignFolder(downloadDir)) {
        await downloadDir.tryDel(recursive: true);
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
        }
      }
    }
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
    bool deleteExported = false,
  }) async {
    _releaseExtras();
    // pages of one video share the folder: a page still downloading or
    // merging must be stopped first, or it recreates what is deleted here
    for (final entry in [...downloadList, ...waitDownloadQueue]) {
      if (entry.pageDirPath != pageDirPath) continue;
      if (_mergingKeys.contains(entry.key)) {
        _mergeDeletedKeys.add(entry.key);
      }
      if (entry is BiliDownloadEntryInfo) {
        await _repairManagers[entry.cid]?.cancel(isDelete: true);
      }
      if (curDownload.value?.key == entry.key) {
        await cancelDownload(isDelete: true, downloadNext: false);
      }
      await _cancelExtras(entry.key);
      if (deleteExported) await _deleteMerged(entry);
      await _savesDone(entry);
    }
    waitDownloadQueue.removeWhere((e) => e.pageDirPath == pageDirPath);
    final pageDir = Directory(pageDirPath);
    // as in [deleteDownload]: never remove a folder outside the configured
    // download root (the root can change while this page is listed)
    if (path.isWithin(downloadPath, pageDirPath)) {
      if (pageDir.existsSync() && _isForeignFolder(pageDir)) {
        // also an export folder: remove only the downloads inside it
        for (final e in pageDir.listSync()) {
          if (e is Directory &&
              File(path.join(e.path, _entryFile)).existsSync()) {
            await e.tryDel(recursive: true);
          }
        }
      } else {
        await pageDir.tryDel(recursive: true);
      }
    }
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    if (curDownload.value == null) nextDownload();
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> cancelDownload({
    required bool isDelete,
    bool downloadNext = true,
  }) async {
    // nothing to pause while merging; the merge completes the entry
    if (!isDelete && _mergingKeys.contains(curDownload.value?.key)) {
      return;
    }
    _startGen++;
    await _downloadManager?.cancel(isDelete: isDelete);
    await _audioDownloadManager?.cancel(isDelete: isDelete);
    _downloadManager = null;
    _audioDownloadManager = null;
    if (!isDelete) {
      final entry = curDownload.value;
      if (entry != null) {
        await _saveEntry(entry);
      }
    }
    if (isDelete) {
      _curKey = null;
      curDownload.value = null;
    } else {
      _updateCurStatus(DownloadStatus.pause);
    }
    if (downloadNext) {
      nextDownload();
    }
  }
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
