// LibrePili: the YouTube pair transfer as the service sees it (design
// §4.4, stage-2 plan §3.4; AC16's first part). Nothing is called back from
// the constructor; every callback comes from within `task` (none after
// it); none after `cancel`, which sets `pause` before it closes the
// client; a pause reports no failure; one stream failing stops the other
// and reports once, with the stream that failed.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_transfer_errors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_download_test_support.dart';

void main() {
  setUpPairTransfer();
  late Directory root;
  late PairFixture f;
  late PairCalls calls;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yt-pair-');
    f = PairFixture(root);
    calls = PairCalls();
  });
  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// Holds [stream]'s body once it reaches [offset]; [reached] completes
  /// then. The hold ends when the client is closed.
  Completer<void> holdAt(String stream, int offset) {
    final reached = Completer<void>();
    final before = f.server.pace;
    f.server.pace = (s, o) async {
      await before?.call(s, o);
      if (s == stream && o >= offset) {
        if (!reached.isCompleted) reached.complete();
        await Completer<void>().future;
      }
    };
    return reached;
  }

  test(
    'both streams already complete: nothing called back in the constructor',
    () async {
      f
        ..plant('video')
        ..plant('audio')
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      final t = f.start(calls);
      expect(calls.count, 0);
      await t.task;
      expect(calls.videoDone, 1);
      expect(calls.done, 1);
      expect(calls.errors, isEmpty);
      expect(f.server.requests, isEmpty);
    },
  );

  test(
    'done is called within the task: once, and nothing after it',
    () async {
      final t = f.start(calls);
      await t.task;
      expect(calls.done, 1);
      final count = calls.count;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls.count, count);
      expect(calls.calls.last, 'done');
    },
  );

  test(
    'progress before a cancel, none after it; no done (AC16)',
    () async {
      late YtPairTransfer t;
      var atCancel = -1;
      Future<void>? cancelled;
      // the cancel lands between a piece written and its report, one due
      // (more than the 200 ms between reports since the last): the report
      // must not go out
      f.server.pace = (stream, offset) async {
        if (stream == 'video' && offset == 48 << 10) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      };
      YtPairTransfer.selfTestOnBytes = (stream, onDisk) {
        if (stream == 'video' && onDisk >= 64 << 10 && cancelled == null) {
          atCancel = calls.count;
          cancelled = t.cancel(isDelete: false);
        }
      };
      t = f.start(calls);
      await t.task;
      await cancelled;
      expect(calls.video, greaterThan(0));
      expect(atCancel, greaterThan(0));
      expect(calls.count, atCancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls.count, atCancel);
      expect(calls.done, 0);
      expect(t.status, DownloadStatus.pause);
    },
  );

  test('a cancel sets pause before the client is closed', () async {
    final reached = holdAt('video', 32 << 10);
    final t = f.start(calls);
    final seen = <DownloadStatus>[];
    f.server.onClose = () => seen.add(t.status);
    await reached.future;
    await t.cancel(isDelete: false);
    expect(seen, isNotEmpty);
    expect(seen, everyElement(DownloadStatus.pause));
  });

  test(
    'a pause mid-body: no done, the status stays pause, bytes kept',
    () async {
      final reached = holdAt('video', 32 << 10);
      final t = f.start(calls);
      await reached.future;
      await t.cancel(isDelete: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls.done, 0);
      expect(t.status, DownloadStatus.pause);
      expect(f.file('video').lengthSync(), greaterThan(0));
    },
  );

  test('a delete mid-body: no callback after it, not pause', () async {
    final reached = holdAt('video', 32 << 10);
    final t = f.start(calls);
    await reached.future;
    final count = calls.count;
    await t.cancel(isDelete: true);
    expect(calls.count, count);
    expect(t.status, isNot(DownloadStatus.pause));
  });

  test('a cancel before the first turn: nothing asked, nothing said', () async {
    final t = f.start(calls);
    await t.cancel(isDelete: false);
    expect(calls.count, 0);
    expect(f.server.requests, isEmpty);
    expect(t.status, DownloadStatus.pause);
  });

  test(
    'the audio fails: the video stopped, one done with the audio',
    () async {
      // the video held mid-body; the audio's 403 comes after that
      final reached = holdAt('video', 32 << 10);
      final held = f.server.pace!;
      f.server
        ..pace = (s, o) async {
          if (s == 'audio') await reached.future;
          await held(s, o);
        }
        ..script = (s, n, _) =>
            s == 'audio' && n == 1 ? const FakeAnswer.status(403) : null;
      final t = f.start(calls);
      await t.task;
      expect(calls.done, 1);
      final error = calls.errors.single as YtTransferError;
      expect(error.stream, 'audio');
      expect((error.cause as YtHttpStatus).code, 403);
      expect(t.status, DownloadStatus.failDownloadAudio);
      expect(calls.videoDone, 0);
    },
  );

  test(
    'the video fails while the audio is held: one done, with the video',
    () async {
      // the audio held mid-body; the video's 410 comes after that
      final reached = holdAt('audio', 16 << 10);
      final held = f.server.pace!;
      f.server
        ..pace = (s, o) async {
          if (s == 'video') await reached.future;
          await held(s, o);
        }
        ..script = (s, n, _) =>
            s == 'video' && n == 1 ? const FakeAnswer.status(410) : null;
      final t = f.start(calls);
      await t.task;
      expect(reached.isCompleted, isTrue);
      expect(calls.done, 1);
      expect((calls.errors.single as YtTransferError).stream, 'video');
      expect(t.status, DownloadStatus.failDownload);
      // the audio's bytes are kept for the next start
      expect(f.file('audio').lengthSync(), greaterThan(0));
    },
  );

  test(
    'the video done first: videoDone, then audioDownloading, then done',
    () async {
      final release = Completer<void>();
      final reached = Completer<void>();
      f.server.pace = (s, o) async {
        if (s == 'audio' && o >= 16 << 10) {
          if (!reached.isCompleted) reached.complete();
          await release.future;
        }
      };
      final t = f.start(calls);
      final atVideoDone = <DownloadStatus>[];
      calls.onCall = (call) {
        if (call == 'videoDone') {
          atVideoDone.add(t.status);
          release.complete();
        }
      };
      await t.task;
      expect(atVideoDone, [DownloadStatus.audioDownloading]);
      expect(
        calls.calls.indexOf('videoDone'),
        lessThan(calls.calls.indexOf('done')),
      );
      expect(t.status, DownloadStatus.completed);
      expect(calls.errors, isEmpty);
    },
  );

  test(
    'the audio done first: still downloading until the video is',
    () async {
      final release = Completer<void>();
      f.server.pace = (s, o) async {
        if (s == 'video' && o >= 16 << 10) await release.future;
      };
      final t = f.start(calls);
      final statuses = <DownloadStatus>[];
      calls.onCall = (call) {
        statuses.add(t.status);
        if (call == 'audio' &&
            calls.lastAudio!.$1 == f.body('audio').length &&
            !release.isCompleted) {
          release.complete();
        }
      };
      await t.task;
      expect(statuses.contains(DownloadStatus.audioDownloading), isFalse);
      expect(calls.videoDone, 1);
      expect(calls.calls.last, 'done');
    },
  );

  test('both fail: one done', () async {
    f.server.script = (s, n, _) => const FakeAnswer.status(404);
    final t = f.start(calls);
    await t.task;
    expect(calls.done, 1);
    expect(
      t.status,
      anyOf(DownloadStatus.failDownload, DownloadStatus.failDownloadAudio),
    );
  });

  test(
    'a resume: first reported at what is on disk, of its own total (p4#4)',
    () async {
      f
        ..plant('video', 200000)
        ..plant('audio', 50000)
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      final t = f.start(calls);
      await t.task;
      final v = f.body('video').length;
      final a = f.body('audio').length;
      expect(
        calls.calls.where((c) => c.startsWith('video')).first,
        'video 200000/$v',
      );
      expect(
        calls.calls.where((c) => c.startsWith('audio')).first,
        'audio 50000/$a',
      );
      for (final c in calls.calls.where((c) => c.contains('/'))) {
        final [got, of] = c.split(' ').last.split('/').map(int.parse).toList();
        expect(got, lessThanOrEqualTo(of), reason: c);
      }
    },
  );

  test('progress: each stream its own bytes and total', () async {
    final t = f.start(calls);
    await t.task;
    final v = f.body('video').length;
    final a = f.body('audio').length;
    expect(calls.lastVideo, (v, v));
    expect(calls.lastAudio, (a, a));
    expect(calls.calls.first, anyOf('video 0/$v', 'audio 0/$a'));
  });
}
