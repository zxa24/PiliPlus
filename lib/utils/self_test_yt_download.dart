// LibrePili: the YouTube download self-tests (feature-logs/
// download-platforms stage-2 plan §5): `--yt-download`, `--yt-resume`,
// `--yt-download-transcribe`, `--yt-panel`, `--yt-open`, with
// `--yt-quality`, `--yt-stop`, `--yt-tamper`, `--yt-inject`, `--yt-away`
// (and `--yt-list-delay`, read in SelfTestPref before the list is). A part
// of self_test.dart: it shares its report helpers.
part of 'self_test.dart';

/// What one `--yt-inject` asks for (stage-2 plan §5).
final class _YtInject {
  _YtInject._(this.kind, {this.dropFrom, this.drop = const {}});

  /// Null: the value is not one of §5's ([error] says).
  static _YtInject? parse(String? value) {
    if (value == null) return null;
    if (value.startsWith('drop:')) {
      final parts = value.split(':');
      final itags = parts.length == 3
          ? parts[2].split(',').map(int.tryParse).toList()
          : const <int?>[];
      if (parts.length != 3 ||
          !const {'direct', 'invidious', 'all'}.contains(parts[1]) ||
          itags.isEmpty ||
          itags.contains(null)) {
        return null;
      }
      return _YtInject._(
        'drop',
        dropFrom: parts[1],
        drop: {for (final i in itags) i!},
      );
    }
    return const {
          '403',
          '429',
          '429-all',
          'merge-error',
          'no-mp4',
          'client-broken',
          'live',
          'offline-live',
        }.contains(value)
        ? _YtInject._(value)
        : null;
  }

  final String kind;
  final String? dropFrom;
  final Set<int> drop;

  bool dropsFrom(String sourceId) =>
      kind == 'drop' && (dropFrom == 'all' || dropFrom == sourceId);
}

/// A source of a download's (or the panel's) router, as the self-test
/// sees it: every call noted ([asked]), and `--yt-inject`'s source-side
/// kinds answered in its place.
final class _YtInjectSource implements YouTubeVideoSource {
  _YtInjectSource(this.inner, this.inject, this.asked, this.onPair);

  final YouTubeVideoSource inner;
  final _YtInject? inject;
  final List<Map<String, Object?>> asked;
  final void Function(YtStreamPair pair) onPair;

  /// `client-broken` answers once (the retry then finds the pair).
  static var _brokenOnce = false;

  @override
  String get id => inner.id;

  @override
  String get label => inner.label;

  bool get _isDirect => id == 'direct';

  /// [call] in a zone that leaves `drop:`'s itags out of this source's
  /// picks ([ytSelfTestDropKey]).
  Future<T> _inZone<T>(Future<T> Function() call) =>
      inject?.dropsFrom(id) ?? false
      ? runZoned(call, zoneValues: {ytSelfTestDropKey: inject!.drop})
      : call();

