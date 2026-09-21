import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/member/search_archive/data.dart';
import 'package:PiliPlus/models_new/space/space_archive/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

/// Command-line self test (LibrePili), for scripted checks of a real build:
///
///   LibrePili.exe --selftest [--download BVxxx] [--qn 80] [--local]
///                 [--keep] [--out result.json]
///
/// Runs after the app has started normally, writes a JSON report and exits
/// with 0 when every check passed, 1 otherwise.
abstract final class SelfTest {
  static bool isRequested(List<String> args) => args.contains('--selftest');

  static String? _arg(List<String> args, String name) {
    final i = args.indexOf(name);
    return i != -1 && i + 1 < args.length ? args[i + 1] : null;
  }

  /// Writes the `started` marker so a caller can tell "app never started"
  /// from "test still running". `--out` comes from the args alone, so this
  /// works before storage (and everything else) is up.
  static void markStarted(List<String> args) {
    if (_arg(args, '--out') case final out?) {
      try {
        File(out).writeAsStringSync(jsonEncode({'stage': 'started'}));
      } catch (_) {}
    }
  }

  /// The app could not start (e.g. storage init failed): the run is recorded
  /// as failed and the process exits non-zero, so a scripted caller checking
  /// the exit code does not read a broken build as a pass.
  static Never abort(List<String> args, Object error) {
    if (_arg(args, '--out') case final out?) {
      try {
        File(out).writeAsStringSync(
          jsonEncode({'stage': 'error', 'pass': false, 'error': '$error'}),
        );
      } catch (_) {}
    }
    exit(1);
  }

