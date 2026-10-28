part of 'download_service.dart';

/// LibrePili: bilibili's part of the downloads (feature-logs/
/// download-platforms design, §3.1). It is a part of the service's library
/// (§3.3): its start, merge and record are the service's own code, moved
/// here as they were, and use the service's private state directly (the
/// transfers' callbacks and slots, the start generation, the segment
/// repairs, the export folders being merged into).
final class _BiliPlatform implements DownloadPlatform {
  _BiliPlatform(this._service);

  final DownloadService _service;

  @override
  String get id => BiliDownloadEntryInfo.platformId;

  @override
  String get recordFile => DownloadService._entryFile;

  @override
  DownloadEntry parse(Map<String, dynamic> json) {
    final entry = BiliDownloadEntryInfo.fromJson(json);
    // [cid] reads one of the two: without either the
    // entry throws later, wherever the list is used
    if (entry.source == null && entry.pageData == null) {
      throw const FormatException('neither source nor page_data');
    }
    return entry;
  }

  /// Writes `entry.json` through `<file>.tmp` + rename: this runs on every
  /// size change and at the completion point, so a truncated file would
  /// hide the whole (possibly finished) download from the list. Only called
  /// from [DownloadService._saveEntry], which keeps the writes apart.
  @override
  Future<void> save(DownloadEntry entry) async {
    final entryJsonFile = File(path.join(entry.entryDirPath, recordFile));
    final tmp = File('${entryJsonFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode((entry as BiliDownloadEntryInfo).toJson()),
      flush: true,
    );
    await tmp.rename(entryJsonFile.path);
  }

  /// The danmaku: the service's [DownloadService.downloadDanmaku], also
  /// 「更新弹幕」's, which reports its own status and progress.
  @override
  Future<void> prepare(DownloadEntry entry, DownloadReport report) =>
      _service.downloadDanmaku(entry: entry as BiliDownloadEntryInfo);

  @override
  Future<void> start(DownloadEntry entry, int gen) =>
      _service._startBili(entry as BiliDownloadEntryInfo, gen);

