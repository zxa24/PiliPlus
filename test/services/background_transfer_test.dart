// LibrePili: the Dart side of the background-transfer keep-alive
// (lib/services/background_transfer.dart) against a fake platform channel:
// what it tells the job, and that a refused job leaves the download as it
// was.
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/background_transfer.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('librepili/transfer-test');

AsrProgress _p(int received, {int total = 1000}) =>
    (label: 'm · f', received: received, total: total, verifying: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;

  setUp(() {
    calls = [];
    reply = (call) =>
        call.method == 'start' ? {'scheduled': true, 'id': 7} : null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  BackgroundTransfer transfer({
    Duration minInterval = Duration.zero,
    bool supported = true,
  }) => BackgroundTransfer(
    channel: _channel,
    supported: supported,
    minInterval: minInterval,
    heartbeat: const Duration(hours: 1),
  );

  /// The platform calling into Dart, as the job's service would.
  Future<void> fromPlatform(String method, Map<String, Object?> args) async {
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  /// A download that runs until [token] is cancelled.
  Future<void> untilCancelled(AsrCancelToken token) async {
    while (!token.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw const AsrCancelled();
  }

  List<String> methods() => [for (final c in calls) c.method];

  test('start, progress and finish around a download', () async {
    final result = await transfer().run(
      title: '下载语音识别模型',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (progress) async {
        progress(_p(10));
        progress(_p(1000));
        return 'ok';
      },
    );
    expect(result, 'ok');
    expect(methods(), ['start', 'progress', 'progress', 'finish']);
    expect(calls.first.arguments, containsPair('title', '下载语音识别模型'));
    expect(calls.first.arguments, containsPair('total', 1000));
    expect(calls[1].arguments, containsPair('id', 7));
    expect(calls[1].arguments, containsPair('received', 10));
    expect(calls[2].arguments, containsPair('received', 1000));
    expect(calls.last.arguments, {'id': 7, 'outcome': 'done'});
  });

  test('progress is sent at most once per interval', () async {
    await transfer(minInterval: const Duration(hours: 1)).run(
      title: 't',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (progress) async {
        for (var i = 0; i < 50; i++) {
          progress(_p(i * 20));
        }
      },
    );
    expect(methods(), ['start', 'progress', 'finish']);
  });

  test('a failed download ends the job as failed and still throws', () async {
    await expectLater(
      transfer().run(
        title: 't',
        bytes: 1000,
        token: AsrCancelToken(),
        body: (_) async => throw const AsrModelException('x 下载失败'),
      ),
      throwsA(isA<AsrModelException>()),
    );
    expect(calls.last.method, 'finish');
    expect(calls.last.arguments, {'id': 7, 'outcome': 'failed'});
  });

  test('cancelling in the app ends the job as cancelled', () async {
    final token = AsrCancelToken();
    final run = transfer().run(
      title: 't',
      bytes: 1000,
      token: token,
      body: (_) => untilCancelled(token),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    token.cancel();
    await expectLater(run, throwsA(isA<AsrCancelled>()));
    expect(calls.last.arguments, {'id': 7, 'outcome': 'cancelled'});
  });

  test("the notification's cancel button cancels the download", () async {
    final token = AsrCancelToken();
    final run = transfer().run(
      title: 't',
      bytes: 1000,
      token: token,
      body: (_) => untilCancelled(token),
    );
    // listened to first: the run fails while the call is still returning
    final failed = expectLater(run, throwsA(isA<AsrCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await fromPlatform('cancel', {'id': 7});
    await failed;
    expect(token.isCancelled, isTrue);
  });

  test('stopped by the user from the task manager cancels it', () async {
    final token = AsrCancelToken();
    final run = transfer().run(
      title: 't',
      bytes: 1000,
      token: token,
      body: (_) => untilCancelled(token),
    );
    // listened to first: the run fails while the call is still returning
    final failed = expectLater(run, throwsA(isA<AsrCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await fromPlatform('stopped', {'id': 7, 'reason': 13});
    await failed;
  });

  test('stopped by the system, the download goes on', () async {
    final token = AsrCancelToken();
    final transfer0 = transfer();
    var stopped = false;
    final result = await transfer0.run(
      title: 't',
      bytes: 1000,
      token: token,
      body: (_) async {
        // STOP_REASON_CONSTRAINT_CONNECTIVITY
        await fromPlatform('stopped', {'id': 7, 'reason': 7});
        stopped = true;
        return token.isCancelled;
      },
    );
    expect(stopped, isTrue);
    expect(result, isFalse);
    expect(EventLog.recent.last, contains('job 7 done'));
  });

  test('a refused job leaves the download in-process', () async {
    reply = (call) => call.method == 'start'
        ? {'scheduled': false, 'reason': 'schedule() refused: app not visible?'}
        : null;
    final transfer0 = transfer();
    var reported = 0;
    final result = await transfer0.run(
      title: '下载翻译模型',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (progress) async {
        progress(_p(500));
        reported++;
        return 42;
      },
    );
    expect(result, 42);
    expect(reported, 1);
    // asked once, then left alone: no progress, no finish
    expect(methods(), ['start']);
    expect(transfer0.lastStart?.scheduled, isFalse);
    expect(EventLog.recent.last, contains('downloading in-process'));
    expect(EventLog.recent.last, contains('app not visible'));
  });

  test('a platform error when scheduling falls back too', () async {
    reply = (call) =>
        throw PlatformException(code: 'X', message: 'SecurityException');
    final result = await transfer().run(
      title: 't',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (_) async => 'ok',
    );
    expect(result, 'ok');
    expect(methods(), ['start']);
  });

  test('no channel (older build, other platform): the download runs', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final transfer0 = transfer();
    final result = await transfer0.run(
      title: 't',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (_) async => 'ok',
    );
    expect(result, 'ok');
    expect(transfer0.lastStart?.reason, 'no channel');
  });

  test('off Android nothing is asked of the platform', () async {
    await transfer(supported: false).run(
      title: 't',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (progress) async => progress(_p(1)),
    );
    expect(calls, isEmpty);
  });

  test('nothing to download: no job', () async {
    await transfer().run(
      title: 't',
      bytes: 0,
      token: AsrCancelToken(),
      body: (_) async {},
    );
    expect(calls, isEmpty);
  });

  test('the heartbeat repeats the last progress while nothing moves', () async {
    final transfer0 = BackgroundTransfer(
      channel: _channel,
      supported: true,
      minInterval: const Duration(hours: 1),
      heartbeat: const Duration(milliseconds: 5),
    );
    await transfer0.run(
      title: 't',
      bytes: 1000,
      token: AsrCancelToken(),
      body: (progress) async {
        progress(_p(300));
        // an unpack or a hash: no progress for a while
        await Future<void>.delayed(const Duration(milliseconds: 40));
      },
    );
    final progress = [
      for (final c in calls)
        if (c.method == 'progress') c,
    ];
    expect(progress.length, greaterThan(2));
    expect(progress.last.arguments, containsPair('received', 300));
  });
}
