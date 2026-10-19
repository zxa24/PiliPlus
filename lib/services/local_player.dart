import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/local_documents.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as path;

/// LibrePili: plays local videos with the offline player. A folder written
/// by a LibrePili download (see [DownloadExtras]) also brings its danmaku,
/// subtitles and comments; any other video file just plays.
abstract final class LocalPlayer {
  static const videoExtensions = {
    'mp4',
    'mkv',
    'webm',
    'mov',
    'm4v',
    'flv',
    'avi',
    'ts',
    'wmv',
  };

  static bool isVideo(String file) => videoExtensions.contains(
    path.extension(file).replaceFirst('.', '').toLowerCase(),
  );

  /// Asks for a video file and opens it.
  static Future<void> pickFile() async {
    if (Platform.isAndroid) return _pickDocument();
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: videoExtensions.toList(),
    );
    final file = res.firstOrNull?.path;
    if (file != null) await open(file);
  }

  /// Asks for a (downloaded) video folder and opens it.
  static Future<void> pickFolder() async {
    if (Platform.isAndroid) return _pickTree();
    final dir = await FilePicker.getDirectoryPath();
    if (dir != null) await open(dir);
  }

  // ------------------------------------------------ Android (system grant)
  //
  // Without storage permission a path cannot see files the user granted,
  // and file_picker would copy the whole video into the cache. Instead the
  // video is played from its content:// URI; only the small side files are
  // copied into a per-video cache folder, where the existing loaders
  // (danmaku, subtitles, comments, cover) find them next to `mergedPath`.

  /// Picks one video file. Android grants no access to the files next to
  /// it, so danmaku / subtitles / comments need the folder picker.
  static Future<void> _pickDocument() async {
    final LocalDocument? doc;
    try {
      doc = await LocalDocuments.pickFile();
    } catch (e) {
      SmartDialog.showToast('无法打开文件选择器: $e');
      return;
    }
    if (doc == null) return;
    // the picker also offers untyped files (MKV / FLV some providers do not
    // label as video)
    if (!isVideo(doc.name) && !(doc.mime?.startsWith('video/') ?? false)) {
      SmartDialog.showToast('不是可播放的视频文件');
      return;
    }
    final mirror = await _mirrorDir(doc.key ?? doc.uri);
    final entry = _plainEntry(
      path.basenameWithoutExtension(doc.name),
      doc.size,
    );
    try {
      await _openDocument(entry, mirror: mirror, video: doc, mirrored: false);
    } finally {
      release(mirror);
    }
    SmartDialog.showToast('Android 上单个文件无法读取同目录的弹幕/字幕/评论，请用「打开视频文件夹」');
  }

  /// Picks a folder (e.g. one exported by a LibrePili download).
  static Future<void> _pickTree() async {
    final ({String treeUri, List<LocalDocument> children})? tree;
    try {
      tree = await LocalDocuments.pickFolder();
    } catch (e) {
      SmartDialog.showToast('无法打开文件夹选择器: $e');
      return;
    }
    if (tree == null) return;
    final match = LocalDocuments.match(tree.children, isVideo: isVideo);
    if (match == null) {
      SmartDialog.showToast('没有找到可播放的视频文件');
      return;
    }
    final video = match.video;
    final mirror = await _mirrorDir(video.key ?? video.uri);
    try {
      final images = match.imagesDir;
      var imageFiles = const <LocalDocument>[];
      if (images?.docId case final docId?) {
        try {
          imageFiles = await LocalDocuments.list(tree.treeUri, docId);
        } catch (e) {
          // comments still load, just without their pictures
          if (kDebugMode) debugPrint('list comment images: $e');
        }
      }
      await LocalDocuments.copy([
        for (final f in match.sideFiles)
          (uri: f.uri, path: path.join(mirror, f.name)),
        for (final f in imageFiles)
          if (!f.isDir)
            (
              uri: f.uri,
              path: path.join(mirror, CommentImages.dirName, f.name),
            ),
      ]);
      await _openDocument(
        _entryFor(
          folder: mirror,
          video: path.join(mirror, video.name),
          size: video.size,
        ),
        mirror: mirror,
        video: video,
      );
    } finally {
      release(mirror);
    }
  }

  static Future<void> _openDocument(
    BiliDownloadEntryInfo entry, {
    required String mirror,
    required LocalDocument video,
    // whether side files were copied into [mirror]: they are named after the
    // video, so `mergedPath` anchors them there. With nothing mirrored it
    // would only name a file that does not exist (the video plays from its
    // URI), so it stays null.
    bool mirrored = true,
  }) async {
    entry
      ..mergedPath = mirrored ? path.join(mirror, video.name) : null
      ..playUri = video.uri
      ..playKey = video.key
      ..isCompleted = true
      ..entryDirPath = mirror
      ..pageDirPath = path.dirname(mirror);
    // held only for the navigation: the page itself takes its own count
    // ([VideoDetailController.initFileSource]), so a `toVideoPage` that
    // returns without ever building a controller cannot leave the folder
    // counted for the rest of the session
    retain(mirror);
    try {
      await _toVideoPage(entry);
    } finally {
      release(mirror);
    }
  }

  /// Cache folders shown by a video page that is still open (count per
  /// folder): kept until that page closes ([release]).
  static final _mirrorsInUse = <String, int>{};

  /// Cache folder for one document's side files. Folders no open page
  /// shows are removed here (on the next open); this one is refilled.
  /// It is returned retained (the caller [release]s it once the page has
  /// taken its own count): an open running at the same time, still copying
  /// or not yet on its page, must not have its folder removed by this one.
  static Future<String> _mirrorDir(String key) async {
    final root = Directory(path.join(tmpDirPath, 'local_documents'));
    final dir = Directory(
      path.join(root.path, md5.convert(utf8.encode(key)).toString()),
    );
    final wasInUse = _mirrorsInUse.containsKey(dir.path);
    retain(dir.path);
    if (root.existsSync()) {
      for (final e in root.listSync()) {
        if (_mirrorsInUse.containsKey(e.path) &&
            (e.path != dir.path || wasInUse)) {
          continue;
        }
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
    try {
      await dir.create(recursive: true);
    } catch (_) {
      release(dir.path);
      rethrow;
    }
    return dir.path;
  }

  /// Removes every cached side-file mirror, the ones an open page still
  /// shows included: 重置所有数据 must not leave copies of the user's picked
  /// documents behind. Folders are recreated on the next open.
  static Future<void> clearMirrors() async {
    _mirrorsInUse.clear();
    final root = Directory(path.join(tmpDirPath, 'local_documents'));
    try {
      if (root.existsSync()) await root.delete(recursive: true);
    } catch (_) {}
  }

  /// A video page now shows the picked document in [dir]: its side-file
  /// cache folder is kept until that page releases it again.
  static void retain(String? dir) {
    if (dir == null) return;
    _mirrorsInUse.update(dir, (n) => n + 1, ifAbsent: () => 1);
  }

  /// The video page showing a picked document closed: its side-file cache
  /// folder goes once no other open page shows it. [dir] is the folder
  /// captured when the document was opened — the page's entry may since
  /// have been replaced by a playlist item that has no mirror.
  static void release(String? dir) {
    if (dir == null) return;
    final n = (_mirrorsInUse[dir] ?? 1) - 1;
    if (n > 0) {
      _mirrorsInUse[dir] = n;
      return;
    }
    _mirrorsInUse.remove(dir);
    Directory(dir).delete(recursive: true).catchError((_) => Directory(dir));
  }

  /// Opens a video file or a folder containing one. Returns false (and
  /// shows a toast) when nothing playable is found.
  static Future<bool> open(String target, {String? heroTag}) async {
    final video = _findVideo(target);
    if (video == null) {
      SmartDialog.showToast('没有找到可播放的视频文件');
      return false;
    }
    final entry = _entryFor(
      folder: path.dirname(video.path),
      video: video.path,
      size: video.lengthSync(),
    );
    await _toVideoPage(entry, heroTag: heroTag);
    return true;
  }

  static Future<void> _toVideoPage(
    BiliDownloadEntryInfo entry, {
    String? heroTag,
  }) async {
    await PageUtils.toVideoPage(
      aid: entry.avid,
      cid: entry.cid,
      cover: entry.cover,
      title: entry.showTitle,
      extraArguments: {
        'sourceType': SourceType.file,
        'entry': entry,
        'dirPath': entry.entryDirPath,
        'heroTag': ?heroTag,
      },
    );
  }

  static File? _findVideo(String target) {
    if (FileSystemEntity.isFileSync(target)) {
      return isVideo(target) ? File(target) : null;
    }
    final dir = Directory(target);
    if (!dir.existsSync()) return null;
    final videos =
        dir.listSync().whereType<File>().where((f) => isVideo(f.path)).toList()
          ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
    return videos.firstOrNull;
  }

  /// The saved download record when present (LibrePili folder), otherwise a
  /// minimal record built from the file itself.
  static BiliDownloadEntryInfo _entryFor({
    required String folder,
    required String video,
    required int size,
  }) {
    BiliDownloadEntryInfo? entry;
    final info = File(path.join(folder, DownloadExtras.infoName));
    if (info.existsSync() && _isRecordOf(folder, video)) {
      try {
        final parsed = BiliDownloadEntryInfo.fromJson(
          jsonDecode(info.readAsStringSync()) as Map<String, dynamic>,
        );
        // `cid` and `sortKey` read `pageData!` when there is no `source`: a
        // record with neither (written by another tool) parses but throws on
        // the very next step, so it is treated like a foreign file
        if (parsed.source != null || parsed.pageData != null) {
          entry = parsed;
        }
      } catch (_) {}
    }
    entry ??= _plainEntry(path.basenameWithoutExtension(video), size);
    return entry
      ..mergedPath = video
      ..isCompleted = true
      ..entryDirPath = folder
      ..pageDirPath = path.dirname(folder);
  }

  /// Whether the record in [folder] is [video]'s own: another video in
  /// that folder must not take its cid, title and resume key (its
  /// transcript would be kept under the download's). The record does not
  /// name its file, but the intro written beside it is `<base>.intro.json`,
  /// as the video is `<base>.mp4` (`<base>.2.flv`, ... for segments). A
  /// folder without an intro (it could not be saved) is taken as before.
  static bool _isRecordOf(String folder, String video) {
    final intros = Directory(folder).existsSync()
        ? Directory(folder)
              .listSync()
              .map((e) => path.basename(e.path))
              .where((n) => n.endsWith(DownloadExtras.introSuffix))
              .toList()
        : const <String>[];
    if (intros.isEmpty) return true;
    final name = path.basenameWithoutExtension(video);
    final base = name.replaceFirst(RegExp(r'\.\d+$'), '');
    return intros.contains('$name${DownloadExtras.introSuffix}') ||
        intros.contains('$base${DownloadExtras.introSuffix}');
  }

  static BiliDownloadEntryInfo _plainEntry(String title, int size) {
    return BiliDownloadEntryInfo(
      mediaType: 2,
      isCompleted: true,
      totalBytes: size,
      downloadedBytes: size,
      title: title,
      typeTag: '80',
      cover: '',
      preferedVideoQuality: 80,
      qualityPithyDescription: '本地视频',
      guessedTotalBytes: size,
      totalTimeMilli: 0,
      danmakuCount: 0,
      avid: 0,
      bvid: '',
      pageData: PageInfo(
        cid: 0,
        page: 1,
        part: title,
        hasAlias: false,
        tid: 0,
        width: 0,
        height: 0,
        rotate: 0,
        downloadTitle: title,
        downloadSubtitle: title,
      ),
    );
  }
}
