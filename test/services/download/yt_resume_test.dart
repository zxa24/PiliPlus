// LibrePili: a YouTube download's streams resumed or downloaded again
// (design §4.2, stage-2 plan §3.4; the unit part of AC3). Each stream is
// resumed only with the same itag, track and total in `stream.json`, the
// same `lmt` on both sides and the last 64 KB on disk read back the same;
// anything less downloads it from 0, with a line saying why. A restart is
// allowed once per reason per start. `stream.json` has one writer, through
// `.tmp` + rename.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_transfer_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'yt_download_test_support.dart';

void main() {
  setUpPairTransfer();
  late Directory root;
  late PairFixture f;
  late PairCalls calls;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yt-resume-');
    f = PairFixture(root);
    calls = PairCalls();
  });
  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// Runs a transfer to its end.
  Future<YtPairTransfer> run({YtStreamId? video, YtStreamId? audio}) async {
    final t = f.start(calls, video: video, audio: audio);
    await t.task;
    return t;
  }

  void expectWhole(String stream) => expect(
    f.file(stream).readAsBytesSync(),
    f.body(stream),
    reason: '$stream on disk',
  );

  void expectCompleted(YtPairTransfer t) {
    expect(calls.errors, isEmpty);
    expect(calls.done, 1);
    expect(t.status, DownloadStatus.completed);
    expectWhole('video');
    expectWhole('audio');
  }

  /// The audio stream complete with its identity, so a test is about the
  /// video alone.
  void audioComplete() => f.plant('audio');

  test(
    'a first start: start from 0 on both, stream.json both, no .size',
    () async {
      final t = await run();
      expectCompleted(t);
      expect(f.log, containsAll(['video start from 0', 'audio start from 0']));
      expect(f.log.where((l) => l.contains('restarted')), isEmpty);
      expect(f.server.rangesOf('video').first, 'bytes=0-102399');
      final json = f.readJson();
      expect(json['format'], 'librepili-yt-stream-1');
      expect(json['source'], 'direct');
      expect(json['video'], {
        'itag': 137,
        'track': null,
        'bytes': f.body('video').length,
        'lmt': 'v1',
      });
      expect(json['audio'], {
        'itag': 140,
        'track': null,
        'default': false,
        'drc': false,
        'bytes': f.body('audio').length,
        'lmt': 'a1',
      });
      expect(f.jsonTmp.existsSync(), isFalse);
      expect(f.size('video').existsSync(), isFalse);
      expect(f.size('audio').existsSync(), isFalse);
    },
  );

  group('a resume (rule 7)', () {
    test(
      'the last 64 KB read back first, then the rest; no restart',
      () async {
        f
          ..plant('video', 200000)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        final t = await run();
        expectCompleted(t);
        expect(f.server.rangesOf('video').first, 'bytes=134464-199999');
        expect(f.log, contains('video resume at 200000 (overlap ok)'));
        expect(f.log.where((l) => l.startsWith('video restarted')), isEmpty);
        expect(f.server.rangesOf('video')[1], startsWith('bytes=200000-'));
      },
    );

    test('under 64 KB on disk: all of it read back', () async {
      f
        ..plant('video', 30000)
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      audioComplete();
      final t = await run();
      expectCompleted(t);
      expect(f.server.rangesOf('video').first, 'bytes=0-29999');
      expect(f.log, contains('video resume at 30000 (overlap ok)'));
    });

    test(
      'a byte changed in the last 64 KB: from 0 (overlap mismatch)',
      () async {
        final torn = [...f.body('video')]..[199990] ^= 0xff;
        f
          ..plant('video', 200000, torn)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 (overlap mismatch)'));
        expect(f.log.where((l) => l.startsWith('video resume')), isEmpty);
        expect(f.server.rangesOf('video')[1], 'bytes=0-102399');
      },
    );

    for (final (side, newLmt, oldLmt) in [
      ('the new side', null, 'v1'),
      ('the old side', 'v1', null),
    ]) {
      test(
        'no lmt on $side: from 0 (no validator), never a resume',
        () async {
          f
            ..plant('video', 200000)
            ..plantJson(f.idOf('video', lmt: oldLmt), f.idOf('audio'));
          audioComplete();
          final t = await run(video: f.idOf('video', lmt: newLmt));
          expectCompleted(t);
          expect(f.log, contains('video restarted from 0 (no validator)'));
          expect(f.log.where((l) => l.startsWith('video resume')), isEmpty);
          expect(f.server.rangesOf('video').first, 'bytes=0-102399');
        },
      );
    }
  });

  group('already complete (rule 6)', () {
    test(
      'no request for it, reported once at its length, then done',
      () async {
        f
          ..plant('video')
          ..plant('audio', 50000)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        final t = await run();
        expectCompleted(t);
        final n = f.body('video').length;
        expect(f.log, contains('video already complete ($n)'));
        expect(f.server.rangesOf('video'), isEmpty);
        expect(f.log.where((l) => l.startsWith('video restarted')), isEmpty);
        expect(calls.calls, contains('video $n/$n'));
        expect(f.log, contains('audio resume at 50000 (overlap ok)'));
      },
    );

    test(
      'a total and a version not given now: those known kept (p3#2)',
      () async {
        final n = f.body('video').length;
        f
          ..plant('video')
          ..plant('audio')
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        final t = await run(
          video: f.idOf('video', bytes: null, lmt: null),
          audio: f.idOf('audio', bytes: null, lmt: null),
        );
        expectCompleted(t);
        expect(f.log, contains('video already complete ($n)'));
        expect(f.readJson()['video'], {
          'itag': 137,
          'track': null,
          'bytes': n,
          'lmt': 'v1',
        });
        expect((f.readJson()['audio'] as Map)['lmt'], 'a1');
        expect(f.server.requests, isEmpty);
      },
    );
  });

  group('from 0 at the start (rules 0–5)', () {
    test(
      'the stream file gone, its identity there: from 0 (missing)',
      () async {
        f.plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 (missing)'));
        expect(f.log, isNot(contains('video start from 0')));
        expect(f.server.rangesOf('video').first, 'bytes=0-102399');
      },
    );

    for (final (name, reason, video, oldVideo)
        in <
          (
            String,
            String,
            YtStreamId Function(),
            YtStreamId Function(),
          )
        >[
          (
            'another itag',
            'itag',
            () => f.idOf('video'),
            () =>
                YtStreamId(itag: 136, bytes: f.body('video').length, lmt: 'v1'),
          ),
          (
            'another lmt',
            'lmt',
            () => f.idOf('video'),
            () => f.idOf('video', lmt: 'v0'),
          ),
          (
            'another total',
            'size',
            () => f.idOf('video'),
            () => f.idOf('video', bytes: f.body('video').length + 1),
          ),
          (
            'no total anywhere',
            'size',
            () => f.idOf('video', bytes: null),
            () => f.idOf('video', bytes: null),
          ),
        ]) {
      test('$name: from 0 ($reason)', () async {
        f
          ..plant('video', 200000)
          ..plantJson(oldVideo(), f.idOf('audio'));
        audioComplete();
        final t = await run(video: video());
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 ($reason)'));
        expect(f.log.where((l) => l.startsWith('video resume')), isEmpty);
        expect(f.server.rangesOf('video').first, 'bytes=0-102399');
      });
    }

    test('another audio track: from 0 (track)', () async {
      f
        ..plant('video')
        ..plant('audio', 50000)
        ..plantJson(f.idOf('video'), f.idOf('audio', track: 'en.4'));
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('audio restarted from 0 (track)'));
      expect((f.readJson()['audio'] as Map)['track'], isNull);
    });

    test('more on disk than its total: from 0 (size)', () async {
      f
        ..plant('video', null, [...f.body('video'), 1, 2, 3])
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      audioComplete();
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (size)'));
    });

    test('a .size of another total: from 0 (size)', () async {
      f
        ..plant('video', 200000)
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      f.size('video').writeAsStringSync('999999');
      audioComplete();
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (size)'));
    });

    test(
      'a total not given now: the .size, then stream.json\'s (rule 5 not hit)',
      () async {
        f
          ..plant('video', 200000)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        final t = await run(video: f.idOf('video', bytes: null));
        expectCompleted(t);
        expect(f.log, contains('video resume at 200000 (overlap ok)'));
      },
    );
  });

  group('stream.json read and written (§2.2 p5#7)', () {
    test(
      'torn, with a whole .tmp: the .tmp read, a resume (variant d(1))',
      () async {
        f.plant('video', 200000);
        f.json.writeAsStringSync('{"format": "librepili-yt-st');
        f.jsonTmp.writeAsStringSync(
          PairFixture.jsonText(f.idOf('video'), f.idOf('audio')),
        );
        audioComplete();
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video resume at 200000 (overlap ok)'));
        expect(f.log.where((l) => l.contains('restarted')), isEmpty);
        expect(f.readJson()['format'], 'librepili-yt-stream-1');
        expect(f.jsonTmp.existsSync(), isFalse);
      },
    );

    test('torn, no .tmp: from 0 (no identity) (variant d(2))', () async {
      f.plant('video', 200000);
      f.json.writeAsStringSync('{"format": "librepili-yt-st');
      audioComplete();
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (no identity)'));
      expect(f.log.where((l) => l.startsWith('video resume')), isEmpty);
      expect(f.readJson()['video'], isA<Map>());
      expect(f.jsonTmp.existsSync(), isFalse);
    });

    test('a field of the wrong shape: not known, not taken', () async {
      f.plant('video', 200000);
      f.json.writeAsStringSync(
        jsonEncode({
          'format': 'librepili-yt-stream-1',
          'video': {'itag': 137, 'bytes': '../x', 'lmt': 7},
          'audio': {'itag': '140'},
        }),
      );
      audioComplete();
      final t = await run();
      expectCompleted(t);
      // a total of the wrong shape: the new one; the version: not known
      expect(f.log, contains('video restarted from 0 (no validator)'));
    });

    test('written through .tmp + rename, never in place', () async {
      final writes = <String>[];
      await IOOverrides.runWithIOOverrides(() async {
        f
          ..plant('video', 200000)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        writes.clear();
        final t = await run();
        expectCompleted(t);
      }, _WatchJson(writes));
      expect(writes, isEmpty);
      expect(f.readJson()['video'], isA<Map>());
    });

    test(
      'only the .tmp readable: a write cut at its .tmp leaves it readable',
      () async {
        f.plant('video', 200000);
        f.jsonTmp.writeAsStringSync(
          PairFixture.jsonText(f.idOf('video'), f.idOf('audio')),
        );
        audioComplete();
        await IOOverrides.runWithIOOverrides(() async {
          final t = f.start(calls);
          await t.task;
        }, _CutJsonTmp());
        expect(calls.errors.single, isA<YtTransferError>());
        // the identity read survives: stream.json or the .tmp holds it
        final kept = [f.json, f.jsonTmp].where((x) {
          try {
            jsonDecode(x.readAsStringSync());
            return true;
          } catch (_) {
            return false;
          }
        });
        expect(kept, isNotEmpty);
        expect(
          (jsonDecode(kept.first.readAsStringSync()) as Map)['video'],
          f.idOf('video').toJson(audio: false),
        );
      },
    );

    test(
      'both streams learn their totals together: both in stream.json',
      () async {
        // neither total known: each learns it from its first answer
        final reached = {
          'video': Completer<void>(),
          'audio': Completer<void>(),
        };
        f.server.pace = (stream, offset) async {
          if (offset >= 48 << 10) {
            if (!reached[stream]!.isCompleted) reached[stream]!.complete();
            await Completer<void>().future; // held until the cancel
          }
        };
        final t = f.start(
          calls,
          video: f.idOf('video', bytes: null),
          audio: f.idOf('audio', bytes: null),
        );
        await Future.wait([for (final c in reached.values) c.future]);
        await t.cancel(isDelete: false);
        final json = f.readJson();
        expect((json['video'] as Map)['bytes'], f.body('video').length);
        expect((json['audio'] as Map)['bytes'], f.body('audio').length);
      },
    );

    test(
      'known → unknown → known: the old lmt not kept for the new bytes',
      () async {
        final a = f.body('video');
        // another version: a prefix of its own, the same bytes after it
        final b = [...a]..setRange(0, 10, List.filled(10, 0x5a));
        f
          ..plant('video', 200000)
          ..plantJson(f.idOf('video'), f.idOf('audio'));
        audioComplete();
        // 2nd start: the version not given; version b served, paused
        f.server.bodies['video'] = b;
        final reached = Completer<void>();
        f.server.pace = (stream, offset) async {
          if (stream == 'video' && offset >= 150000) {
            if (!reached.isCompleted) reached.complete();
            await Completer<void>().future;
          }
        };
        final second = f.start(calls, video: f.idOf('video', lmt: null));
        await reached.future;
        await second.cancel(isDelete: false);
        expect(f.log, contains('video restarted from 0 (no validator)'));
        expect((f.readJson()['video'] as Map)['lmt'], isNull);
        // 3rd start: version a again, its lmt given
        f.server
          ..bodies['video'] = a
          ..pace = null;
        final third = PairCalls();
        final t = f.start(third);
        await t.task;
        expect(f.log, contains('video restarted from 0 (no validator)'));
        expect(f.log.where((l) => l.startsWith('video resume')), isEmpty);
        expect(f.file('video').readAsBytesSync(), a);
        expect(third.errors, isEmpty);
      },
    );
  });

  group('answers that do not fit (§4.2)', () {
    void resumable() {
      f
        ..plant('video', 200000)
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      audioComplete();
    }

    test('a 416 mid-file: from 0 (416) once, then done', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n == 1 ? const FakeAnswer.status(416) : null;
      final t = await run();
      expectCompleted(t);
      expect(
        f.log.where((l) => l == 'video restarted from 0 (416)'),
        hasLength(1),
      );
    });

    test('a second 416 in the same start: failDownload', () async {
      f.server.script = (s, n, _) => s == 'video' && (n == 1 || n == 3)
          ? const FakeAnswer.status(416)
          : null;
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      final error = calls.errors.single as YtTransferError;
      expect(error.stream, 'video');
      expect((error.cause as YtRangeError).kind, YtRangeKind.notSatisfiable);
      expect(
        f.log.where((l) => l == 'video restarted from 0 (416)'),
        hasLength(1),
      );
    });

    test(
      'a 200 to a resume: from 0 (range ignored), its body not taken',
      () async {
        resumable();
        f.server.script = (s, n, _) =>
            s == 'video' && n == 0 ? const FakeAnswer.whole() : null;
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 (range ignored)'));
        expect(f.server.rangesOf('video')[1], 'bytes=0-102399');
      },
    );

    test(
      'a 200 to a range after the overlap: from 0 (range ignored)',
      () async {
        resumable();
        f.server.script = (s, n, _) =>
            s == 'video' && n == 1 ? const FakeAnswer.whole() : null;
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video resume at 200000 (overlap ok)'));
        expect(f.log, contains('video restarted from 0 (range ignored)'));
        expect(f.server.rangesOf('video')[2], 'bytes=0-102399');
      },
    );

    test('a 200 to the first range of a start from 0: taken whole', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n == 0 ? const FakeAnswer.whole() : null;
      final t = await run();
      expectCompleted(t);
      expect(f.server.rangesOf('video'), hasLength(1));
    });

    test('another total stated: from 0 (range total), then done', () async {
      resumable();
      f.server.script = (s, n, _) =>
          s == 'video' && n == 0 ? const FakeAnswer.range(total: 1) : null;
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (range total)'));
    });

    test('another total again in the same start: failDownload', () async {
      f.server.script = (s, n, _) => s == 'video' && (n == 1 || n == 3)
          ? const FakeAnswer.range(total: 7)
          : null;
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      expect(
        ((calls.errors.single as YtTransferError).cause as YtRangeError).kind,
        YtRangeKind.total,
      );
    });

    test(
      'a body past its range: not written past it, from 0 once',
      () async {
        f.server.script = (s, n, _) =>
            s == 'video' && n == 1 ? const FakeAnswer.range(extra: 5) : null;
        final t = await run();
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 (range unexpected)'));
      },
    );
  });

  group('the budget (as DownloadManager)', () {
    test(
      'a connection dropped mid-body: resumed in place, no restart',
      () async {
        f.server.script = (s, n, _) => s == 'video' && n == 1
            ? const FakeAnswer.range(cutAfter: 40000)
            : null;
        final t = await run();
        expectCompleted(t);
        expect(f.log.where((l) => l.contains('restarted')), isEmpty);
        expect(f.server.rangesOf('video')[2], 'bytes=142400-244799');
      },
    );

    test('six drops in a row that saved nothing: failDownload', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n >= 1 ? const FakeAnswer.range(cutAfter: 0) : null;
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      expect(
        (calls.errors.single as YtTransferError).cause,
        isA<HttpException>(),
      );
      expect(
        f.server.rangesOf('video'),
        hasLength(1 + YtPairTransfer.maxAttempts),
      );
      // the bytes saved are kept for the next start
      expect(f.file('video').lengthSync(), 100 << 10);
    });

    test('a body that ends short: retried (YtShortBody)', () async {
      f.server.script = (s, n, _) => s == 'video' && n == 0
          ? const FakeAnswer.range(endAfter: 1000)
          : null;
      final t = await run();
      expectCompleted(t);
      expect(f.server.rangesOf('video')[1], 'bytes=1000-103399');
    });

    test('a 403: not retried in the transfer', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n == 1 ? const FakeAnswer.status(403) : null;
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      final cause = (calls.errors.single as YtTransferError).cause;
      expect(cause, isA<YtHttpStatus>());
      expect((cause as YtHttpStatus).code, 403);
      expect(f.server.rangesOf('video'), hasLength(2));
    });

    test('a 503: retried in the transfer', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n == 1 ? const FakeAnswer.status(503) : null;
      final t = await run();
      expectCompleted(t);
    });

    test('a body with no bytes for the idle time: let go, retried', () async {
      YtPairTransfer.idleTimeout = const Duration(milliseconds: 300);
      var held = false;
      f.server.pace = (stream, offset) async {
        if (stream == 'video' && offset == 0 && !held) {
          held = true;
          await Completer<void>().future;
        }
      };
      final t = await run();
      expectCompleted(t);
    });

    test('a self-test injected status: as if the server said it', () async {
      YtPairTransfer.selfTestInject = (s, r) =>
          s == 'audio' && r.startsWith('bytes=0-') ? 404 : null;
      final ranges = <String>[];
      YtPairTransfer.selfTestOnRequest = (s, r) => ranges.add('$s $r');
      final t = await run();
      expect(t.status, DownloadStatus.failDownloadAudio);
      expect(ranges, contains('audio bytes=0-102399'));
      expect(f.server.rangesOf('audio'), isEmpty);
    });
  });

  group('the folder', () {
    test(
      'a name that is not a stream tag: nothing asked, nothing made',
      () async {
        final odd = path.join(root.path, 'yt_$ytId', 'main', '..');
        final t = f.start(calls, streamDir: odd);
        await t.task;
        expect(t.status, DownloadStatus.failDownload);
        expect(
          (calls.errors.single as YtTransferError).cause,
          isA<ArgumentError>(),
        );
        expect(f.server.requests, isEmpty);
      },
    );

    test('a deleted entry folder is not made again', () async {
      await Directory(path.dirname(f.dir)).delete(recursive: true);
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      expect(Directory(path.dirname(f.dir)).existsSync(), isFalse);
    });

    test(
      'a second transfer in the same folder (another case): refused',
      () async {
        final held = Completer<void>();
        f.server.pace = (s, o) async {
          if (o > 0) await held.future;
        };
        final first = f.start(calls);
        final other = PairCalls();
        final second = f.start(other, streamDir: f.dir.toUpperCase());
        await second.task;
        expect(other.errors.single, isA<YtTransferError>());
        expect(
          (other.errors.single as YtTransferError).cause,
          isA<StateError>(),
        );
        held.complete();
        await first.task;
        expect(calls.errors, isEmpty);
      },
    );
  });
}

/// Records every write made to a file named `stream.json` itself (not its
/// `.tmp`): the record is only ever renamed into place.
final class _WatchJson extends IOOverrides {
  _WatchJson(this.writes);

  final List<String> writes;

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return path.basename(file) == 'stream.json' ? _Watched(made, writes) : made;
  }
}

class _Watched implements File {
  _Watched(this._file, this._writes);

  final File _file;
  final List<String> _writes;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  int lengthSync() => _file.lengthSync();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _file.readAsString(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _writes.add('writeAsString $path');
    return _file.writeAsString(contents, mode: mode, flush: flush);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _writes.add('writeAsStringSync $path');
    _file.writeAsStringSync(contents, mode: mode, flush: flush);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every `stream.json.tmp` written in its zone is cut at its write:
/// truncated, then the write fails.
final class _CutJsonTmp extends IOOverrides {
  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return path.basename(file) == 'stream.json.tmp' ? _CutTmp(made) : made;
  }
}

class _CutTmp implements File {
  _CutTmp(this._file);

  final File _file;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  int lengthSync() => _file.lengthSync();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _file.readAsString(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _file.writeAsStringSync('');
    return Future.error(const FileSystemException('cut at the write'));
  }

  @override
  Future<File> rename(String newPath) => _file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
