// LibrePili: the YouTube download extras' self-tests (feature-logs/
// download-platforms design §6, stage 4): `--yt-extras-probe <A>
// --probe-baseline <B> --probe-after <C>` (design §9 probe 4: the comment
// step at its pacing, `--comment-gap-ms` to change it, then whether the
// next online video still plays from the direct source),
// `--yt-caption-list <id>` (a video's caption tracks and what an export
// would keep of them), `--yt-extras-wait <id>` (a completed download whose
// extras a launch is to do: they are waited for and reported), and the
// extras' report of `--yt-download` ([_YtX.report]). A part of
// self_test.dart: it shares its report helpers.
part of 'self_test.dart';

abstract final class _YtX {
  static String? _arg(List<String> args, String name) =>
      SelfTest._arg(args, name);

  static DownloadService get _service => Get.find<DownloadService>();

  /// What [YtExtras] reported of the requests since [hook] was called, and
  /// the export's `written` (the returned function takes the hooks away).
  static (List<Map<String, Object?>>, Map<String, Object?>, void Function())
  hook(DateTime since) {
    final requests = <Map<String, Object?>>[];
    final written = <String, Object?>{};
    YtExtras.onRequestForTest = (kind, verdict, took) => requests.add({
      'at': DateTime.now().difference(since).inMilliseconds,
      'kind': kind,
      'cause': verdict.cause.name,
      if (!verdict.isOk) 'verdict': '$verdict',
      'ms': took.inMilliseconds,
    });
    YtExtras.onWrittenForTest = (key, w) => written
      ..clear()
      ..addAll(w)
      ..['key'] = key;
    return (
      requests,
      written,
      () {
        YtExtras.onRequestForTest = null;
        YtExtras.onWrittenForTest = null;
      },
    );
  }

  /// The requests by kind: how many, how many not ok, their verdicts, the
  /// time they took.
  static Map<String, Object?> requestSummary(
    List<Map<String, Object?>> requests,
  ) {
    final byKind = <String, List<Map<String, Object?>>>{};
    for (final r in requests) {
      byKind.putIfAbsent(r['kind']! as String, () => []).add(r);
    }
    return {
      'count': requests.length,
      'notOk': requests.where((r) => r['cause'] != 'ok').length,
      'ipBlocked': requests.where((r) => r['cause'] == 'ipBlocked').length,
      'firstAtMs': requests.firstOrNull?['at'],
      'lastAtMs': requests.lastOrNull?['at'],
      'byKind': {
        for (final MapEntry(:key, :value) in byKind.entries)
          key: {
            'count': value.length,
            'notOk': [
              for (final r in value)
                if (r['cause'] != 'ok') r['verdict'],
            ],
            'msTotal': value.fold<int>(0, (s, r) => s + (r['ms']! as int)),
            'msMax': value.fold<int>(
              0,
              (s, r) => math.max(s, r['ms']! as int),
            ),
          },
      },
    };
  }

  /// The export folder of [entry] as it is on disk: its files, the
  /// subtitles' SHA-1, the intro's and the comments' counts, the avatars.
  static Map<String, Object?> report(YtDownloadEntry entry) {
    final merged = entry.mergedPath;
    if (merged == null) return {'error': 'no export'};
    final folder = Directory(path.dirname(merged));
    final base = path.basenameWithoutExtension(merged);
    if (!folder.existsSync()) return {'error': 'no export folder'};
    final files = {
      for (final f in folder.listSync().whereType<File>())
        path.basename(f.path): f.lengthSync(),
    };
    Map<String, dynamic>? json(String name) {
      final f = File(path.join(folder.path, name));
      if (!f.existsSync()) return null;
      try {
        return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      } catch (e) {
        return {'unreadable': '$e'};
      }
    }

    final intro = json('$base${YtExtras.introSuffix}');
    final comments = json('$base${YtExtras.commentsSuffix}');
    final list = (comments?['comments'] as List?)?.cast<Map>() ?? const [];
    final images = Directory(path.join(folder.path, YtCommentImages.dirName));
    final imageSizes = images.existsSync()
        ? [for (final f in images.listSync().whereType<File>()) f.lengthSync()]
        : const <int>[];
    final info = json(DownloadExtras.infoName);
    return {
      'folder': folder.path,
      'base': base,
      'files': files,
      'srt': {
        for (final name in files.keys.where((n) => n.endsWith('.srt')))
          name: {
            'sha1': sha1
                .convert(File(path.join(folder.path, name)).readAsBytesSync())
                .toString(),
            'track': switch (YtExtras.trackOfFile(name, base)) {
              final t? => '${t.lang} ${t.source.name}',
              null => null,
            },
          },
      },
      'infoKeys': info?.keys.toList(),
      'intro': intro == null
          ? null
          : {
              'format': intro['format'],
              'title': intro['title'],
              'published': intro['published'],
              'subscriberText': intro['subscriberText'],
              'descriptionLength': (intro['description'] as String?)?.length,
              'faces': (intro['faces'] as Map?)?.length,
            },
      'comments': comments == null
          ? null
          : {
              'format': comments['format'],
              'count': list.length,
              'replies': list.fold<int>(
                0,
                (s, c) => s + ((c['replies'] as List?)?.length ?? 0),
              ),
              'withAvatarFile': list
                  .where((c) => c['avatarFile'] != null)
                  .length,
              'stoppedBy': comments['stoppedBy'],
            },
      'images': {
        'count': imageSizes.length,
        'maxBytes': imageSizes.fold<int>(0, math.max),
        'parts': images.existsSync()
            ? images
                  .listSync()
                  .where((e) => e.path.endsWith('.part'))
                  .length
            : 0,
      },
    };
  }

