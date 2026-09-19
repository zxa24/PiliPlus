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
      final error = await _attempt(urls[attempt % urls.length]);
      if (error == null) return; // completed
      if (!_canRetry || attempt + 1 >= _maxAttempts) {
        await _fail(error);
        return;
      }
      // resume from what is on disk, on the next address; pause/delete
      // cuts the wait short
      await Future.any<void>([
        Future.delayed(Duration(seconds: attempt + 1)),
        _cancelToken.whenCancel,
      ]);
      if (!_canRetry) {
        await _fail(error);
        return;
      }
    }
  }

  bool get _canRetry =>
      _status == DownloadStatus.downloading && !_cancelToken.isCancelled;

  Future<void> _fail(Object e) async {
    final file = File(path);
    if (_status == DownloadStatus.downloading) {
      _status = DownloadStatus.failDownload;
      // keep any saved bytes: a later start resumes from them
      if (file.existsSync() && file.lengthSync() == 0) {
        await file.tryDel();
      }
    }
    onDone(e);
  }

  static final _contentRangeReg = RegExp(r'bytes\s+(\d+)-\d+/(\d+|\*)');

  /// One transfer attempt. Returns null when the file is complete, else the
  /// error.
  Future<Object?> _attempt(String url) async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
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
      return e;
    }
    final data = response.data!;
    final contentRange = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );

    Future<void> discard() async {
      try {
        await data.stream.listen(null).cancel();
      } catch (_) {}
    }

    if (response.statusCode == 416) {
      await discard();
      // nothing left to send: complete only if the file on disk is whole
      final total = int.tryParse(contentRange?.split('/').last ?? '');
      if (total != null && total == received) {
        _status = DownloadStatus.completed;
        onDone();
        return null;
      }
      // what is on disk does not match the stream: start over
      await file.writeAsBytes(const []);
      return 'range not satisfiable ($contentRange, have $received)';
    }

    int expected = data.contentLength < 0 ? -1 : data.contentLength + received;
    if (received > 0) {
      if (response.statusCode != 206) {
        // Range ignored: the body is the whole file, rewrite it from 0
        received = 0;
        expected = data.contentLength;
      } else {
        final match = contentRange == null
            ? null
            : _contentRangeReg.firstMatch(contentRange);
        if (match == null || int.parse(match[1]!) != received) {
          await discard();
          return 'unexpected content-range: $contentRange (have $received)';
        }
        expected = int.tryParse(match[2]!) ?? expected;
      }
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    if (received == 0) {
      onReceiveProgress?.call(0, expected);
    }

    int? last;
    try {
      await for (final chunk in data.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (last != now) {
          last = now;
          onReceiveProgress?.call(received, expected);
        }
      }
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      return e;
    }
    if (expected >= 0 && received != expected) {
      // clean early EOF: retry from what was saved
      return 'incomplete transfer: $received of $expected bytes';
    }
    _status = DownloadStatus.completed;
    onDone();
    return null;
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
