import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io'
    show Directory, File, FileSystemEntity, FileSystemException, Platform;
import 'dart:isolate' show Isolate;

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
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  static const _maxDanmakuConcurrency = 4;

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value != null) {
      curDownload
        ..value!.status = status
        ..refresh();
    }
  }

  DownloadManager? _downloadManager;
  DownloadManager? _audioDownloadManager;

  late Future<void> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
  }

  void initDownloadList() {
    waitForInitialization = _readDownloadList();
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir));
      }
    }
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    await for (final entryDir in pageDir.list()) {
      if (entryDir is Directory) {
        final entryFile = File(path.join(entryDir.path, _entryFile));
        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path;
            if (entry.isCompleted) {
              result.add(entry);
            } else {
              waitDownloadQueue.add(entry..status = DownloadStatus.wait);
            }
          } catch (_) {}
        }
      }
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
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
      cover: episode.cover!,
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
      cover: episode.cover!,
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
        _isForeignFolder(page) &&
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
    // already finished downloading; the merge completes it
    if (_mergingCids.contains(entry.cid)) return Future.value();
    return _lock.synchronized(() async {
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
      await _startDownload(entry);
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) {
      return false;
    }
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      try {
        if (!isUpdate) {
          _updateCurStatus(DownloadStatus.getDanmaku);
        }
        final seg = (entry.totalTimeMilli / DmUtils.segLength).ceil();
        if (seg <= 0) {
          throw StateError('Invalid danmaku segment count: $seg');
        }

        final danmaku = (await DmGrpc.dmSegMobile(
          cid: cid,
          segmentIndex: 1,
        )).data;
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
        }
        await danmakuFile.writeAsBytes(danmaku.writeToBuffer());

        return true;
      } catch (e) {
        if (!isUpdate) {
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
      final file = (await CacheManager.manager.getFileFromCache(
        entry.cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(entry.cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startDownload(BiliDownloadEntryInfo entry) async {
    try {
      if (!await downloadDanmaku(entry: entry)) {
        return;
      }

      _updateCurStatus(DownloadStatus.getPlayUrl);

      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );

      final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
      if (!videoDir.existsSync()) {
        await videoDir.create(recursive: true);
      }

      final mediaJsonFile = File(path.join(videoDir.path, _indexFile));
      await Future.wait([
        mediaJsonFile.writeAsString(jsonEncode(mediaFileInfo.toJson())),
        _downloadCover(entry: entry),
      ]);

      if (curDownload.value?.cid != entry.cid) {
        return;
      }

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
          );
          final audio = mediaFileInfo.audio;
          if (audio != null && audio.isNotEmpty) {
            _audioDownloadManager = DownloadManager(
              url: audio.first.baseUrl,
              backupUrls: audio.first.backupUrl ?? const [],
              path: path.join(videoDir.path, PathUtils.audioNameType2),
              onReceiveProgress: null,
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
      _updateCurStatus(DownloadStatus.failPlayUrl);
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
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

  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) {
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    return entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
  }

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      if (progress == 0 && total != 0) {
        _updateBiliDownloadEntryJson(entry..totalBytes = total);
      }
      entry
        ..downloadedBytes = progress
        ..status = DownloadStatus.downloading;
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
      _updateCurStatus(_downloadManager?.status ?? DownloadStatus.pause);
      return;
    }

    final status = switch (_audioDownloadManager?.status) {
      DownloadStatus.downloading => DownloadStatus.audioDownloading,
      DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
      _ => _downloadManager?.status ?? DownloadStatus.pause,
    };
    _updateCurStatus(status);

    if (curDownload.value case final curEntryInfo?) {
      curEntryInfo.downloadedBytes = curEntryInfo.totalBytes;
      if (status == DownloadStatus.completed) {
        _completeDownload();
      } else {
        _updateBiliDownloadEntryJson(curEntryInfo);
      }
    }
  }

  void _onAudioDone([Object? error]) {
    if (error != null) {
      lastError = 'audio: $error';
      debugPrint('download failed: $lastError');
    }
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
    if (entry == null) {
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
    final deleted = _mergeDeletedCids.remove(cid);
    if (deleted || !Directory(entry.entryDirPath).existsSync()) {
      // deleted while merging (the merge may have kept files open, so the
      // delete may not have removed everything)
      await _deleteMerged(entry);
      await Directory(entry.entryDirPath).tryDel(recursive: true);
      waitDownloadQueue.remove(entry);
      if (curDownload.value == null) nextDownload();
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
    // record completion before removing the stream files, so a crash here
    // cannot turn the entry back into an incomplete one
    entry.isCompleted = true;
    await _updateBiliDownloadEntryJson(entry);
    if (output != null) {
      for (final input in inputs) {
        await File(input).tryDel();
      }
      if (Platform.isAndroid) {
        for (final part in _exportedParts(output)) {
          await _scanMedia(part);
        }
      }
    }
    waitDownloadQueue.remove(entry);
    downloadList.insert(0, entry);
    flagNotifier.refresh();
    if (curDownload.value?.cid == entry.cid) {
      _curCid = null;
      curDownload.value = null;
      nextDownload();
    }
    // comments / subtitles etc. can take many requests: do not hold the
    // queue for them
    if (output != null) _queueExtras(entry, output);
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
      try {
        await DownloadExtras.export(
          entry: entry,
          folder: path.dirname(output),
          base: path.basenameWithoutExtension(output),
          cancelled: () => _extrasCancelled.contains(cid),
        );
      } catch (e) {
        if (kDebugMode) debugPrint('download extras: $e');
      } finally {
        _extrasRunningCid = null;
      }
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
    if (!_extrasJobs.containsKey(cid)) return;
    _extrasCancelled.add(cid);
    if (_extrasRunningCid == cid) await _extrasJobs[cid];
  }

  /// cids of the entries being merged (a deleted entry's merge can overlap
  /// the next one's); pause/start requests for them are ignored.
  final _mergingCids = <int>{};

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
    final videoDir = path.join(entry.entryDirPath, entry.typeTag);
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
      final damaged = entry.mediaType == 1 && e is FormatException;
      entry.status = DownloadStatus.failMerge;
      SmartDialog.showToast(
        damaged ? '视频分段已损坏且重新下载失败，可稍后重新开始该下载' : '合并音视频失败，已保留分离的音视频文件',
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
        await File(file).tryDel();
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
  /// a single mp4 segment is moved as is. Damaged data ([FormatException])
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
      await _moveFile(inputs.first, kept);
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
    String? first;
    for (var i = 0; i < inputs.length; i++) {
      final ext = _sniffExt(inputs[i]);
      final to = i == 0 ? '$base$ext' : '$base.${i + 1}$ext';
      await _moveFile(inputs[i], to);
      first ??= to;
    }
    if (inputs.length > 1) {
      SmartDialog.showToast('分段无法合并，已按原格式分为${inputs.length}个文件保存');
    }
    return first!;
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

  static Future<void> _moveFile(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      // across volumes
      await File(from).copy(to);
      await File(from).tryDel();
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
    if (downloadDir.existsSync()) {
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
    for (final entry in downloadList.toList()) {
      if (entry.pageDirPath != pageDirPath) continue;
      await _cancelExtras(entry.cid);
      if (deleteExported) await _deleteMerged(entry);
    }
    final pageDir = Directory(pageDirPath);
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
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
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
