// LibrePili: a new YouTube download from the panel (stage-2 plan §3.2
// 「新建」; AC14): only after the list is read, never over a record already
// on disk — the same id (listed or not), an id that differs only in letter
// case (one folder on Windows and macOS), or a record this build cannot
// read. In none of those is anything written or cleaned up. A folder of
// streams with no record is reused.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
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
  tearDown(h.stop);

  /// Every file under `yt_<id>` with its bytes.
  Map<String, String> snapshot(String id) {
    final dir = Directory(path.join(h.root.path, 'yt_$id'));
    return {
      for (final f in dir.listSync(recursive: true).whereType<File>())
        path.relative(f.path, from: dir.path): base64.encode(
          f.readAsBytesSync(),
        ),
    };
  }

  test('no record: added, its record written, queued', () async {
    await h.start(entries: const []);
    final result = await YtDownloadPlatform.create(
      h.service,
      ytDetail(),
      720,
    );
    expect(result, YtCreateResult.added);
    expect(result.message, '已加入下载队列');
    final record = File(
      path.join(h.root.path, 'yt_$ytId', 'main', YtDownloadEntry.recordFile),
    );
    expect(record.existsSync(), isTrue);
    final json = jsonDecode(await readRecord(record)) as Map<String, dynamic>;
    expect(json['video_id'], ytId);
    expect(json['max_height'], 720);
    expect(json['quality_label'], '720p');
    expect(
      [
        ...h.service.waitDownloadQueue,
        ?h.service.curDownload.value,
      ].map((e) => e.key),
      contains('yt:$ytId'),
    );

    // a second tap: in the queue now
    expect(
      await YtDownloadPlatform.create(h.service, ytDetail(), 720),
      YtCreateResult.queued,
    );
  });

  test('two taps at once: one entry', () async {
    await h.start(entries: const []);
    final results = await Future.wait([
      YtDownloadPlatform.create(h.service, ytDetail(), 720),
      YtDownloadPlatform.create(h.service, ytDetail(), 720),
    ]);
    expect(
      results,
      unorderedEquals([
        YtCreateResult.added,
        YtCreateResult.queued,
      ]),
    );
    expect(
      h.service.waitDownloadQueue.where((e) => e.key == 'yt:$ytId'),
      hasLength(1),
    );
  });

  test(
    'a folder of streams without a record: reused, the streams kept',
    () async {
      await h.start(
        entries: const [],
        before: (root) {
          final streams = Directory(
            path.join(ytFolder(root, ytId).path, '137-140'),
          )..createSync();
          File(path.join(streams.path, 'video.mp4'))
              .writeAsBytesSync([1, 2, 3]);
        },
      );
      expect(
        await YtDownloadPlatform.create(h.service, ytDetail(), 1080),
        YtCreateResult.added,
      );
      expect(
        File(
          path.join(h.root.path, 'yt_$ytId', 'main', '137-140', 'video.mp4'),
        ).readAsBytesSync(),
        [1, 2, 3],
      );
    },
  );

  test('completed and listed: 已下载, nothing written', () async {
    await h.start(
      entries: const [],
      before: (root) => writeYtRecord(root, ytEntry(root, completed: true)),
    );
    final before = snapshot(ytId);
    expect(
      await YtDownloadPlatform.create(h.service, ytDetail(), 720),
      YtCreateResult.done,
    );
    expect(snapshot(ytId), before);
  });

  test('a record the list does not hold (written after it was read): not '
      'made again', () async {
    await h.start(entries: const []);
    writeYtRecord(h.root, ytEntry(h.root, completed: true));
    final before = snapshot(ytId);
    final result = await YtDownloadPlatform.create(h.service, ytDetail(), 720);
    expect(result, YtCreateResult.recordExists);
    expect(result.message, '该视频已有下载记录，请重新进入缓存页');
    expect(snapshot(ytId), before);
    expect(h.service.waitDownloadQueue, isEmpty);
  });

  test('an id differing only in case: refused, nothing written', () async {
    await h.start(entries: const []);
    // the folder of dQw4w9WgXcQ holding dQw4w9WgXcq's record: what a
    // case-insensitive file system shows for yt_dQw4w9WgXcq
    writeYtRecord(
      h.root,
      ytEntry(h.root, id: 'dQw4w9WgXcq', completed: true),
      folderId: ytId,
    );
    final before = snapshot(ytId);
    final result = await YtDownloadPlatform.create(h.service, ytDetail(), 720);
    expect(result, YtCreateResult.caseConflict);
    expect(snapshot(ytId), before);
    expect(
      YtDownloadPlatform.checkExisting(h.root.path, ytId),
      isA<YtCaseConflict>().having((c) => c.otherId, 'otherId', 'dQw4w9WgXcq'),
    );
  });

  test('a record this build cannot read: refused, its folder named, nothing '
      'written', () async {
    await h.start(entries: const []);
    final file = writeYtRecord(h.root, ytEntry(h.root), raw: '{"format": 2');
    final before = snapshot(ytId);
    String? named;
    final result = await YtDownloadPlatform.create(
      h.service,
      ytDetail(),
      720,
      unreadable: (folder) => named = folder,
    );
    expect(result, YtCreateResult.unreadable);
    expect(named, file.parent.path);
    expect(snapshot(ytId), before);
    expect(h.service.waitDownloadQueue, isEmpty);
  });

  test('a record of a platform this build does not know: unreadable', () async {
    await h.start(entries: const []);
    final e = ytEntry(h.root);
    writeYtRecord(h.root, e, raw: jsonEncode(e.toJson()..['platform'] = 'foo'));
    expect(
      YtDownloadPlatform.checkExisting(h.root.path, ytId),
      isA<YtUnreadable>(),
    );
  });

  test('while the list is still being read: waits for it, then finds the '
      'completed download', () async {
    final gate = Completer<void>();
    DownloadService.readListGateForTest = () => gate.future;
    final started = h.start(
      entries: const [],
      before: (root) => writeYtRecord(root, ytEntry(root, completed: true)),
    );
    // the service is made and reading (held at the gate)
    await pumpEventQueue();
    final service = h.service;
    YtCreateResult? result;
    final create = YtDownloadPlatform.create(service, ytDetail(), 720).then(
      (r) => result = r,
    );
    await pumpEventQueue();
    expect(result, isNull, reason: 'answered before the list was read');
    gate.complete();
    await started;
    await create;
    expect(result, YtCreateResult.done);
  });

  // review 2bc: case-only ids, a tap while the first is writing, a failed
  // save
  test('ids that differ only in case, at once: one added, the other '
      'queued (one folder on Windows and macOS)', () async {
    await h.start(entries: const []);
    final results = await Future.wait([
      YtDownloadPlatform.create(h.service, ytDetail(), 720),
      YtDownloadPlatform.create(h.service, ytDetail(id: 'dQw4w9WgXcq'), 720),
    ]);
    expect(results, [YtCreateResult.added, YtCreateResult.queued]);
    expect(
      h.service.waitDownloadQueue.where((e) => e.key.startsWith('yt:')),
      hasLength(1),
    );
    final record = File(
      path.join(h.root.path, 'yt_$ytId', 'main', YtDownloadEntry.recordFile),
    );
    expect(
      (jsonDecode(await readRecord(record)) as Map)['video_id'],
      ytId,
    );
  });

  test('a second tap while the first has written its .tmp but not renamed '
      'it: 已在下载队列中, the .tmp not read', () async {
    await h.start(entries: const []);
    final hold = Completer<void>();
    final first = IOOverrides.runWithIOOverrides(
      () => YtDownloadPlatform.create(h.service, ytDetail(), 720),
      _RecordTmp(rename: hold.future),
    );
    final tmp = File(
      path.join(
        h.root.path,
        'yt_$ytId',
        'main',
        '${YtDownloadEntry.recordFile}.tmp',
      ),
    );
    await until(tmp.existsSync, reason: 'the first tap writing its .tmp');
    for (final id in [ytId, 'dQw4w9WgXcq']) {
      expect(
        await YtDownloadPlatform.create(h.service, ytDetail(id: id), 720),
        YtCreateResult.queued,
        reason: id,
      );
    }
    hold.complete();
    expect(await first, YtCreateResult.added);
  });

  test('a save that fails: failed, what it wrote removed, nothing queued; '
      'a later tap adds it', () async {
    await h.start(entries: const []);
    final result = await IOOverrides.runWithIOOverrides(
      () => YtDownloadPlatform.create(h.service, ytDetail(), 720),
      _RecordTmp(fail: true),
    );
    expect(result, YtCreateResult.failed);
    expect(result.message, '下载记录写入失败，请检查下载目录');
    expect(Directory(path.join(h.root.path, 'yt_$ytId')).existsSync(), isFalse);
    expect(h.service.waitDownloadQueue, isEmpty);
    expect(h.service.curDownload.value, isNull);
    expect(
      await YtDownloadPlatform.create(h.service, ytDetail(), 720),
      YtCreateResult.added,
    );
  });

  test('a save that fails in a folder of streams: the streams stay', () async {
    late File video;
    await h.start(
      entries: const [],
      before: (root) {
        final streams = Directory(
          path.join(ytFolder(root, ytId).path, '137-140'),
        )..createSync();
        video = File(path.join(streams.path, 'video.mp4'))
          ..writeAsBytesSync([1, 2, 3]);
      },
    );
    final result = await IOOverrides.runWithIOOverrides(
      () => YtDownloadPlatform.create(h.service, ytDetail(), 1080),
      _RecordTmp(fail: true),
    );
    expect(result, YtCreateResult.failed);
    expect(video.readAsBytesSync(), [1, 2, 3]);
    expect(
      Directory(
        path.join(h.root.path, 'yt_$ytId', 'main'),
      ).listSync().map((e) => path.basename(e.path)),
      ['137-140'],
    );
  });
}

/// The record's `.tmp`: its rename held until [rename] completes, or its
/// write failing ([fail]).
final class _RecordTmp extends IOOverrides {
  _RecordTmp({this.rename, this.fail = false});

  final Future<void>? rename;
  final bool fail;

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return file.endsWith('${YtDownloadEntry.recordFile}.tmp')
        ? _Tmp(made, this)
        : made;
  }
}

class _Tmp implements File {
  _Tmp(this._file, this._how);

  final File _file;
  final _RecordTmp _how;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    if (_how.fail) throw const FileSystemException('disk full');
    return _file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) async {
    await _how.rename;
    return _file.rename(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _file.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