  /// Schedules the run once the first frame is on screen.
  static void schedule(List<String> args) {
    markStarted(args);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () => _run(args));
    });
  }

  static Future<void> _run(List<String> args) async {
    final out = _arg(args, '--out') ?? path.join(tmpDirPath, 'selftest.json');
    final report = <String, dynamic>{
      'startedAt': DateTime.now().toIso8601String(),
      'args': args,
      // isolated profile: never the user's own data (see isSelfTestProfile)
      'dataDir': appSupportDirPath,
      'downloadDir': downloadPath,
      'checks': <Map<String, dynamic>>[],
    };
    final checks = report['checks'] as List<Map<String, dynamic>>;
    var ok = true;

    Future<void> scenario(
      String name,
      Future<Map<String, dynamic>> Function() body,
    ) async {
      final sw = Stopwatch()..start();
      Map<String, dynamic> result;
      try {
        result = await body();
      } catch (e, s) {
        result = {'pass': false, 'error': '$e', 'stack': '$s'};
      }
      result['name'] = name;
      result['ms'] = sw.elapsedMilliseconds;
      ok &= result['pass'] == true;
      checks.add(result);
    }

    if (_arg(args, '--feed') case final mid?) {
      await scenario('feed', () => _feed(int.parse(mid)));
    }
    if (args.contains('--local')) {
      await scenario('localLibrary', _localLibrary);
    }
    if (_arg(args, '--open-local') case final target?) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 15;
      await scenario(
        'openLocal',
        () => _openLocal(target, hold, play: args.contains('--play')),
      );
    }
    if (args.contains('--open-offline')) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 15;
      final tab = int.tryParse(_arg(args, '--tab') ?? '');
      await scenario(
        'openOffline',
        () => _openOffline(hold, tab: tab, play: args.contains('--play')),
      );
    }
    if (_arg(args, '--download') case final bvid?) {
      final qn = int.tryParse(_arg(args, '--qn') ?? '') ?? 80;
      await scenario(
        'download',
        () => _download(bvid, qn, keep: args.contains('--keep')),
      );
    }
    if (_arg(args, '--probe-playback') case final url?) {
      final seconds = int.tryParse(_arg(args, '--probe-secs') ?? '') ?? 20;
      await scenario('probePlayback', () => _probePlayback(url, seconds));
    }
    if (_arg(args, '--asr-download') case final dir?) {
      await scenario('asrDownload', () => _asrDownload(dir));
    }
    if (_arg(args, '--asr') case final source?) {
      await scenario(
        'asr',
        () => _asr(
          source,
          modelDir: _arg(args, '--asr-models'),
          srtOut: _arg(args, '--asr-srt'),
          pcmOut: _arg(args, '--asr-pcm'),
        ),
      );
    }

    report
      ..['pass'] = ok
      ..['finishedAt'] = DateTime.now().toIso8601String();
    await File(out).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    exit(ok ? 0 : 1);
  }

  // ------------------------------------------------------------ scenarios

  /// LibrePili: what the player can actually tell us about how the stream is
  /// arriving, sampled once a second against a real source.
  ///
  /// Automatic quality switching needs a health signal; this reports which
  /// mpv properties exist in media_kit's build and how they move, so the
  /// policy is written against measurements instead of assumptions.
  static Future<Map<String, dynamic>> _probePlayback(
    String url,
    int seconds,
  ) async {
    const names = [
      'cache-speed',
      'demuxer-cache-time',
      'demuxer-cache-duration',
      'paused-for-cache',
      'video-bitrate',
      'audio-bitrate',
    ];
    final player = await Player.create(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
    final native = player;
    final samples = <Map<String, dynamic>>[];
    try {
      native
        ..setProperty('cache', 'yes')
        ..setProperty('cache-secs', '16');
      player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
      await player.open(Media(url));
      for (var i = 0; i < seconds; i++) {
        await Future.delayed(const Duration(seconds: 1));
        samples.add({
          'at': i + 1,
          'position': player.state.position.inMilliseconds,
          'buffer': player.state.buffer.inMilliseconds,
          'buffering': player.state.buffering,
          for (final name in names) name: native.getProperty(name),
        });
      }
    } finally {
      await player.dispose();
    }

    final available = <String>[];
    final missing = <String>[];
    for (final name in names) {
      final any = samples.any(
        (s) => (s[name] as String?)?.isNotEmpty ?? false,
      );
      (any ? available : missing).add(name);
    }
    return {
      'pass': samples.isNotEmpty && available.isNotEmpty,
      'available': available,
      'missing': missing,
      'samples': samples,
    };
  }

  /// LibrePili: fetches the recogniser's models for real, against the real
  /// URLs, into a throwaway directory — the one part of the pipeline whose
  /// failure modes (a dead mirror, a renamed release asset, a tarball whose
  /// member paths moved) only show up against the live internet.
  static Future<Map<String, dynamic>> _asrDownload(String dir) async {
    final store = AsrModelStore(root: Directory(dir));
    final started = DateTime.now();
    var lastLabel = '';
    final steps = <String>[];
    await store.ensureAll(
      onProgress: (p) {
        if (p.label != lastLabel) {
          lastLabel = p.label;
          steps.add(p.label);
        }
      },
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    return {
      'pass': store.isReady,
      'ms': ms,
      'bytes': store.installedBytes(),
      'steps': steps,
      'files': [
        for (final model in AsrModelCatalog.required)
          for (final file in model.files)
            {
              'name': file.name,
              'size': store.fileOf(model, file).existsSync()
                  ? store.fileOf(model, file).lengthSync()
                  : 0,
              'expected': file.size,
            },
      ],
    };
  }

  /// LibrePili: end-to-end on-device transcription over a real file or URL —
  /// libmpv audio extraction, Silero VAD, SenseVoice — with the timings the
  /// benchmarks are compared against.
  static Future<Map<String, dynamic>> _asr(
    String source, {
    String? modelDir,
    String? srtOut,
    String? pcmOut,
  }) async {
    final store = AsrModelStore(
      root: modelDir == null ? null : Directory(modelDir),
    );
    if (!store.isReady) {
      return {
        'pass': false,
        'error': 'models missing under ${store.root.path}',
        'missing': [for (final m in store.missing) m.id],
      };
    }

    final pcm = pcmOut ?? path.join(tmpDirPath, 'asr', 'selftest.pcm');
    final extractStarted = DateTime.now();
    final audio = await AsrAudioExtractor.extract(
      source: source,
      output: pcm,
      referer: HttpString.baseUrl,
      userAgent: BrowserUa.pc,
    );
    final extractMs = DateTime.now().difference(extractStarted).inMilliseconds;

    final transcribeStarted = DateTime.now();
    final cues = <AsrCue>[];
    String? language;
    String? error;
    final transcriber = await AsrTranscriber.start((
      pcmPath: audio.path,
      modelPath: store
          .fileOf(
            AsrModelCatalog.senseVoice,
            AsrModelCatalog.senseVoice.files[0],
          )
          .path,
      tokensPath: store
          .fileOf(
            AsrModelCatalog.senseVoice,
            AsrModelCatalog.senseVoice.files[1],
          )
          .path,
      vadPath: store
          .fileOf(AsrModelCatalog.vad, AsrModelCatalog.vad.files.first)
          .path,
      threads: Pref.asrThreads,
      language: '',
    ));
    await for (final event in transcriber.events) {
      switch (event) {
        case AsrCuesEvent(cues: final batch):
          cues.addAll(batch);
        case AsrLanguageEvent(language: final lang):
          language ??= lang;
        case AsrErrorEvent(message: final message):
          error = message;
        case AsrProgressUpdate():
          break;
      }
    }
    final transcribeMs = DateTime.now()
        .difference(transcribeStarted)
        .inMilliseconds;
    if (srtOut != null && cues.isNotEmpty) {
      await File(srtOut).writeAsString(cues.toSrt());
    }
    if (pcmOut == null) {
      try {
        await File(pcm).delete();
      } catch (_) {}
    }

    return {
      'pass': error == null && cues.isNotEmpty,
      'error': ?error,
      'source': source,
      'audioSeconds': audio.durationSeconds,
      'extractMs': extractMs,
      'transcribeMs': transcribeMs,
      'rtf': audio.durationSeconds == 0
          ? null
          : (extractMs + transcribeMs) / 1000 / audio.durationSeconds,
      'language': language,
      'cueCount': cues.length,
      'cues': [
        for (final cue in cues.take(40))
          {
            'from': cue.from,
            'to': cue.to,
            'content': cue.content,
          },
      ],
    };
  }

  /// Opens a video file / folder with the local player, optionally starts
  /// playback, and reports position, duration and loaded danmaku.
  static Future<Map<String, dynamic>> _openLocal(
    String target,
    int hold, {
    required bool play,
  }) async {
    const heroTag = 'selftest_local';
    PlDanmakuController.lastLoadedCount = -1;
    unawaited(LocalPlayer.open(target, heroTag: heroTag));
    await Future.delayed(const Duration(seconds: 6));
    // read only: getInstance() would raise the player count
    final player = PlPlayerController.instance;
    if (play) {
      // same steps as tapping play on the page (handlePlay)
      final ctr = Get.find<VideoDetailController>(tag: heroTag)
        ..autoPlay = true;
      await ctr.playerInit(autoplay: true);
    }
    await Future.delayed(Duration(seconds: hold));
    final pos = player?.positionInMilliseconds ?? 0;
    return {
      'pass': !play || pos > 0,
      'positionMs': pos,
      // no player (nothing playing): 0, the scripted checks read these as
      // numbers
      'durationMs': player?.durationInMilliseconds ?? 0,
      'danmakuLoaded': PlDanmakuController.lastLoadedCount,
    };
  }

  /// Opens the newest completed download (merged file present) in the
  /// offline player and keeps it on screen for [hold] seconds, so a caller
  /// can screenshot it. Reports which folder extras it should pick up.
  static Future<Map<String, dynamic>> _openOffline(
    int hold, {
    int? tab,
    bool play = false,
  }) async {
    const heroTag = 'selftest_offline';
    final service = Get.find<DownloadService>();
    await service.waitForInitialization;
    final entry = service.downloadList.firstWhereOrNull(
      (e) => e.mergedPath != null && File(e.mergedPath!).existsSync(),
    );
    if (entry == null) {
      return {
        'pass': false,
        'error': 'no completed download with a video file',
      };
    }
    final merged = entry.mergedPath!;
    final folder = Directory(path.dirname(merged));
    final base = path.basenameWithoutExtension(merged);
    final extras = [
      for (final f in folder.listSync().whereType<File>())
        if (path.basename(f.path).startsWith('$base.') &&
            !f.path.endsWith('.mp4'))
          path.basename(f.path).substring(base.length),
    ];
    unawaited(
      PageUtils.toVideoPage(
        aid: entry.avid,
        cid: entry.cid,
        cover: entry.cover,
        title: entry.showTitle,
        isVertical: entry.pageData?.isVertical ?? false,
        extraArguments: {
          'sourceType': SourceType.file,
          'entry': entry,
          'dirPath': entry.entryDirPath,
          'heroTag': heroTag,
        },
      ),
    );
    PlDanmakuController.lastLoadedCount = -1;
    if (play) {
      await Future.delayed(const Duration(seconds: 5));
      final ctr = Get.find<VideoDetailController>(tag: heroTag)
        ..autoPlay = true;
      await ctr.playerInit(autoplay: true);
    }
    String? tabs;
    if (tab != null) {
      await Future.delayed(const Duration(seconds: 5));
      final ctr = Get.find<VideoDetailController>(tag: heroTag);
      tabs = 'tabs=${ctr.tabCtr.length}, showReply=${ctr.showReply}';
      if (tab < ctr.tabCtr.length) ctr.tabCtr.animateTo(tab);
    }
    await Future.delayed(Duration(seconds: hold));
    // read only: getInstance() would raise the player count
    final player = PlPlayerController.instance;
    final detail = Get.find<VideoDetailController>(tag: heroTag);
    return {
      'pass': true,
      'title': entry.showTitle,
      'subtitles': [for (final s in detail.subtitles) s.lan],
      'subtitleIndex': detail.vttSubtitlesIndex.value,
      'extras': extras,
      'tabs': ?tabs,
      if (play) ...{
        'positionMs': player?.positionInMilliseconds ?? 0,
        'durationMs': player?.durationInMilliseconds ?? 0,
        'danmakuLoaded': PlDanmakuController.lastLoadedCount,
      },
    };
  }

  /// Diagnoses the local feed: the web API it uses (searchArchive, WBI) vs
  /// the app API (spaceArchive, app-signed), both anonymous.
  static Future<Map<String, dynamic>> _feed(int mid) async {
    final web = await MemberHttp.searchArchive(mid: mid, pn: 1, ps: 10);
    final app = await MemberHttp.spaceArchive(
      type: ContributeType.video,
      mid: mid,
    );
    final webOk = web is Success<SearchArchiveData>;
    final appOk = app is Success<SpaceArchiveData>;
    return {
      'pass': webOk,
      'mid': mid,
      'web_searchArchive': webOk
          ? 'ok, ${web.response.list?.vlist?.length ?? 0} items'
          : '$web',
      'app_spaceArchive': appOk
          ? 'ok, ${app.response.item?.length ?? 0} items'
          : '$app',
      if (appOk && (app.response.item?.isNotEmpty ?? false))
        'app_first_item': {
          'title': app.response.item!.first.title,
          'bvid': app.response.item!.first.bvid,
          'param': app.response.item!.first.param,
          'ctime': app.response.item!.first.ctime,
          'duration': app.response.item!.first.duration,
        },
    };
  }

  static Future<Map<String, dynamic>> _localLibrary() async {
    const mid = 999999999999; // not a real UP, never collides with user data
    const key = 'av999999999999';
    final steps = <String, bool>{};
    void expect(String step, bool cond) => steps[step] = cond;

    final data = LocalLibrary.buildFavData(
      aid: 999999999999,
      bvid: 'BV_selftest',
      title: 'selftest item',
      durationSec: 3725,
      pubdate: 1700000000,
      mid: mid,
      author: 'selftest',
    );
    try {
      expect('notFollowedInitially', !LocalLibrary.isFollowed(mid));
      expect('followReturnsTrue', await LocalLibrary.toggleFollow(mid));
      expect('isFollowed', LocalLibrary.isFollowed(mid));
      await LocalLibrary.updateFollowInfo(mid, name: 'renamed');
      expect(
        'followInfoUpdated',
        LocalLibrary.followList().any(
          (f) => f.mid == mid && f.name == 'renamed',
        ),
      );
      expect('unfollowReturnsFalse', !await LocalLibrary.toggleFollow(mid));
      expect('notFollowedAfter', !LocalLibrary.isFollowed(mid));

      final folder = await LocalLibrary.createFolder('selftest folder');
      expect(
        'folderCreated',
        LocalLibrary.folders().any((f) => f.id == folder.id),
      );
      await LocalLibrary.renameFolder(folder.id, 'selftest renamed');
      expect(
        'folderRenamed',
        LocalLibrary.folders().any(
          (f) => f.id == folder.id && f.title == 'selftest renamed',
        ),
      );
      final ids = [for (final f in LocalLibrary.folders()) f.id];
      await LocalLibrary.reorderFolders([
        folder.id,
        ...ids.where((e) => e != folder.id),
      ]);
      expect('folderReordered', LocalLibrary.folders().first.id == folder.id);
      await LocalLibrary.reorderFolders(ids); // restore user order

      await LocalLibrary.setFolders(key, data, {folder.id});
      expect('favAdded', LocalLibrary.isFav(key));
      expect('favInFolder', LocalLibrary.folderCount(folder.id) == 1);
      final item = LocalLibrary.folderItems(folder.id).single.toVideoItem();
      expect('favItemTitle', item.title == 'selftest item');
      expect('favItemDuration', item.duration == 3725);
      expect('favItemPubdate', item.pubdate == 1700000000);

      await LocalLibrary.deleteFolder(folder.id);
      expect(
        'folderDeleted',
        !LocalLibrary.folders().any((f) => f.id == folder.id),
      );
      expect('favRemovedWithFolder', !LocalLibrary.isFav(key));
      expect(
        'defaultFolderKept',
        LocalLibrary.folders().any((f) => f.id == LocalLibrary.defaultFolderId),
      );
    } finally {
      // never leave test data behind
      await LocalLibrary.unfollow(mid);
      await LocalLibrary.setFolders(key, data, {});
      for (final f in LocalLibrary.folders()) {
        if (f.title.startsWith('selftest')) {
          await LocalLibrary.deleteFolder(f.id);
        }
      }
    }
    return {'pass': steps.values.every((e) => e), 'steps': steps};
  }

  static Future<Map<String, dynamic>> _download(
    String bvid,
    int qn, {
    required bool keep,
  }) async {
    final service = Get.find<DownloadService>();
    await service.waitForInitialization;

    // `hot`: first video of the current popular list, so the test does not
    // depend on one video staying online
    if (bvid == 'hot') {
      final hot = await VideoHttp.hotVideoList(pn: 1, ps: 10);
      final picked = hot is Success<List<HotVideoItemModel>>
          ? hot.response.firstWhereOrNull((e) => e.bvid != null)?.bvid
          : null;
      if (picked == null) {
        return {'pass': false, 'error': 'hot list failed: $hot'};
      }
      bvid = picked;
    }
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (res is! Success<VideoDetailData>) {
      return {'pass': false, 'error': 'videoIntro failed: $res'};
    }
    final detail = res.response;
    final page = detail.pages!.first;
    final cid = page.cid!;

    // start from a clean state
    for (final e in [...service.downloadList, ...service.waitDownloadQueue]) {
      if (e.cid == cid) {
        await service.deleteDownload(
          entry: e,
          removeList: true,
          removeQueue: true,
          deleteExported: true,
        );
      }
    }

    final quality = VideoQuality.fromCode(qn);
    service.downloadVideo(page, detail, null, quality);

    final statuses = <String>[];
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    BiliDownloadEntryInfo? done;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
      final cur = service.curDownload.value;
      if (cur != null && cur.cid == cid) {
        final s = cur.status.name;
        if (statuses.isEmpty || statuses.last != s) statuses.add(s);
        if (s.startsWith('fail')) {
          return {
            'pass': false,
            'error': 'download status $s: ${service.lastError}',
            'statuses': statuses,
          };
        }
      }
      done = service.downloadList.firstWhereOrNull((e) => e.cid == cid);
      if (done != null) break;
    }
    if (done == null) {
      return {'pass': false, 'error': 'timeout', 'statuses': statuses};
    }

    // extras run after completion: let them finish so the folder report
    // includes them (deleting below would cancel them anyway)
    await service
        .extrasDone(cid)
        ?.timeout(const Duration(minutes: 5), onTimeout: () {});
    final merged = done.mergedPath;
    final mergedFile = merged == null ? null : File(merged);
    final streamDir = path.join(done.entryDirPath, done.streamTypeTag);
    final leftovers = [
      PathUtils.videoNameType2,
      PathUtils.audioNameType2,
      PathUtils.videoNameType1,
    ].where((n) => File(path.join(streamDir, n)).existsSync()).toList();
    final entryJson = File(path.join(done.entryDirPath, 'entry.json'));
    final savedMergedPath = entryJson.existsSync()
        ? (jsonDecode(await entryJson.readAsString()) as Map)['merged_path']
        : null;

    final result = <String, dynamic>{
      'bvid': bvid,
      'cid': cid,
      'quality': done.qualityPithyDescription,
      'statuses': statuses,
      'mergedPath': merged,
      'mergedExists': mergedFile?.existsSync() ?? false,
      'mergedBytes': mergedFile?.existsSync() == true
          ? mergedFile!.lengthSync()
          : 0,
      'downloadedBytes': done.totalBytes,
      'streamLeftovers': leftovers,
      'entryJsonMergedPath': savedMergedPath,
      'entryDir': done.entryDirPath,
      // per-video folder contents (video + danmaku / subtitles / comments)
      if (merged != null)
        'folderFiles': {
          for (final f in Directory(path.dirname(merged)).listSync())
            if (f is File) path.basename(f.path): f.lengthSync(),
        },
    };
    result['pass'] =
        merged != null &&
        result['mergedExists'] == true &&
        (result['mergedBytes'] as int) > 0 &&
        leftovers.isEmpty &&
        savedMergedPath == merged;

    if (!keep) {
      await service.deleteDownload(
        entry: done,
        removeList: true,
        deleteExported: true,
      );
      result['cleanedUp'] = !(mergedFile?.existsSync() ?? false);
    }
    return result;
  }
}
