import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:file_picker/file_picker.dart';
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
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: videoExtensions.toList(),
    );
    final file = res.firstOrNull?.path;
    if (file != null) await open(file);
  }

  /// Asks for a (downloaded) video folder and opens it.
  static Future<void> pickFolder() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir != null) await open(dir);
  }

  /// Opens a video file or a folder containing one. Returns false (and
  /// shows a toast) when nothing playable is found.
  static Future<bool> open(String target, {String? heroTag}) async {
    final video = _findVideo(target);
    if (video == null) {
      SmartDialog.showToast('没有找到可播放的视频文件');
      return false;
    }
    final entry = _entryFor(video);
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
    return true;
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
  static BiliDownloadEntryInfo _entryFor(File video) {
    final folder = path.dirname(video.path);
    BiliDownloadEntryInfo? entry;
    final info = File(path.join(folder, DownloadExtras.infoName));
    if (info.existsSync()) {
      try {
        entry = BiliDownloadEntryInfo.fromJson(
          jsonDecode(info.readAsStringSync()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    entry ??= _plainEntry(video);
    return entry
      ..mergedPath = video.path
      ..isCompleted = true
      ..entryDirPath = folder
      ..pageDirPath = path.dirname(folder);
  }

  static BiliDownloadEntryInfo _plainEntry(File video) {
    final title = path.basenameWithoutExtension(video.path);
    final size = video.lengthSync();
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
