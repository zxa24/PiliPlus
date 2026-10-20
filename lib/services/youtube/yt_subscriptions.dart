/// LibrePili: YouTube channels the user follows, kept on this device.
///
/// Its own store rather than a row in the bilibili follow box: that one is
/// keyed by a numeric mid, a YouTube channel is a `UC…` string, and the two
/// lists are shown separately. They meet only in the merged feed of the
/// `全部` platform mode.
///
/// There is no account here and no subscription on their side: the list
/// itself exists only in this app, in its backups, and in what is moved in
/// and out of it by hand (a NewPipe / PipePipe / Takeout file in, a NewPipe
/// file out — yt_subscription_io.dart). Its contents still reach YouTube when
/// the feed is refreshed (pages/youtube/subscriptions): the page asks
/// InnerTube for the uploads of every followed channel, one request per
/// channel id, a few at a time, from this device's IP. With
/// 「订阅刷新时每个频道使用独立身份」 on (the default) each channel is asked
/// over its own connection under a visitorData minted for it alone; off, all
/// of them go over one connection. The IP is the same either way, so the
/// requests can still be tied together by it.
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

  /// Adds the channels of [channels] not already followed and leaves the
  /// rest as they are (an import merges, it does not replace). Returns how
  /// many were added and how many were already there.
  static Future<({int added, int skipped})> merge(
    Iterable<({String channelId, String name})> channels,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = <String, Map<String, dynamic>>{};
    var skipped = 0;
    for (final c in channels) {
      if (isFollowed(c.channelId) || rows.containsKey(c.channelId)) {
        skipped++;
        continue;
      }
      rows[c.channelId] = {
        'channelId': c.channelId,
        'name': c.name.isEmpty ? c.channelId : c.name,
        'avatar': null,
        // a millisecond apart, so the list keeps the file's order
        'followedAt': now - rows.length,
      };
    }
    if (rows.isNotEmpty) await _box.putAll(rows);
    return (added: rows.length, skipped: skipped);
  }

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
