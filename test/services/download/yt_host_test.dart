// LibrePili: the handle's transfer slot and saves as a YouTube download
// uses them (stage-2 plan §2.2, design §4.4; AC16's second part). The
// callbacks `attach` builds are the service's: each first checks that the
// slot still holds its transfer, so one that comes late (a transfer
// replaced by the next download's) changes nothing; `attach` takes no
// transfer for a start that is no longer the current one; `videoDone`
// does not merge; the record's total is both streams'; the handle's saves
// of one folder go one after another.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

/// A transfer that only does what a test tells it through [report].
class _Transfer implements DownloadTransfer {
  _Transfer(this.spec, this.report);

  final YtTransferSpec spec;
  final DownloadTransferReport report;
  final _task = Completer<void>();

  @override
  DownloadStatus status = DownloadStatus.downloading;

  @override
  Future<void> get task => _task.future;

  @override
  Future<void> cancel({required bool isDelete}) async {
    if (!isDelete) status = DownloadStatus.pause;
    if (!_task.isCompleted) _task.complete();
  }
}

const _otherId = 'jNQXAC9IVRw';

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  final transfers = <_Transfer>[];
  setUp(transfers.clear);

  Future<void> start() async {
    h.newTransfer = (spec, report) {
      final t = _Transfer(spec, report);
      transfers.add(t);
      return t;
    };
    await h.start(
      records: [
        (root) => ytEntry(root, maxHeight: 1080),
        (root) => ytEntry(root, id: _otherId, maxHeight: 1080),
      ],
    );
  }

  /// Starts [e] and waits for its transfer.
  Future<_Transfer> transferOf(YtDownloadEntry e) async {
    final n = transfers.length;
    unawaited(h.service.startDownload(e));
    await until(() => transfers.length > n, reason: 'a transfer of $e');
    return transfers.last;
  }

  test(
    "a late done of the first transfer: the second download's state, "
    'record and bytes unchanged, no merge (AC16)',
    () async {
      await start();
      final first = h.entry();
      final second = h.entry(_otherId);
      final a = await transferOf(first);
      a.report.video(1000, 4000);
      await h.service.cancelDownload(isDelete: false);
      final b = await transferOf(second);
      b.report.video(10, 300);
      await settle();
      final status = second.status;
      final bytes = second.downloadedBytes;
      final record = await h.record(second);
      // the first transfer's closures, called past its own guard: after
      // each, the second download as it was (a later one could undo what
      // an earlier one changed)
      for (final late in <void Function()>[
        () => a.report.video(4000, 4000),
        () => a.report.audio(50, 50),
        a.report.videoDone,
        a.report.done,
      ]) {
        late();
        await settle();
        expect(second.status, status);
        expect(second.downloadedBytes, bytes);
      }
      await settle(100);
      expect(second.status, status);
      expect(second.downloadedBytes, bytes);
      expect(await h.record(second), record);
      expect(h.beforeMerge, isEmpty);
      expect(identical(h.service.curDownload.value, second), isTrue);
    },
  );

  test(
    'a start no longer current: attach takes nothing, build not called',
    () async {
      await start();
      final e = h.entry();
      final a = await transferOf(e);
      // not live: a second transfer is then not refused for that alone
      a.status = DownloadStatus.completed;
      var built = 0;
      final got = h.service.hostForTest.attach(
        h.service.startGenForTest - 1,
        e,
        (report) {
          built++;
          return _Transfer(a.spec, report);
        },
      );
      expect(got, isNull);
      expect(built, 0);
    },
  );

  test(
    'videoDone while the audio is downloading: no merge',
    () async {
      await start();
      final e = h.entry();
      final a = await transferOf(e);
      a.report.video(4000, 4000);
      a.status = DownloadStatus.audioDownloading;
      a.report.videoDone();
      await settle(100);
      expect(h.beforeMerge, isEmpty);
      expect(e.status, DownloadStatus.audioDownloading);
      expect(e.isCompleted, isFalse);
    },
  );

  test("the record's total: both streams', the bytes both", () async {
    await start();
    final e = h.entry();
    final a = await transferOf(e);
    a.report.video(1000, 4000);
    a.report.audio(30, 500);
    expect(e.totalBytes, 4500);
    expect(e.downloadedBytes, 1030);
    await h.service.saveEntryForTest(e);
    expect((await h.record(e))['total_bytes'], 4500);
  });

  test(
    "the handle's saves of one folder: the second's write after the "
    "first's rename",
    () async {
      await start();
      final e = h.entry();
      await transferOf(e);
      final events = <String>[];
      final gen = h.service.startGenForTest;
      await IOOverrides.runWithIOOverrides(
        () => Future.wait([
          h.service.hostForTest.save(gen, e..downloadedBytes = 1),
          h.service.hostForTest.save(gen, e..downloadedBytes = 2),
        ]),
        _WatchTmp(events),
      );
      expect(events, [
        'write start',
        'write end',
        'rename',
        'write start',
        'write end',
        'rename',
      ]);
      expect((await h.record(e))['downloaded_bytes'], 2);
    },
  );
}

/// Records the writes and renames of `entry.librepili.json.tmp`.
final class _WatchTmp extends IOOverrides {
  _WatchTmp(this.events);

  final List<String> events;

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return path.basename(file) == '${YtDownloadEntry.recordFile}.tmp'
        ? _Watched(made, events)
        : made;
  }
}

class _Watched implements File {
  _Watched(this._file, this._events);

  final File _file;
  final List<String> _events;

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
  }) async {
    _events.add('write start');
    // a turn for an overlapping save to get in, if nothing keeps it out
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final f = await _file.writeAsString(contents, mode: mode, flush: flush);
    _events.add('write end');
    return f;
  }

  @override
  Future<File> rename(String newPath) async {
    final f = await _file.rename(newPath);
    _events.add('rename');
    return f;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
