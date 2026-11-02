// LibrePili (review of 2d): the pair transfer's checks under the rule of
// design §10 item 4 (user decision A) — bytes on disk are kept only when
// the version is known equal on both sides and the expected total is
// known; a stream is complete only when its length is a known expected
// total. Answers that do not state their total (`*`), start elsewhere or
// end short; a retry after a dropped connection; conflicting totals; the
// DRC mark; the folder's name; URLs out of the error text; lookups and
// connections bounded; `done` once.
import 'dart:async';
import 'dart:convert';
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
    root = await Directory.systemTemp.createTemp('yt-checks-');
    f = PairFixture(root);
    calls = PairCalls();
  });
  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<YtPairTransfer> run({
    YtStreamId? video,
    YtStreamId? audio,
    String query = '',
  }) async {
    final t = f.start(calls, video: video, audio: audio, query: query);
    await t.task;
    return t;
  }

  void expectCompleted(YtPairTransfer t) {
    expect(calls.errors, isEmpty);
    expect(t.status, DownloadStatus.completed);
    expect(f.file('video').readAsBytesSync(), f.body('video'));
    expect(f.file('audio').readAsBytesSync(), f.body('audio'));
  }

  void resumable() {
    f
      ..plant('video', 200000)
      ..plantJson(f.idOf('video'), f.idOf('audio'));
    f.plant('audio');
  }

  Iterable<String> restarts() => f.log.where((l) => l.contains('restarted'));

  group('answers that do not state their total, or other bytes', () {
    test(
      'a short range with `*`, the total known: not the end, the next asked',
      () async {
        resumable();
        f.server.script = (s, n, _) => s == 'video' && n == 1
            ? FakeAnswer.range(
                rangeHeader: (first, last) => 'bytes $first-${first + 999}/*',
              )
            : null;
        final t = await run();
        expectCompleted(t);
        expect(f.server.rangesOf('video')[2], startsWith('bytes=201000-'));
        expect((f.readJson()['video'] as Map)['bytes'], f.body('video').length);
      },
    );

    test(
      '`*` throughout, no total known: complete at the 416 that states it',
      () async {
        final n = f.body('video').length;
        f.server.script = (s, i, range) => s == 'video'
            ? FakeAnswer.range(
                rangeHeader: (first, last) => 'bytes $first-$last/*',
              )
            : null;
        final t = await run(video: f.idOf('video', bytes: null));
        expectCompleted(t);
        expect(f.server.rangesOf('video').last, startsWith('bytes=$n-'));
        expect((f.readJson()['video'] as Map)['bytes'], n);
      },
    );

    test(
      '`*` throughout and a 416 that states no total: never complete',
      () async {
        final n = f.body('video').length;
        f.server.script = (s, i, range) {
          if (s != 'video') return null;
          if (range!.startsWith('bytes=$n-')) {
            return const FakeAnswer.status(416);
          }
          return FakeAnswer.range(
            rangeHeader: (first, last) => 'bytes $first-$last/*',
          );
        };
        final t = await run(video: f.idOf('video', bytes: null));
        expect(t.status, DownloadStatus.failDownload);
        expect(f.log, contains('video restarted from 0 (416)'));
      },
    );

    test('a 206 of another start: from 0 (range unexpected)', () async {
      f.server.script = (s, n, _) => s == 'video' && n == 1
          ? FakeAnswer.range(
              rangeHeader: (first, last) =>
                  'bytes ${first + 1}-$last/${f.body('video').length}',
            )
          : null;
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (range unexpected)'));
    });

    test('a 206 whose last byte is past its total: from 0', () async {
      final n = f.body('video').length;
      f.server.script = (s, i, _) => s == 'video' && i == 1
          ? FakeAnswer.range(rangeHeader: (first, last) => 'bytes $first-$n/$n')
          : null;
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (range unexpected)'));
    });

    test('the overlap answered with `*`: from 0 (range total)', () async {
      resumable();
      f.server.script = (s, n, _) => s == 'video' && n == 0
          ? FakeAnswer.range(
              rangeHeader: (first, last) => 'bytes $first-$last/*',
            )
          : null;
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (range total)'));
      expect(f.log.where((l) => l.contains('resume at')), isEmpty);
    });

    test('an overlap body past its range: from 0 (range unexpected)', () async {
      resumable();
      f.server.script = (s, n, _) =>
          s == 'video' && n == 0 ? const FakeAnswer.range(extra: 5) : null;
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('video restarted from 0 (range unexpected)'));
    });

    test('an overlap read short: retried, then the resume', () async {
      resumable();
      f.server.script = (s, n, _) => s == 'video' && n == 0
          ? const FakeAnswer.range(endAfter: 1000)
          : null;
      final t = await run();
      expectCompleted(t);
      expect(f.server.rangesOf('video').take(2), [
        'bytes=134464-199999',
        'bytes=134464-199999',
      ]);
      expect(f.log, contains('video resume at 200000 (overlap ok)'));
      expect(restarts(), isEmpty);
    });

    test(
      'a 200 at 0, no total known: its length learnt into .size and '
      'stream.json before the body, the bar never past it',
      () async {
        final n = f.body('video').length;
        final seen = <(int?, String?)>[];
        f.server
          ..script = ((s, i, _) =>
              s == 'video' && i == 0 ? const FakeAnswer.whole() : null)
          ..pace = (s, offset) async {
            if (s == 'video' && offset == 32 << 10) {
              seen.add((
                (f.readJson()['video'] as Map)['bytes'] as int?,
                f.size('video').readAsStringSync(),
              ));
            }
          };
        final t = await run(video: f.idOf('video', bytes: null));
        expectCompleted(t);
        expect(seen.single, (n, '$n'));
        for (final c in calls.calls.where((c) => c.startsWith('video '))) {
          final [got, of] = c
              .split(' ')
              .last
              .split('/')
              .map(int.parse)
              .toList();
          expect(got, lessThanOrEqualTo(of), reason: c);
        }
      },
    );
  });

  test(
    'a 200 of no length, no total known: not taken whole (range total)',
    () async {
      f.server.script = (s, n, _) => s == 'video' && n <= 1
          ? const FakeAnswer.whole(noLength: true)
          : null;
      final t = await run(video: f.idOf('video', bytes: null));
      expect(t.status, DownloadStatus.failDownload);
      expect(f.log, contains('video restarted from 0 (range total)'));
      expect(
        ((calls.errors.single as YtTransferError).cause as YtRangeError).kind,
        YtRangeKind.total,
      );
    },
  );

  group('a retry within a start keeps bytes only with a version', () {
    test(
      'no lmt: a drop, then another version: from 0 (no validator)',
      () async {
        final b = [...f.body('video')]..setRange(0, 10, List.filled(10, 0x5a));
        f.server.script = (s, n, _) {
          if (s != 'video') return null;
          if (n == 1) return const FakeAnswer.range(cutAfter: 40000);
          // the retry: the server has another version now
          if (n == 2) f.server.bodies['video'] = b;
          return null;
        };
        final t = await run(video: f.idOf('video', lmt: null));
        expect(calls.errors, isEmpty);
        expect(t.status, DownloadStatus.completed);
        expect(f.log, contains('video restarted from 0 (no validator)'));
        expect(f.file('video').readAsBytesSync(), b);
      },
    );

    test('its lmt known: the drop resumed in place', () async {
      f.server.script = (s, n, _) => s == 'video' && n == 1
          ? const FakeAnswer.range(cutAfter: 40000)
          : null;
      final t = await run();
      expectCompleted(t);
      expect(restarts(), isEmpty);
      expect(f.server.rangesOf('video')[2], 'bytes=142400-244799');
    });

    test(
      'no lmt, a second drop with bytes kept: failed (once per start)',
      () async {
        f.server.script = (s, n, _) => s == 'video' && (n == 1 || n == 3)
            ? const FakeAnswer.range(cutAfter: 40000)
            : null;
        final t = await run(video: f.idOf('video', lmt: null));
        expect(t.status, DownloadStatus.failDownload);
        expect(
          (calls.errors.single as YtTransferError).cause,
          isA<HttpException>(),
        );
        expect(
          f.log.where((l) => l == 'video restarted from 0 (no validator)'),
          hasLength(1),
        );
      },
    );

    test('no lmt, a drop before any byte: retried, nothing to drop', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n == 0 ? const FakeAnswer.range(cutAfter: 0) : null;
      final t = await run(video: f.idOf('video', lmt: null));
      expect(t.status, DownloadStatus.completed);
      expect(restarts(), isEmpty);
    });
  });

  group('the identity', () {
    test(
      'totals that disagree (.size against the old one): from 0 (size), '
      'not taken as complete',
      () async {
        // the old identity: 307205 bytes, v1; a stale .size and the bytes
        // on disk: 200000; the new identity: no total, v1
        resumable();
        f.size('video').writeAsStringSync('200000');
        final t = await run(video: f.idOf('video', bytes: null));
        expectCompleted(t);
        expect(f.log, contains('video restarted from 0 (size)'));
        expect(
          f.log.where((l) => l.contains('already complete (200000)')),
          isEmpty,
        );
        expect((f.readJson()['video'] as Map)['bytes'], f.body('video').length);
      },
    );

    test('a DRC 140 against a plain 140 on disk: from 0 (drc)', () async {
      f = PairFixture(root, tag: '137-140.drc');
      f
        ..plant('video')
        ..plant('audio', 50000)
        ..plantJson(f.idOf('video'), f.idOf('audio'));
      final t = f.start(calls, audio: f.idOf('audio', drc: true));
      await t.task;
      expect(calls.errors, isEmpty);
      expect(f.log, contains('audio restarted from 0 (drc)'));
      expect((f.readJson()['audio'] as Map)['drc'], isTrue);
    });

    test('a DRC mark of the wrong shape: the identity not read', () async {
      f
        ..plant('video', 200000)
        ..plant('audio', 50000);
      f.json.writeAsStringSync(
        jsonEncode({
          'format': 'librepili-yt-stream-1',
          'video': f.idOf('video').toJson(audio: false),
          'audio': {...f.idOf('audio').toJson(audio: true), 'drc': 'yes'},
        }),
      );
      final t = await run();
      expectCompleted(t);
      expect(f.log, contains('audio restarted from 0 (no identity)'));
    });

    for (final (name, tag, audioDrc) in [
      ('a DRC stream in a plain folder', '137-140', true),
      ('a plain stream in a DRC folder', '137-140.drc', false),
      ('another video itag', '136-140', false),
    ]) {
      test('$name: refused, nothing asked or written', () async {
        f = PairFixture(root, tag: tag);
        final t = f.start(calls, audio: f.idOf('audio', drc: audioDrc));
        await t.task;
        expect(t.status, DownloadStatus.failDownload);
        expect(
          (calls.errors.single as YtTransferError).cause,
          isA<ArgumentError>(),
        );
        expect(f.server.requests, isEmpty);
        expect(Directory(f.dir).existsSync(), isFalse);
      });
    }
  });

  group('what an error says', () {
    test('a dropped connection: no URL, no query in its text', () async {
      f.server.script = (s, n, _) =>
          s == 'video' && n >= 1 ? const FakeAnswer.range(cutAfter: 0) : null;
      await run(query: '?sig=SECRET1&ip=203.0.113.9');
      final text = '${calls.errors.single}';
      expect(text, contains('HttpException: Connection closed'));
      expect(text, isNot(contains('SECRET1')));
      expect(text, isNot(contains('203.0.113.9')));
      expect(text, isNot(contains('/video')));
    });

    test('ytErrorText: a FormatException without its input, URLs cut', () {
      expect(
        ytErrorText(const FormatException('bad', 'https://h.example/v?sig=9')),
        'FormatException: bad',
      );
      expect(
        ytErrorText(StateError('at https://h.example/videoplayback?sig=9 x')),
        'Bad state: at https://h.example/… x',
      );
    });
  });

  group('waits that are bounded', () {
    test('the clients have a connection timeout', () async {
      final t = await run();
      expectCompleted(t);
      expect(
        f.server.made.map((c) => c.connectionTimeout),
        everyElement(YtPairTransfer.idleTimeout),
      );
    });

    test(
      'a connection that takes too long: let go, retried, done',
      () async {
        YtPairTransfer.idleTimeout = const Duration(milliseconds: 300);
        var held = false;
        f.server.openHold = (s) async {
          if (s == 'video' && !held) {
            held = true;
            await Completer<void>().future;
          }
        };
        final t = await run();
        expectCompleted(t);
      },
    );

    test(
      'a pause during a connection: done at once; nothing opened later',
      () async {
        final opening = Completer<void>();
        final release = Completer<void>();
        f.server.openHold = (s) async {
          if (!opening.isCompleted) opening.complete();
          await release.future;
        };
        final t = f.start(calls);
        await opening.future;
        final watch = Stopwatch()..start();
        await t.cancel(isDelete: false);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        final asked = f.server.requests.length;
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(f.server.requests.length, asked);
        expect(calls.done, 0);
        expect(t.status, DownloadStatus.pause);
      },
    );

    test('a pause during the wait between attempts: done at once', () async {
      YtPairTransfer.backoff = (_) => const Duration(seconds: 20);
      final cut = Completer<void>();
      f.server.script = (s, n, _) {
        if (s == 'video' && n == 1) {
          if (!cut.isCompleted) cut.complete();
          return const FakeAnswer.range(cutAfter: 0);
        }
        return null;
      };
      final t = f.start(calls);
      await cut.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      await t.cancel(isDelete: false);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a redirect loop: YtTooManyRedirects, not retried', () async {
      f.server.script = (s, n, _) => s == 'video'
          ? FakeAnswer.status(302, location: FakeStreamServer.url('video'))
          : null;
      final t = await run();
      expect(t.status, DownloadStatus.failDownload);
      expect(
        (calls.errors.single as YtTransferError).cause,
        isA<YtTooManyRedirects>(),
      );
      expect(f.server.rangesOf('video'), hasLength(6));
    });
  });

  group('the callbacks', () {
    test('a done that throws: delivered once, the transfer complete', () async {
      var n = 0;
      calls.onCall = (call) {
        if (call == 'done' && n++ == 0) throw StateError('the service fell');
      };
      final t = await run();
      expect(calls.done, 1);
      expect(t.status, DownloadStatus.completed);
      expect(f.log, contains(contains('a callback threw')));
    });

    test('a videoDone that throws: not a failure of the video', () async {
      calls.onCall = (call) {
        if (call == 'videoDone') throw StateError('the service fell');
      };
      final t = await run();
      expect(calls.errors, isEmpty);
      expect(calls.done, 1);
      expect(t.status, DownloadStatus.completed);
    });

    test(
      'a pause while the other stream is stopped after a failure: pause, '
      'no done',
      () async {
        // the video held mid-body; the audio refused at once
        f.server.pace = (s, o) async {
          if (s == 'video' && o >= 32 << 10) await Completer<void>().future;
        };
        f.server.script = (s, n, _) =>
            s == 'audio' ? const FakeAnswer.status(403) : null;
        late YtPairTransfer t;
        var paused = false;
        // the video's client closed by the audio's failure: the user's
        // pause lands right then
        f.server.onClose = () {
          if (paused) return;
          paused = true;
          unawaited(t.cancel(isDelete: false));
        };
        t = f.start(calls);
        await t.task;
        expect(paused, isTrue);
        expect(t.status, DownloadStatus.pause);
        expect(calls.done, 0);
      },
    );
  });
}
