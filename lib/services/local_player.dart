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
    await _openDocument(entry, mirror: mirror, video: doc);
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
          (uri: f.uri, path: path.join(mirror, CommentImages.dirName, f.name)),
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
  }

  static Future<void> _openDocument(
    BiliDownloadEntryInfo entry, {
    required String mirror,
    required LocalDocument video,
  }) {
    entry
      ..mergedPath = path.join(mirror, video.name)
      ..playUri = video.uri
      ..playKey = video.key
      ..isCompleted = true
      ..entryDirPath = mirror
      ..pageDirPath = path.dirname(mirror);
    _mirrorsInUse.update(mirror, (n) => n + 1, ifAbsent: () => 1);
    return _toVideoPage(entry);
  }

  /// Cache folders shown by a video page that is still open (count per
  /// folder): kept until that page closes ([release]).
  static final _mirrorsInUse = <String, int>{};

  /// Cache folder for one document's side files. Folders no open page
  /// shows are removed here (on the next open); this one is refilled.
  static Future<String> _mirrorDir(String key) async {
    final root = Directory(path.join(tmpDirPath, 'local_documents'));
    final dir = Directory(
      path.join(root.path, md5.convert(utf8.encode(key)).toString()),
    );
    if (root.existsSync()) {
      for (final e in root.listSync()) {
        if (_mirrorsInUse.containsKey(e.path)) continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
    await dir.create(recursive: true);
    return dir.path;
  }

  /// The video page showing [entry] closed: its side-file cache folder
  /// goes once no other open page shows it.
  static void release(BiliDownloadEntryInfo entry) {
    if (entry.playUri == null) return;
    final dir = entry.entryDirPath;
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
    if (info.existsSync()) {
      try {
        entry = BiliDownloadEntryInfo.fromJson(
          jsonDecode(info.readAsStringSync()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    entry ??= _plainEntry(path.basenameWithoutExtension(video), size);
    return entry
      ..mergedPath = video
      ..isCompleted = true
      ..entryDirPath = folder
      ..pageDirPath = path.dirname(folder);
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