  void _note(String call, YtVerdict verdict, [Object? more]) => asked.add({
    'source': id,
    'call': call,
    'cause': verdict.cause.name,
    'signal': verdict.signal,
    'more': ?more,
  });

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) async {
    if (_isDirect && inject?.kind == 'offline-live') {
      // as the classifier gives it: suspect, `videoDetails` came back
      const verdict = YtVerdict(
        YtCause.contentUnavailable,
        'playability:live_stream_offline',
        'self-test',
        true,
      );
      _note('detail', verdict, 'injected');
      return const YtResult.failed(verdict);
    }
    final r = await _inZone(() => inner.detail(videoId));
    var value = r.value;
    if (value != null) {
      final drop = inject?.dropsFrom(id) ?? false;
      final live = _isDirect && inject?.kind == 'live';
      if (drop || live) {
        value = YtVideoDetail(
          videoId: value.videoId,
          title: value.title,
          author: value.author,
          channelId: value.channelId,
          duration: value.duration,
          thumbnails: value.thumbnails,
          formats: drop
              ? value.formats
                    .where((f) => !inject!.drop.contains(f.itag))
                    .toList()
              : value.formats,
          captionTracks: value.captionTracks,
          isLive: value.isLive || live,
          expiresIn: value.expiresIn,
          liveNow: value.liveNow || live,
          description: value.description,
          viewCount: value.viewCount,
          hlsManifestUrl: value.hlsManifestUrl,
        );
      }
    }
    _note('detail', r.verdict, {
      'liveNow': ?value?.liveNow,
      'formats': ?value?.formats.length,
    });
    return value == null ? r : YtResult.ok(value);
  }

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async {
    if (_isDirect && inject?.kind == 'no-mp4') {
      const verdict = YtVerdict(
        YtCause.contentUnavailable,
        'no-playable-pair',
        'self-test',
      );
      _note('streams', verdict, 'injected');
      return const YtResult.failed(verdict);
    }
    if (_isDirect && inject?.kind == 'client-broken' && !_brokenOnce) {
      _brokenOnce = true;
      const verdict = YtVerdict(
        YtCause.clientBroken,
        'no-playable-pair',
        'self-test',
      );
      _note('streams', verdict, 'injected');
      return const YtResult.failed(verdict);
    }
    final r = await _inZone(
      () => inner.streams(videoId, preference: preference),
    );
    final pair = r.value;
    if (pair != null) onPair(pair);
    _note('streams', r.verdict, {
      'tier': preference.exactHeight,
      'pin': ?preference.pin?.toString(),
      'video': ?pair?.video?.itag,
      'audio': ?pair?.audio?.itag,
    });
    return r;
  }

  @override
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId) =>
      inner.captionTracks(videoId);

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) => inner.captionContent(track, format: format, translateTo: translateTo);

  @override
  Future<YtVerdict> probe() => inner.probe();
}

/// What a YouTube download run collects for its report.
final class _YtRun {
  final requests = <String, List<String>>{'video': [], 'audio': []};
  final asked = <Map<String, Object?>>[];
  final dioHosts = <String>{};
  final progressSamples = <List<Object?>>[];
  final keepAliveTexts = <String>[];
  var extrasQueueSeen = false;
  final pairHosts = <String>{};
  bool? lockedAtMerge;
  bool? noTransferAtMerge;
  DateTime? mergeAt;
  DateTime? audioLastByteAt;
  final injected = <String>[];

  /// `googlevideo` / `companion` / another host: where the streams' bytes
  /// came from (design §10-5 item 5 b).
  String? get via {
    if (pairHosts.isEmpty) return null;
    return pairHosts
        .map((h) {
          if (h.endsWith('googlevideo.com')) return 'googlevideo';
          if (h.contains('/companion')) return 'companion';
          return h;
        })
        .toSet()
        .join(',');
  }
}

abstract final class _YtDl {
  static String? _arg(List<String> args, String name) =>
      SelfTest._arg(args, name);

  static DownloadService get _service => Get.find<DownloadService>();

  static YtDownloadPlatform get _platform =>
      _service.platformNamed(YtDownloadEntry.platformId)! as YtDownloadPlatform;

  static YtDownloadEntry? _entryOf(String id) => [
    ..._service.waitDownloadQueue,
    ..._service.extrasQueue,
    ..._service.downloadList,
  ].whereType<YtDownloadEntry>().firstWhereOrNull((e) => e.key == 'yt:$id');