  /// The source a ready YouTube page plays from, and why.
  static Map<String, Object?> _pageSource(YtVideoController page) => {
    'streamSource': page.streams?.sourceId,
    'overrideReason': page.play.activeOverrideReason,
    'fellThroughFor': page.play.fellThroughFor?.name,
  };

  static Object? _cooldowns() =>
      GStorage.localCache.get(LocalCacheKey.ytCooldowns);

  /// A YouTube page of [id] opened, its source noted, and closed again.
  static Future<Map<String, Object?>> _visit(String id) async {
    final (page, why) = await _YtDl._openPage(id);
    if (page == null) {
      return {'id': id, 'error': why};
    }
    final out = {'id': id, ..._pageSource(page)};
    Get.back();
    await Future.delayed(const Duration(seconds: 2));
    return out;
  }

  /// `--yt-extras-probe <A> --probe-baseline <B> --probe-after <C>` (§9
  /// probe 4): B opened online (the direct source must play it, else the
  /// run says so and stops); A's comments saved at the pacing
  /// ([YtExtras.commentGap], `--comment-gap-ms`) with `dlCommentCount` /
  /// `dlReplyCount` as set (200/10 by default), through the export's own
  /// network ([YtExtrasLiveNet]: the comments' own direct-only router);
  /// then C opened online: does it still play from the direct source?
  static Future<Map<String, dynamic>> probe(List<String> args, String a) async {
    final b = _arg(args, '--probe-baseline');
    final c = _arg(args, '--probe-after');
    if (b == null || c == null) {
      return {
        'pass': false,
        'error': '--probe-baseline and --probe-after are needed',
      };
    }
    if (_arg(args, '--comment-gap-ms') case final ms?) {
      YtExtras.commentGap = Duration(milliseconds: int.parse(ms));
    }
    final since = DateTime.now();
    final report = <String, dynamic>{
      'video': a,
      'commentGapMs': YtExtras.commentGap.inMilliseconds,
      'dlCommentCount': Pref.dlCommentCount,
      'dlReplyCount': Pref.dlReplyCount,
      'cooldownsBefore': _cooldowns(),
      'sharedHealthBefore': _YtDl._sharedHealth(),
    };
    final baseline = report['baseline'] = await _visit(b);
    if (baseline['streamSource'] != 'direct') {
      return {
        ...report,
        'pass': false,
        'error': 'the baseline did not play from the direct source: the '
            'probe would not tell what the comments did',
      };
    }
    final (requests, written, unhook) = hook(since);
    final saved = <String, Object?>{};
    final settings = [
      SettingBoxKey.dlSaveCover,
      SettingBoxKey.dlSaveSubtitle,
      SettingBoxKey.dlSaveComments,
    ];
    for (final k in settings) {
      saved[k] = GStorage.setting.get(k);
    }
    try {
      await GStorage.setting.put(SettingBoxKey.dlSaveCover, false);
      await GStorage.setting.put(SettingBoxKey.dlSaveSubtitle, false);
      await GStorage.setting.put(SettingBoxKey.dlSaveComments, true);
      final dir = Directory(
        path.join((await appTempDirectory()).path, 'yt-extras-probe', a),
      )..createSync(recursive: true);
      final entry = YtDownloadEntry(
        videoId: a,
        title: 'probe $a',
        channel: '',
        channelId: '',
        cover: '',
        durationMs: 0,
        maxHeight: 360,
        isCompleted: true,
        mergedPath: path.join(dir.path, 'probe.mp4'),
        timeCreateStamp: 0,
        timeUpdateStamp: 0,
      );
      final play = YtSourceRouter(
        YtDirectSource.create(),
        fallback: YtInvidiousSource.shared,
        mode: YtSourceStore.debugMode,
      );
      final net = YtExtrasLiveNet(play: play);
      final clock = Stopwatch()..start();
      await YtExtras.export(
        entry: entry,
        folder: dir.path,
        base: 'probe',
        net: net,
        transcriptKey: SubtitleCacheKey.youtube(a),
      );
      report['seconds'] = clock.elapsed.inMilliseconds / 1000;
      report['written'] = Map.of(written);
      report['requests'] = requestSummary(requests);
      report['requestLog'] = requests;
      report['commentsHealth'] = {
        for (final e in net.commentsHealth.entries)
          e.key: {
            'cooldownUntil': e.value.cooldownUntil?.toIso8601String(),
            'blockSignalStreak': e.value.blockSignalStreak,
            'last': e.value.last?.toString(),
          },
      };
      (play.direct as YtDirectSource).close();
      report['saved'] = folderReport(dir.path, 'probe');
    } finally {
      for (final MapEntry(:key, :value) in saved.entries) {
        value == null
            ? await GStorage.setting.delete(key)
            : await GStorage.setting.put(key, value);
      }
      unhook();
    }
    report['after'] = await _visit(c);
    report['cooldownsAfter'] = _cooldowns();
    report['sharedHealthAfter'] = _YtDl._sharedHealth();
    report['log'] = [
      for (final (_, line) in EventLog.entries(since: since))
        if (line.contains('[invidious]') ||
            line.contains('[download]') ||
            line.contains('[youtube]'))
          line.replaceFirst(RegExp(r'^\S+ '), ''),
    ];
    final summary = report['requests'] as Map;
    // the pre-registered prediction (report.md): no wall met by the
    // comments, none left behind for the pages, C from the direct source
    report['predictionHolds'] =
        summary['ipBlocked'] == 0 &&
        (report['after'] as Map)['streamSource'] == 'direct' &&
        '${report['cooldownsAfter']}' == '${report['cooldownsBefore']}';
    report['pass'] = true;
    return report;
  }

