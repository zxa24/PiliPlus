/// LibrePili: bring a PiliPlus installation's preferences across.
///
/// The fork has its own application id, so it has its own data directory and
/// starts with an empty settings box. That is correct — two apps must not
/// share one profile — but it means every preference someone had set in
/// PiliPlus silently reverts to its default here, and defaults are invisible:
/// the 字号 slider reads 1.00 because nothing was ever written, which looks
/// exactly like "this app renders smaller than the other one".
///
/// Desktop only. On Android the other app's data lives under its own uid in
/// `/data/data/...`, which is unreadable without root, so there is nothing
/// to offer.
library;

import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

class SettingsImportResult {
  const SettingsImportResult({required this.imported, required this.skipped});

  final int imported;
  final int skipped;
}

abstract final class SettingsImport {
  /// Keys that must not travel: these describe *this* installation rather
  /// than a preference, and copying them makes the app point at the other
  /// app's files or claim its state. (The credentials and device keys of
  /// [GStorage] are left out as well, see [run].)
  static const _notPreferences = {
    'downloadPath',
    'appFont', // a path to a font file inside the other app's directory
    'lastCheckUpdateTime',
    'accessKeyInfo',
    'userInfoCache',
  };

  /// Where PiliPlus keeps its data, relative to a parent of ours.
  static final _otherDirs = Platform.isWindows
      ? const [
          ['com.example', 'piliplus'],
        ]
      : [
          const ['com.example.piliplus'],
          if (!Platform.isMacOS) const ['piliplus'],
        ];

  /// The PiliPlus settings box, if one is there.
  ///
  /// On Windows our support directory is `<vendor>/<product>` and
  /// PiliPlus's is `com.example/piliplus`, a sibling two levels up; on Linux
  /// and macOS it is named by the application id, `com.example.piliplus`
  /// (Linux: or, from older builds, the executable name `piliplus`), a
  /// sibling one level up. Derived rather than hardcoded to an absolute path
  /// so it follows wherever the platform puts application support. (A
  /// sandboxed macOS build cannot read another app's container: nothing is
  /// found there.)
  static File? findBox() {
    if (!PlatformUtils.isDesktop) return null;
    // Walked up rather than computed: our own support path is
    // `<root>/<vendor>/<product>` normally but `<root>/<vendor>/<product>/
    // selftest` under --selftest, so a fixed number of `.parent`s is right
    // for one profile and silently wrong for the other.
    var dir = Directory(appSupportDirPath);
    for (var i = 0; i < 4; i++) {
      for (final other in _otherDirs) {
        final file = File(
          path.joinAll([dir.path, ...other, 'hive', 'setting.hive']),
        );
        if (file.existsSync()) return file;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Copies every preference from that box into ours, leaving anything
  /// already set here alone only when [overwrite] is false.
  ///
  /// The box is opened from its own directory under a distinct name, so the
  /// running app's own `setting` box is untouched by the read.
  static Future<SettingsImportResult> run({bool overwrite = true}) async {
    final file = findBox();
    if (file == null) {
      return const SettingsImportResult(imported: 0, skipped: 0);
    }
    // a copy, because Hive writes a lock/compaction file beside the box it
    // opens and the other app's directory is not ours to write in
    final temp = await appTempDirectory();
    final copyDir = await Directory(
      path.join(temp.path, 'import'),
    ).create(recursive: true);
    final copy = File(path.join(copyDir.path, 'piliplusImport.hive'));
    await file.copy(copy.path);

    var imported = 0;
    var skipped = 0;
    Box<dynamic>? box;
    try {
      box = await Hive.openBox<dynamic>(
        'piliplusImport',
        path: copyDir.path,
      );
      final values = <String, dynamic>{};
      for (final key in box.keys) {
        if (key is! String ||
            _notPreferences.contains(key) ||
            // this device's credentials, paths and login opt-in: the
            // dialog promises 不含账号, and the JSON import keeps them too
            GStorage.credentialKeys.contains(key) ||
            GStorage.deviceKeys.contains(key) ||
            key == SettingBoxKey.loginMode) {
          skipped++;
          continue;
        }
        if (!overwrite && GStorage.setting.containsKey(key)) {
          skipped++;
          continue;
        }
        values[key] = box.get(key);
      }
      // a value of another kind than this device's (a String where a number
      // is read, ...) would throw wherever the getter casts it
      final mismatched = GStorage.mismatched(GStorage.setting, values);
      skipped += mismatched.length;
      values.removeWhere((key, _) => mismatched.containsKey(key));
      if (values.isNotEmpty) {
        // like every other import path, so 恢复到导入前 can undo it
        await GStorage.saveSnapshot();
        await GStorage.setting.putAll(values);
        imported = values.length;
      }
    } finally {
      await box?.close();
      try {
        await copyDir.delete(recursive: true);
      } catch (_) {}
    }
    return SettingsImportResult(imported: imported, skipped: skipped);
  }
}