  /// The source wrapper and the transfer's, merge's and service's hooks a
  /// run sets ([run] collects); the returned function takes them away.
  static void Function() _hooks(
    List<String> args,
    _YtRun run,
    _YtInject? inject,
  ) {
    YtDownloadPlatform.selfTestWrapSource = (s) =>
        _YtInjectSource(s, inject, run.asked, (pair) {
          for (final url in [pair.videoUrl, pair.audioUrl]) {
            final uri = Uri.tryParse(url);
            if (uri == null) continue;
            run.pairHosts.add(
              uri.path.contains('/companion')
                  ? '${uri.host}/companion'
                  : uri.host,
            );
          }
        });
    var refusedOnce = false;
    var tooManyOnce = false;
    YtPairTransfer.selfTestOnRequest = (stream, range) =>
        run.requests[stream]?.add(range);
    YtPairTransfer.selfTestInject = switch (inject?.kind) {
      '403' => (stream, range) {
        if (refusedOnce || stream != 'video') return null;
        refusedOnce = true;
        run.injected.add('403 $stream $range');
        return 403;
      },
      '429' => (stream, range) {
        if (tooManyOnce || stream != 'video') return null;
        tooManyOnce = true;
        run.injected.add('429 $stream $range');
        return 429;
      },
      '429-all' => (stream, range) {
        run.injected.add('429 $stream $range');
        return 429;
      },
      _ => null,
    };
    if (inject?.kind == 'merge-error') {
      YtDownloadPlatform.selfTestMergeError = StateError(
        'self-test: the remuxer gave up',
      );
    }
    final dio = InterceptorsWrapper(
      onRequest: (options, handler) {
        run.dioHosts.add(options.uri.host);
        handler.next(options);
      },
    );
    Request.dio.interceptors.add(dio);
    return () {
      YtDownloadPlatform.selfTestWrapSource = null;
      YtDownloadPlatform.selfTestMergeError = null;
      YtPairTransfer.selfTestOnRequest = null;
      YtPairTransfer.selfTestInject = null;
      YtPairTransfer.selfTestOnBytes = null;
      DownloadService.selfTestBeforeOtherMerge = null;
      Request.dio.interceptors.remove(dio);
    };
  }

