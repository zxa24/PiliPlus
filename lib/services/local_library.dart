import 'package:PiliPlus/models_new/member/search_archive/vlist.dart';
import 'package:hive_ce/hive.dart';

/// Account-free follows and favorites stored on this device only (LibrePili).
///
/// Everything is kept as plain maps in Hive so no type adapters are needed.
/// Favorite items use the same JSON shape as the web space-archive API, so
/// they render with the existing [VListItemModel] / `VideoCardH`.
abstract final class LocalLibrary {
  static late final Box<dynamic> _follows; // mid(str) -> LocalFollow json
  static late final Box<dynamic> _folders; // folder id(str) -> folder json
  static late final Box<dynamic> _items; // item key -> item json

  static const defaultFolderId = 0;

  static Future<void> init() async {
    _follows = await Hive.openBox('localFollows');
    _folders = await Hive.openBox('localFavFolders');
    _items = await Hive.openBox('localFavItems');
    await _ensureDefaultFolder();
  }

  static Future<void> _ensureDefaultFolder() async {
    if (_folders.isEmpty) {
      await _folders.put('$defaultFolderId', {
        'id': defaultFolderId,
        'title': '默认收藏夹',
        'order': 0,
        'ctime': _now(),
      });
    }
    await _dropGhostFolders();
  }

  /// Moves items that only reference folders which no longer exist back to
  /// the default folder. A [deleteFolder] killed while it rewrote the items
  /// leaves the rest pointing at the folder it already removed: they then
  /// show in no folder and in no count, while [isFav] stays true and the
  /// fav sheet keeps the ghost id, so nothing can ever clear them.
  static Future<void> _dropGhostFolders() async {
    final ids = {
      for (final v in _folders.values)
        if ((v as Map)['id'] case final int id) id,
    };
    for (final item in _allItems().toList()) {
      final kept = item.folders.where(ids.contains).toSet();
      if (kept.length == item.folders.length) continue;
      await _saveItem(
        LocalFavItem(
          key: item.key,
          data: item.data,
          folders: kept.isEmpty ? {defaultFolderId} : kept,
          time: item.time,
        ),
      );
    }
  }

  /// The boxes, for backup / compact / close (see GStorage).
  static List<Box<dynamic>> get boxes => [_follows, _folders, _items];

  /// Restores boxes from a backup made with [boxes]; boxes missing from
  /// [map] (older backups) are left as they are.
  /// Throws a [FormatException] before anything is cleared if a box in
  /// [map] is malformed: these boxes are the only copy without an account.
  static Future<void> importAll(Map<String, dynamic> map) async {
    checkImport(map);
    for (final box in boxes) {
      if (map[box.name] case final Map data) {
        await box.clear();
        await box.putAll(
          // follows are looked up by '$mid' and items by their own `key`:
          // key them that way, so a hand-edited backup cannot hold an entry
          // unfollow / un-favorite cannot reach
          identical(box, _follows)
              ? {for (final v in data.values) '${(v as Map)['mid']}': v}
              : identical(box, _items)
              ? {for (final v in data.values) '${(v as Map)['key']}': v}
              : data,
        );
      }
    }
    await _ensureDefaultFolder();
  }

