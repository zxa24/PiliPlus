/// LibrePili: YouTube channels the user follows, kept on this device.
///
/// Its own store rather than a row in the bilibili follow box: that one is
/// keyed by a numeric mid, a YouTube channel is a `UC…` string, and the two
/// lists are shown separately. They meet only in the merged feed of the
/// `全部` platform mode.
///
/// There is no account here and no subscription on their side: the list
/// itself exists only in this app (and in its backups; there is no NewPipe /
/// PipePipe import or export). Its contents still reach YouTube when the
/// feed is refreshed (pages/youtube/subscriptions): the page asks InnerTube
/// for the uploads of up to 12 channels, the most recently followed first,
/// one request per channel id, one after another, from this device's IP and
/// under one visitorData — minted once by the page's own source and reused
/// for every channel (a fresh one only when a bot check asks for it). Those
/// requests can therefore be tied together as one viewer's list.
library;

import 'package:hive_ce/hive.dart';

class YtSubscription {
  const YtSubscription({
    required this.channelId,
    required this.name,
    this.avatar,
    this.followedAt,
  });

  factory YtSubscription.fromMap(Map map) => YtSubscription(
    channelId: (map['channelId'] ?? '').toString(),
    name: (map['name'] ?? '').toString(),
    avatar: map['avatar'] as String?,
    followedAt: map['followedAt'] as int?,
  );

  final String channelId;
  final String name;
  final String? avatar;
  final int? followedAt;

  Map<String, dynamic> toMap() => {
    'channelId': channelId,
    'name': name,
    'avatar': avatar,
    'followedAt': followedAt,
  };
}

abstract final class YtSubscriptions {
  static late Box _box;

  static Future<void> init() async {
    _box = await Hive.openBox('ytSubscriptions');
  }

  static Stream<BoxEvent> watch() => _box.watch();

  static bool isFollowed(String? channelId) =>
      channelId != null && channelId.isNotEmpty && _box.containsKey(channelId);

  static List<YtSubscription> all() => [
    for (final value in _box.values)
      if (value is Map) YtSubscription.fromMap(value),
  ]..sort((a, b) => (b.followedAt ?? 0).compareTo(a.followedAt ?? 0));

  static Future<void> follow(
    String channelId, {
    required String name,
    String? avatar,
  }) {
    final old = _box.get(channelId) as Map?;
    return _box.put(channelId, {
      'channelId': channelId,
      'name': name.isEmpty ? (old?['name'] ?? channelId) : name,
      'avatar': avatar ?? old?['avatar'],
      'followedAt': old?['followedAt'] ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> unfollow(String channelId) => _box.delete(channelId);

  /// Returns the new state.
  static Future<bool> toggle(
    String channelId, {
    required String name,
    String? avatar,
  }) async {
    if (isFollowed(channelId)) {
      await unfollow(channelId);
      return false;
    }
    await follow(channelId, name: name, avatar: avatar);
    return true;
  }

  static Future<void> clear() => _box.clear();

  // -------------------------------------------------------------- backup

  /// The box, for backup / compact / close (see GStorage).
  static Box get box => _box;

  /// Checks that the backup's list (if it has one) parses the way the app
  /// reads it and that no two rows share a channel ([importAll] keys them
  /// by it). Throws a [FormatException] before anything is changed.
  static void checkImport(Map<String, dynamic> map) {
    final data = map[_box.name];
    if (data == null) return;
    if (data is! Map) throw const FormatException('YouTube 关注数据无效');
    final ids = <String>{};
    for (final v in data.values) {
      if (v is! Map) throw const FormatException('YouTube 关注数据无效');
      final id = v['channelId'];
      if (id is! String || id.isEmpty) {
        throw FormatException('YouTube 关注数据无效: $v');
      }
      if (!ids.add(id)) {
        throw FormatException('YouTube 关注数据有重复的频道: $id');
      }
      try {
        YtSubscription.fromMap(v);
      } catch (e) {
        throw FormatException('YouTube 关注数据无效: $e');
      }
    }
  }

  /// Replaces the list with the backup's; a backup without one (made
  /// before it was backed up) leaves this device's as it is.
  static Future<void> importAll(Map<String, dynamic> map) async {
    checkImport(map);
    if (map[_box.name] case final Map data) {
      await _box.clear();
      // keyed by their own channel: a hand-edited backup cannot hold a row
      // that unfollow cannot reach
      await _box.putAll({
        for (final v in data.values) (v as Map)['channelId'] as String: v,
      });
    }
  }
}
