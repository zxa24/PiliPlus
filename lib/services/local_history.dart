import 'dart:math' show max;

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce/hive.dart';

/// The watch history kept on this device (LibrePili).
///
/// Recorded whatever the login state: in incognito it is the only history
/// there is, and in login mode it sits beside the account's own (which
/// bilibili keeps as it always has). Nothing here is ever sent anywhere.
///
/// One entry per video — a bilibili video (`av<aid>`), a bangumi season
/// (`ss<seasonId>`), a course (`cs<seasonId>`) or a YouTube video
/// (`yt<videoId>`) — with the progress of each part (分 P / episode) it was
/// watched to, so a multi-part video is one line in the list, and opening
/// any of its parts again finds where that part was left.
///
/// Plain maps in Hive, like [LocalLibrary]: no adapters, and the backup is
/// the box as JSON.
abstract final class LocalHistory {
  static late Box<dynamic> _box;

  static const boxName = 'localHistory';

  /// How many entries are kept when the user has not chosen (user decision
  /// 2026-09-28: the most recent 5000, the oldest dropped past that).
  static const defaultMax = 5000;

  /// Choices offered for [maxEntries].
  static const maxChoices = [1000, 2000, 5000, 10000, 20000];

  /// Parts kept per entry: a long series watched through would otherwise
  /// rewrite an ever larger record on every save.
  static const maxParts = 100;

  static Future<void> init() async {
    _box = await Hive.openBox(
      boxName,
      // every save of a playing video replaces its record: compact once the
      // replaced copies add up, not on each one
      compactionStrategy: (entries, deletedEntries) => deletedEntries > 300,
    );
  }

  /// For tests: a box opened by the caller.
  @visibleForTesting
  static set box(Box<dynamic> box) => _box = box;

  static Box<dynamic> get box => _box;

  // ------------------------------------------------------------ settings

  /// 「暂停记录」: nothing new is recorded while on; what is there stays.
  static bool get paused => GStorage.setting.get(
    SettingBoxKey.localHistoryPaused,
    defaultValue: false,
  );

  static Future<void> setPaused(bool value) =>
      GStorage.setting.put(SettingBoxKey.localHistoryPaused, value);

  static int get maxEntries {
    final value = GStorage.setting.get(SettingBoxKey.localHistoryMax);
    return value is int && value > 0 ? value : defaultMax;
  }

  /// Sets the cap and drops what is now over it.
  static Future<void> setMaxEntries(int value) async {
    await GStorage.setting.put(SettingBoxKey.localHistoryMax, value);
    await _trim();
  }

  // ---------------------------------------------------------------- keys

  static String ugcKey(int aid) => 'av$aid';
  static String pgcKey(int seasonId) => 'ss$seasonId';
  static String pugvKey(int seasonId) => 'cs$seasonId';
  static String ytKey(String videoId) => 'yt$videoId';

  /// The part id of a YouTube video, which has a single part.
  static const ytPart = '0';

  // --------------------------------------------------------------- clock

  /// Replaceable in tests.
  @visibleForTesting
  static int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  static int _lastStamp = 0;

  /// Strictly increasing, so two saves in the same millisecond still order.
  static int _stamp() => _lastStamp = max(clock(), _lastStamp + 1);

  // ------------------------------------------------------------- writing