  /// Checks that every box in [map] parses the way the app reads it, that
  /// no two follows share a mid and no two items a key ([importAll] keys
  /// both by their own field, so duplicates would be dropped without the
  /// user noticing), and that no item references a folder the backup does
  /// not have: such an item would show in no folder and in no count while
  /// staying favorited, with no way to clear it.
  static void checkImport(Map<String, dynamic> map) {
    if (map[_follows.name] case final Map data) {
      final mids = <Object?>{};
      for (final v in data.values) {
        if (v is Map && !mids.add(v['mid'])) {
          throw FormatException('本地关注数据有重复的 mid: ${v['mid']}');
        }
      }
    }
    if (map[_items.name] case final Map data) {
      // only when the backup brings its own folders: with that box left out
      // the items keep referencing the ones already on this device, and
      // [_ensureDefaultFolder] heals whatever no longer resolves
      final foldersMap = map[_folders.name];
      final Set<Object?>? ids = foldersMap is Map
          ? {
              for (final v in foldersMap.values)
                if (v is Map) v['id'],
            }
          : null;
      final keys = <Object?>{};
      for (final v in data.values) {
        if (v is! Map) continue;
        if (!keys.add(v['key'])) {
          throw FormatException('本地收藏数据有重复的 key: ${v['key']}');
        }
        if (ids == null) continue;
        if (v['folders'] case final List refs) {
          for (final id in refs) {
            if (!ids.contains(id)) {
              throw FormatException('本地收藏「${v['key']}」引用了不存在的收藏夹: $id');
            }
          }
        }
      }
    }
    final parsers = <String, Object Function(Map)>{
      _follows.name: LocalFollow.fromJson,
      _folders.name: LocalFavFolder.fromJson,
      _items.name: LocalFavItem.fromJson,
    };
    for (final MapEntry(key: name, value: parse) in parsers.entries) {
      final data = map[name];
      if (data == null) continue;
      try {
        for (final value in (data as Map).values) {
          parse(value as Map);
        }
      } catch (e) {
        throw FormatException('本地关注/收藏数据无效 ($name): $e');
      }
    }
  }

