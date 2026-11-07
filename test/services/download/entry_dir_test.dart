// LibrePili: which folders are entry folders (stage-2 plan §3.2
// `isEntryDir`; AC2 「五种目录 × 四处」). The list (`tmp: true`) reads all
// four record files; the three guards that keep downloads apart from
// exports (`tmp: false`: the old-export move, the merged-folder delete,
// deletePage's foreign-folder branch) take `entry.json`,
// `entry.librepili.json` and its `.tmp`, but not a bilibili
// `entry.json.tmp` alone — as before stage 2.
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));

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

  // review 2bc: the three guards that keep downloads apart from exports,
  // each with a YouTube record in the folder (a revert to `entry.json`
  // there fails one of these); each with its control, the same folder
  // without the record, so the guarded action is shown to happen
  group('the three guards, a YouTube folder', () {
    tearDown(h.stop);

    File record(String dir) {
      Directory(dir).createSync(recursive: true);
      return File(path.join(dir, YtDownloadEntry.recordFile))
        ..writeAsStringSync('{}');
    }

    for (final withRecord in [true, false]) {
      test(
        "bilibili's folder: an old export holding a download is "
        '${withRecord ? 'left in place' : 'moved aside (control)'}',
        () async {
          await h.start(entries: const []);
          final e = fixtureEntry(recordFixtures, recordUgc);
          final page = path.join(h.root.path, '${e.avid}');
          Directory(page).createSync();
          final export = File(path.join(page, '${e.avid}.mp4'))
            ..writeAsBytesSync([1]);
          if (withRecord) record(path.join(page, 'x'));
          await h.service.entryDirForTest(e);
          expect(export.existsSync(), withRecord);
        },
      );

      test(
        'the export deleted with a download: its folder '
        '${withRecord ? 'keeps the download inside it' : 'goes (control)'}',
        () async {
          late Directory exportDir;
          late File mp4;
          await h.start(
            entries: const [],
            before: (root) {
              exportDir = Directory(path.join(root.parent.path, 'Never Gonna'))
                ..createSync();
              mp4 = File(path.join(exportDir.path, 'Never Gonna.mp4'))
                ..writeAsBytesSync([0]);
              if (withRecord) record(path.join(exportDir.path, 'd'));
              writeYtRecord(
                root,
                ytEntry(root, completed: true, merged: mp4.path),
              );
            },
          );
          final e = h.service.downloadList.single;
          // the transcripts beside the list are read over it in the
          // background: not deleted from under that read
          await h.service.knownReadForTest;
          await h.service.deleteDownload(
            entry: e,
            removeList: true,
            deleteExported: true,
          );
          expect(mp4.existsSync(), isFalse);
          expect(exportDir.existsSync(), withRecord);
          if (withRecord) {
            expect(
              Directory(path.join(exportDir.path, 'd')).existsSync(),
              isTrue,
            );
          }
        },
      );

      test(
        'a page folder that is also an export: its download '
        '${withRecord ? 'deleted, the export kept' : 'not there (control)'}',
        () async {
          await h.start(entries: const []);
          final page = path.join(h.root.path, 'yt_$ytId');
          final main = path.join(page, 'main');
          Directory(main).createSync(recursive: true);
          if (withRecord) record(main);
          final export = File(path.join(page, 'Never Gonna.mp4'))
            ..writeAsBytesSync([0]);
          await h.service.deletePage(pageDirPath: page);
          expect(export.existsSync(), isTrue);
          // the entry folder goes with its record; without one it is not a
          // download and stays (as before)
          expect(Directory(main).existsSync(), !withRecord);
        },
      );
    }
  });
}
