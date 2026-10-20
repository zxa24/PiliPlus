/// LibrePili: keeps the video download queue on the network when the app
/// leaves the screen (user 2026-10-19, D8 C: 下载放前台任务).
///
/// The same keep-alive as a model download's (lib/services/background_transfer
/// .dart, `TransferJobService.kt`): while the queue has a download running,
/// a user-initiated data transfer job (Android 14+) holds the network for
/// the app and carries the progress notification; the job transfers nothing
/// itself. It ends once nothing is downloading — the queue empty, paused or
/// stopped on a failure. Its notification's button, or the system's task
/// manager, pauses the queue.
///
/// Where no job can be had — below Android 14 (no such jobs; the download
/// goes on in-process for as long as the system lets the app run, as
/// before), the permission refused, the app not on screen when the queue
/// started — the queue runs as it always did, in-process.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the notification shows of the running download.
typedef DownloadKeepAliveState = ({
  String title,
  String text,
  int received,
  int total,
});

class DownloadKeepAlive {
  DownloadKeepAlive({
    this.channel = const MethodChannel('librepili/transfer/downloads'),
    bool? supported,
    this.minInterval = const Duration(seconds: 1),
    this.heartbeat = const Duration(seconds: 30),
    this.linger = const Duration(seconds: 5),
    this.onPause,
  }) : _supported = supported ?? Platform.isAndroid;

  /// `TransferJobService.kt`; tests give a fake.
  final MethodChannel channel;
  final bool _supported;

  /// Progress reaches the notification at most this often.
  final Duration minInterval;

  /// The last progress is sent again this often while nothing new is
  /// reported (a merge): the job ends itself after minutes of silence.
  final Duration heartbeat;

  /// How long the queue may have nothing running before the job ends: one
  /// download ending and the next starting are a moment apart, and a job
  /// cannot be had again while the app is off screen.
  final Duration linger;

  /// The notification's button or the system's task manager: the queue is
  /// paused.
  final VoidCallback? onPause;

  int? _id;
  bool _starting = false;

  /// A start the platform refused: not asked again until the queue has
  /// stopped or the app is back on screen, rather than at every update.
  bool _refused = false;

  DownloadKeepAliveState? _last;
  DateTime? _sentAt;
  Timer? _beat;
  Timer? _ending;
  var _listening = false;

  /// Whether a job holds the network now, for tests and the log.
  bool get holding => _id != null;

  /// The queue's state: [state] while a download runs, null when nothing
  /// does. [visible]: the app is on screen, the only time a job can be had.
  void update(DownloadKeepAliveState? state, {required bool visible}) {
    if (!_supported) return;
    if (state == null) {
      _last = null;
      _refused = false;
      if (_id != null && _ending == null) {
        _ending = Timer(linger, () {
          _ending = null;
          if (_last == null) _finish('done');
        });
      }
      return;
    }
    _ending?.cancel();
    _ending = null;
    _last = state;
    if (_id != null) {
      final at = _sentAt;
      if (at == null || DateTime.now().difference(at) >= minInterval) {
        _send(state);
      }
      return;
    }
    if (_starting || _refused || !visible) return;
    unawaited(_start(state));
  }

  /// The app back on screen: a refused or lost job may be had now.
  void resumed() => _refused = false;

  Future<void> _start(DownloadKeepAliveState state) async {
    _starting = true;
    _listen();
    Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMapMethod<Object?, Object?>('start', {
        'title': state.title,
        'text': state.text,
        'total': state.total,
      });
    } on MissingPluginException {
      // a build or platform without the channel: as before
      _refused = true;
      return;
    } catch (e) {
      _refused = true;
      EventLog.add('transfer', 'no background job for downloads: $e');
      return;
    } finally {
      _starting = false;
    }
    final id = reply?['id'];
    if (reply?['scheduled'] != true || id is! int) {
      _refused = true;
      // the queue goes on as it did before jobs existed: fine while the app
      // is on screen, cut off ~5 s after it leaves on Android 15
      EventLog.add(
        'transfer',
        'no background job for downloads '
            '(${reply?['reason'] ?? 'refused'}): downloading in-process',
      );
      return;
    }
    _id = id;
    EventLog.add('transfer', 'job $id holds the network for downloads');
    _beat = Timer.periodic(heartbeat, (_) {
      if (_last case final last?) _send(last);
    });
    // the queue stopped while the job was being scheduled
    final last = _last;
    if (last == null) {
      _finish('done');
    } else {
      _send(last);
    }
  }

  void _send(DownloadKeepAliveState state) {
    final id = _id;
    if (id == null) return;
    _sentAt = DateTime.now();
    _invoke('progress', {
      'id': id,
      'text': state.text,
      'received': state.received,
      'total': state.total,
    });
  }

  void _finish(String outcome) {
    final id = _id;
    _drop();
    if (id == null) return;
    EventLog.add('transfer', 'job $id $outcome');
    _invoke('finish', {'id': id, 'outcome': outcome});
  }

  /// The job gone, by Dart's word or the platform's.
  void _drop() {
    _id = null;
    _sentAt = null;
    _beat?.cancel();
    _beat = null;
    _ending?.cancel();
    _ending = null;
  }

  void _invoke(String method, Map<String, Object?> arguments) {
    // fire and forget, as for a model download: a job that never hears
    // "finish" ends itself once the heartbeat stops
    channel.invokeMethod<void>(method, arguments).catchError((Object e) {
      if (kDebugMode) debugPrint('download transfer: $method failed: $e');
    });
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler(_onPlatformCall);
  }

  /// JobParameters.STOP_REASON_USER: stopped from the system's task manager.
  static const _stopReasonUser = 13;

  Future<void> _onPlatformCall(MethodCall call) async {
    final args = call.arguments;
    final id = args is Map ? args['id'] : null;
    if (id is! int || id != _id) return;
    switch (call.method) {
      // the notification's button: the job is already ended
      case 'cancel':
        EventLog.add(
          'transfer',
          'job $id: downloads paused from its notification',
        );
        _drop();
        onPause?.call();
      case 'stopped':
        _drop();
        if (args['reason'] == _stopReasonUser) {
          EventLog.add('transfer', 'job $id stopped by the user');
          onPause?.call();
        } else {
          // the system took the job back: the queue goes on in-process; a
          // new job once the app is on screen again
          EventLog.add(
            'transfer',
            'job $id stopped by the system (reason ${args['reason']}): '
                'downloads go on without it',
          );
        }
    }
  }
}
