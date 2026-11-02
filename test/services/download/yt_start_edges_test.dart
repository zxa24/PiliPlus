// LibrePili (review of 2e): a YouTube start's edges. A stream whose length
// cannot be read does not stop the start (it goes the normal way); the pin
// keeps the audio track and the DRC mark from stream.json, and the pick
// prefers non-DRC; "both streams whole" is the transfer's own rule (a
// `.size` that disagrees is not whole); what the start found is saved even
// when another start comes right after; the pair's own source says whether
// the video is live; the download's own router health goes with it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

const _otherId = 'jNQXAC9IVRw';
const _v = 300 * 1024 + 5;
const _a = 120 * 1024 + 3;

/// The first `video.m4s` made in its zone cannot tell its length.
final class _NoLength extends IOOverrides {
  var _done = false;

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    if (_done || path.basename(file) != 'video.m4s') return made;
    _done = true;
    return _Unmeasured(made);
  }
}

class _Unmeasured implements File {
  _Unmeasured(this._file);

  final File _file;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => true;

  @override
  int lengthSync() =>
      throw FileSystemException('the length cannot be read', _file.path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every `entry.librepili.json.tmp` written in its zone waits for [gate]:
/// a save of the record held, the ones behind it in its folder's chain
/// with it.
final class _HeldSave extends IOOverrides {
  _HeldSave(this.gate);

  final Future<void> gate;

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return path.basename(file) == '${YtDownloadEntry.recordFile}.tmp'
        ? _HeldTmp(made, gate)
        : made;
  }
}

class _HeldTmp implements File {
  _HeldTmp(this._file, this._gate);

  final File _file;
  final Future<void> _gate;

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
    await _gate;
    return _file.writeAsString(contents, mode: mode, flush: flush);
  }

  @override
  Future<File> rename(String newPath) => _file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A transfer that only does what a test tells it.
class _Transfer implements DownloadTransfer {
  _Transfer(this.report);

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

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage(inMemory: true));
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  YtDownloadEntry record(Directory root) => ytEntry(root, maxHeight: 1080);

  /// [tag]'s folder: the two streams' identities, [video] / [audio] bytes
  /// of each on disk (null: all of it).
  void plant(
    Directory root,
    String tag, {
    int? video,
    int? audio,
    String? track,
    bool drc = false,
  }) {
    final dir = Directory(path.join(root.path, 'yt_$ytId', 'main', tag))
      ..createSync(recursive: true);
    final v = h.server.bodies['video']!;
    final a = h.server.bodies['audio']!;
    File(
      path.join(dir.path, 'video.m4s'),
    ).writeAsBytesSync(v.sublist(0, video ?? v.length));
    File(
      path.join(dir.path, 'audio.m4s'),
    ).writeAsBytesSync(a.sublist(0, audio ?? a.length));
    File(path.join(dir.path, 'stream.json')).writeAsStringSync(
      PairFixture.jsonText(
        const YtStreamId(itag: 137, bytes: _v, lmt: 'v1'),
        YtStreamId(
          itag: 140,
          track: track,
          isDefault: true,
          drc: drc,
          bytes: _a,
          lmt: 'a1',
        ),
      ),
    );
  }

  YtDownloadPlatform platformOf(YtDownloadEntry e) =>
      h.service.platformOf(e) as YtDownloadPlatform;

