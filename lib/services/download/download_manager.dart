import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:dio/dio.dart';

class DownloadManager {
  final String url;

  /// Other CDN addresses of the same stream, tried in turn when a transfer
  /// breaks off (LibrePili: some mirrors drop long transfers mid-way).
  final List<String> backupUrls;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  static const _maxAttempts = 6;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;

  DownloadManager({
    required this.url,
    this.backupUrls = const [],
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
  }) {
    task = _start();
  }

  Future<void> _start() async {
    final urls = [
      url,
      for (final u in backupUrls)
        if (u != url) u,
    ];
    for (var attempt = 0; ; attempt++) {
      final failure = await _attempt(urls[attempt % urls.length]);
      if (failure == null) return; // completed
      final retry =
          _status == DownloadStatus.downloading &&
          !_cancelToken.isCancelled &&
          attempt + 1 < _maxAttempts;
      if (!retry) {
        await _fail(failure.error, delete: failure.beforeData);
        return;
      }
      // resume from what is on disk, on the next address
      await Future.delayed(Duration(seconds: attempt + 1));
    }
  }

  Future<void> _fail(Object e, {required bool delete}) async {
    final file = File(path);
    if (_status == DownloadStatus.downloading) {
      _status = DownloadStatus.failDownload;
      if (delete && file.existsSync()) {
        await file.tryDel();
      }
    }
    onDone(e);
  }

  /// One transfer attempt. Returns null when the file is complete, else the
  /// error and whether it happened before any data was received.
  Future<({Object error, bool beforeData})?> _attempt(String url) async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    Future<void> closeSink() async {
      try {
        await sink.close();
      } catch (_) {}
    }

    Response<ResponseBody> response;
    try {
      response = await Request.http11Dio.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null &&
              (status == 416 || (status >= 200 && status < 300)),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      await closeSink();
      return (error: e, beforeData: true);
    }
    final data = response.data!;
    final contentLength = data.contentLength + received;

    if (received == 0) {
      onReceiveProgress?.call(0, contentLength);
    }

    int? last;
    try {
      await for (final chunk in data.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (last != now) {
          last = now;
          onReceiveProgress?.call(received, contentLength);
        }
      }
      await sink.close();
      _status = DownloadStatus.completed;
      onDone();
      return null;
    } catch (e) {
      await closeSink();
      return (error: e, beforeData: false);
    }
  }

  Future<void> cancel({required bool isDelete}) {
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel();
    }
    return task;
  }
}
