/// LibrePili — downloading a YouTube video as one finished mp4.
///
/// The bilibili download service is built around `BiliDownloadEntryInfo`:
/// aid/cid, danmaku, cover, an on-disk entry the bilibili app can read back.
/// None of that describes a YouTube video, so this does not go through it.
/// What it does share is the part that matters — [Mp4Remuxer], the same pure
/// Dart remuxer that turns bilibili's two DASH tracks into one progressive
/// file. YouTube's adaptive streams are the same kind of fragmented MP4, so
/// the video and the audio arrive separately and leave as one file that any
/// player opens.
///
/// The requests carry no cookies and no bilibili headers: a bare
/// [HttpClient], not the app's Dio stack.
library;

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

/// Progress of a download, 0..1, and what it is doing.
typedef YtDownloadProgress = void Function(double fraction, String stage);

class YtDownloadCancelled implements Exception {
  const YtDownloadCancelled();
  @override
  String toString() => '已取消';
}

class YtDownloadToken {
  bool _cancelled = false;
  void Function()? _abort;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    // tears the socket down: a stalled read does not notice a flag
    _abort?.call();
    _abort = null;
  }

  void _register(void Function()? abort) {
    if (_cancelled) {
      abort?.call();
      return;
    }
    _abort = abort;
  }
}

abstract final class YtDownloader {
  /// No single request may sit idle longer than this. A YouTube URL that
  /// stops producing bytes does not close on its own.
  static const _idleTimeout = Duration(seconds: 30);

  /// Downloads [pair] and writes one mp4 into the app's download folder.
  /// Returns the path of the finished file.
  static Future<String> download({
    required YtStreamPair pair,
    required String videoId,
    required String title,
    YtDownloadProgress? onProgress,
    YtDownloadToken? token,
  }) async {
    final temp = await appTempDirectory();
    final work = await Directory(
      path.join(temp.path, 'ytdl', videoId),
    ).create(recursive: true);
    final videoFile = path.join(work.path, 'video.m4s');
    final audioFile = path.join(work.path, 'audio.m4s');
    final muxed = pair.videoUrl == pair.audioUrl;

    try {
      // The two tracks are weighted by their own sizes rather than counted as
      // two halves: the audio is a small fraction of the video, and a bar
      // that sits at 50% for the whole audio track is a bar that is lying.
      final videoBytes = await _contentLength(pair.videoUrl, token);
      final audioBytes = muxed
          ? 0
          : await _contentLength(pair.audioUrl, token);
      final total = (videoBytes ?? 0) + (audioBytes ?? 0);

      var done = 0;
      void report(int received, String stage) {
        if (total <= 0) return;
        // 0.9 of the bar is the transfer; the remux gets the rest
        onProgress?.call(((done + received) / total) * 0.9, stage);
      }

      await _fetch(
        pair.videoUrl,
        videoFile,
        token,
        (n) => report(n, muxed ? '下载中' : '下载视频'),
        videoBytes,
      );
      done += videoBytes ?? 0;
      if (!muxed) {
        await _fetch(
          pair.audioUrl,
          audioFile,
          token,
          (n) => report(n, '下载音频'),
          audioBytes,
        );
      }

      onProgress?.call(0.92, '合成中');
      final out = await _outputPath(title, videoId);
      if (muxed) {
        // itag 18 and friends are already one progressive mp4
        await File(videoFile).copy(out);
      } else {
        await Mp4Remuxer.remux(
          inputs: [videoFile, audioFile],
          output: out,
        );
      }
      onProgress?.call(1, '完成');
      return out;
    } finally {
      // the parts are never left behind: a half-written m4s beside a
      // finished mp4 reads as a broken download that is not broken
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<String> _outputPath(String title, String videoId) async {
    final dir = await Directory(downloadPath).create(recursive: true);
    final name = '${sanitise(title)}-$videoId.mp4';
    return path.join(dir.path, name);
  }

  /// Everything a file name cannot hold on Windows, plus the separators.
  /// Trimmed to a length that leaves room for the id and the extension.
  static String sanitise(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final safe = cleaned.isEmpty ? 'video' : cleaned;
    return safe.length <= 80 ? safe : safe.substring(0, 80).trim();
  }

  static Future<int?> _contentLength(String url, YtDownloadToken? token) async {
    final client = HttpClient()..idleTimeout = _idleTimeout;
    token?._register(() => client.close(force: true));
    try {
      final request = await client.openUrl('HEAD', Uri.parse(url));
      final response = await request.close().timeout(_idleTimeout);
      await response.drain<void>();
      final length = response.headers.contentLength;
      return length > 0 ? length : null;
    } catch (_) {
      // a missing length only costs the progress bar its precision
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// How much of a stream one request asks for.
  ///
  /// Measured: a single open-ended GET of a googlevideo URL is throttled to
  /// a few KB/s — 3.6 MB of audio in ten minutes — while the same URL plays
  /// at 1080p in the player without trouble. The player is mpv, which reads
  /// in ranges. Asking in ranges is what the throttle is keyed on, so this
  /// does the same.
  static const _chunkSize = 4 << 20;

  static Future<void> _fetch(
    String url,
    String output,
    YtDownloadToken? token,
    void Function(int received) onBytes,
    int? contentLength,
  ) async {
    if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
    final uri = Uri.parse(url);
    final client = HttpClient()..idleTimeout = _idleTimeout;
    token?._register(() => client.close(force: true));
    final sink = File(output).openWrite();
    try {
      var received = 0;
      while (true) {
        if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
        final end = received + _chunkSize - 1;
        final request = await client.getUrl(uri)
          ..headers.set(HttpHeaders.rangeHeader, 'bytes=$received-$end');
        final response = await request.close().timeout(_idleTimeout);
        if (response.statusCode != HttpStatus.partialContent &&
            response.statusCode != HttpStatus.ok) {
          if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            // asked past the end: everything is already on disk
            await response.drain<void>();
            break;
          }
          throw HttpException('HTTP ${response.statusCode}', uri: uri);
        }
        var inChunk = 0;
        await for (final bytes in response.timeout(_idleTimeout)) {
          if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
          sink.add(bytes);
          inChunk += bytes.length;
          onBytes(received + inChunk);
        }
        received += inChunk;
        // a server that ignored the range and sent the whole file, or a
        // short read at the end, both mean there is nothing more to ask for
        if (inChunk == 0 || inChunk < _chunkSize) break;
        if (contentLength != null && received >= contentLength) break;
      }
      await sink.flush();
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }
}