  static Future<void> clear() async {
    for (final box in boxes) {
      await box.clear();
    }
    await _ensureDefaultFolder();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Stream<BoxEvent> watchFollows() => _follows.watch();
  static Stream<BoxEvent> watchFavs() => _items.watch();
  static Stream<BoxEvent> watchFolders() => _folders.watch();

  // ---------------------------------------------------------------- follows

  static bool isFollowed(int? mid) =>
      mid != null && _follows.containsKey('$mid');

  static Future<void> follow(int mid, {String? name, String? face}) {
    final old = _follows.get('$mid') as Map?;
    return _follows.put('$mid', {
      'mid': mid,
      'name': name ?? old?['name'],
      'face': face ?? old?['face'],
      'time': old?['time'] ?? _now(),
    });
  }

  static Future<void> unfollow(int mid) => _follows.delete('$mid');

  /// Returns the new follow state.
  static Future<bool> toggleFollow(
    int mid, {
    String? name,
    String? face,
  }) async {
    if (isFollowed(mid)) {
      await unfollow(mid);
      return false;
    }
    await follow(mid, name: name, face: face);
    return true;
  }

  /// Fills in name/avatar learned later (e.g. from the feed) without
  /// changing the follow time.
  static Future<void> updateFollowInfo(int mid, {String? name, String? face}) {
    final old = _follows.get('$mid') as Map?;
    if (old == null ||
        ((name == null || name == old['name']) &&
            (face == null || face == old['face']))) {
      return Future.value();
    }
    return follow(mid, name: name, face: face);
  }

  static List<LocalFollow> followList() =>
      _follows.values.map((e) => LocalFollow.fromJson(e as Map)).toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  // ---------------------------------------------------------------- folders

  static List<LocalFavFolder> folders() =>
      _folders.values.map((e) => LocalFavFolder.fromJson(e as Map)).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  static Future<LocalFavFolder> createFolder(String title) async {
    final list = folders();
    final id = list.fold<int>(0, (m, e) => e.id > m ? e.id : m) + 1;
    final folder = LocalFavFolder(
      id: id,
      title: title,
      order: list.isEmpty ? 0 : list.last.order + 1,
      ctime: _now(),
    );
    await _folders.put('$id', folder.toJson());
    return folder;
  }

  static Future<void> renameFolder(int id, String title) async {
    final old = _folders.get('$id') as Map?;
    if (old == null) return;
    await _folders.put('$id', {...old, 'title': title});
  }

  /// Deletes a folder; items only in that folder are removed too.
  static Future<void> deleteFolder(int id) async {
    if (id == defaultFolderId) return;
    await _folders.delete('$id');
    for (final item in _allItems()) {
      if (item.folders.remove(id)) {
        await _saveItem(item);
      }
    }
  }

  /// Persists a new folder order (ids in display order).
  static Future<void> reorderFolders(List<int> ids) async {
    for (var i = 0; i < ids.length; i++) {
      final old = _folders.get('${ids[i]}') as Map?;
      if (old != null) await _folders.put('${ids[i]}', {...old, 'order': i});
    }
  }

  static int folderCount(int folderId) =>
      _allItems().where((e) => e.folders.contains(folderId)).length;

  // ---------------------------------------------------------------- items

  static Iterable<LocalFavItem> _allItems() =>
      _items.values.map((e) => LocalFavItem.fromJson(e as Map));

  static bool isFav(String key) => _items.containsKey(key);

  static Set<int> foldersOf(String key) {
    final raw = _items.get(key) as Map?;
    return raw == null ? {} : LocalFavItem.fromJson(raw).folders;
  }

  /// Puts [key] into exactly [folderIds] (empty set removes it).
  static Future<void> setFolders(
    String key,
    Map<String, dynamic> data,
    Set<int> folderIds,
  ) async {
    if (folderIds.isEmpty) {
      await _items.delete(key);
      return;
    }
    final old = _items.get(key) as Map?;
    await _saveItem(
      LocalFavItem(
        key: key,
        data: data,
        folders: folderIds,
        time: (old?['time'] as int?) ?? _now(),
      ),
    );
  }

  static Future<void> removeFromFolder(String key, int folderId) async {
    final raw = _items.get(key) as Map?;
    if (raw == null) return;
    final item = LocalFavItem.fromJson(raw)..folders.remove(folderId);
    await _saveItem(item);
  }

  static Future<void> _saveItem(LocalFavItem item) => item.folders.isEmpty
      ? _items.delete(item.key)
      : _items.put(item.key, item.toJson());

  /// Builds item data in the web space-archive shape.
  static Map<String, dynamic> buildFavData({
    int? aid,
    String? bvid,
    required String title,
    String? cover,
    int? durationSec,
    int? pubdate,
    int? mid,
    String? author,
    int? play,
    int? danmaku,
    String? jumpUrl,
  }) => {
    'aid': ?aid,
    'bvid': ?bvid,
    'title': title,
    'pic': ?cover,
    if (durationSec != null && durationSec > 0)
      'length': _formatLength(durationSec),
    'created': ?pubdate,
    'mid': ?mid,
    'author': ?author,
    'play': ?play,
    'video_review': ?danmaku,
    'jump_url': ?jumpUrl,
  };

  static String _formatLength(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = (sec % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  static List<LocalFavItem> folderItems(int folderId) =>
      _allItems().where((e) => e.folders.contains(folderId)).toList()
        ..sort((a, b) => b.time.compareTo(a.time));
}

class LocalFollow {
  LocalFollow({required this.mid, this.name, this.face, required this.time});
  final int mid;
  final String? name;
  final String? face;
  final int time;

  factory LocalFollow.fromJson(Map json) => LocalFollow(
    mid: json['mid'] as int,
    name: json['name'] as String?,
    face: json['face'] as String?,
    time: json['time'] as int? ?? 0,
  );
}

class LocalFavFolder {
  LocalFavFolder({
    required this.id,
    required this.title,
    required this.order,
    required this.ctime,
  });
  final int id;
  final String title;
  final int order;
  final int ctime;

  factory LocalFavFolder.fromJson(Map json) => LocalFavFolder(
    id: json['id'] as int,
    title: json['title'] as String,
    order: json['order'] as int? ?? 0,
    ctime: json['ctime'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'order': order,
    'ctime': ctime,
  };
}

class LocalFavItem {
  LocalFavItem({
    required this.key,
    required this.data,
    required this.folders,
    required this.time,
  });

  /// `av<aid>` for videos, `ep<epid>` for bangumi episodes.
  final String key;

  /// Web space-archive shaped JSON (see [VListItemModel.fromJson]).
  final Map<String, dynamic> data;
  final Set<int> folders;

  /// When it was favorited (unix seconds).
  final int time;

  String get title => data['title'] as String? ?? '';
  String get author => data['author'] as String? ?? '';

  VListItemModel toVideoItem() => VListItemModel.fromJson(data);

  factory LocalFavItem.fromJson(Map json) => LocalFavItem(
    key: json['key'] as String,
    data: Map<String, dynamic>.from(json['data'] as Map),
    folders: {...(json['folders'] as List).cast<int>()},
    time: json['time'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'data': data,
    'folders': folders.toList(),
    'time': time,
  };
}
