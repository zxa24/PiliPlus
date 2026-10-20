// LibrePili: the download queue's keep-alive (lib/services/download/
// download_keepalive.dart) against a fake platform channel, and which
// download failures count as the network's.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/download/download_keepalive.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('librepili/transfer/downloads-test');

DownloadKeepAliveState _s(int received) =>
    (title: 'v', text: '正在下载', received: received, total: 100);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;

  setUp(() {
    calls = [];
    reply = (call) =>
        call.method == 'start' ? {'scheduled': true, 'id': 9} : null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  List<String> methods() => [for (final c in calls) c.method];

  DownloadKeepAlive keepAlive({VoidCallback? onPause}) => DownloadKeepAlive(
    channel: _channel,
    supported: true,
    minInterval: Duration.zero,
    heartbeat: const Duration(hours: 1),
    linger: const Duration(milliseconds: 20),
    onPause: onPause,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  Future<void> fromPlatform(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  test('one job while the queue runs, ended once it stops', () async {
    final k = keepAlive()..update(_s(1), visible: true);
    await settle();
    k.update(_s(50), visible: true);
    await settle();
    expect(k.holding, isTrue);
    expect(methods(), ['start', 'progress', 'progress']);
    expect(calls[2].arguments, containsPair('received', 50));
    k.update(null, visible: true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(methods().last, 'finish');
    expect(k.holding, isFalse);
  });

  test('the next download starting at once keeps the same job', () async {
    final k = keepAlive()..update(_s(1), visible: true);
    await settle();
    k
      ..update(null, visible: true)
      ..update(_s(2), visible: true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(methods().where((m) => m == 'start'), hasLength(1));
    expect(methods(), isNot(contains('finish')));
  });

  test('none is asked for off screen; refused is not asked again', () async {
    final k = keepAlive()..update(_s(1), visible: false);
    await settle();
    expect(calls, isEmpty);
    reply = (call) => {'scheduled': false, 'reason': 'not visible'};
    k.update(_s(1), visible: true);
    await settle();
    k.update(_s(2), visible: true);
    await settle();
    expect(methods(), ['start']);
    expect(k.holding, isFalse);
    // back on screen: asked once more
    reply = (call) =>
        call.method == 'start' ? {'scheduled': true, 'id': 9} : null;
    k
      ..resumed()
      ..update(_s(3), visible: true);
    await settle();
    expect(k.holding, isTrue);
  });

  test('the notification button pauses the queue', () async {
    var paused = 0;
    final k = keepAlive(onPause: () => paused++)..update(_s(1), visible: true);
    await settle();
    await fromPlatform('cancel', {'id': 9});
    expect(paused, 1);
    expect(k.holding, isFalse);
    // stopped by the system for another reason: the queue goes on
    k.update(_s(2), visible: true);
    await settle();
    await fromPlatform('stopped', {'id': 9, 'reason': 1});
    expect(paused, 1);
  });

  test('not supported: nothing reaches the platform', () async {
    DownloadKeepAlive(channel: _channel, supported: false)
      ..update(_s(1), visible: true)
      ..update(null, visible: true);
    await settle();
    expect(calls, isEmpty);
  });

  test('network failures, as the queue resumes them', () {
    final options = RequestOptions(path: '/');
    expect(
      DownloadManager.isNetworkFailure(
        DioException.connectionError(requestOptions: options, reason: 'x'),
      ),
      isTrue,
    );
    expect(
      DownloadManager.isNetworkFailure(
        DioException(
          requestOptions: options,
          error: const SocketException('reset'),
        ),
      ),
      isTrue,
    );
    expect(
      DownloadManager.isNetworkFailure(const HttpException('closed')),
      isTrue,
    );
    expect(DownloadManager.isNetworkFailure(TimeoutException('t')), isTrue);
    expect(
      DownloadManager.isNetworkFailure('incomplete transfer: 1 of 2 bytes'),
      isTrue,
    );
    // the server's answer, a pause, the disk: not the network
    expect(
      DownloadManager.isNetworkFailure(
        DioException.badResponse(
          statusCode: 403,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 403),
        ),
      ),
      isFalse,
    );
    expect(
      DownloadManager.isNetworkFailure(
        DioException.requestCancelled(requestOptions: options, reason: 'p'),
      ),
      isFalse,
    );
    expect(
      DownloadManager.isNetworkFailure(const FileSystemException('full')),
      isFalse,
    );
    expect(
      DownloadManager.isNetworkFailure('stream size changed (1, had 2)'),
      isFalse,
    );
  });
}
