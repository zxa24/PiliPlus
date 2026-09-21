import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/user/danmaku_rule_adapter.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:PiliPlus/utils/accounts/account_type_adapter.dart';
import 'package:PiliPlus/utils/accounts/cookie_jar_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/set_int_adapter.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

abstract final class GStorage {
  static late final Box<UserInfoData> userInfo;
  static late final Box<dynamic> historyWord;
  static late final Box<dynamic> localCache;
  static late final Box<dynamic> setting;
  static late final Box<dynamic> video;
  static late final Box<int> watchProgress;
  static late final Box<Uint8List>? reply;

  static Future<void> init() async {
    Hive.init(path.join(appSupportDirPath, 'hive'));
    regAdapter();

    await Future.wait([
      // 登录用户信息
      Hive.openBox<UserInfoData>(
        'userInfo',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 2;
        },
      ).then((res) => userInfo = res),
      // 本地缓存
      Hive.openBox(
        'localCache',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => localCache = res),
      // 设置
      Hive.openBox('setting').then((res) => setting = res),
      // 搜索历史
      Hive.openBox(
        'historyWord',
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 10;
        },
      ).then((res) => historyWord = res),
      // 视频设置
      Hive.openBox('video').then((res) => video = res),
      Accounts.init(),
      LocalLibrary.init(),
      YtSubscriptions.init(),
      Hive.openBox<int>(
        'watchProgress',
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => watchProgress = res),
    ]);

    await _capLocalProgress();

    if (Pref.saveReply) {
      reply = await Hive.openBox<Uint8List>(
        'reply',
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 10;
        },
      );
    } else {
      reply = null;
    }
  }

  /// How many resume points for local files [watchProgress] keeps.
  static const _maxLocalProgress = 500;

  /// Resume points for downloads are keyed by cid and pruned when the
  /// download goes, but those for plain local files / picked documents are
  /// keyed by a hash of the path (`f…` / `u…`, see the video controller's
  /// `_progressKey`): nothing can tell from the key whether the target
  /// still exists, and renaming or moving a file leaves its row behind for
  /// good. Cap them so the box cannot grow with every file ever opened.
  /// The box is key-ordered ([_intStrDescKeyComparator] puts the cid rows
  /// first), so this is a stable subset rather than a random one.
  static Future<void> _capLocalProgress() async {
    final hashed = [
      for (final key in watchProgress.keys)
        if (key is String) key,
    ];
    if (hashed.length <= _maxLocalProgress) return;
    await watchProgress.deleteAll(hashed.skip(_maxLocalProgress));
  }

  /// Setting keys that are credentials of this device: left out of an
  /// export unless asked for, and kept on import unless the user agrees.
  static const credentialKeys = [
    SettingBoxKey.webdavUsername,
    SettingBoxKey.webdavPassword,
    SettingBoxKey.blockUserID,
  ];

  /// Whether a backup [map] carries any of the [credentialKeys].
  static bool hasCredentials(Map<String, dynamic> map) {
    final settingMap = map[setting.name];
    return settingMap is Map && credentialKeys.any(settingMap.containsKey);
  }

  static String exportAllSettings({bool includeCredentials = false}) {
    return Utils.jsonEncoder.convert({
      setting.name: {
        for (final e in setting.toMap().entries)
          // login mode is a per-device opt-in, never part of a backup
          // (see [importAllJsonSettings])
          if (e.key != SettingBoxKey.loginMode &&
              (includeCredentials || !credentialKeys.contains(e.key)))
            e.key: e.value,
      },
      video.name: video.toMap(),
      // local follows / favorites: the only copy without an account
      for (final box in LocalLibrary.boxes) box.name: box.toMap(),
    });
  }

  static Future<String?> importAllSettings(
    String data, {
    bool importCredentials = false,
  }) => importAllJsonSettings(
    jsonDecode(data),
    importCredentials: importCredentials,
  );

  static String get _snapshotDir => path.join(appSupportDirPath, 'snapshots');
  static const _snapshotPrefix = 'before_import_';
  static const _maxSnapshots = 5;

  /// Saves the current settings and local library before an import replaces
  /// them, [credentialKeys] included: an import the user answered
  /// 使用备份中的凭据 to overwrites this device's, so leaving them out of the
  /// snapshot would make the undo unable to bring them back. The file stays
  /// in the app's own data dir, which the optional Documents provider does
  /// not serve.
  /// Returns the file path; only the newest [_maxSnapshots] are kept.
  static Future<String> saveSnapshot() async {
    final dir = Directory(_snapshotDir);
    await dir.create(recursive: true);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    // milliseconds and, if that is still not enough, a counter: two imports
    // sharing a name would overwrite each other's snapshot, and an undo
    // taken at the same instant as its import would write its replacement
    // over the very file it then deletes. The suffixes keep sorting by name
    // newest-first (see [_snapshots]).
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
        '${now.millisecond.toString().padLeft(3, '0')}';
    var file = File(path.join(dir.path, '$_snapshotPrefix$stamp.json'));
    for (var i = 1; file.existsSync(); i++) {
      file = File(path.join(dir.path, '$_snapshotPrefix${stamp}_$i.json'));
    }
    await file.writeAsString(exportAllSettings(includeCredentials: true));
    final old = await _snapshots();
    for (final f in old.skip(_maxSnapshots)) {
      try {
        await f.delete();
      } catch (_) {}
    }
    return file.path;
  }

  /// Snapshots taken before imports, newest first.
  static Future<List<File>> _snapshots() async {
    final dir = Directory(_snapshotDir);
    if (!dir.existsSync()) return [];
    final files = [
      await for (final f in dir.list())
        if (f is File && path.basename(f.path).startsWith(_snapshotPrefix)) f,
    ]..sort((a, b) => path.basename(b.path).compareTo(path.basename(a.path)));
    return files;
  }

  /// The newest snapshot taken before an import, if any.
  static Future<File?> latestSnapshot() async =>
      (await _snapshots()).firstOrNull;

  /// Undoes the last import: restores [latestSnapshot], credentials
  /// included (see [saveSnapshot]), and removes it.
  static Future<void> restoreLatestSnapshot() async {
    final file = await latestSnapshot();
    if (file == null) throw const FormatException('没有导入前的快照');
    // the state being replaced is snapshotted too, so the undo can itself
    // be undone instead of destroying what it replaces
    await importAllJsonSettings(
      jsonDecode(await file.readAsString()),
      importCredentials: true,
    );
    await file.delete();
  }

  /// Replaces settings and the local library with [map]. Unless [snapshot]
  /// is false, the current state is saved first (see [saveSnapshot]) and
  /// the snapshot path is returned. This device's [credentialKeys] are kept
  /// unless [importCredentials] (the user agreed) and [map] has them.
  static Future<String?> importAllJsonSettings(
    Map<String, dynamic> map, {
    bool importCredentials = false,
    bool snapshot = true,
  }) async {
    // login mode is a per-device opt-in: a backup must not switch it (the
    // running account state is not re-applied after an import)
    final loginMode = Pref.loginMode;
    // validate everything first, so a bad backup changes nothing; a missing
    // section leaves that box as it is
    final settingMap = map[setting.name];
    final videoMap = map[video.name];
    if ((settingMap != null && settingMap is! Map) ||
        (videoMap != null && videoMap is! Map) ||
        (settingMap == null && videoMap == null)) {
      throw const FormatException('不是有效的设置备份');
    }
    LocalLibrary.checkImport(map);
    final snapshotPath = snapshot ? await saveSnapshot() : null;
    final credentials = {
      for (final key in credentialKeys)
        if (setting.containsKey(key)) key: setting.get(key),
    };
    await Future.wait([
      if (settingMap is Map)
        setting
            .clear()
            .then(
              (_) => setting.putAll({
                for (final e in settingMap.entries)
                  if (importCredentials || !credentialKeys.contains(e.key))
                    e.key: e.value,
              }),
            )
            .then(
              (_) => setting.putAll({
                SettingBoxKey.loginMode: loginMode,
                // credentials the backup does not replace stay as they were
                for (final e in credentials.entries)
                  if (!importCredentials || !settingMap.containsKey(e.key))
                    e.key: e.value,
              }),
            ),
      if (videoMap is Map) video.clear().then((_) => video.putAll(videoMap)),
      LocalLibrary.importAll(map),
    ]);
    return snapshotPath;
  }

  static void regAdapter() {
    Hive
      ..registerAdapter(OwnerAdapter())
      ..registerAdapter(UserInfoDataAdapter())
      ..registerAdapter(LevelInfoAdapter())
      ..registerAdapter(BiliCookieJarAdapter())
      ..registerAdapter(LoginAccountAdapter())
      ..registerAdapter(AccountTypeAdapter())
      ..registerAdapter(SetIntAdapter())
      ..registerAdapter(RuleFilterAdapter());
  }

  static Future<List<void>> compact() {
    return Future.wait([
      userInfo.compact(),
      historyWord.compact(),
      localCache.compact(),
      setting.compact(),
      video.compact(),
      Accounts.account.compact(),
      watchProgress.compact(),
      for (final box in LocalLibrary.boxes) box.compact(),
      ?reply?.compact(),
    ]);
  }

  static Future<List<void>> close() {
    return Future.wait([
      userInfo.close(),
      historyWord.close(),
      localCache.close(),
      setting.close(),
      video.close(),
      Accounts.account.close(),
      watchProgress.close(),
      for (final box in LocalLibrary.boxes) box.close(),
      ?reply?.close(),
    ]);
  }

  static Future<List<void>> clear() {
    return Future.wait([
      userInfo.clear(),
      historyWord.clear(),
      localCache.clear(),
      setting.clear(),
      video.clear(),
      Accounts.clear(),
      watchProgress.clear(),
      LocalLibrary.clear(),
      clearReply(),
      // "reset all data" must not leave the pre-import snapshots behind
      _clearSnapshots(),
    ]);
  }

  /// Removes the user's own posted comments. The [reply] box is opened only
  /// while 记录评论 is on, so going through the handle would skip the file
  /// exactly when the setting is off — which is when nothing else in the app
  /// can reach the bodies any more (the /myReply entry is hidden too).
  static Future<void> clearReply() async {
    final box = reply;
    if (box != null && box.isOpen) {
      await box.clear();
    } else {
      await Hive.deleteBoxFromDisk('reply');
    }
  }

  static Future<void> _clearSnapshots() async {
    try {
      final dir = Directory(_snapshotDir);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static int _intStrDescKeyComparator(dynamic k1, dynamic k2) {
    if (k1 is int) {
      if (k2 is int) {
        return k2.compareTo(k1);
      } else {
        return -1;
      }
    } else if (k2 is String) {
      final lenCompare = k2.length.compareTo((k1 as String).length);
      if (lenCompare == 0) {
        return k2.compareTo(k1);
      } else {
        return lenCompare;
      }
    } else {
      return 1;
    }
  }
}
