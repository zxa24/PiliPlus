import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path/path.dart' as path;

/// A document reached through the Storage Access Framework (Android).
class LocalDocument {
  const LocalDocument({
    required this.name,
    required this.uri,
    this.size = 0,
    this.isDir = false,
    this.docId,
    this.key,
    this.mime,
  });

  final String name;

  /// `content://` URI, readable through the grant the user gave.
  final String uri;
  final int size;
  final bool isDir;

  /// Document id inside the granted tree (folders: to list their children).
  final String? docId;

  /// Stable identity (provider + document id), for progress / cache keys.
  final String? key;

  factory LocalDocument.fromMap(Map map) => LocalDocument(
    name: safeName(map['name'] as String? ?? ''),
    uri: map['uri'] as String,
    size: (map['size'] as num?)?.toInt() ?? 0,
    isDir: map['isDir'] as bool? ?? false,
    docId: map['docId'] as String?,
    key: map['key'] as String?,
    mime: map['mime'] as String?,
  );

  /// MIME type reported by the provider (picked files only).
  final String? mime;

  /// A provider's display name as a single path segment: names are joined
  /// into cache paths, so separators and `.` / `..` must not survive.
  static String safeName(String name) {
    final s = name.replaceAll(RegExp(r'[/\\\x00]'), '_');
    return s.isEmpty || s == '.' || s == '..' ? '_' : s;
  }
}

/// The video of a folder and the side files that belong to it.
class LocalFolderMatch {
  const LocalFolderMatch({
    required this.video,
    required this.sideFiles,
    this.imagesDir,
  });

  final LocalDocument video;

  /// Small files read next to the video (download record, cover, danmaku,
  /// subtitles, comments).
  final List<LocalDocument> sideFiles;

  /// `comments_images/`, when the folder has saved comments.
  final LocalDocument? imagesDir;
}

/// LibrePili: Android access to a video file / folder the user picked, read
/// through the system grant (no storage permission, no copy of the video).
abstract final class LocalDocuments {
  static const _channel = MethodChannel('librepili/media');

  /// Lets the user pick a video file; null when cancelled.
  static Future<LocalDocument?> pickFile() async {
    final res = await _channel.invokeMapMethod<String, Object?>(
      'pickVideoFile',
    );
    return res == null ? null : LocalDocument.fromMap(res);
  }

  /// Lets the user grant a folder; returns its children, null when
  /// cancelled.
  static Future<({String treeUri, List<LocalDocument> children})?>
  pickFolder() async {
    final res = await _channel.invokeMapMethod<String, Object?>(
      'pickVideoFolder',
    );
    if (res == null) return null;
    return (
      treeUri: res['uri'] as String,
      children: _docs(res['children']),
    );
  }

  /// Children of the folder [docId] inside the granted tree [treeUri].
  static Future<List<LocalDocument>> list(String treeUri, String docId) async =>
      _docs(
        await _channel.invokeListMethod<Object?>('listTree', {
          'uri': treeUri,
          'docId': docId,
        }),
      );

  /// Copies small documents to local files (`uri` -> `path`); returns how
  /// many were copied. Never used for the video itself.
  static Future<int> copy(List<({String uri, String path})> items) async {
    if (items.isEmpty) return 0;
    try {
      return await _channel.invokeMethod<int>('copyDocuments', {
            'items': [
              for (final i in items) {'uri': i.uri, 'path': i.path},
            ],
          }) ??
          0;
    } catch (e) {
      if (kDebugMode) debugPrint('copy documents: $e');
      return 0;
    }
  }

  /// A read-only file descriptor of [uri] for the player (`fdclose://<fd>`
  /// hands it to mpv, which closes it). Null if it cannot be opened.
  static Future<int?> openFd(String uri) async {
    try {
      final fd = await _channel.invokeMethod<int>('openFd', {'uri': uri});
      return fd == null || fd < 0 ? null : fd;
    } catch (e) {
      if (kDebugMode) debugPrint('open fd: $e');
      return null;
    }
  }

  /// Closes a descriptor from [openFd] that the player did not take.
  static Future<void> closeFd(int fd) async {
    try {
      await _channel.invokeMethod<void>('closeFd', {'fd': fd});
    } catch (e) {
      if (kDebugMode) debugPrint('close fd: $e');
    }
  }

  static List<LocalDocument> _docs(Object? list) => [
    for (final e in (list as List?) ?? const [])
      if (e is Map) LocalDocument.fromMap(e),
  ];

  /// Picks the video of a folder (the largest video file, as on desktop)
  /// and the side files written next to it by a LibrePili download or by
  /// other tools: `librepili.json`, `cover.jpg`, `<base>.danmaku.xml` /
  /// `<base>.xml`, `<base>.<lan>.srt`, `<base>.comments.json` and its
  /// `comments_images/` folder.
  static LocalFolderMatch? match(
    List<LocalDocument> children, {
    required bool Function(String name) isVideo,
  }) {
    final videos = children.where((e) => !e.isDir && isVideo(e.name)).toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    final video = videos.firstOrNull;
    if (video == null) return null;
    final base = path.basenameWithoutExtension(video.name);
    bool isSide(String name) =>
        name == DownloadExtras.infoName ||
        name == DownloadExtras.coverName ||
        name == '$base${DownloadExtras.xmlSuffix}' ||
        name == '$base.xml' ||
        name == '$base${DownloadExtras.commentsSuffix}' ||
        (name.startsWith('$base.') && name.endsWith('.srt'));
    final sideFiles = [
      for (final e in children)
        if (!e.isDir && isSide(e.name)) e,
    ];
    final hasComments = sideFiles.any(
      (e) => e.name == '$base${DownloadExtras.commentsSuffix}',
    );
    return LocalFolderMatch(
      video: video,
      sideFiles: sideFiles,
      imagesDir: hasComments
          ? children
                .where((e) => e.isDir && e.name == CommentImages.dirName)
                .firstOrNull
          : null,
    );
  }
}
