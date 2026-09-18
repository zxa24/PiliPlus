import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_library.dart';
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

  /// Schedules the run once the first frame is on screen. Writes a
  /// `started` marker right away so a caller can tell "app never started"
  /// from "test still running".
  static void schedule(List<String> args) {
    if (_arg(args, '--out') case final out?) {
      File(out).writeAsStringSync(jsonEncode({'stage': 'started'}));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () => _run(args));
    });
  }

  static Future<void> _run(List<String> args) async {
    final out = _arg(args, '--out') ?? path.join(tmpDirPath, 'selftest.json');
    final report = <String, dynamic>{
      'startedAt': DateTime.now().toIso8601String(),
      'args': args,
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

    if (args.contains('--local')) {
      await scenario('localLibrary', _localLibrary);
    }
    if (_arg(args, '--download') case final bvid?) {
      final qn = int.tryParse(_arg(args, '--qn') ?? '') ?? 80;
      await scenario(
        'download',
        () => _download(bvid, qn, keep: args.contains('--keep')),
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
            'error': 'download status $s',
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

    final merged = done.mergedPath;
    final mergedFile = merged == null ? null : File(merged);
    final streamDir = path.join(done.entryDirPath, done.typeTag);
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
    };
    result['pass'] =
        merged != null &&
        result['mergedExists'] == true &&
        (result['mergedBytes'] as int) > 0 &&
        leftovers.isEmpty &&
        savedMergedPath == merged;

    if (!keep) {
      await service.deleteDownload(entry: done, removeList: true);
      result['cleanedUp'] = !(mergedFile?.existsSync() ?? false);
    }
    return result;
  }
}