  /// Records that [visit]'s part was watched up to [progress] ms of
  /// [duration] ms (0: unknown). Does nothing while [paused]. Not awaited by
  /// the players: Hive keeps the write off the frame.
  ///
  /// The entry is read and put back with nothing awaited in between, and
  /// Hive shows a put to [Box.get] at once (before it is on disk), so saves
  /// close together — a pause, then the next part — each build on the last.
  static Future<void> record(
    LocalWatchVisit visit, {
    required int progress,
    int duration = 0,
  }) async {
    if (paused) return;
    final now = _stamp();
    final old = _box.get(visit.key);
    final oldEntry = old is Map ? LocalWatchEntry.fromJson(old) : null;
    final part = LocalWatchPart(
      id: visit.partId,
      cid: visit.cid ?? oldEntry?.parts[visit.partId]?.cid,
      epId: visit.epId ?? oldEntry?.parts[visit.partId]?.epId,
      page: visit.page ?? oldEntry?.parts[visit.partId]?.page,
      title: visit.partTitle ?? oldEntry?.parts[visit.partId]?.title,
      progress: max(0, progress),
      duration: duration > 0
          ? duration
          : oldEntry?.parts[visit.partId]?.duration ?? 0,
      time: now,
    );
    final parts = {...?oldEntry?.parts, part.id: part};
    if (parts.length > maxParts) {
      final oldest = parts.values.toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      for (final p in oldest.take(parts.length - maxParts)) {
        parts.remove(p.id);
      }
    }
    final entry = LocalWatchEntry(
      key: visit.key,
      platform: visit.platform,
      type: visit.type ?? oldEntry?.type,
      aid: visit.aid ?? oldEntry?.aid,
      bvid: visit.bvid ?? oldEntry?.bvid,
      seasonId: visit.seasonId ?? oldEntry?.seasonId,
      ytId: visit.ytId ?? oldEntry?.ytId,
      // what the page knew may be less than an earlier visit knew (the
      // intro still loading): keep what was learnt before
      title: _nonEmpty(visit.title) ?? oldEntry?.title ?? '',
      cover: _nonEmpty(visit.cover) ?? oldEntry?.cover,
      author: _nonEmpty(visit.author) ?? oldEntry?.author,
      mid: visit.mid ?? oldEntry?.mid,
      channelId: visit.channelId ?? oldEntry?.channelId,
      time: now,
      last: part.id,
      parts: parts,
    );
    await _box.put(visit.key, entry.toJson());
    if (oldEntry == null) await _trim();
  }

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  /// Drops the oldest entries past [maxEntries].
  static Future<void> _trim() async {
    final cap = maxEntries;
    if (_box.length <= cap) return;
    final byTime = <(Object?, int)>[
      for (final key in _box.keys)
        (key, ((_box.get(key) as Map?)?['time'] as int?) ?? 0),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    await _box.deleteAll([
      for (final e in byTime.take(_box.length - cap)) e.$1,
    ]);
  }

  static Future<void> remove(String key) => _box.delete(key);

  static Future<void> removeAll(Iterable<String> keys) => _box.deleteAll(keys);

  static Future<void> clear() => _box.clear();

  // ------------------------------------------------------------- reading

  static Stream<BoxEvent> watch() => _box.watch();

  static int get length => _box.length;

  static LocalWatchEntry? get(String key) {
    final raw = _box.get(key);
    return raw is Map ? LocalWatchEntry.fromJson(raw) : null;
  }

  /// Most recently watched first.
  static List<LocalWatchEntry> entries() => [
    for (final v in _box.values)
      if (v is Map) LocalWatchEntry.fromJson(v),
  ]..sort((a, b) => b.time.compareTo(a.time));

  /// Where to resume part [partId] of [key], in ms: null when it was never
  /// played, barely started or watched to the end (it starts over then).
  static int? resumePoint(String key, String partId) {
    final part = get(key)?.parts[partId];
    if (part == null || part.progress < 1000 || part.finished) return null;
    return part.progress;
  }

  // -------------------------------------------------------------- backup

  /// Checks that the backup's history (if it has one) parses the way the
  /// app reads it. Throws a [FormatException] before anything is changed.
  static void checkImport(Map<String, dynamic> map) {
    final data = map[boxName];
    if (data == null) return;
    try {
      for (final v in (data as Map).values) {
        LocalWatchEntry.fromJson(v as Map);
      }
    } catch (e) {
      throw FormatException('本机观看记录数据无效: $e');
    }
  }

  /// Replaces the history with the backup's; a backup without one (made
  /// before it existed) leaves this device's as it is.
  static Future<void> importAll(Map<String, dynamic> map) async {
    checkImport(map);
    if (map[boxName] case final Map data) {
      await _box.clear();
      // keyed by their own `key`: a hand-edited backup cannot hold an entry
      // that delete cannot reach
      await _box.putAll({
        for (final v in data.values) '${(v as Map)['key']}': v,
      });
      // not trimmed here: the setting box is being replaced alongside, so
      // the cap read now could be neither the old nor the imported one.
      // The next new entry trims to whatever it then is.
    }
  }
}

/// What a player knows about the video it is showing, for [LocalHistory].
class LocalWatchVisit {
  const LocalWatchVisit({
    required this.key,
    required this.platform,
    required this.partId,
    this.type,
    this.aid,
    this.bvid,
    this.seasonId,
    this.ytId,
    this.title,
    this.cover,
    this.author,
    this.mid,
    this.channelId,
    this.cid,
    this.epId,
    this.page,
    this.partTitle,
  });

