/// LibrePili: keeps a model download on the network when the app leaves the
/// screen.
///
/// Android 15 cuts a backgrounded app off the network: measured on a Pixel 6
/// Pro (2026-09-29), about 5 s after the app went behind the lock screen
/// `dumpsys netpolicy` showed `effective=APP_BACKGROUND`, its sockets were
/// destroyed, and the next lookup of github.com failed with errno 7 while
/// the shell resolved it fine. Model downloads are 0.9 to 2.8 GB; people
/// lock the phone while they wait.
///
/// The download itself stays in Dart (resume, hash check, mirror fallback
/// in [AsrModelStore]). Around it the platform runs a user-initiated data
/// transfer job (Android 14+, `TransferJobService.kt`): the system binds the
/// job with the flags that give the app network while backgrounded, and the
/// job carries the progress notification the system requires. The job does
/// no transfer of its own; it holds the permission while Dart works.
///
/// Where no job can be had — below Android 14, the permission refused, the
/// app not visible when the user's tap reaches here — the download runs as
/// it always did, in-process, and the reason is put in the [EventLog].
/// See research/uidt-download-2026-09-29.md.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How a transfer's keep-alive went, for the self test's report.
typedef BackgroundTransferStart = ({bool scheduled, String? reason});

class BackgroundTransfer {
  BackgroundTransfer({
    this.channel = const MethodChannel('librepili/transfer'),
    bool? supported,
    this.minInterval = const Duration(seconds: 1),
    this.heartbeat = const Duration(seconds: 30),
  }) : _supported = supported ?? Platform.isAndroid;

  static final instance = BackgroundTransfer();

  /// `TransferJobService.kt`; tests give a fake.
  final MethodChannel channel;
  final bool _supported;

  /// Progress reaches the notification at most this often: every chunk of a
  /// 2.8 GB download would be a platform call and a notification update.
  final Duration minInterval;

  /// While nothing new is reported (a tarball unpacking, a hash running),
  /// the last progress is sent again this often. The job ends itself when
  /// it has heard nothing for minutes — an engine that died with the
  /// download must not leave a notification up for the 12 h a job may run.
  final Duration heartbeat;

  /// The cancel token of each running job, by the job's id.
  final _running = <int, AsrCancelToken>{};

  var _listening = false;

  /// What the last [run] got from the platform.
  BackgroundTransferStart? lastStart;

  /// Runs [body] — a download the user just asked for — inside a job when
  /// one can be had, and plainly when not. [title] and [bytes] describe the
  /// whole of what this one action downloads: one job for all its files.
  ///
  /// [body] reports its progress through the callback it is given. [token]
  /// is the download's own: cancelling it in the app ends the job, and the
  /// notification's cancel button or the system's task manager cancels it.
  ///
  /// Call this straight from the user's tap: the system only allows the job
  /// to be scheduled while the app is visible.
  Future<T> run<T>({
    required String title,
    required int bytes,
    required AsrCancelToken token,
    required Future<T> Function(ValueChanged<AsrProgress> progress) body,
  }) async {
    final id = await _schedule(title, bytes);
    if (id == null) return body(_ignore);

    _running[id] = token;
    AsrProgress? last;
    DateTime? sentAt;
    void send(AsrProgress p) {
      sentAt = DateTime.now();
      _invoke('progress', {
        'id': id,
        'text': _describe(p),
        'received': p.received,
        'total': p.total,
      });
    }

    final beat = Timer.periodic(heartbeat, (_) {
      final p = last;
      if (p == null) {
        _invoke('progress', {
          'id': id,
          'text': '准备下载',
          'received': 0,
          'total': bytes,
        });
      } else {
        send(p);
      }
    });
    try {
      final result = await body((p) {
        last = p;
        final at = sentAt;
        if (at == null || DateTime.now().difference(at) >= minInterval) send(p);
      });
      _end(id, 'done');
      return result;
    } catch (e) {
      if (e is AsrCancelled) {
        _end(id, 'cancelled');
      } else {
        _end(id, 'failed', '$e');
      }
      rethrow;
    } finally {
      beat.cancel();
      _running.remove(id);
    }
  }

  static void _ignore(AsrProgress _) {}

  static String _describe(AsrProgress p) {
    final size = p.total > 0
        ? '${CacheManager.formatSize(p.received)} / '
              '${CacheManager.formatSize(p.total)}'
        : CacheManager.formatSize(p.received);
    return '${p.verifying ? '校验' : '下载'} ${p.label} · $size';
  }

  /// The job's id, or null where the download is to run without one.
  Future<int?> _schedule(String title, int bytes) async {
    if (!_supported) return null;
    if (bytes <= 0) {
      // everything is here already: the body only checks
      lastStart = (scheduled: false, reason: 'nothing to download');
      return null;
    }
    _listen();
    Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMapMethod<Object?, Object?>('start', {
        'title': title,
        'text': '准备下载',
        'total': bytes,
      });
    } on MissingPluginException {
      // a build or platform without the channel: as before
      lastStart = (scheduled: false, reason: 'no channel');
      return null;
    } catch (e) {
      lastStart = (scheduled: false, reason: '$e');
      EventLog.add('transfer', 'no background job for "$title": $e');
      return null;
    }
    final id = reply?['id'];
    if (reply?['scheduled'] == true && id is int) {
      lastStart = (scheduled: true, reason: null);
      EventLog.add('transfer', 'job $id holds the network for "$title"');
      return id;
    }
    final reason = '${reply?['reason'] ?? 'refused'}';
    lastStart = (scheduled: false, reason: reason);
    // the download goes on as it did before jobs existed: fine while the
    // app is on screen, cut off ~5 s after it leaves on Android 15
    EventLog.add(
      'transfer',
      'no background job for "$title" ($reason): downloading in-process',
    );
    return null;
  }

  void _end(int id, String outcome, [String? message]) {
    EventLog.add(
      'transfer',
      'job $id $outcome${message == null ? '' : ': $message'}',
    );
    _invoke('finish', {'id': id, 'outcome': outcome});
  }

  void _invoke(String method, Map<String, Object?> arguments) {
    // fire and forget: a progress update that did not arrive is not worth
    // failing a download for, and a job that never hears "finish" ends
    // itself once the heartbeat stops
    channel.invokeMethod<void>(method, arguments).catchError((Object e) {
      if (kDebugMode) debugPrint('transfer: $method failed: $e');
    });
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler(_onPlatformCall);
  }

  /// JobParameters.STOP_REASON_USER: the user stopped the job from the
  /// system's task manager.
  static const _stopReasonUser = 13;

  Future<void> _onPlatformCall(MethodCall call) async {
    final args = call.arguments;
    final id = args is Map ? args['id'] : null;
    if (id is! int) return;
    switch (call.method) {
      // the notification's cancel button: the job is already ended
      case 'cancel':
        EventLog.add('transfer', 'job $id cancelled from its notification');
        _running[id]?.cancel();
      case 'stopped':
        final reason = args['reason'];
        if (reason == _stopReasonUser) {
          // the user stopped it from the task manager: that is a cancel,
          // and the system will not let the job be scheduled again anyway
          EventLog.add('transfer', 'job $id stopped by the user');
          _running[id]?.cancel();
        } else {
          // the system took the job back (network lost, device state):
          // the download goes on in-process as it would have without one,
          // which on Android 15 lasts while the app is on screen. What it
          // wrote stays in the .part file; the next tap resumes from there.
          EventLog.add(
            'transfer',
            'job $id stopped by the system (reason $reason): '
                'the download goes on without it',
          );
        }
    }
  }
}
