// LibrePili: which folders are entry folders (stage-2 plan §3.2
// `isEntryDir`; AC2 「五种目录 × 四处」). The list (`tmp: true`) reads all
// four record files; the three guards that keep downloads apart from
// exports (`tmp: false`: the old-export move, the merged-folder delete,
// deletePage's foreign-folder branch) take `entry.json`,
// `entry.librepili.json` and its `.tmp`, but not a bilibili
// `entry.json.tmp` alone — as before stage 2.
import 'dart:io';

import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('entry-dir-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Directory folder(String name, [String? file]) {
    final d = Directory(path.join(dir.path, name))..createSync();
    if (file != null) File(path.join(d.path, file)).writeAsStringSync('{}');
    return d;
  }

  test('the five kinds of folder, for the list and for the guards', () {
    final cases = {
      // name: (list, guards)
      'entry.json': (true, true),
      'entry.json.tmp': (true, false),
      'entry.librepili.json': (true, true),
      'entry.librepili.json.tmp': (true, true),
      null: (false, false),
    };
    var i = 0;
    cases.forEach((file, want) {
      final d = folder('d${i++}', file);
      expect(
        DownloadService.isEntryDir(d, tmp: true),
        want.$1,
        reason: 'list, $file',
      );
      expect(
        DownloadService.isEntryDir(d, tmp: false),
        want.$2,
        reason: 'guards, $file',
      );
    });
  });

  test('other files are not records', () {
    for (final file in ['cover.jpg', 'index.json', 'entry.librepili.jsonx']) {
      expect(DownloadService.isEntryDir(folder(file, file), tmp: true), false);
    }
  });

  group('the list', () {
    late Directory storage;
    final h = DownloadHarness();
    setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
    tearDownAll(() => closeDownloadStorage(storage));
    tearDown(h.stop);

    test('a YouTube record that is only a .tmp is read; a video at the '
        'root is not an entry', () async {
      await h.start(
        entries: const [],
        before: (root) {
          writeYtRecord(root, ytEntry(root), tmpOnly: true);
          File(
            path.join(root.path, 'Never Gonna Give You Up-$ytId.mp4'),
          ).writeAsBytesSync([0]);
        },
      );
      expect(h.service.waitDownloadQueue.map((e) => e.key), ['yt:$ytId']);
      expect(h.service.downloadList, isEmpty);
    });
  });
}
