// LibrePili: a start in the platform's steps (stage-2 plan
// feature-logs/download-platforms/phase2-plan.md §2.3-§2.4): the service
// checks the start's generation after the play URL and after the cover, an
// unreadable stream index keeps the bytes, and bilibili's failed play URL
// is logged as it always was. Bilibili entries on the service's real start
// path, fake play URLs and transfers (design AC1 「基线提交加的注入点」).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

Map<String, Object?> queued(String entry, Map<String, dynamic> json) => {
  ...json,
  'is_completed': false,
  'downloaded_bytes': 0,
};

/// The stream index's `.tmp` of [folder], written only once [gate]
/// completes, into its folder made again should it be gone (as the cover's
/// download makes its folder): what a write still under way when the entry
/// is deleted does. Every other file is left as it is.
final class _SlowIndex extends IOOverrides {
  _SlowIndex(this.folder, this.gate);

  final String folder;
  final Future<void> gate;

  /// The `.tmp` asked for: its write is waiting for [gate].
  final asked = Completer<void>();

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    if (file.endsWith('index.json.tmp') && path.isWithin(folder, file)) {
      return _GatedTmp(made, gate, asked);
    }
    return made;
  }
}

/// Only what the stream index's save does with its `.tmp` is passed on.
class _GatedTmp implements File {
  _GatedTmp(this._file, this._gate, this._asked);

  final File _file;
  final Future<void> _gate;
  final Completer<void> _asked;

  @override
  String get path => _file.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (!_asked.isCompleted) _asked.complete();
    await _gate;
    _file.parent.createSync(recursive: true);
    return _file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) => _file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not passed on: ${invocation.memberName}');
}

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  late BiliDownloadEntryInfo p1;

  /// The transfers left running unless a test says otherwise.
  Future<void> start() async {
    h.onTransport = (_) {};
    await h.start(patch: queued);
    p1 = h.entry(fixtureP1);
  }

  /// A stream folder of [p1] for [tag], its `index.json` the one of [plan]
  /// (or [index] as it is), with [bytes] of video in it.
  Directory streamFolder(
    String tag, {
    BiliDownloadMediaInfo? plan,
    String? index,
    int bytes = 1000,
  }) {
    final dir = Directory(path.join(p1.entryDirPath, tag))
      ..createSync(recursive: true);
    File(
      path.join(dir.path, 'index.json'),
    ).writeAsStringSync(index ?? jsonEncode(plan!.toJson()));
    File(
      path.join(dir.path, 'video.m4s'),
    ).writeAsBytesSync(List.filled(bytes, 7));
    return dir;
  }

  test('paused while the play URL is fetched: another quality\'s stream '
      'folder, whose index is another stream, keeps its bytes', () async {
    await start();
    // quality 64 was downloaded before, with another stream than the one
    // the play URL is about to give
    final other = streamFolder('64', plan: dashPlan(id: 64, width: 960));
    final gate = Completer<void>();
    final asked = Completer<void>();
    DownloadService.getVideoUrlForTest =
        ({required entry, source, pageData, ep}) async {
          asked.complete();
          await gate.future;
          // the play URL writes the quality it got into the entry
          entry.typeTag = '64';
          return dashPlan(id: 64, width: 1280);
        };
    final started = h.service.startDownload(p1);
    await asked.future;
    await h.service.cancelDownload(isDelete: false, downloadNext: false);
    gate.complete();
    await started;
    await settle();

    expect(other.existsSync(), isTrue);
    expect(File(path.join(other.path, 'video.m4s')).lengthSync(), 1000);
    expect(h.transports, isEmpty);
  });

  test('deleted while the cover and the stream index are written: no '
      'folder of it is left behind', () async {
    await start();
    final gate = Completer<void>();
    final slow = _SlowIndex(p1.entryDirPath, gate.future);
    final started = IOOverrides.runWithIOOverrides(
      () => h.service.startDownload(p1),
      slow,
    );
    await slow.asked.future;
    await h.service.deleteDownload(
      entry: p1,
      removeQueue: true,
      downloadNext: false,
    );
    expect(Directory(p1.entryDirPath).existsSync(), isFalse);
    // the index's write lands now, in the folder it makes again
    gate.complete();
    await started;
    await settle();

    expect(Directory(p1.entryDirPath).existsSync(), isFalse);
    expect(h.transports, isEmpty);
  });

  test('a stream index that cannot be read: the bytes beside it are kept '
      'and resumed', () async {
    await start();
    // the quality the entry has, its index torn
    final dir = streamFolder(p1.streamTypeTag, index: '{"video": [');
    h.service.startDownload(p1);
    await until(() => h.transports.isNotEmpty);
    await settle();

    final video = File(path.join(dir.path, 'video.m4s'));
    expect(video.existsSync(), isTrue);
    expect(video.lengthSync(), 1000);
    expect(h.transports.single.path, video.path);
  });

  test('a failed play URL: retried, its line says no error of its own, as '
      'it always did', () async {
    await start();
    DownloadService.getVideoUrlForTest =
        ({required entry, source, pageData, ep}) async =>
            // what DownloadHttp.getVideoUrl throws: the answer's text
            throw 'no play url';
    h.service.startDownload(p1, retry: false);
    await until(
      () => h.log.any(
        (l) =>
            l.contains(' ${p1.logLabel}: failPlayUrl (') &&
            l.contains('no more retries'),
      ),
      reason: 'the retries given up',
    );

    expect(p1.status, DownloadStatus.failPlayUrl);
    final again = h.log.where(
      (l) => l.contains(' ${p1.logLabel}: ') && l.contains('again in'),
    );
    expect(
      again,
      [
        '${p1.logLabel}: failPlayUrl (-), again in 0 s (1/3)',
        '${p1.logLabel}: failPlayUrl (-), again in 0 s (2/3)',
        '${p1.logLabel}: failPlayUrl (-), again in 0 s (3/3)',
      ].map(endsWith).toList(),
    );
  });
}
