/// LibrePili — downloading a YouTube video as one finished mp4.
///
/// The bilibili download service is built around `BiliDownloadEntryInfo`:
/// aid/cid, danmaku, cover, an on-disk entry the bilibili app can read back.
/// None of that describes a YouTube video, so this does not go through it.
/// What it does share is the part that matters — [Mp4Remuxer], the same pure
/// Dart remuxer that turns bilibili's two DASH tracks into one progressive
/// file. YouTube's AVC/AV1 and AAC streams are the same kind of fragmented
/// MP4, so the video and the audio arrive separately and leave as one file
/// that any player opens; its VP9 and Opus ones are WebM, which the remuxer
/// cannot read ([YtDownloader.remuxable]).
///
/// The requests carry no cookies and no bilibili headers: a bare
/// [HttpClient], not the app's Dio stack.
library;

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/youtube/invidious_source.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_video_id.dart';
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

class YtDownloadNotMp4 implements Exception {
  const YtDownloadNotMp4();
  @override
  String toString() => '该视频没有可合成为 mp4 的格式（只有 WebM），无法下载';
}

abstract final class YtDownloader {
  /// Whether [pair] can be made one mp4: [Mp4Remuxer] reads ISO BMFF only,
  /// and YouTube serves VP9 (every height above 1080p) and Opus as WebM.
  static bool remuxable(YtStreamPair pair) {
    final video = pair.video;
    if (video == null) return false;
    // itag 18 and friends: one progressive mp4 already
    if (pair.videoUrl == pair.audioUrl) {
      return video.mimeType.startsWith('video/mp4');
    }
    final audio = pair.audio;
    return audio != null &&
        video.mimeType.startsWith('video/mp4') &&
        audio.mimeType.startsWith('audio/mp4');
  }

  /// No single request may sit idle longer than this. A YouTube URL that
  /// stops producing bytes does not close on its own.
  static const _idleTimeout = Duration(seconds: 30);

  /// Downloads [pair] and writes one mp4 where bilibili downloads are
  /// exported ([DownloadService.exportDir]).
  /// Returns the path of the finished file.
  static Future<String> download({
    required YtStreamPair pair,
    required String videoId,
    required String title,
    YtDownloadProgress? onProgress,
    YtDownloadToken? token,
  }) async {
    // a folder of its own that is deleted whole: never a path made of
    // anything but an id
    if (!isYouTubeVideoId(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', 'not a YouTube video id');
    }
    // said before the transfer, not after it as the remuxer's "bad box"
    if (!remuxable(pair)) throw const YtDownloadNotMp4();
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
      final audioBytes = muxed ? 0 : await _contentLength(pair.audioUrl, token);
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
      // galleries and other apps see it, as they do a bilibili download
      if (Platform.isAndroid) await DownloadService.scanMedia(out);
      onProgress?.call(1, '完成');
      return out;
    } catch (_) {
      // a cancel tears the socket down, which surfaces as an HttpException
      // carrying the signed stream URL: it is a cancel, nothing failed
      if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
      rethrow;
    } finally {
      // the parts are never left behind: a half-written m4s beside a
      // finished mp4 reads as a broken download that is not broken
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<String> _outputPath(String title, String videoId) async {
    // Android: the public folder bilibili downloads are exported to (the
    // download folder is app-private there, removed on uninstall)
    final dir = await Directory(
      await DownloadService.exportDir(),
    ).create(recursive: true);
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
    // by code point: by UTF-16 unit, an emoji cut in two
    final runes = safe.runes;
    return runes.length <= 80
        ? safe
        : String.fromCharCodes(runes.take(80)).trim();
  }

  /// [method] on [uri], its redirects followed here rather than by the
  /// client: each hop must be public https ([YtInvidiousSource.isPublicUrl]),
  /// as the stream URL itself had to be when it was listed.
  static Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri uri, {
    String? range,
  }) async {
    for (var hop = 0; hop < 5; hop++) {
      if (hop > 0 && await YtInvidiousSource.isPublicUrl(uri) != true) {
        throw HttpException('redirected to a non-public address', uri: uri);
      }
      final request = await client.openUrl(method, uri)
        ..followRedirects = false;
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(_idleTimeout);
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.statusCode ~/ 100 != 3 || location == null) {
        return response;
      }
      await response.drain<void>();
      uri = uri.resolve(location);
    }
    throw HttpException('too many redirects', uri: uri);
  }

  static Future<int?> _contentLength(String url, YtDownloadToken? token) async {
    final client = HttpClient()..idleTimeout = _idleTimeout;
    token?._register(() => client.close(force: true));
    try {
      final response = await _send(client, 'HEAD', Uri.parse(url));
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
      // the HEAD's length, else the first 206's Content-Range total
      var total = contentLength;
      while (true) {
        if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
        final end = received + _chunkSize - 1;
        final response = await _send(
          client,
          'GET',
          uri,
          range: 'bytes=$received-$end',
        );
        if (response.statusCode != HttpStatus.partialContent &&
            response.statusCode != HttpStatus.ok) {
          if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            // asked past the end: everything is already on disk
            await response.drain<void>();
            break;
          }
          throw HttpException('HTTP ${response.statusCode}', uri: uri);
        }
        final whole = response.statusCode == HttpStatus.ok;
        if (whole) {
          // the range ignored: the whole file, which can only follow nothing
          // (after a first chunk it would be appended to it)
          if (received != 0) {
            await response.drain<void>();
            throw HttpException('range ignored at $received', uri: uri);
          }
        } else {
          // the bytes asked for, not others
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          final m = range == null
              ? null
              : RegExp(r'^bytes (\d+)-\d+/(\d+|\*)').firstMatch(range);
          if (m == null || int.tryParse(m[1]!) != received) {
            await response.drain<void>();
            throw HttpException(
              'unexpected range $range at $received',
              uri: uri,
            );
          }
          total ??= int.tryParse(m[2]!);
        }
        var inChunk = 0;
        await for (final bytes in response.timeout(_idleTimeout)) {
          if (token?.isCancelled ?? false) throw const YtDownloadCancelled();
          sink.add(bytes);
          inChunk += bytes.length;
          onBytes(received + inChunk);
        }
        received += inChunk;
        if (total != null) {
          // the length is known: until all of it, a short reply included
          if (received >= total) break;
          if (whole || inChunk == 0) {
            throw HttpException('ended at $received of $total', uri: uri);
          }
          continue;
        }
        // a server that ignored the range and sent the whole file, or a
        // short read at the end, both mean there is nothing more to ask for
        if (whole || inChunk == 0 || inChunk < _chunkSize) break;
      }
      await sink.flush();
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }
}
