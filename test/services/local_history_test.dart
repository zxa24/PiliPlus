import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

LocalWatchVisit _ugc(
  int aid, {
  int cid = 1,
  int page = 1,
  String? title,
  String? partTitle,
}) => LocalWatchVisit(
  key: LocalHistory.ugcKey(aid),
  platform: LocalHistoryPlatform.bili,
  type: 'ugc',
  aid: aid,
  bvid: 'BV$aid',
  title: title ?? 'video $aid',
  cover: 'https://i0.hdslb.com/$aid.jpg',
  author: 'up $aid',
  mid: 100 + aid,
  partId: '$cid',
  cid: cid,
  page: page,
  partTitle: partTitle,
);

LocalWatchVisit _yt(String id) => LocalWatchVisit(
  key: LocalHistory.ytKey(id),
  platform: LocalHistoryPlatform.yt,
  ytId: id,
  title: 'yt $id',
  author: 'channel',
  channelId: 'UC1',
  partId: LocalHistory.ytPart,
);

void main() {
  late Directory tempDir;
  var now = 1000000;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('local-history-test-');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    await LocalLibrary.init();
    await LocalHistory.init();
    LocalHistory.clock = () => now;
  });

  setUp(() async {
    now += 1000;
    await LocalHistory.clear();
    await GStorage.setting.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('records one entry per video with each part progress', () async {
    await LocalHistory.record(
      _ugc(1, cid: 11, page: 1, partTitle: 'P1'),
      progress: 30000,
      duration: 600000,
    );
    await LocalHistory.record(
      _ugc(1, cid: 12, page: 2, partTitle: 'P2'),
      progress: 5000,
      duration: 300000,
    );
    // the first part again, further on
    await LocalHistory.record(
      _ugc(1, cid: 11, page: 1),
      progress: 45000,
      duration: 600000,
    );

    expect(LocalHistory.length, 1);
    final entry = LocalHistory.get('av1')!;
    expect(entry.platform, LocalHistoryPlatform.bili);
    expect(entry.title, 'video 1');
    expect(entry.author, 'up 1');
    expect(entry.bvid, 'BV1');
    expect(entry.last, '11');
    expect(entry.lastPart!.progress, 45000);
    // a part title learnt once is kept when a later save does not know it
    expect(entry.lastPart!.title, 'P1');
    expect(entry.parts['12']!.progress, 5000);
    expect(entry.parts['12']!.page, 2);
    expect(LocalHistory.resumePoint('av1', '12'), 5000);
  });

  test(
    'keeps what an earlier visit knew when a later one knows less',
    () async {
      await LocalHistory.record(_ugc(2), progress: 3000, duration: 9000);
      await LocalHistory.record(
        const LocalWatchVisit(
          key: 'av2',
          platform: LocalHistoryPlatform.bili,
          partId: '1',
          title: '',
        ),
        progress: 4000,
      );
      final entry = LocalHistory.get('av2')!;
      expect(entry.title, 'video 2');
      expect(entry.cover, isNotNull);
      expect(entry.lastPart!.progress, 4000);
      expect(entry.lastPart!.duration, 9000);
    },
  );

  test('lists the most recently watched first', () async {
    await LocalHistory.record(_ugc(1), progress: 1000);
    await LocalHistory.record(_yt('abc'), progress: 1000);
    await LocalHistory.record(_ugc(3), progress: 1000);
    // watching 1 again moves it to the top
    await LocalHistory.record(_ugc(1), progress: 2000);
    expect(LocalHistory.entries().map((e) => e.key), ['av1', 'av3', 'ytabc']);
    expect(
      LocalHistory.get('ytabc')!.platform,
      LocalHistoryPlatform.yt,
    );
  });

  test('saves close together are not lost', () async {
    // not awaited, as the players call it
    final a = LocalHistory.record(_ugc(5, cid: 51), progress: 1000);
    final b = LocalHistory.record(_ugc(5, cid: 52), progress: 2000);
    final c = LocalHistory.record(_ugc(6), progress: 3000);
    await Future.wait([a, b, c]);
    expect(LocalHistory.get('av5')!.parts.keys, unorderedEquals(['51', '52']));
    expect(LocalHistory.get('av5')!.last, '52');
    expect(LocalHistory.length, 2);
  });

  test('keeps the most recent N and drops the oldest', () async {
    expect(LocalHistory.maxEntries, LocalHistory.defaultMax);
    expect(LocalHistory.defaultMax, 5000);
    await LocalHistory.setMaxEntries(3);
    for (var i = 1; i <= 3; i++) {
      await LocalHistory.record(_ugc(i), progress: 1000);
    }
    // 1 is watched again: now 2 is the oldest
    await LocalHistory.record(_ugc(1), progress: 5000);
    await LocalHistory.record(_ugc(4), progress: 1000);
    expect(LocalHistory.entries().map((e) => e.key), ['av4', 'av1', 'av3']);
    await LocalHistory.record(_yt('x'), progress: 1000);
    expect(LocalHistory.entries().map((e) => e.key), ['ytx', 'av4', 'av1']);

    // lowering the cap trims at once
    await LocalHistory.setMaxEntries(1);
    expect(LocalHistory.entries().map((e) => e.key), ['ytx']);
  });

  test('keeps at most maxParts parts per entry, the recent ones', () async {
    for (var i = 1; i <= LocalHistory.maxParts + 2; i++) {
      await LocalHistory.record(_ugc(7, cid: i, page: i), progress: 1000);
    }
    final parts = LocalHistory.get('av7')!.parts;
    expect(parts.length, LocalHistory.maxParts);
    expect(parts.containsKey('1'), isFalse);
    expect(parts.containsKey('2'), isFalse);
    expect(parts.containsKey('${LocalHistory.maxParts + 2}'), isTrue);
  });

  test('pausing stops recording and keeps what is there', () async {
    await LocalHistory.record(_ugc(1), progress: 1000);
    await LocalHistory.setPaused(true);
    expect(
      GStorage.setting.get(SettingBoxKey.localHistoryPaused),
      isTrue,
    );
    await LocalHistory.record(_ugc(2), progress: 1000);
    await LocalHistory.record(_ugc(1), progress: 9000);
    expect(LocalHistory.length, 1);
    expect(LocalHistory.get('av1')!.lastPart!.progress, 1000);

    await LocalHistory.setPaused(false);
    await LocalHistory.record(_ugc(2), progress: 1000);
    expect(LocalHistory.length, 2);
  });

  test('resume point: none when barely started or finished', () async {
    await LocalHistory.record(_ugc(1, cid: 1), progress: 500, duration: 60000);
    await LocalHistory.record(
      _ugc(1, cid: 2),
      progress: 59500,
      duration: 60000,
    );
    await LocalHistory.record(
      _ugc(1, cid: 3),
      progress: 20000,
      duration: 60000,
    );
    // duration unknown: resume as is
    await LocalHistory.record(_ugc(1, cid: 4), progress: 20000);
    expect(LocalHistory.resumePoint('av1', '1'), isNull);
    expect(LocalHistory.get('av1')!.parts['2']!.finished, isTrue);
    expect(LocalHistory.resumePoint('av1', '2'), isNull);
    expect(LocalHistory.resumePoint('av1', '3'), 20000);
    expect(LocalHistory.resumePoint('av1', '4'), 20000);
    expect(LocalHistory.resumePoint('av9', '1'), isNull);
  });

  test('delete one, several, all', () async {
    for (var i = 1; i <= 4; i++) {
      await LocalHistory.record(_ugc(i), progress: 1000);
    }
    await LocalHistory.remove('av1');
    await LocalHistory.removeAll(['av2', 'av3']);
    expect(LocalHistory.entries().map((e) => e.key), ['av4']);
    await LocalHistory.clear();
    expect(LocalHistory.length, 0);
  });

  test('backup round-trip through the settings export', () async {
    await LocalHistory.record(
      _ugc(1, cid: 11, partTitle: 'P1'),
      progress: 30000,
      duration: 60000,
    );
    await LocalHistory.record(_yt('abc'), progress: 1000, duration: 2000);
    await LocalHistory.setPaused(true);
    final exported = GStorage.exportAllSettings();
    final before = LocalHistory.entries().map((e) => e.toJson()).toList();

    await LocalHistory.clear();
    await GStorage.setting.clear();
    await GStorage.importAllJsonSettings(
      jsonDecode(exported) as Map<String, dynamic>,
      snapshot: false,
    );
    expect(
      LocalHistory.entries().map((e) => e.toJson()).toList(),
      before,
    );
    // the pause switch is a setting, and travels with them
    expect(LocalHistory.paused, isTrue);
  });

  test('a backup without a history leaves this one alone', () async {
    await LocalHistory.record(_ugc(1), progress: 1000);
    final map = jsonDecode(GStorage.exportAllSettings()) as Map<String, dynamic>
      ..remove(LocalHistory.boxName);
    await GStorage.importAllJsonSettings(map, snapshot: false);
    expect(LocalHistory.length, 1);
  });

  test('a malformed history in a backup changes nothing', () async {
    await LocalHistory.record(_ugc(1), progress: 1000);
    final map =
        jsonDecode(GStorage.exportAllSettings()) as Map<String, dynamic>;
    map[LocalHistory.boxName] = {
      'av2': {'key': 'av2', 'platform': 'nowhere', 'parts': {}},
    };
    await expectLater(
      GStorage.importAllJsonSettings(map, snapshot: false),
      throwsFormatException,
    );
    expect(LocalHistory.entries().map((e) => e.key), ['av1']);
  });

  test('reset clears it', () async {
    await LocalHistory.record(_ugc(1), progress: 1000);
    // GStorage.clear (重置所有数据) calls this alongside the other boxes;
    // the whole of it needs the account and cookie stores, not set up here
    await LocalHistory.clear();
    expect(LocalHistory.length, 0);
    expect(LocalHistory.entries(), isEmpty);
    // ...so check that it does: the body of GStorage.clear names it
    final source = File('lib/utils/storage.dart').readAsStringSync();
    final start = source.indexOf('static Future<List<void>> clear()');
    final body = source.substring(start, source.indexOf('  }', start));
    expect(body, contains('LocalHistory.clear()'));
  });
}
