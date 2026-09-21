/// LibrePili: YouTube channels the user follows, kept on this device.
///
/// Its own store rather than a row in the bilibili follow box: that one is
/// keyed by a numeric mid, a YouTube channel is a `UC…` string, and the two
/// lists are shown separately. They meet only in the merged feed of the
/// `全部` platform mode.
///
/// Nothing is sent to YouTube. There is no account here and no subscription
/// on their side — the list exists only in this app, which is also why it is
/// importable from and exportable to NewPipe and PipePipe.
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
}