  /// The YouTube page of [id] opened and ready (its streams in), or why
  /// not.
  static Future<(YtVideoController?, String?)> _openPage(String id) async {
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': id}));
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 30)) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (Get.isRegistered<YtVideoController>(tag: id)) {
        final c = Get.find<YtVideoController>(tag: id);
        if (c.stage.value == .ready) return (c, null);
      }
    }
    return (null, 'the YouTube page did not get ready');
  }

  /// `--yt-download <id>` (a new download through the panel's code path:
  /// [YtDownloadPlatform.offerFor] and [YtDownloadPlatform.create], no
  /// taps), `--yt-resume <id>` (the same profile's second run: the record
  /// read, its first progress noted, `--yt-tamper` applied, started) and
  /// `--yt-download-transcribe <id>` (a download, then its background
  /// transcription waited for).
  static Future<Map<String, dynamic>> download(
    List<String> args,
    String input, {
    required String mode,
  }) async {
    final id = tryParseYouTubeVideoId(input) ?? input;
    final key = 'yt:$id';
    final service = _service;
    final injectArg = _arg(args, '--yt-inject');
    final inject = _YtInject.parse(injectArg);
    if (injectArg != null && inject == null) {
      return {'pass': false, 'error': 'unknown --yt-inject "$injectArg"'};
    }
    final stop = _arg(args, '--yt-stop');
    if (stop != null &&
        !RegExp(r'^(video|audio):(\d+|done)$|^merge$').hasMatch(stop)) {
      return {'pass': false, 'error': 'unknown --yt-stop "$stop"'};
    }
    final tamper = _arg(args, '--yt-tamper');
    if (tamper != null &&
        !const {
          'video-tail',
          'video-delete',
          'json-torn',
          'json-torn-notmp',
        }.contains(tamper)) {
      return {'pass': false, 'error': 'unknown --yt-tamper "$tamper"'};
    }
    final away = args.contains('--yt-away');
    final run = _YtRun();
    final logSince = DateTime.now();
    final unhook = _hooks(args, run, inject);
    final report = <String, dynamic>{'key': key, 'mode': mode};
    final stopped = Completer<String>();
    _StatusTrail? trail;
    try {
      await service.waitForInitialization;
      // the stop (bytes of a stream on disk, a stream done, the merge
      // reached and held there: the run ends before it merges) and the
      // merge's moment, set before the start
      DownloadService.selfTestBeforeOtherMerge = (e) async {
        if (e.key != key) return;
        final state = service.selfTestState;
        run
          ..mergeAt = DateTime.now()
          ..lockedAtMerge = state.locked
          ..noTransferAtMerge = state.noTransfer;
        if (stop == 'merge') {
          if (!stopped.isCompleted) stopped.complete('merge');
          await Completer<void>().future;
        }
      };
      final [stopStream, stopAt] = stop == null || stop == 'merge'
          ? ['', '']
          : stop.split(':');
      final stopBytes = int.tryParse(stopAt);
      YtPairTransfer.selfTestOnBytes = (s, onDisk) {
        if (s == 'audio') run.audioLastByteAt = DateTime.now();
        if (s != stopStream || stopped.isCompleted) return;
        final p = _entryOf(id)?.progress;
        final total = s == 'video' ? p?.videoTotal : p?.audioTotal;
        if ((stopBytes != null && onDisk >= stopBytes) ||
            (stopAt == 'done' &&
                total != null &&
                total > 0 &&
                onDisk >= total)) {
          stopped.complete('$s at $onDisk');
        }
      };
      if (away) {
        // before the start: what fails, fails off screen
        service.didChangeAppLifecycleState(AppLifecycleState.paused);
        report['away'] = true;
      }
      trail = _StatusTrail(service, () => _entryOf(id))..start();
      YtDownloadEntry? entry;
      if (mode == 'resume') {
        entry = _entryOf(id);
        if (entry == null) {
          return {...report, 'pass': false, 'error': 'no record of $key'};
        }
        report['initial'] = _progressOf(entry);
        report['initialBytes'] = _initialBytes(entry);
        if (tamper != null) report['tamper'] = await _tamper(entry, tamper);
      } else {
        final (page, why) = await _openPage(id);
        if (page == null) return {...report, 'pass': false, 'error': why};
        final offer = await _platform.offerFor(id);
        final detail = offer.detail;
        Get.back();
        if (detail == null) {
          return {
            ...report,
            'pass': false,
            'error':
                'offer: ${offer.verdict.cause.name}<${offer.verdict.signal}>',
            'sourcesAsked': run.asked,
          };
        }
        final tier =
            int.tryParse(_arg(args, '--yt-quality') ?? '') ??
            ytDefaultTier(detail.formats, page.maxHeight.value);
        report['offer'] = {
          'sourceId': offer.sourceId,
          'liveNow': offer.liveNow,
          'tiers': ytDownloadableTiers(detail.formats),
          'tier': tier,
        };
        if (tier == null) {
          return {
            ...report,
            'pass': false,
            'error': 'no MP4 tier',
            'sourcesAsked': run.asked,
          };
        }
        String? unreadable;
        final made = await YtDownloadPlatform.create(
          service,
          detail,
          tier,
          unreadable: (f) => unreadable = f,
        );
        report['createResult'] = made.name;
        if (unreadable != null) report['unreadable'] = unreadable;
        entry = _entryOf(id);
        if (made != YtCreateResult.added || entry == null) {
          // AC14's second run ends here: nothing new made
          return {
            ...report,
            'pass': made != YtCreateResult.failed,
            'record': await _record(entry),
          };
        }
      }
      final target = entry;
      // the old stream folder's bytes, for the 720p switch (AC-Q ④)
      final oldDir = target.streamTag == null
          ? null
          : path.join(target.entryDirPath, target.streamTypeTag);
      final oldSha = oldDir == null ? null : _shaOf(oldDir);
      Map<String, dynamic>? switched;
      if (mode == 'resume') unawaited(service.startDownload(target));

      final clock = Stopwatch()..start();
      DateTime? failedAt;
      var resumed = false;
      String? end;
      // the kinds the service took its failures as, in order
      final kinds = <String>[];
      while (clock.elapsed < const Duration(minutes: 20)) {
        await Future.delayed(const Duration(milliseconds: 500));
        _sample(run, target, clock);
        if (service.extrasQueue.any((e) => e.key == key)) {
          run.extrasQueueSeen = true;
        }
        if (service.selfTestFailureOf(key)?.name case final kind?
            when kinds.lastOrNull != kind) {
          kinds.add(kind);
        }
        if (service.selfTestState.keepAlive case final k?) {
          final text = '${k.title}|${k.text}';
          if (run.keepAliveTexts.lastOrNull != text) {
            run.keepAliveTexts.add(text);
          }
        }
        if (stopped.isCompleted) {
          end = 'stopped: ${await stopped.future}';
          if (stop != 'merge') {
            await service.cancelDownload(isDelete: false, downloadNext: false);
          }
          break;
        }
        if (service.downloadList.contains(target)) {
          end = 'complete';
          break;
        }
        final status = target.status;
        if (away && status.isFailed && !resumed) {
          failedAt ??= DateTime.now();
          if (DateTime.now().difference(failedAt) >=
              const Duration(seconds: 5)) {
            resumed = true;
            report['failedOffScreen'] = status.name;
            service.didChangeAppLifecycleState(AppLifecycleState.resumed);
          }
          continue;
        }
        if (status == DownloadStatus.failNoFormat) {
          end = 'failNoFormat';
          break;
        }
        if (target.gaveUp && status.isFailed) {
          // AC-Q ①: the 720p switch, as the row's button does it
          final action = switched == null
              ? _platform.failureAction(target)
              : null;
          if (action != null) {
            switched = {
              'label': action.label,
              'before': await _record(target),
            };
            final took = await service.takeFailureAction(target, action);
            switched['taken'] = took;
            switched['after'] = await _record(target);
            switched['videoTotalAtStart'] = target.progress.videoTotal;
            if (took ?? false) continue;
          }
          end = 'gave up: ${status.name}';
          break;
        }
      }
      // the completion's own work (record, transcript mark) right after
      await Future.delayed(const Duration(milliseconds: 500));
      _sample(run, target, clock);
      trail.stop();
      end ??= 'timeout';

      Map<String, dynamic>? transcribe;
      if (mode == 'transcribe' && end == 'complete') {
        transcribe = await _waitTranscript(target, logSince);
      }

      final merged = target.mergedPath;
      final streamDir = path.join(target.entryDirPath, target.streamTypeTag);
      report.addAll({
        'end': end,
        'statusTransitions': trail.statuses,
        'failureKind': kinds.lastOrNull,
        'failureKinds': kinds,
        'lastError': service.lastError,
        'gaveUp': target.gaveUp,
        'record': await _record(target),
        'streamJson': _streamJson(streamDir),
        'streamDirs': _streamDirs(target),
        'mergedPath': merged,
        'mergedExists': merged != null && File(merged).existsSync(),
        if (merged != null && File(merged).existsSync())
          'mergedStreams': await SelfTest._streamsOf(merged),
        'coverExists': File(
          path.join(target.entryDirPath, PathUtils.coverName),
        ).existsSync(),
        'requestsPerStream': {
          for (final e in run.requests.entries) e.key: e.value.length,
        },
        'ranges': run.requests,
        'progressSamples': run.progressSamples,
        'dioHosts': run.dioHosts.toList()..sort(),
        'lockedAtMerge': run.lockedAtMerge,
        'managerNullAtMerge': run.noTransferAtMerge,
        'mergeAt': run.mergeAt?.toIso8601String(),
        'audioLastByteAt': run.audioLastByteAt?.toIso8601String(),
        'via': run.via,
        'sourcesAsked': run.asked,
        'sharedHealth': _sharedHealth(),
        'extrasQueueSeen': run.extrasQueueSeen,
        'keepAliveTexts': run.keepAliveTexts,
        'injected': run.injected,
        'switched': ?switched,
        if (oldDir != null) ...{
          'oldStreamDir': oldDir,
          'oldStreamDirSha1': oldSha,
          'oldStreamDirExists': Directory(oldDir).existsSync(),
        },
        'transcribe': ?transcribe,
        'log': [
          for (final (_, line) in EventLog.entries(since: logSince))
            if (line.contains('[download]') || line.contains('[invidious]'))
              line.replaceFirst(RegExp(r'^\S+ '), ''),
        ],
      });
      // an end the run may have; whether it is the one a scenario expects
      // is the comparison's (stage-2 plan §5, the 2f report's list)
      report['pass'] = switch (end) {
        'timeout' => false,
        'complete' => (merged != null) != (inject?.kind == 'merge-error'),
        _ => true,
      };
      return report;
    } finally {
      trail?.stop();
      unhook();
    }
  }

  static Map<String, Object?> _progressOf(YtDownloadEntry e) {
    final p = e.progress;
    return {
      'video': [p.videoReceived, p.videoTotal],
      'audio': [p.audioReceived, p.audioTotal],
      'mediaReceived': p.mediaReceived,
      'mediaTotal': p.mediaTotal,
      'value': (p.value * 1000).round() / 1000,
      'status': e.status.name,
    };
  }

  static Map<String, Object?> _initialBytes(YtDownloadEntry e) {
    final b = _platform.initialBytes(e);
    return {
      'video': [b.video.$1, b.video.$2],
      if (b.audio case (final r, final t)) 'audio': [r, t],
      'mediaGuess': b.mediaGuess,
      'expectAudio': b.expectAudio,
    };
  }

  static void _sample(_YtRun run, YtDownloadEntry e, Stopwatch clock) {
    final p = e.progress;
    final row = [
      clock.elapsedMilliseconds / 1000,
      e.status.name,
      p.videoReceived,
      p.videoTotal,
      p.audioReceived,
      p.audioTotal,
      p.mediaReceived,
      p.mediaTotal,
      (p.value * 1000).round() / 1000,
    ];
    final last = run.progressSamples.lastOrNull;
    if (last == null ||
        !const ListEquality<Object?>().equals(
          last.sublist(1),
          row.sublist(1),
        )) {
      run.progressSamples.add(row);
    }
  }

  static Future<Map<String, dynamic>?> _record(YtDownloadEntry? e) async {
    if (e == null) return null;
    final f = File(path.join(e.entryDirPath, YtDownloadEntry.recordFile));
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      return {'unreadable': '$e'};
    }
  }

  static Object? _streamJson(String dir) {
    final f = File(path.join(dir, 'stream.json'));
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } catch (e) {
      return 'unreadable: $e';
    }
  }

  /// Each stream folder under `main/` with its files' sizes.
  static Map<String, Map<String, int>> _streamDirs(YtDownloadEntry e) {
    final main = Directory(e.entryDirPath);
    if (!main.existsSync()) return const {};
    return {
      for (final d in main.listSync().whereType<Directory>())
        path.basename(d.path): {
          for (final f in d.listSync().whereType<File>())
            path.basename(f.path): f.lengthSync(),
        },
    };
  }

  /// SHA-1 of each file in [dir] (name order).
  static Map<String, String>? _shaOf(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return null;
    final files = d.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return {
      for (final f in files)
        path.basename(f.path): sha1.convert(f.readAsBytesSync()).toString(),
    };
  }

  static Map<String, Object?> _sharedHealth() => {
    for (final e in YtSourceRouter.sharedHealth.entries)
      e.key: {
        'cooldownUntil': e.value.cooldownUntil?.toIso8601String(),
        'last': e.value.last?.signal,
      },
  };

  /// `--yt-tamper` on the record's current stream folder (AC3 b–d).
  static Future<String> _tamper(YtDownloadEntry e, String how) async {
    final dir = path.join(e.entryDirPath, e.streamTypeTag);
    final video = File(path.join(dir, 'video.m4s'));
    final json = File(path.join(dir, 'stream.json'));
    switch (how) {
      case 'video-tail':
        if (!video.existsSync()) return 'no video.m4s';
        final bytes = video.readAsBytesSync();
        // the last 64 KB changed: the overlap check must see it
        final from = math.max(0, bytes.length - 1024);
        for (var i = from; i < bytes.length; i++) {
          bytes[i] ^= 0xff;
        }
        video.writeAsBytesSync(bytes, flush: true);
        return 'video.m4s last ${bytes.length - from} bytes flipped';
      case 'video-delete':
        if (video.existsSync()) video.deleteSync();
        return 'video.m4s deleted';
      case 'json-torn':
      case 'json-torn-notmp':
        if (!json.existsSync()) return 'no stream.json';
        final text = json.readAsStringSync();
        if (how == 'json-torn') {
          File('${json.path}.tmp').writeAsStringSync(text);
        }
        json.writeAsStringSync(text.substring(0, text.length ~/ 2));
        return 'stream.json torn${how == 'json-torn' ? ', .tmp whole' : ''}';
    }
    return 'nothing';
  }

  /// AC-T: after the download, its background transcription.
  static Future<Map<String, dynamic>> _waitTranscript(
    YtDownloadEntry e,
    DateTime since,
  ) async {
    final transcripts = _service.transcripts;
    final pendingAtCompletion = e.transcriptPending;
    final percents = <int>[];
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(minutes: 20)) {
      await Future.delayed(const Duration(milliseconds: 500));
      final state = transcripts.stateOf(e.key);
      if (state != null) {
        final pct = (state.fraction * 100).floor();
        if (percents.lastOrNull != pct) percents.add(pct);
      }
      if (!e.transcriptPending && state == null) break;
    }
    final merged = e.mergedPath;
    final srt = merged == null
        ? null
        : File('${path.withoutExtension(merged)}.asr.srt');
    return {
      'transcriptPendingAtCompletion': pendingAtCompletion,
      'transcriptPendingAfter': e.transcriptPending,
      'percents': percents,
      'asrLog': [
        for (final (_, line) in EventLog.entries(since: since))
          if (line.contains('[asr]') ||
              line.contains('transcrib') ||
              line.contains('download yt:'))
            line,
      ],
      'srt': srt?.path,
      'srtExists': srt?.existsSync() ?? false,
      'seconds': clock.elapsed.inSeconds,
    };
  }

  /// `--yt-panel <id>`: the page and its panel opened, the panel's state
  /// once both sources have answered (or the other timed out), and a
  /// screenshot.
  static Future<Map<String, dynamic>> panel(String input) async {
    final id = tryParseYouTubeVideoId(input) ?? input;
    final run = _YtRun();
    final unhook = _hooks(const [], run, null);
    try {
      final before = _sharedHealth();
      final (page, why) = await _openPage(id);
      if (page == null) return {'pass': false, 'error': why};
      final states = <Map<String, Object?>>[];
      YtDownloadSheet.selfTestState = states.add;
      final context = Get.context!;
      unawaited(
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => YtDownloadSheet(
            videoId: id,
            pageCap: page.maxHeight.value,
            pageDetail: page.detail.value,
          ),
        ),
      );
      final clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 40)) {
        await Future.delayed(const Duration(milliseconds: 300));
        final last = states.lastOrNull;
        if (last != null &&
            last['loading'] == false &&
            last['otherPending'] == false) {
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 500));
      final shot = await SelfTest._shot('yt-panel-$id');
      final last = states.lastOrNull;
      Get.back();
      await Future.delayed(const Duration(milliseconds: 500));
      Get.back();
      return {
        'pass': last != null && last['loading'] == false,
        'pageCap': page.maxHeight.value,
        'panel': last,
        'states': states.length,
        'sourcesAsked': run.asked,
        'sharedHealthBefore': before,
        'sharedHealthAfter': _sharedHealth(),
        'shot': shot,
      };
    } finally {
      YtDownloadSheet.selfTestState = null;
      unhook();
    }
  }

  /// `--yt-open <id>`: the completed entry's row tapped in the list (its
  /// own tap handler), what opened: the route and the player's file, or
  /// the toast.
  static Future<Map<String, dynamic>> open(String input) async {
    final id = tryParseYouTubeVideoId(input) ?? input;
    final run = _YtRun();
    final unhook = _hooks(const [], run, null);
    final toasts = <String>[];
    // ignore: invalid_use_of_visible_for_testing_member
    YtDownloadPlatform.toastForTest = (msg) {
      toasts.add(msg);
      SmartDialog.showToast(msg);
    };
    try {
      await _service.waitForInitialization;
      final entry = _entryOf(id);
      if (entry == null || !entry.isCompleted) {
        return {'pass': false, 'error': 'no completed yt:$id'};
      }
      final routeBefore = Get.currentRoute;
      unawaited(Get.toNamed('/download'));
      await Future.delayed(const Duration(seconds: 2));
      // the row's own onTap, found in the tree as it is drawn
      final tap = _rowTap(entry.key);
      if (tap == null) {
        return {'pass': false, 'error': 'its row is not on the page'};
      }
      final routeAtTap = Get.currentRoute;
      tap();
      final clock = Stopwatch()..start();
      int? firstMs;
      int? lastMs;
      while (clock.elapsed < const Duration(seconds: 25)) {
        await Future.delayed(const Duration(milliseconds: 500));
        final player = PlPlayerController.instance;
        if (player != null) {
          final ms = player.positionInMilliseconds;
          firstMs ??= ms;
          lastMs = ms;
        }
        if (toasts.isNotEmpty && clock.elapsed > const Duration(seconds: 2)) {
          break;
        }
      }
      final player = PlPlayerController.instance;
      final source = player?.dataSource;
      final result = {
        'mergedPath': entry.mergedPath,
        'routeBefore': routeBefore,
        'routeAtTap': routeAtTap,
        'routeAfter': Get.currentRoute,
        'dataSource': switch (source) {
          final FileSource f => {
            'file': true,
            'dir': f.dir,
            'mergedPath': f.mergedPath,
          },
          null => null,
          final other => {'file': false, 'type': other.runtimeType.toString()},
        },
        'positionAdvancedMs': firstMs == null || lastMs == null
            ? null
            : lastMs - firstMs,
        'toasts': toasts,
        'dioHosts': run.dioHosts.toList()..sort(),
        'transferRequests': run.requests.values.expand((r) => r).length,
        'sourcesAsked': run.asked,
      };
      while (Get.currentRoute != routeBefore &&
          Navigator.canPop(Get.context!)) {
        Get.back();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return {...result, 'pass': true};
    } finally {
      // ignore: invalid_use_of_visible_for_testing_member
      YtDownloadPlatform.toastForTest = null;
      unhook();
    }
  }

  /// The onTap of the list row ([DetailItem]) drawn for [key], or null.
  static VoidCallback? _rowTap(DownloadKey key) {
    VoidCallback? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is DetailItem && w.entry.key == key) {
        void inner(Element c) {
          if (found != null) return;
          if (c.widget case final InkWell ink when ink.onTap != null) {
            found = ink.onTap;
            return;
          }
          c.visitChildren(inner);
        }

        e.visitChildren(inner);
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }
}
