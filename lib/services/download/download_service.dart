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
import 'package:PiliPlus/services/download/download_transcripts.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService with WidgetsBindingObserver {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  static const _maxDanmakuConcurrency = 4;

  /// Stream folder of [entry]. [BiliDownloadEntryInfo.typeTag] is nullable
  /// (an `entry.json` written by another client may have no `type_tag`) and
  /// `path.join` drops a null part, so joining it directly would give the
  /// entry folder itself — which is deleted recursively below.
  static String _streamDirPath(BiliDownloadEntryInfo entry) =>
      path.join(entry.entryDirPath, entry.streamTypeTag);

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  /// Entries whose video is complete (they are in [downloadList] too) while
  /// their extras — comments, subtitles, ... — are still being saved: they
  /// are listed as downloading until then.
  final extrasQueue = RxList<BiliDownloadEntryInfo>();

  bool isSavingExtras(BiliDownloadEntryInfo entry) =>
      extrasQueue.any((e) => e.cid == entry.cid);

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value case final entry?) {
      entry.status = status;
      curDownload.refresh();
      entry.progress.statusChanged();
    }
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
  final _heldExtras = <BiliDownloadEntryInfo>[];
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
    save: _updateBiliDownloadEntryJson,
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
      if (entry != null && _mergingCids.contains(entry.cid)) {
        _pauseAfterMergeCid = entry.cid;
      } else if (entry?.status.isDownloading ?? false) {
        cancelDownload(isDelete: false, downloadNext: false);
      }
    },
  );
  var _keepAliveWorkers = <Worker>[];

  /// The app is off screen (Android): a job cannot be had then, and a
  /// download the network failed meanwhile is started again on the return.
  bool _away = false;

  /// cids of downloads that failed for the network while [_away].
  final _failedAway = <int>{};

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
      final more = waitDownloadQueue.where((e) => e.cid != entry.cid).length;
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
    // the play URL's request gives no error to tell the network by
    if (!playUrl && !DownloadManager.isNetworkFailure(error)) return;
    if (curDownload.value case final entry?) _failedAway.add(entry.cid);
  }

  void _resumeFailedAway() {
    if (_failedAway.isEmpty) return;
    final cids = {..._failedAway};
    _failedAway.clear();
    // started meanwhile (the user's tap, a notification)
    if (curDownload.value?.status.isDownloading ?? false) return;
    for (final entry in waitDownloadQueue) {
      if (cids.contains(entry.cid) &&
          const {
            DownloadStatus.failDownload,
            DownloadStatus.failDownloadAudio,
            DownloadStatus.failPlayUrl,
          }.contains(entry.status)) {
        EventLog.add(
          'download',
          '${entry.cid}: failed off screen (${entry.status.name}), '
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
    if (!id.startsWith('bili:')) return;
    final cid = int.tryParse(id.substring(5));
    if (cid == null) return;
    for (final download in downloadList) {
      if (download.cid != cid || !download.isCompleted) continue;
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
      if (!_mergingCids.contains(_curCid)) {
        _curCid = null;
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
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

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
              final entry =
                  BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
                    ..pageDirPath = pageDir.path
                    ..entryDirPath = entryDir.path;
              // [cid] reads one of the two: without either the
              // entry throws later, wherever the list is used
              if (entry.source == null && entry.pageData == null) {
                throw const FormatException('neither source nor page_data');
              }
              if (entry.isCompleted) {
                result.add(entry);
                // the app closed while they were being saved
                if (entry.extrasPending) _resumeExtras(entry);
              } else {
                entry.progress
                  ..planExtras(DownloadExtras.plan())
                  ..video(entry.downloadedBytes, entry.totalBytes);
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
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
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
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
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
            await _updateBiliDownloadEntryJson(e);
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

  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    _releaseExtras();
    // already finished downloading; the merge completes it
    if (_mergingCids.contains(entry.cid)) return Future.value();
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

      _curCid = entry.cid;
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
        if (kDebugMode) SmartDialog.showToast(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<bool> _downloadCover({
    required BiliDownloadEntryInfo entry,
  }) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      // over https also for entries saved with an http cover
      final cover = entry.cover.http2https;
      final file = (await CacheManager.manager.getFileFromCache(
        cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startDownload(BiliDownloadEntryInfo entry, int gen) async {
    entry.progress
      ..restart()
      ..planExtras(DownloadExtras.plan())
      // until the play URL tells: about 2 Mbps
      ..mediaGuess = entry.totalTimeMilli * 250
      ..video(entry.downloadedBytes, entry.totalBytes);
    try {
      // danmaku is optional: a failed fetch must not block the video (it
      // can be fetched again later with "update danmaku")
      await downloadDanmaku(entry: entry);
      if (gen != _startGen) return;

      _updateCurStatus(DownloadStatus.getPlayUrl);

      final oldTypeTag = entry.typeTag;
      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );
      if (gen != _startGen) return;

      // the stream is picked again on every start (codec / login / quality
      // settings may have changed). Each quality has its own folder, so the
      // new one never resumes the old one's bytes; the old folder is kept
      // until this download completes ([_delStaleStreamDirs]) instead of
      // being dropped here — leaving login mode re-resolves to a lower
      // quality and that used to throw away a nearly finished transfer
      if (oldTypeTag != null &&
          oldTypeTag.isNotEmpty &&
          oldTypeTag != entry.typeTag) {
        debugPrint('download stream changed: $oldTypeTag -> ${entry.typeTag}');
      }
      final videoDir = Directory(_streamDirPath(entry));
      final mediaJsonFile = File(path.join(videoDir.path, _indexFile));
      if (videoDir.existsSync()) {
        String? oldKey;
        try {
          oldKey = _streamKey(jsonDecode(await mediaJsonFile.readAsString()));
        } catch (_) {}
        // an unreadable / missing index.json says nothing about the bytes on
        // disk: they are kept and re-verified by the resume's `Content-Range`
        // total ([DownloadManager.expectedTotal]) instead of being dropped
        if (oldKey != null && oldKey != _streamKey(mediaFileInfo.toJson())) {
          await videoDir.tryDel(recursive: true);
        }
      }
      if (gen != _startGen) return;
      if (!videoDir.existsSync()) {
        await videoDir.create(recursive: true);
      }

      await Future.wait([
        _writeIndexJson(mediaJsonFile, mediaFileInfo),
        _downloadCover(entry: entry),
      ]);

      if (gen != _startGen) {
        // deleted meanwhile: what was written here (the cover's download
        // creates its folder) would be left behind as an orphan
        if (!File(path.join(entry.entryDirPath, _entryFile)).existsSync()) {
          await Directory(entry.entryDirPath).tryDel(recursive: true);
        }
        return;
      }
      if (curDownload.value?.cid != entry.cid) {
        return;
      }

      entry.progress.mediaGuess = switch (mediaFileInfo) {
        Type1(:final segmentList) => segmentList.fold(0, (s, e) => s + e.bytes),
        // bits per second over the duration (dash: seconds)
        Type2(:final duration, :final video, :final audio) =>
          (video.first.bandwidth + (audio?.firstOrNull?.bandwidth ?? 0)) *
              duration ~/
              8,
        _ => entry.progress.mediaGuess,
      };
      entry.progress.expectAudio =
          mediaFileInfo is Type2 && (mediaFileInfo.audio?.isNotEmpty ?? false);

      switch (mediaFileInfo) {
        case Type1 mediaFileInfo:
          _startSegment(mediaFileInfo.segmentList, 0, videoDir.path);
          break;
        case Type2 mediaFileInfo:
          _downloadManager = DownloadManager(
            url: mediaFileInfo.video.first.baseUrl,
            backupUrls: mediaFileInfo.video.first.backupUrl ?? const [],
            path: path.join(videoDir.path, PathUtils.videoNameType2),
            onReceiveProgress: _onReceive,
            onDone: _onDone,
            // the size the saved partial was written for ([_streamKey] only
            // compares id / codec / resolution). The manager's own record
            // beside the file wins; this is for partials saved before it,
            // and only while the entry's size is this quality's: after
            // another quality ran it is that one's
            expectedTotal: oldTypeTag == entry.typeTag ? entry.totalBytes : 0,
          );
          final audio = mediaFileInfo.audio;
          if (audio != null && audio.isNotEmpty) {
            _audioDownloadManager = DownloadManager(
              url: audio.first.baseUrl,
              backupUrls: audio.first.backupUrl ?? const [],
              path: path.join(videoDir.path, PathUtils.audioNameType2),
              onReceiveProgress: _onAudioReceive,
              onDone: _onAudioDone,
            );
          }
          late final first = mediaFileInfo.video.first;
          entry.pageData
            ?..width = first.width
            ..height = first.height;
          entry.ep
            ?..width = first.width
            ..height = first.height;
          _updateBiliDownloadEntryJson(entry);
          break;
        default:
          break;
      }
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

  /// What identifies the bytes of a saved stream ([_indexFile] json): the
  /// dash video / audio stream picked (id / codec / resolution — its size
  /// is still 0 when this runs, so a stream of the same id and codec but
  /// another length is caught when a resume compares the `Content-Range`
  /// total, see [DownloadManager.expectedTotal]), or the durl segment sizes.
  static String? _streamKey(Object? json) {
    if (json is! Map) return null;
    String file(Object? list) {
      if (list is! List || list.isEmpty || list.first is! Map) return '';
      final f = list.first as Map;
      return '${f['id']}/${f['codecid']}/${f['width']}x${f['height']}';
    }

    if (json['video'] != null) {
      return 'dash:${file(json['video'])}:${file(json['audio'])}';
    }
    if (json['segment_list'] case final List segments) {
      return 'durl:${segments.map((e) => e is Map ? e['bytes'] : null).join(',')}';
    }
    return null;
  }

  /// Old single-URL (durl) streams may come in several segments: they are
  /// downloaded one after another (resuming what is on disk) and joined by
  /// [_mergeDownload]. Progress runs over their total size.
  void _startSegment(List<Type1Segment> segments, int index, String dir) {
    final total = segments.fold<int>(0, (s, e) => s + e.bytes);
    final done = segments.take(index).fold<int>(0, (s, e) => s + e.bytes);
    final segment = segments[index];
    late final DownloadManager manager;
    manager = DownloadManager(
      url: segment.url,
      backupUrls: segment.backupUrls,
      path: path.join(dir, PathUtils.segmentNameType1(index)),
      expectedTotal: segment.bytes,
      onReceiveProgress: segments.length == 1 || total <= 0
          ? _onReceive
          : (received, _) => _onReceive(done + received, total),
      onDone: ([error]) {
        if (error != null || index + 1 == segments.length) {
          return _onDone(error);
        }
        // paused / deleted / replaced meanwhile
        if (!identical(_downloadManager, manager)) return;
        _startSegment(segments, index + 1, dir);
      },
    );
    _downloadManager = manager;
  }

  /// Writes `index.json` through `<file>.tmp` + rename: it is rewritten on
  /// every start, and a torn one used to make the resume look like another
  /// stream — throwing away the bytes already on disk.
  static Future<void> _writeIndexJson(
    File file,
    BiliDownloadMediaInfo mediaFileInfo,
  ) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(mediaFileInfo.toJson()), flush: true);
    await tmp.rename(file.path);
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
  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) {
    final dir = entry.entryDirPath;
    final save = (_entrySaves[dir] ?? Future<void>.value()).then(
      (_) => _writeEntryJson(entry),
    );
    // a failed save must not stall the ones behind it
    final chained = _entrySaves[dir] = save.catchError((_) {});
    chained.whenComplete(() {
      if (identical(_entrySaves[dir], chained)) _entrySaves.remove(dir);
    });
    return save;
  }

  /// Writes `entry.json` through `<file>.tmp` + rename: this runs on every
  /// size change and at the completion point, so a truncated file would
  /// hide the whole (possibly finished) download from the list. Only called
  /// from [_updateBiliDownloadEntryJson], which keeps the writes apart.
  static Future<void> _writeEntryJson(BiliDownloadEntryInfo entry) async {
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    final tmp = File('${entryJsonFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(entry.toJson()), flush: true);
    await tmp.rename(entryJsonFile.path);
  }

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      // the size is known from the response headers, also when the transfer
      // resumed at an offset; an unknown size (-1) is never recorded
      if (total > 0 && entry.totalBytes != total) {
        _updateBiliDownloadEntryJson(entry..totalBytes = total);
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
        _updateBiliDownloadEntryJson(curEntryInfo);
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
    if (entry == null || _mergingCids.contains(entry.cid)) {
      return;
    }
    _downloadManager = null;
    _audioDownloadManager = null;
    entry.downloadedBytes = entry.totalBytes;
    final cid = entry.cid;
    _mergingCids.add(cid);
    _mergeDeletedCids.remove(cid);
    _updateCurStatus(DownloadStatus.merging);
    final (:output, :inputs, :damaged) = await _mergeDownload(entry);
    _mergingCids.remove(cid);
    final pauseNext = _pauseAfterMergeCid == cid;
    if (pauseNext) _pauseAfterMergeCid = null;
    if (!damaged && output != null) entry.progress.mergeDone();
    final deleted = _mergeDeletedCids.remove(cid);
    if (deleted || !Directory(entry.entryDirPath).existsSync()) {
      // deleted while merging (the merge may have kept files open, so the
      // delete may not have removed everything)
      await _deleteMerged(entry);
      await Directory(entry.entryDirPath).tryDel(recursive: true);
      waitDownloadQueue.remove(entry);
      if (curDownload.value == null && !pauseNext) nextDownload();
      return;
    }
    if (damaged) {
      // segments still damaged / missing: not complete. Stays in the queue
      // as failed (like a failed transfer, the queue waits for the user);
      // starting it again fetches a fresh play URL and merges again.
      if (curDownload.value?.cid == cid) {
        _updateCurStatus(DownloadStatus.failMerge);
      }
      await _updateBiliDownloadEntryJson(entry);
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
    await _updateBiliDownloadEntryJson(entry);
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
    if (curDownload.value?.cid == entry.cid) {
      _curCid = null;
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
  void _resumeExtras(BiliDownloadEntryInfo entry) {
    if (_holdExtras) {
      _heldExtras.add(entry);
      return;
    }
    final merged = entry.mergedPath;
    if (_extrasJobs.containsKey(entry.cid)) return;
    if (merged == null || !File(merged).existsSync()) {
      // the video was moved or deleted: nothing to save them next to
      _updateBiliDownloadEntryJson(entry..extrasPending = false);
      return;
    }
    entry.progress
      ..planExtras(DownloadExtras.plan())
      ..video(1, 1)
      ..mergeDone();
    extrasQueue.add(entry..status = DownloadStatus.extrasWait);
    _queueExtras(entry, merged);
  }

  /// Removes the stream folders of qualities this entry no longer uses.
  /// They are kept while the download runs (a re-resolve to another quality
  /// must not throw away a nearly finished transfer, see [_startDownload]),
  /// so this runs once the entry is complete.
  static Future<void> _delStaleStreamDirs(BiliDownloadEntryInfo entry) async {
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

  /// Pending or running extras export per cid.
  final _extrasJobs = <int, Future<void>>{};

  /// cids whose export must stop (entry deleted).
  final _extrasCancelled = <int>{};

  /// cid whose export is running now.
  int? _extrasRunningCid;

  /// The extras export of [cid], if one is pending or running.
  Future<void>? extrasDone(int cid) => _extrasJobs[cid];

  void _queueExtras(BiliDownloadEntryInfo entry, String output) {
    final cid = entry.cid;
    _extrasCancelled.remove(cid);
    final job = _extrasQueue = _extrasQueue.then((_) async {
      if (_extrasCancelled.contains(cid)) return;
      _extrasRunningCid = cid;
      entry.status = DownloadStatus.savingExtras;
      extrasQueue.refresh();
      try {
        await DownloadExtras.export(
          entry: entry,
          folder: path.dirname(output),
          base: path.basenameWithoutExtension(output),
          cancelled: () => _extrasCancelled.contains(cid),
          progress: entry.progress,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('download extras: $e');
      } finally {
        _extrasRunningCid = null;
      }
      if (_extrasCancelled.contains(cid)) return;
      entry
        ..extrasPending = false
        ..status = DownloadStatus.completed
        ..progress.complete();
      // its folder may be gone meanwhile (download folder changed and the
      // old one removed): nothing to record then
      if (Directory(entry.entryDirPath).existsSync()) {
        await _updateBiliDownloadEntryJson(entry);
        // one merged by a version that marked it for its transcript only
        // here (the app closed while its extras were saved): marked now
        if (!entry.transcriptPending && transcripts.progress[cid] == null) {
          unawaited(transcripts.finished(entry));
        }
      }
      extrasQueue.remove(entry);
      flagNotifier.refresh();
    });
    _extrasJobs[cid] = job;
    job.whenComplete(() {
      if (identical(_extrasJobs[cid], job)) {
        _extrasJobs.remove(cid);
        _extrasCancelled.remove(cid);
      }
    });
  }

  /// Stops the extras export of a deleted entry; a running one is awaited so
  /// it cannot write into (or recreate) a folder that is being removed.
  Future<void> _cancelExtras(int cid) async {
    await transcripts.forget(cid);
    extrasQueue.removeWhere((e) => e.cid == cid);
    if (!_extrasJobs.containsKey(cid)) return;
    _extrasCancelled.add(cid);
    if (_extrasRunningCid == cid) await _extrasJobs[cid];
  }

  /// cids of the entries being merged (a deleted entry's merge can overlap
  /// the next one's); pause/start requests for them are ignored.
  final _mergingCids = <int>{};

  /// cid of the entry being merged when the notification's 「暂停」 was
  /// tapped: the next download is not started after its merge.
  int? _pauseAfterMergeCid;

  /// cids of entries deleted while they were being merged.
  final _mergeDeletedCids = <int>{};

  /// Turns the downloaded streams into one complete video file in the export
  /// directory. Returns the file (null on failure) and the stream files the
  /// caller removes once completion is saved. On failure the stream files
  /// are kept, so the entry still plays in-app as before. [damaged]: durl
  /// segments are damaged / missing even after re-downloading, so the
  /// entry must not be treated as complete.
  Future<({String? output, List<String> inputs, bool damaged})> _mergeDownload(
    BiliDownloadEntryInfo entry,
  ) async {
    final videoDir = _streamDirPath(entry);
    final List<String> inputs;
    // durl segments of the play URL this download used (for re-downloading
    // a damaged one); segments on disk beyond them are left over from an
    // earlier attempt
    List<Type1Segment>? segments;
    if (entry.mediaType == 1) {
      int? count;
      try {
        final index = File(path.join(videoDir, _indexFile));
        final list =
            jsonDecode(await index.readAsString())['segment_list'] as List;
        count = list.length;
        segments = [
          for (final e in list)
            Type1Segment.fromJson(e as Map<String, dynamic>),
        ];
      } catch (_) {}
      inputs = [
        for (
          var i = 0;
          // known segments: all of them (a missing one is re-downloaded)
          count != null
              ? i < count
              : File(
                  path.join(videoDir, PathUtils.segmentNameType1(i)),
                ).existsSync();
          i++
        )
          path.join(videoDir, PathUtils.segmentNameType1(i)),
      ];
      if (count != null) {
        for (
          var i = count;
          File(path.join(videoDir, PathUtils.segmentNameType1(i))).existsSync();
          i++
        ) {
          await File(path.join(videoDir, PathUtils.segmentNameType1(i)))
              .tryDel();
        }
      }
      if (inputs.isEmpty) {
        inputs.add(path.join(videoDir, PathUtils.videoNameType1));
      }
    } else {
      final audio = path.join(videoDir, PathUtils.audioNameType2);
      inputs = [
        path.join(videoDir, PathUtils.videoNameType2),
        if (entry.hasDashAudio && File(audio).existsSync()) audio,
      ];
    }
    String? output;
    try {
      output = await _exportFilePath(entry);
      if (entry.mediaType == 1) {
        // a damaged segment is a download problem, not a reason to keep the
        // parts apart: fetch it again (bounded) before joining
        if (segments != null) {
          await _repairSegments(entry.cid, inputs, segments);
        }
        output = await _exportType1(inputs, output);
      } else {
        await _remuxInBackground(inputs, output);
      }
      entry.mergedPath = output;
      return (output: output, inputs: inputs, damaged: false);
    } catch (e) {
      if (output != null) {
        await File(output).tryDel();
        final folder = Directory(path.dirname(output));
        if (_isOwnFolder(output) && folder.listSync().isEmpty) {
          await folder.tryDel();
        }
      }
      // damaged bytes ([FormatException] / [RangeError] out of the remuxers)
      // or a missing / unreadable stream file ([FileSystemException]): the
      // entry is not complete whatever its mediaType is, it stays in the
      // queue so starting it again re-downloads and merges it
      final damaged =
          e is FormatException || e is RangeError || e is FileSystemException;
      entry.status = DownloadStatus.failMerge;
      SmartDialog.showToast(
        damaged
            ? (entry.mediaType == 1
                  ? '视频分段已损坏且重新下载失败，可稍后重新开始该下载'
                  : '音视频文件已损坏或丢失，可稍后重新开始该下载')
            : '合并音视频失败，已保留分离的音视频文件',
      );
      if (kDebugMode) debugPrint('merge download error: $e');
      return (output: null, inputs: inputs, damaged: damaged);
    } finally {
      if (output != null) _mergeFolders.remove(path.dirname(output));
    }
  }

  static const _maxSegmentRepairs = 2;

  /// Checks every durl segment (size against the play URL's byte count,
  /// structure via [Mp4Remuxer.checkSegment]) and downloads damaged or
  /// missing ones again, up to [_maxSegmentRepairs] rounds; throws
  /// [FormatException] if segments are still damaged after that.
  Future<void> _repairSegments(
    int cid,
    List<String> inputs,
    List<Type1Segment> segments,
  ) async {
    for (var round = 0; ; round++) {
      final bad = <int>[];
      final short = <int>{};
      for (var i = 0; i < inputs.length && i < segments.length; i++) {
        final file = File(inputs[i]);
        final expected = segments[i].bytes;
        final input = inputs[i];
        if (!file.existsSync() ||
            (expected > 0 && file.lengthSync() < expected)) {
          // missing, or the transfer stopped early: resume what is there
          bad.add(i);
          short.add(i);
        } else if (!await Isolate.run(() => Mp4Remuxer.checkSegment(input))) {
          bad.add(i);
        }
      }
      if (bad.isEmpty) return;
      if (round >= _maxSegmentRepairs) {
        throw FormatException('damaged segments after re-download: $bad');
      }
      if (kDebugMode) debugPrint('re-downloading damaged segments $bad');
      for (final i in bad) {
        await _redownloadSegment(
          cid,
          segments[i],
          inputs[i],
          resume: short.contains(i),
        );
      }
    }
  }

  /// Segment re-downloads in flight, by cid. Kept apart from the queue's
  /// [_downloadManager]: the merge runs outside [_lock], so the queue may
  /// start another entry meanwhile and must neither cancel nor replace it.
  /// Deleting the entry cancels it.
  final _repairManagers = <int, DownloadManager>{};

  /// Fetches [segment] again. [resume]: the file is only short, so the
  /// transfer continues in place (bytes are only appended). Otherwise a
  /// fresh copy goes to `<file>.redl` and replaces [file] only once it is
  /// complete: a failed re-download never loses the bytes that were there.
  Future<void> _redownloadSegment(
    int cid,
    Type1Segment segment,
    String file, {
    required bool resume,
  }) async {
    final target = resume ? file : '$file.redl';
    if (!resume) await File(target).tryDel();
    final done = Completer<Object?>();
    final manager = DownloadManager(
      url: segment.url,
      backupUrls: segment.backupUrls,
      path: target,
      expectedTotal: segment.bytes,
      onReceiveProgress: null,
      onDone: ([error]) {
        if (!done.isCompleted) done.complete(error);
      },
    );
    _repairManagers[cid] = manager;
    try {
      final error = await done.future;
      if (error != null) throw FormatException('segment re-download: $error');
      if (!resume) {
        // over the old copy (rename replaces it): deleting it first would
        // lose both should the rename fail
        await File(target).rename(file);
      }
    } finally {
      if (identical(_repairManagers[cid], manager)) _repairManagers.remove(cid);
      if (!resume) await File(target).tryDel();
    }
  }

  /// Old single-URL (durl) streams. FLV (H.264 / HEVC + AAC) is remuxed into
  /// a real mp4 and MP4 segments are joined, all segments in timeline order,
  /// also when the codec configuration changes between or within segments;
  /// a single mp4 segment is copied as is. Damaged data ([FormatException])
  /// is rethrown: [_repairSegments] has already re-downloaded what it could,
  /// so the merge fails rather than splitting the video. Only what has no
  /// MP4 mapping here ([UnsupportedError]: other codecs, a codec or the set
  /// of tracks changing between segments, FLV and MP4 segments mixed) is
  /// kept with its own extension (several segments: `<base>.flv`,
  /// `<base>.2.flv`, ...). Returns the (first) exported file.
  static Future<String> _exportType1(List<String> inputs, String output) async {
    final allFlv = inputs.every(Mp4Remuxer.isFlv);
    if (!allFlv && inputs.length == 1) {
      final kept = '${path.withoutExtension(output)}${_sniffExt(inputs.first)}';
      await _copyFile(inputs.first, kept);
      return kept;
    }
    if (allFlv || inputs.every(Mp4Remuxer.isMp4)) {
      try {
        await Isolate.run(
          () => allFlv
              ? Mp4Remuxer.remuxFlv(inputs: inputs, output: output)
              : Mp4Remuxer.joinMp4(inputs: inputs, output: output),
        );
        return output;
      } on UnsupportedError catch (e) {
        await File(output).tryDel();
        if (kDebugMode) debugPrint('segments kept as they are: $e');
      }
    }
    final base = path.withoutExtension(output);
    final copied = <String>[];
    try {
      for (var i = 0; i < inputs.length; i++) {
        final ext = _sniffExt(inputs[i]);
        final to = i == 0 ? '$base$ext' : '$base.${i + 1}$ext';
        await _copyFile(inputs[i], to);
        copied.add(to);
      }
    } catch (_) {
      // none of them is the export until all are there
      for (final f in copied) {
        await File(f).tryDel();
      }
      rethrow;
    }
    final first = copied.first;
    if (inputs.length > 1) {
      SmartDialog.showToast('分段无法合并，已按原格式分为${inputs.length}个文件保存');
    }
    return first;
  }

  /// Extension for stream data kept as it is, from its content.
  static String _sniffExt(String file) {
    if (Mp4Remuxer.isFlv(file)) return '.flv';
    if (Mp4Remuxer.isMp4(file)) return '.mp4';
    try {
      final raf = File(file).openSync();
      try {
        final head = raf.readSync(189);
        // MPEG-TS: 188-byte packets starting with the 0x47 sync byte
        if (head.length == 189 && head[0] == 0x47 && head[188] == 0x47) {
          return '.ts';
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return '.bin';
  }

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

  // Static so the isolate closure only captures the two arguments.
  static Future<void> _remuxInBackground(List<String> inputs, String output) =>
      Isolate.run(() => Mp4Remuxer.remux(inputs: inputs, output: output));

  /// Copies a stream file kept as it is into the export folder. Copied, not
  /// moved: the stream files are the entry's data until its completion is
  /// recorded, and the caller removes them only after that
  /// ([_completeDownload]). Through `<to>.part`, so a copy cut short is a
  /// leftover the next merge reuses (see [_exportFilePath]).
  static Future<void> _copyFile(String from, String to) async {
    final part = '$to.part';
    try {
      await File(from).copy(part);
      // on disk before the rename: the caller deletes the stream files
      // next, and an unflushed copy lost in a power cut would leave nothing
      final raf = await File(part).open(mode: FileMode.append);
      try {
        await raf.flush();
      } finally {
        await raf.close();
      }
      await File(part).rename(to);
    } catch (_) {
      await File(part).tryDel();
      rethrow;
    }
  }

  /// Whether [file] lives in its own per-video folder (named like the file),
  /// as opposed to the older flat layout.
  static bool _isOwnFolder(String file) =>
      path.basename(path.dirname(file)) == path.basenameWithoutExtension(file);

  Future<void> _deleteMerged(BiliDownloadEntryInfo entry) async {
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

  static Future<String> _exportFilePath(BiliDownloadEntryInfo entry) async {
    final dir = await _exportDir();
    final parts = <String>[entry.title];
    if (entry.ep case final ep?) {
      parts.add(ep.showTitle ?? '${ep.index} ${ep.indexTitle}');
    } else if (entry.pageData case final page?) {
      final part = page.part;
      if (part != null && part.isNotEmpty && part != entry.title) {
        parts.add('P${page.page} $part');
      }
    }
    var name = parts
        .join(' - ')
        .replaceAll(_illegalFileChars, '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // cut by code point (never half an emoji); the name is used twice in
    // the path (folder and file), so keep it short for Windows' 260 limit
    if (name.runes.length > 80) {
      name = String.fromCharCodes(name.runes.take(80)).trim();
    }
    if (entry.qualityPithyDescription.isNotEmpty) {
      name +=
          ' [${entry.qualityPithyDescription.replaceAll(_illegalFileChars, '_')}]';
    }
    name = exportFolderName(name);
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

  void nextDownload() {
    if (waitDownloadQueue.isNotEmpty) {
      startDownload(waitDownloadQueue.first);
    }
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
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
    if (_mergingCids.contains(entry.cid)) {
      _mergeDeletedCids.add(entry.cid);
    }
    await _repairManagers[entry.cid]?.cancel(isDelete: true);
    if (curDownload.value?.cid == entry.cid) {
      await cancelDownload(
        isDelete: true,
        downloadNext: downloadNext,
      );
    }
    await _cancelExtras(entry.cid);
    if (deleteExported) await _deleteMerged(entry);
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
      if (_mergingCids.contains(entry.cid)) {
        _mergeDeletedCids.add(entry.cid);
      }
      await _repairManagers[entry.cid]?.cancel(isDelete: true);
      if (curDownload.value?.cid == entry.cid) {
        await cancelDownload(isDelete: true, downloadNext: false);
      }
      await _cancelExtras(entry.cid);
      if (deleteExported) await _deleteMerged(entry);
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
    if (!isDelete && _mergingCids.contains(curDownload.value?.cid)) {
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
        await _updateBiliDownloadEntryJson(entry);
      }
    }
    if (isDelete) {
      _curCid = null;
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