  test(
    "a stream whose length cannot be read: the start goes on (it is not "
    'stuck before its failure handling)',
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140'],
        before: (root) => plant(root, '137-140', video: 200000),
      );
      final e = h.entry();
      IOOverrides.runWithIOOverrides(() {
        unawaited(h.service.startDownload(e));
      }, _NoLength());
      await h.untilStatus(e);
      expect(e.isCompleted, isTrue);
    },
  );

  test(
    'the pin from stream.json: its track id and DRC mark; the pick prefers '
    'non-DRC',
    () async {
      final digest = ytAudioTrackDigest('en.4')!;
      final tag = '137-140.$digest.drc';
      await h.start(
        records: [(root) => record(root)..streamTag = tag],
        formats: [
          ytVideoFormat(137, bytes: _v),
          ytAudioFormat(140, bytes: _a, track: 'en.4', drc: true),
          ytAudioFormat(140, bytes: _a, track: 'en.4'),
        ],
        before: (root) =>
            plant(root, tag, audio: 50000, track: 'en.4', drc: true),
      );
      final e = h.entry();
      await h.run(e);
      final first = h.direct.preferences.first;
      expect(first.pin?.audioTrackId, 'en.4');
      expect(first.pin?.drc, isTrue);
      expect(first.preferNonDrc, isTrue);
      expect(e.streamTag, tag);
    },
  );

  test(
    "both streams whole but a `.size` that disagrees: not whole — a "
    'resolve, no failure',
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140'],
        before: (root) {
          plant(root, '137-140');
          File(
            path.join(
              root.path,
              'yt_$ytId',
              'main',
              '137-140',
              'video.m4s.size',
            ),
          ).writeAsStringSync('999');
        },
      );
      final e = h.entry();
      await h.run(e);
      expect(h.routers, isNotEmpty);
      expect(h.log.where((l) => l.contains('again in')), isEmpty);
      expect(h.log, contains(contains('video restarted from 0 (size)')));
    },
  );

  test(
    'saved once taken, though another start comes before the save',
    () async {
      final transfers = <_Transfer>[];
      h.newTransfer = (spec, report) => _Transfer(report)..also(transfers.add);
      await h.start(
        records: [
          record,
          (root) => ytEntry(root, id: _otherId, maxHeight: 1080),
        ],
      );
      final e = h.entry();
      // the folder's saves held behind one already under way
      final gate = Completer<void>();
      IOOverrides.runWithIOOverrides(() {
        unawaited(h.service.saveEntryForTest(e));
      }, _HeldSave(gate.future));
      unawaited(h.service.startDownload(e));
      await until(() => transfers.isNotEmpty, reason: 'its transfer');
      // another start bumps the generation at once (it waits for this
      // start's lock, which waits for the held save); this one is then
      // paused unsaved
      unawaited(h.service.startDownload(h.entry(_otherId)));
      gate.complete();
      await until(() => transfers.length == 2, reason: 'the other transfer');
      await settle(200);
      expect((await h.record(e))['stream_tag'], '137-140');
    },
  );

  test(
    "the pair from the other (direct) source: that source's detail says it "
    'is live',
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140'],
        before: (root) => plant(root, '137-140', video: 200000),
      );
      // direct does not answer the shared calls (the detail through its
      // retries, then the streams): Invidious does, without the pinned 137
      h.direct
        ..detailFailures.addAll(
          List.filled(4, const YtVerdict(YtCause.transient, 'timeout')),
        )
        ..streamFailures.add(const YtVerdict(YtCause.transient, 'timeout'))
        ..liveIds.add(ytId);
      h.invidious.formats = [
        ytVideoFormat(399, codec: 'av01.0.08M.08', bytes: _v),
        ytAudioFormat(140, bytes: _a),
      ];
      final e = h.entry();
      await h.run(e, status: DownloadStatus.failNoFormat);
      expect(h.service.lastError, 'live or upcoming');
      expect(h.routers.last.own, isTrue);
    },
  );

  test(
    "the download deleted while its own router asks: its health goes",
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140'],
        before: (root) => plant(root, '137-140', video: 200000),
      );
      h.direct.formats = [
        ytVideoFormat(399, codec: 'av01.0.08M.08', bytes: _v),
        ytAudioFormat(140, bytes: _a),
      ];
      final held = Completer<void>();
      final release = Completer<void>();
      h.invidious.holdStreams = () {
        if (!held.isCompleted) held.complete();
        return release.future;
      };
      final e = h.entry();
      unawaited(h.service.startDownload(e));
      await held.future;
      await h.service.deleteDownload(entry: e, removeQueue: true);
      release.complete();
      await settle(200);
      expect(platformOf(e).ownHealthForTest, isNot(contains(e.key)));
    },
  );

  test(
    'a merge that fails (not damaged) ends the download: its health goes',
    () async {
      await h.start(
        records: [(root) => record(root)..streamTag = '137-140'],
        before: (root) => plant(root, '137-140', video: 200000),
      );
      // the pinned 137 only on Invidious: asked through the own router
      h.direct.formats = [
        ytVideoFormat(399, codec: 'av01.0.08M.08', bytes: _v),
        ytAudioFormat(140, bytes: _a),
      ];
      h.remuxError = StateError('the remuxer gave up');
      final e = h.entry();
      await h.run(e);
      expect(e.mergedPath, isNull);
      expect(platformOf(e).ownHealthForTest, isNot(contains(e.key)));
    },
  );

  test('initialBytes: a length that cannot be read counts as 0', () async {
    await h.start(
      records: [(root) => record(root)..streamTag = '137-140'],
      before: (root) => plant(root, '137-140', video: 200000),
    );
    final e = h.entry();
    final got = IOOverrides.runWithIOOverrides(
      () => platformOf(e).initialBytes(e),
      _NoLength(),
    );
    expect(got.video, (0, _v));
    expect(got.audio, (_a, _a));
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