  /// Saves the cover as `cover.jpg` in the entry folder: from the image
  /// cache, else over [Request.dio]. A failure does not stop the video.
  Future<bool> cover({
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

  @override
  ({(int, int) video, (int, int)? audio}) initialBytes(DownloadEntry entry) =>
      (video: (entry.downloadedBytes, entry.totalBytes), audio: null);

  @override
  ({String name, String suffix}) exportName(DownloadEntry entry) =>
      _exportNameOf(entry as BiliDownloadEntryInfo);

  /// [exportName]; also [DownloadService.exportNameForTest]'s, which has no
  /// service to ask.
  static ({String name, String suffix}) _exportNameOf(
    BiliDownloadEntryInfo entry,
  ) {
    final parts = <String>[entry.title];
    if (entry.ep case final ep?) {
      parts.add(ep.showTitle ?? '${ep.index} ${ep.indexTitle}');
    } else if (entry.pageData case final page?) {
      final part = page.part;
      if (part != null && part.isNotEmpty && part != entry.title) {
        parts.add('P${page.page} $part');
      }
    }
    return (name: parts.join(' - '), suffix: entry.qualityPithyDescription);
  }

  @override
  Future<DownloadMergeResult> merge(DownloadEntry entry) =>
      (DownloadService.mergeForTest ?? _service._mergeDownload)(
        entry as BiliDownloadEntryInfo,
      );

  @override
  Future<Map<String, Object?>> extras({
    required DownloadEntry entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) {
    entry as BiliDownloadEntryInfo;
    if (DownloadService.exportExtrasForTest case final export?) {
      return export(
        entry: entry,
        folder: folder,
        base: base,
        cancelled: cancelled,
        progress: progress,
      );
    }
    return DownloadExtras.export(
      entry: entry,
      folder: folder,
      base: base,
      cancelled: cancelled,
      progress: progress,
      transcriptKey: transcriptKey(entry),
    );
  }

  @override
  Map<String, int> extrasPlan() => DownloadExtras.plan();

  @override
  SubtitleCacheKey transcriptKey(DownloadEntry entry) =>
      SubtitleCacheKey.bilibili((entry as BiliDownloadEntryInfo).cid);

  @override
  String transcriptSessionKey(DownloadEntry entry) =>
      'download:${(entry as BiliDownloadEntryInfo).cid}';

  /// Only the network matters here (a failure off screen is started again
  /// on the return); the play URL's failures are the network's, the
  /// service says so itself.
  @override
  DownloadFailure classify(Object error) =>
      DownloadManager.isNetworkFailure(error)
      ? DownloadFailure.network
      : DownloadFailure.other;

  @override
  int? groupBadge(DownloadEntry entry) =>
      (entry as BiliDownloadEntryInfo).ep?.seasonType;

  @override
  ({DownloadTitleLine first, List<DownloadTitleLine> more}) titleLines(
    DownloadEntry entry,
    bool showTitle,
  ) {
    entry as BiliDownloadEntryInfo;
    return (
      first: (
        text: showTitle ? entry.title : entry.showTitle,
        maxLines: showTitle
            ? entry.ep != null
                  ? 1
                  : 2
            : 2,
      ),
      more: [
        if (showTitle) ...[
          if (entry.pageData?.part case final part?)
            if (part != entry.title) (text: part, maxLines: 1),
          if (entry.ep?.showTitle case final showTitle?)
            (text: showTitle, maxLines: 2),
        ],
      ],
    );
  }

  @override
  bool? coverCacheWidth(DownloadEntry entry) =>
      (entry as BiliDownloadEntryInfo).pageData?.cacheWidth;

  @override
  ({File? file, String? network}) localCover(DownloadEntry entry) {
    final cover = File(path.join(entry.entryDirPath, PathUtils.coverName));
    return (file: cover.existsSync() ? cover : null, network: entry.cover);
  }

  @override
  ({int positionMs, bool finished})? progressOf(DownloadEntry entry) {
    final progress = GStorage.watchProgress.get(
      (entry as BiliDownloadEntryInfo).cid.toString(),
    );
    if (progress == null) return null;
    return (
      positionMs: progress,
      finished: progress >= entry.totalTimeMilli - 400,
    );
  }

  @override
  List<DownloadMenuItem> menu(DownloadEntry entry) => [
    (
      label: '更新弹幕',
      onTap: () async {
        final res = await _service.downloadDanmaku(
          entry: entry as BiliDownloadEntryInfo,
          isUpdate: true,
        );
        if (res) {
          SmartDialog.showToast('更新成功');
        } else {
          SmartDialog.showToast('更新失败');
        }
      },
    ),
  ];

  @override
  List<DownloadMenuItem> groupMenu(List<DownloadEntry> entries) => [
    (
      label: '更新弹幕',
      onTap: () async {
        final res = await Future.wait(
          entries.map(
            (e) => _service.downloadDanmaku(
              entry: e as BiliDownloadEntryInfo,
              isUpdate: true,
            ),
          ),
        );
        if (res.every((e) => e)) {
          SmartDialog.showToast('更新成功');
        } else {
          SmartDialog.showToast('更新失败');
        }
      },
    ),
  ];

  /// 查看详情页, the folder, 访问用户主页.
  @override
  Widget actions(DownloadEntry entry, ColorScheme colorScheme) =>
      (entry as BiliDownloadEntryInfo).moreBtn(colorScheme);

  /// The local watch progress, by cid.
  @override
  Future<void> onDeleted(List<DownloadEntry> entries) =>
      GStorage.watchProgress.deleteAll(
        entries.map((e) => (e as BiliDownloadEntryInfo).cid.toString()),
      );

  /// The `/videoV` page on the files.
  @override
  Future<void> openOffline(DownloadEntry entry) async {
    entry as BiliDownloadEntryInfo;
    await PageUtils.toVideoPage(
      aid: entry.avid,
      cid: entry.cid,
      cover: entry.cover,
      title: entry.showTitle,
      isVertical: entry.pageData?.isVertical ?? false,
      extraArguments: {
        'sourceType': SourceType.file,
        'entry': entry,
        'dirPath': entry.entryDirPath,
      },
    );
  }
}

/// The bilibili download's own steps, moved here from the service as they
/// were (design §3.3): they reach the service's private members directly.
extension _BiliDownload on DownloadService {
  /// The start after the danmaku and the play-URL status: the play URL, the
  /// stream folder, the stream index and the cover, the transfers and the
  /// size saved. [gen] is checked after each await, as it always was.
  Future<void> _startBili(BiliDownloadEntryInfo entry, int gen) async {
    final oldTypeTag = entry.typeTag;
    final mediaFileInfo =
        await (DownloadService.getVideoUrlForTest ?? DownloadHttp.getVideoUrl)(
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
    final videoDir = Directory(DownloadService._streamDirPath(entry));
    final mediaJsonFile = File(
      path.join(videoDir.path, DownloadService._indexFile),
    );
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
      _bili.cover(entry: entry),
    ]);

    if (gen != _startGen) {
      // deleted meanwhile: what was written here (the cover's download
      // creates its folder) would be left behind as an orphan
      if (!File(path.join(entry.entryDirPath, DownloadService._entryFile))
          .existsSync()) {
        await Directory(entry.entryDirPath).tryDel(recursive: true);
      }
      return;
    }
    if (curDownload.value?.key != entry.key) {
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
        _downloadManager =
            (DownloadService.newManagerForTest ?? DownloadManager.new)(
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
          _audioDownloadManager =
              (DownloadService.newManagerForTest ?? DownloadManager.new)(
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
        _saveEntry(entry);
        break;
      default:
        break;
    }
  }

  /// What identifies the bytes of a saved stream (`index.json`): the dash
  /// video / audio stream picked (id / codec / resolution — its size is
  /// still 0 when this runs, so a stream of the same id and codec but
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
    manager = (DownloadService.newManagerForTest ?? DownloadManager.new)(
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

  /// Turns the downloaded streams into one complete video file in the export
  /// directory. Returns the file (null on failure) and the stream files the
  /// caller removes once completion is saved. On failure the stream files
  /// are kept, so the entry still plays in-app as before. [damaged]: durl
  /// segments are damaged / missing even after re-downloading, so the
  /// entry must not be treated as complete. [corrupt]: dash streams whose
  /// bytes are damaged — complete in size, so a start again would only
  /// resume nothing and merge the same bytes; the caller removes them.
  Future<({String? output, List<String> inputs, bool damaged, bool corrupt})>
  _mergeDownload(
    BiliDownloadEntryInfo entry,
  ) async {
    final videoDir = DownloadService._streamDirPath(entry);
    final List<String> inputs;
    // durl segments of the play URL this download used (for re-downloading
    // a damaged one); segments on disk beyond them are left over from an
    // earlier attempt
    List<Type1Segment>? segments;
    if (entry.mediaType == 1) {
      int? count;
      try {
        final index = File(path.join(videoDir, DownloadService._indexFile));
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
      return (output: output, inputs: inputs, damaged: false, corrupt: false);
    } catch (e) {
      if (output != null) {
        await File(output).tryDel();
        final folder = Directory(path.dirname(output));
        if (DownloadService._isOwnFolder(output) && folder.listSync().isEmpty) {
          await folder.tryDel();
        }
      }
      // damaged bytes ([FormatException] / [RangeError] out of the remuxers)
      // or a missing / unreadable stream file ([FileSystemException]): the
      // entry is not complete whatever its mediaType is, it stays in the
      // queue so starting it again re-downloads and merges it
      final damaged =
          e is FormatException || e is RangeError || e is FileSystemException;
      final corrupt =
          entry.mediaType != 1 && (e is FormatException || e is RangeError);
      entry.status = DownloadStatus.failMerge;
      // a corrupt one's is told by the caller: whether it downloads again
      if (!corrupt) {
        (DownloadService.toastForTest ?? SmartDialog.showToast)(
          damaged
              ? (entry.mediaType == 1
                    ? '视频分段已损坏且重新下载失败，可稍后重新开始该下载'
                    : '音视频文件丢失或无法读取，可稍后重新开始该下载')
              : '合并音视频失败，已保留分离的音视频文件',
        );
      }
      EventLog.add('download', '${entry.logLabel}: merge failed: $e');
      if (kDebugMode) debugPrint('merge download error: $e');
      return (
        output: null,
        inputs: inputs,
        damaged: damaged,
        corrupt: corrupt,
      );
    } finally {
      if (output != null) {
        DownloadService._mergeFolders.remove(path.dirname(output));
      }
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
      (DownloadService.toastForTest ?? SmartDialog.showToast)(
        '分段无法合并，已按原格式分为${inputs.length}个文件保存',
      );
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
}