  final String key;
  final LocalHistoryPlatform platform;

  /// `ugc` / `pgc` / `pugv` for bilibili.
  final String? type;
  final int? aid;
  final String? bvid;
  final int? seasonId;
  final String? ytId;
  final String? title;
  final String? cover;
  final String? author;
  final int? mid;
  final String? channelId;

  /// The part: its cid as a string for bilibili, [LocalHistory.ytPart] for
  /// YouTube.
  final String partId;
  final int? cid;
  final int? epId;

  /// 1-based 分 P number.
  final int? page;
  final String? partTitle;
}

enum LocalHistoryPlatform {
  bili('B 站'),
  yt('YouTube');

  const LocalHistoryPlatform(this.label);
  final String label;
}

class LocalWatchPart {
  const LocalWatchPart({
    required this.id,
    this.cid,
    this.epId,
    this.page,
    this.title,
    required this.progress,
    required this.duration,
    required this.time,
  });

  final String id;
  final int? cid;
  final int? epId;
  final int? page;
  final String? title;

  /// Milliseconds.
  final int progress;

  /// Milliseconds; 0 when unknown.
  final int duration;

  /// When it was last watched, ms since epoch.
  final int time;

  /// Watched to (within a second of) the end.
  bool get finished => duration > 0 && progress >= duration - 1000;

  factory LocalWatchPart.fromJson(String id, Map json) => LocalWatchPart(
    id: id,
    cid: json['cid'] as int?,
    epId: json['ep'] as int?,
    page: json['page'] as int?,
    title: json['title'] as String?,
    progress: json['progress'] as int? ?? 0,
    duration: json['duration'] as int? ?? 0,
    time: json['time'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'cid': ?cid,
    'ep': ?epId,
    'page': ?page,
    'title': ?title,
    'progress': progress,
    'duration': duration,
    'time': time,
  };
}

class LocalWatchEntry {
  const LocalWatchEntry({
    required this.key,
    required this.platform,
    this.type,
    this.aid,
    this.bvid,
    this.seasonId,
    this.ytId,
    required this.title,
    this.cover,
    this.author,
    this.mid,
    this.channelId,
    required this.time,
    required this.last,
    required this.parts,
  });

  final String key;
  final LocalHistoryPlatform platform;
  final String? type;
  final int? aid;
  final String? bvid;
  final int? seasonId;
  final String? ytId;
  final String title;
  final String? cover;
  final String? author;
  final int? mid;
  final String? channelId;

  /// Last watched, ms since epoch.
  final int time;

  /// The part watched last: the one the list shows and opens.
  final String last;
  final Map<String, LocalWatchPart> parts;

  LocalWatchPart? get lastPart => parts[last];

  factory LocalWatchEntry.fromJson(Map json) {
    final parts = <String, LocalWatchPart>{
      for (final MapEntry(:key, :value) in (json['parts'] as Map).entries)
        '$key': LocalWatchPart.fromJson('$key', value as Map),
    };
    return LocalWatchEntry(
      key: json['key'] as String,
      platform: LocalHistoryPlatform.values.byName(json['platform'] as String),
      type: json['type'] as String?,
      aid: json['aid'] as int?,
      bvid: json['bvid'] as String?,
      seasonId: json['seasonId'] as int?,
      ytId: json['yt'] as String?,
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String?,
      author: json['author'] as String?,
      mid: json['mid'] as int?,
      channelId: json['channel'] as String?,
      time: json['time'] as int? ?? 0,
      last: json['last'] as String? ?? parts.keys.firstOrNull ?? '',
      parts: parts,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'platform': platform.name,
    'type': ?type,
    'aid': ?aid,
    'bvid': ?bvid,
    'seasonId': ?seasonId,
    'yt': ?ytId,
    'title': title,
    'cover': ?cover,
    'author': ?author,
    'mid': ?mid,
    'channel': ?channelId,
    'time': time,
    'last': last,
    'parts': {for (final p in parts.values) p.id: p.toJson()},
  };
}