  /// [report] for a folder that is not a download's (the probe's).
  static Map<String, Object?> folderReport(String folder, String base) {
    final comments = File(
      path.join(folder, '$base${YtExtras.commentsSuffix}'),
    );
    if (!comments.existsSync()) return {'comments': null};
    final json = jsonDecode(comments.readAsStringSync()) as Map;
    final list = (json['comments'] as List).cast<Map>();
    return {
      'comments': list.length,
      'replies': list.fold<int>(
        0,
        (s, c) => s + ((c['replies'] as List?)?.length ?? 0),
      ),
      'stoppedBy': json['stoppedBy'],
      'images': Directory(path.join(folder, YtCommentImages.dirName))
              .existsSync()
          ? Directory(path.join(folder, YtCommentImages.dirName))
                .listSync()
                .length
          : 0,
    };
  }

  /// `--yt-caption-list <id>`: the video's caption tracks (one `player`
  /// call, the direct source) and the files an export would keep them as.
  static Future<Map<String, dynamic>> captionList(String id) async {
    final source = YtDirectSource.create();
    try {
      final r = await source.captionTracks(id);
      if (!r.ok) return {'pass': false, 'verdict': '${r.verdict}'};
      final tracks = r.value!;
      return {
        'pass': true,
        'tracks': [
          for (final t in tracks)
            {'languageCode': t.languageCode, 'vssId': t.vssId, 'name': t.name},
        ],
        'kept': [
          for (final p in YtExtras.pickTracks(tracks, 'base')) p.name,
        ],
      };
    } finally {
      source.close();
    }
  }

  /// `--yt-extras-wait <id>`: a completed download whose extras this
  /// launch is to do (a stage-2 record marked `extras_pending`, design §6
  /// and §11 stage 4): whether the list's read queued them, then their end.
  static Future<Map<String, dynamic>> extrasWait(String id) async {
    final since = DateTime.now();
    final (requests, written, unhook) = hook(since);
    try {
      await _service.waitForInitialization;
      final entry = _YtDl._entryOf(id);
      if (entry == null) return {'pass': false, 'error': 'no yt:$id'};
      final out = <String, dynamic>{
        'recordBefore': {
          'is_completed': entry.isCompleted,
          'extras_pending': entry.extrasPending,
        },
        'queuedAtRead': _service.extrasQueue.any((e) => e.key == entry.key),
        'jobAtRead': _service.extrasDone(entry.key) != null,
      };
      final clock = Stopwatch()..start();
      // the download page's first use lets held extras go (a launch in
      // the background holds them, §2.3)
      while (_service.extrasDone(entry.key) == null &&
          entry.extrasPending &&
          clock.elapsed < const Duration(seconds: 20)) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
      await _service.extrasDone(entry.key)?.timeout(
        const Duration(minutes: 20),
        onTimeout: () {},
      );
      out
        ..['seconds'] = clock.elapsed.inSeconds
        ..['extrasPendingAfter'] = entry.extrasPending
        ..['status'] = entry.status.name
        ..['recordAfter'] = await _YtDl._record(entry)
        ..['written'] = Map.of(written)
        ..['requests'] = requestSummary(requests)
        ..['export'] = report(entry)
        ..['pass'] = !entry.extrasPending;
      return out;
    } finally {
      unhook();
    }
  }
}
