import 'dart:io' show Directory, Platform, Process;

import 'package:PiliPlus/common/constants.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

late final String tmpDirPath;

late final String appSupportDirPath;

late String downloadPath;

/// LibrePili: set for `--selftest`. App data (Hive boxes, webview data) and
/// downloads then live in a separate `selftest` folder, so the self test
/// never reads or deletes the user's own data.
bool isSelfTestProfile = false;

String get defDownloadPath =>
    path.join(appSupportDirPath, PathUtils.downloadDir);

/// Temp directory owned by this app. On desktop the system temp dir is
/// shared by every app, so use a per-app subfolder: otherwise caches that
/// hold file locks (e.g. the image cache's Hive box) collide with the
/// original PiliPlus when both run at once.
Future<Directory> appTempDirectory() async {
  final dir = await getTemporaryDirectory();
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return dir;
  }
  return Directory(path.join(dir.path, Constants.appName)).create(
    recursive: true,
  );
}

abstract final class PathUtils {
  static const videoNameType1 = '0.mp4';

  /// Segment [index] of an old single-URL (durl) stream; segment 0 is
  /// [videoNameType1]. The content may be FLV despite the name.
  static String segmentNameType1(int index) => '$index.mp4';
  static const _fileExt = '.m4s';
  static const audioNameType2 = 'audio$_fileExt';
  static const videoNameType2 = 'video$_fileExt';
  static const coverName = 'cover.jpg';
  static const danmakuName = 'danmaku.pb';
  static const downloadDir = 'download';

  static String buildShadersAbsolutePath(
    String baseDirectory,
    List<String> shaders,
  ) {
    return shaders
        .map((shader) => path.join(baseDirectory, shader))
        .join(Platform.isWindows ? ';' : ':');
  }

  static Future<void> openDir(String dirPath) async {
    try {
      final String executable;
      if (Platform.isWindows) {
        executable = 'explorer';
      } else if (Platform.isMacOS) {
        executable = 'open';
      } else if (Platform.isLinux) {
        executable = 'xdg-open';
      } else {
        throw UnimplementedError();
      }
      await Process.run(executable, [dirPath]);
    } catch (e) {
      SmartDialog.showToast(e.toString());
    }
  }
}
