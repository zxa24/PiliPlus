// LibrePili: deleting a YouTube download (stage-2 plan §3.2; AC7): its
// `yt_<id>` folder goes, the exported file only when asked, and the local
// watch history (`LocalHistory`, ytKey) is the user's — kept, unlike
// bilibili's download-only progress (delete_progress_test.dart).
//
// The pages delete in two ways, each the platform's `onDeleted` and then
// the service (download/controller.dart and the detail page: a page;
// search/controller.dart: entries); both are done here in their order on
// the real service. Which page calls which is delete_progress_test's.
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

import '../../services/download/download_test_support.dart';
import '../../services/download/yt_download_test_support.dart';

void main() {
  late Directory storage;
  final h = DownloadHarness();
  late File mp4;

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
    LocalHistory.box = await Hive.openBox(
      'localHistory-yt-delete',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  Future<YtDownloadEntry> start() async {
    await h.start(
      entries: const [],
      before: (root) {
        mp4 = File(path.join(root.path, 'Never Gonna Give You Up.mp4'))
          ..writeAsBytesSync([0]);
        writeYtRecord(root, ytEntry(root, completed: true, merged: mp4.path));
      },
    );
    await LocalHistory.record(
      const LocalWatchVisit(
        key: 'yt$ytId',
        platform: LocalHistoryPlatform.yt,
        ytId: ytId,
        title: 'Never Gonna Give You Up',
        partId: LocalHistory.ytPart,
      ),
      progress: 60000,
      duration: 213000,
    );
    return h.service.downloadList.single as YtDownloadEntry;
  }

  Map<dynamic, dynamic>? history() =>
      LocalHistory.box.get(LocalHistory.ytKey(ytId)) as Map?;

  test('as a page (the cache page, the group page), the export kept', () async {
    final e = await start();
    final before = history();
    expect(before, isNotNull);
    await h.service.platformOf(e).onDeleted([e]);
    await h.service.deletePage(pageDirPath: e.pageDirPath);
    expect(Directory(e.pageDirPath).existsSync(), isFalse);
    expect(h.service.downloadList, isEmpty);
    expect(mp4.existsSync(), isTrue);
    expect(history(), before);
  });

  test('as an entry (the search page), the export deleted too', () async {
    final e = await start();
    final before = history();
    await h.service.platformOf(e).onDeleted([e]);
    await h.service.deleteDownload(
      entry: e,
      removeList: true,
      deleteExported: true,
    );
    expect(Directory(e.pageDirPath).existsSync(), isFalse);
    expect(mp4.existsSync(), isFalse);
    expect(history(), before);
  });
}
