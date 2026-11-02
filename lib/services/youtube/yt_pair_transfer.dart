/// LibrePili — a YouTube download's two streams, as one transfer (design
/// §4.2, §4.4; stage-2 plan §3.4).
///
/// The service holds it in its video slot (the audio slot stays empty) and
/// sees it through [DownloadTransfer]: one status for both streams, one
/// `done`. The video and the audio download side by side (measured, §9
/// probe 2: no throttle, no 403 for two parallel range requests).
///
/// Each stream is resumed only when what is on disk is known to be the same
/// encoding as what the server has now: the same itag, audio track and total
/// (`stream.json`, one per stream folder), the same `lmt` on both sides, and
/// the last bytes on disk read back the same (the overlap check). Anything
/// less and the file is downloaded again from 0, with a line in the event
/// log saying why.
///
/// Every request goes through [YtCheckedHops] (each hop public https, its
/// redirects followed here), on a bare [HttpClient]: no cookies, no
/// bilibili headers. There is no host rule beyond that: an Invidious
/// instance serves the streams from its own name.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data' show BytesBuilder;

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_transfer_errors.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:path/path.dart' as path;

/// One stream's identity (design §4.2): `stream.json`'s `video` / `audio`.
@immutable
class YtStreamId {
  const YtStreamId({
    required this.itag,
    this.track,
    this.isDefault = false,
    this.bytes,
    this.lmt,
  });

  /// [format]'s identity as [url] serves it: the total from its
  /// `contentLength` or the URL's `clen=`, the encoding version from its
  /// `lastModified` or the URL's `lmt=` (Invidious maps neither field).
  factory YtStreamId.of(YtFormat format, String url) {
    final query = Uri.tryParse(url)?.queryParameters ?? const {};
    return YtStreamId(
      itag: format.itag,
      track: format.audioTrackId,
      isDefault: format.audioIsDefault,
      bytes: _total(format.contentLength) ?? _total(query['clen']),
      lmt: _version(format.raw['lastModified']) ?? _version(query['lmt']),
    );
  }

  final int itag;

  /// The audio track's own id (not its digest); null: a single track.
  final String? track;
  final bool isDefault;

  /// The stream's total; null: not known.
  final int? bytes;

  /// The encoding version; null: not known.
  final String? lmt;

  /// This, with what [old] knew where this knows nothing (design §2.2
  /// p3#2: a known value is not overwritten by a null).
  YtStreamId over(YtStreamId? old) => old == null
      ? this
      : YtStreamId(
          itag: itag,
          track: track,
          isDefault: isDefault,
          bytes: bytes ?? old.bytes,
          lmt: lmt ?? old.lmt,
        );

  YtStreamId withBytes(int? total) => YtStreamId(
    itag: itag,
    track: track,
    isDefault: isDefault,
    bytes: total,
    lmt: lmt,
  );

  Map<String, Object?> toJson({required bool audio}) => {
    'itag': itag,
    'track': track,
    if (audio) 'default': isDefault,
    'bytes': bytes,
    'lmt': lmt,
  };

  /// [json] as `stream.json` holds a stream, checked field by field; null:
  /// not one (no itag, or a track that is not text). A total that is not
  /// an int, or a version that is not text, reads as not known.
  static YtStreamId? fromJson(Object? json) {
    if (json is! Map) return null;
    final itag = json['itag'];
    final track = json['track'];
    final bytes = json['bytes'];
    final lmt = json['lmt'];
    if (itag is! int || itag <= 0) return null;
    if (track != null && track is! String) return null;
    return YtStreamId(
      itag: itag,
      track: track as String?,
      isDefault: json['default'] == true,
      bytes: bytes is int ? _total(bytes) : null,
      lmt: lmt is String ? _version(lmt) : null,
    );
  }

  /// A stream's total: a positive int no larger than a terabyte.
  static int? _total(Object? v) {
    final n = v is int ? v : (v is String ? int.tryParse(v) : null);
    return n != null && n > 0 && n <= 1 << 40 ? n : null;
  }

  /// An encoding version: non-empty text, not too long to be one.
  static String? _version(Object? v) {
    final s = v?.toString();
    return s != null && s.isNotEmpty && s.length <= 64 ? s : null;
  }
}

/// One stream to download: its address and its identity there.
typedef YtStreamSpec = ({String url, YtStreamId id});

/// A stream folder's identities as a start reads them before its transfer
/// (the progress bar's first values, whether both streams are whole, the
/// pin; stage-2 plan §3.3): `stream.json`, else its `.tmp` (as the
/// transfer reads them); null: neither reads. Read only, and capped as the
/// transfer's read is.
({YtStreamId? video, YtStreamId? audio})? readYtStreamIds(String dir) {
  final file = File(path.join(dir, 'stream.json'));
  for (final f in [file, File('${file.path}.tmp')]) {
    try {
      if (!f.existsSync() || f.lengthSync() > 64 << 10) continue;
      final json = jsonDecode(f.readAsStringSync());
      if (json is Map<String, dynamic> &&
          json['format'] == _StreamMeta.format) {
        return (
          video: YtStreamId.fromJson(json['video']),
          audio: YtStreamId.fromJson(json['audio']),
        );
      }
    } catch (_) {}
  }
  return null;
}

/// What a decision at a stream's start leads to.
enum _Plan { download, resume, complete }

/// A stream stopped from outside (a pause, a delete, the other stream
/// failed): never counted, never reported.
class _Stopped implements Exception {
  const _Stopped();
}

class _Leg {
  _Leg(this.name, YtStreamSpec spec, String dir)
    : url = spec.url,
      id = spec.id,
      file = File(path.join(dir, '$name.m4s'));

  final String name;
  final String url;
  final YtStreamId id;
  final File file;

  File get size => File('${file.path}.size');

  HttpClient? client;
  YtCheckedHops? hops;

  /// The reasons this start has downloaded it from 0 for.
  final reasons = <String>{};

  /// The total this start expects; null: learnt from the first answer.
  int? expected;

  /// Complete in this start.
  var done = false;

  final watch = Stopwatch()..start();
}

/// The two streams of one YouTube download (stage-2 plan §3.4).
///
/// Nothing is called back from the constructor: [task] first waits a turn
/// of the event loop, so the service has put this transfer in its slot
/// before anything is reported, a stream already complete included. Every
/// callback comes from within [task]'s chain (none after it completes),
/// and none after [cancel].
class YtPairTransfer implements DownloadTransfer {
  YtPairTransfer({
    required this.videoId,
    required this.source,
    required this.streamDir,
    required YtStreamSpec video,
    required YtStreamSpec audio,
    required this.report,
    HttpClient Function()? httpClient,
  }) : _video = _Leg('video', video, streamDir),
       _audio = _Leg('audio', audio, streamDir),
       _newClient = httpClient ?? HttpClient.new {
    task = _run();
  }

  final String videoId;

  /// `direct` / `invidious`: written into `stream.json`.
  final String source;

  /// `<entry>/<streamTag>`: its name must be a stream folder's.
  final String streamDir;
  final DownloadTransferReport report;
  final HttpClient Function() _newClient;
  final _Leg _video;
  final _Leg _audio;

  List<_Leg> get _legs => [_video, _audio];

  /// How much of a stream one request asks for: googlevideo throttles an
  /// open-ended GET to a few KB/s, not a ranged one (the old downloader's
  /// measurement).
  @visibleForTesting
  static int chunkSize = 4 << 20;

  /// The bytes read back before a resume (design §4.2 p3#1).
  static const overlapBytes = 64 << 10;

  /// How long a request may wait for its headers, or a body for its next
  /// bytes.
  @visibleForTesting
  static Duration idleTimeout = const Duration(seconds: 30);

  /// The wait after the [failures]th failure in a row that saved nothing
  /// (as `DownloadManager`: 1..5 s).
  @visibleForTesting
  static Duration Function(int failures) backoff = _backoff;

  static Duration _backoff(int failures) => Duration(seconds: failures);

  /// Failures in a row that saved nothing before the stream fails.
  static const maxAttempts = 6;

  /// Self-test hooks (stage-2 plan §3.4): each write's bytes on disk, each
  /// request's range, and a status code to answer a request with instead
  /// of sending it.
  static void Function(String stream, int onDisk)? selfTestOnBytes;
  static void Function(String stream, String range)? selfTestOnRequest;
  static int? Function(String stream, String range)? selfTestInject;

  /// The stream folders a transfer is working in, case-folded as the
  /// service's folder keys: a second one in the same folder is refused.
  static final _busy = <String>{};

  @override
  late final Future<void> task;

  DownloadStatus _status = DownloadStatus.downloading;

  @override
  DownloadStatus get status => _status;

  var _cancelled = false;

  /// One stream failed: the other is being stopped.
  var _stopping = false;

  /// The first stream to fail, and why.
  (_Leg, Object)? _failure;

  /// Ends a wait between attempts early (a cancel, or a stop).
  final _wake = Completer<void>();

  late _StreamMeta _meta;

  /// [call], unless this transfer was cancelled.
  void _say(void Function() call) {
    if (_cancelled) return;
    call();
  }

  void _log(_Leg leg, String text) =>
      EventLog.add('download', 'yt:$videoId: ${leg.name} $text');

  Future<void> _run() async {
    // the service puts this transfer in its slot after the constructor:
    // nothing is reported before that
    await Future<void>.delayed(Duration.zero);
    if (_cancelled) return;
    final key = path.normalize(path.absolute(streamDir)).toLowerCase();
    var held = false;
    try {
      // the folder is joined from the record's stream tag and its files
      // are deleted: only a stream folder's name
      if (!YtDownloadEntry.streamTagPattern.hasMatch(
        path.basename(streamDir),
      )) {
        throw ArgumentError.value(streamDir, 'streamDir', 'not a stream tag');
      }
      if (!_busy.add(key)) {
        throw StateError('another transfer is in $streamDir');
      }
      held = true;
      // not recursive: a folder deleted with its entry is not made again
      await Directory(streamDir).create();
      _meta = await _StreamMeta.open(
        streamDir,
        source,
        video: _video.id,
        audio: _audio.id,
      );
      await Future.wait([_runLeg(_video), _runLeg(_audio)]);
      await _meta.settled;
      // a failure is only ever a stream's own ([_runLeg] looks at the
      // cancel first): a paused transfer has none, and keeps `pause`
      if (_failure case (final leg, final error)) {
        _status = identical(leg, _video)
            ? DownloadStatus.failDownload
            : DownloadStatus.failDownloadAudio;
        _say(() => report.done(YtTransferError(leg.name, error)));
      } else if (!_cancelled) {
        _status = DownloadStatus.completed;
        _say(report.done);
      }
    } catch (e) {
      if (_cancelled) return;
      _status = DownloadStatus.failDownload;
      _say(() => report.done(YtTransferError(_video.name, e)));
    } finally {
      for (final leg in _legs) {
        leg.client?.close(force: true);
      }
      if (held) _busy.remove(key);
    }
  }

  /// [leg] to its end; the first to fail stops the other.
  Future<void> _runLeg(_Leg leg) async {
    try {
      await _stream(leg);
      if (_cancelled || _stopping) return;
      leg.done = true;
      if (identical(leg, _video)) {
        if (!_audio.done) _status = DownloadStatus.audioDownloading;
        _say(report.videoDone);
      }
    } catch (e) {
      // stopped from outside: what that threw is not a failure of its own
      if (_cancelled || _stopping) return;
      _stopping = true;
      _failure = (leg, e);
      if (!_wake.isCompleted) _wake.complete();
      for (final other in _legs) {
        // its bytes are kept: a later start resumes from them
        if (!identical(other, leg)) other.client?.close(force: true);
      }
    }
  }

  void _check() {
    if (_cancelled || _stopping) throw const _Stopped();
  }

  int _length(File file) => file.existsSync() ? file.lengthSync() : 0;

  /// [leg]'s bytes so far to the service: at most every 200 ms unless
  /// [force].
  void _progress(_Leg leg, int received, {bool force = false}) {
    if (!force && leg.watch.elapsedMilliseconds < 200) return;
    leg.watch.reset();
    final total = leg.expected ?? 0;
    _say(
      () => identical(leg, _video)
          ? report.video(received, total)
          : report.audio(received, total),
    );
  }

  Future<void> _stream(_Leg leg) async {
    final plan = await _decide(leg);
    _check();
    _progress(leg, _length(leg.file), force: true);
    if (plan == _Plan.complete) {
      await _complete(leg);
      return;
    }
    var check = plan == _Plan.resume;
    // only failures in a row that saved nothing count (DownloadManager)
    var failures = 0;
    while (true) {
      _check();
      final before = _length(leg.file);
      try {
        if (check) {
          await _overlap(leg);
          check = false;
          _log(leg, 'resume at $before (overlap ok)');
        }
        await _fetch(leg);
        await _complete(leg);
        return;
      } catch (e) {
        // a pause, a delete, the other stream failed: not this one's
        // failure, whatever was thrown
        if (_cancelled || _stopping) rethrow;
        if (e is YtRangeError) {
          await _restart(leg, e.reason, e);
          check = false;
          failures = 0;
          continue;
        }
        if (!ytRetriedInTransfer(e)) rethrow;
        failures = _length(leg.file) > before ? 1 : failures + 1;
        if (failures >= maxAttempts) rethrow;
        // pause / delete / a stop cut the wait short
        await Future.any<void>([
          Future<void>.delayed(backoff(failures)),
          _wake.future,
        ]);
      }
    }
  }

  /// Design §4.2 rules 0–7, in order.
  Future<_Plan> _decide(_Leg leg) async {
    final onDisk = _length(leg.file);
    final old = _meta.old(leg.name);
    final sized = await _readSize(leg);
    final id = leg.id;
    leg.expected = id.bytes ?? sized ?? old?.bytes;
    // 0. nothing on disk to resume
    if (onDisk == 0) {
      if (_meta.existed) return _restart(leg, 'missing');
      _log(leg, 'start from 0');
      await _fresh(leg);
      return _Plan.download;
    }
    // 1. no identity read: the folder's name gives the itag and the track
    if (old != null) {
      // 2.
      if (old.itag != id.itag) return _restart(leg, 'itag');
      if (old.track != id.track) return _restart(leg, 'track');
      // 3.
      if (old.lmt != null && id.lmt != null && old.lmt != id.lmt) {
        return _restart(leg, 'lmt');
      }
      // 4.
      if (old.bytes != null && id.bytes != null && old.bytes != id.bytes) {
        return _restart(leg, 'size');
      }
    }
    // the size the bytes on disk were written for is another stream's
    if (sized != null && id.bytes != null && sized != id.bytes) {
      return _restart(leg, 'size');
    }
    final expected = leg.expected;
    // 5.
    if (expected == null) return _restart(leg, 'size');
    // 6. complete: no request at all
    if (onDisk == expected) {
      _log(leg, 'already complete ($onDisk)');
      await _meta.set(leg.name, id.over(old).withBytes(expected));
      return _Plan.complete;
    }
    if (onDisk > expected) return _restart(leg, 'size');
    // 7. a resume only with a version known on both sides (§10-4 A)
    if (old == null) return _restart(leg, 'no identity');
    if (old.lmt == null || id.lmt == null) {
      return _restart(leg, 'no validator');
    }
    await _meta.set(leg.name, id.over(old).withBytes(expected));
    await _writeSize(leg, expected);
    return _Plan.resume;
  }

  /// [leg] from 0 for [reason], once per reason in a start: a second time,
  /// [cause] fails it.
  Future<_Plan> _restart(_Leg leg, String reason, [Object? cause]) async {
    if (!leg.reasons.add(reason)) {
      throw cause ?? StateError('${leg.name}: from 0 again ($reason)');
    }
    _log(leg, 'restarted from 0 ($reason)');
    await _fresh(leg);
    return _Plan.download;
  }

  /// [leg]'s file and size dropped, and its identity in `stream.json` the
  /// new one before its first new byte: an old version kept would be taken
  /// for the new bytes' (plan §3.4 「版本重置」).
  Future<void> _fresh(_Leg leg) async {
    _check();
    if (leg.file.existsSync()) await leg.file.delete();
    if (leg.size.existsSync()) await leg.size.delete();
    leg.expected = leg.id.bytes;
    await _meta.set(leg.name, leg.id);
    if (leg.expected case final total?) await _writeSize(leg, total);
  }

  Future<void> _complete(_Leg leg) async {
    final onDisk = _length(leg.file);
    if (_meta.now(leg.name).bytes != onDisk) {
      // a total no answer stated: what was there when the stream ended
      await _meta.set(leg.name, _meta.now(leg.name).withBytes(onDisk));
    }
    leg.expected = onDisk;
    try {
      if (leg.size.existsSync()) await leg.size.delete();
    } catch (_) {}
    _check();
    _progress(leg, onDisk, force: true);
  }

  /// `.size`: the total the bytes on disk were written for (as
  /// DownloadManager's).
  Future<int?> _readSize(_Leg leg) async {
    try {
      final f = leg.size;
      if (!f.existsSync() || f.lengthSync() > 32) return null;
      final v = int.tryParse((await f.readAsString()).trim());
      return v != null && v > 0 ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSize(_Leg leg, int total) async {
    try {
      await leg.size.writeAsString('$total', flush: true);
    } catch (_) {}
  }

  Future<HttpClientResponse> _send(_Leg leg, String range) async {
    _check();
    selfTestOnRequest?.call(leg.name, range);
    if (selfTestInject?.call(leg.name, range) case final code?) {
      throw YtHttpStatus(code);
    }
    final hops = leg.hops ??= YtCheckedHops(
      leg.client = _newClient()..idleTimeout = idleTimeout,
    );
    try {
      final (_, response) = await hops.send(
        'GET',
        Uri.parse(leg.url),
        headers: {HttpHeaders.rangeHeader: range},
        timeout: idleTimeout,
        drainTimeout: idleTimeout,
      );
      return response;
    } on HttpException catch (e) {
      if (e.message == 'too many redirects') {
        throw YtTooManyRedirects(e.uri?.host ?? '');
      }
      rethrow;
    }
  }

  /// A body not read: the connection let go rather than read to its end.
  Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {}
  }

  static final _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$');

  /// `(first, last, total)` of [response]'s Content-Range; null: none.
  (int, int, int?)? _rangeOf(HttpClientResponse response) {
    final m = _contentRange.firstMatch(
      (response.headers.value(HttpHeaders.contentRangeHeader) ?? '').trim(),
    );
    if (m == null) return null;
    final first = int.tryParse(m[1]!);
    final last = int.tryParse(m[2]!);
    if (first == null || last == null || last < first) return null;
    return (first, last, m[3] == '*' ? null : int.tryParse(m[3]!));
  }

  /// Reads back the last bytes on disk and compares them (design §4.2
  /// 「重叠校验」).
  Future<void> _overlap(_Leg leg) async {
    final onDisk = _length(leg.file);
    final k = min(overlapBytes, onDisk);
    final from = onDisk - k;
    final response = await _send(leg, 'bytes=$from-${onDisk - 1}');
    switch (response.statusCode) {
      case HttpStatus.partialContent:
        break;
      case HttpStatus.ok:
        await _discard(response);
        throw YtRangeError.ignored('the overlap at $from');
      case HttpStatus.requestedRangeNotSatisfiable:
        await _discard(response);
        throw YtRangeError.notSatisfiable('the overlap at $from');
      default:
        await _discard(response);
        throw YtHttpStatus(response.statusCode);
    }
    final range = _rangeOf(response);
    if (range == null || range.$1 != from || range.$2 != onDisk - 1) {
      await _discard(response);
      throw YtRangeError.unexpected('the overlap at $from');
    }
    if (range.$3 != null && range.$3 != leg.expected) {
      await _discard(response);
      throw YtRangeError.total('${range.$3}, expected ${leg.expected}');
    }
    final theirs = BytesBuilder(copy: false);
    await for (final data in response.timeout(idleTimeout)) {
      _check();
      if (theirs.length + data.length > k) {
        throw const YtRangeError.unexpected('an overlap past its range');
      }
      theirs.add(data);
    }
    if (theirs.length < k) throw YtShortBody(from + theirs.length, onDisk);
    final file = await leg.file.open();
    final List<int> ours;
    try {
      await file.setPosition(from);
      ours = await file.read(k);
    } finally {
      await file.close();
    }
    final got = theirs.takeBytes();
    for (var i = 0; i < k; i++) {
      if (i >= ours.length || ours[i] != got[i]) {
        throw YtRangeError.overlap('at ${from + i}');
      }
    }
  }

  /// [leg] in ranges from what is on disk to its end.
  Future<void> _fetch(_Leg leg) async {
    while (true) {
      _check();
      final at = _length(leg.file);
      final expected = leg.expected;
      if (expected != null && at >= expected) {
        if (at > expected) {
          throw YtRangeError.unexpected('$at on disk of $expected');
        }
        return;
      }
      var end = at + chunkSize - 1;
      if (expected != null && end > expected - 1) end = expected - 1;
      final response = await _send(leg, 'bytes=$at-$end');
      switch (response.statusCode) {
        case HttpStatus.requestedRangeNotSatisfiable:
          // asked past the end: the end only when the server's total is
          // what is on disk and what was expected
          final stated = RegExp(r'^bytes \*/(\d+)$').firstMatch(
            (response.headers.value(HttpHeaders.contentRangeHeader) ?? '')
                .trim(),
          );
          await _discard(response);
          final total = stated == null ? null : int.tryParse(stated[1]!);
          if (at > 0 && total == at && (expected == null || expected == at)) {
            leg.expected = at;
            return;
          }
          throw YtRangeError.notSatisfiable('at $at of ${total ?? '?'}');
        case HttpStatus.ok:
          // the range ignored: the whole stream, which only a start from 0
          // can take (after bytes on disk it would be appended to them)
          if (at != 0) {
            await _discard(response);
            throw YtRangeError.ignored('at $at');
          }
          final length = response.contentLength;
          final whole = length >= 0 ? length : null;
          if (expected != null && whole != null && whole != expected) {
            await _discard(response);
            throw YtRangeError.total('$whole, expected $expected');
          }
          final limit = expected ?? whole;
          final got = await _write(leg, response, 0, limit);
          if (limit != null && got < limit) throw YtShortBody(got, limit);
          leg.expected = got;
          return;
        case HttpStatus.partialContent:
          final range = _rangeOf(response);
          if (range == null || range.$1 != at || range.$2 > end) {
            await _discard(response);
            throw YtRangeError.unexpected(
              '${response.headers.value(HttpHeaders.contentRangeHeader)} '
              'at $at',
            );
          }
          final (_, last, total) = range;
          if (expected != null && total != null && total != expected) {
            await _discard(response);
            throw YtRangeError.total('$total, expected $expected');
          }
          if (total != null && last >= total) {
            await _discard(response);
            throw YtRangeError.unexpected('$last of $total');
          }
          if (expected == null && total != null) {
            // learnt from this answer (only a start from 0 gets here)
            leg.expected = total;
            await _writeSize(leg, total);
            await _meta.set(leg.name, _meta.now(leg.name).withBytes(total));
          }
          final want = last - at + 1;
          final got = await _write(leg, response, at, want);
          if (got < want) throw YtShortBody(at + got, last + 1);
          // no total stated: a range shorter than asked is the end
          if (total == null && last < end) return;
        default:
          await _discard(response);
          throw YtHttpStatus(response.statusCode);
      }
    }
  }

  /// Appends [response]'s body to [leg]'s file, at most [limit] bytes (a
  /// body past its range is not written). Returns the bytes written.
  Future<int> _write(
    _Leg leg,
    HttpClientResponse response,
    int at,
    int? limit,
  ) async {
    final sink = leg.file.openWrite(mode: FileMode.writeOnlyAppend);
    var count = 0;
    Object? failed;
    try {
      await for (final data in response.timeout(idleTimeout)) {
        _check();
        if (limit != null && count + data.length > limit) {
          sink.add(data.sublist(0, limit - count));
          count = limit;
          throw const YtRangeError.unexpected('a body past its range');
        }
        sink.add(data);
        count += data.length;
        selfTestOnBytes?.call(leg.name, at + count);
        _progress(leg, at + count);
      }
    } catch (e) {
      failed = e;
      rethrow;
    } finally {
      try {
        await sink.close();
      } catch (e) {
        // the disk's failure, unless another is already on its way
        if (failed == null) rethrow;
      }
    }
    return count;
  }

  @override
  Future<void> cancel({required bool isDelete}) {
    if (!_cancelled) {
      // the status and the flag first: whatever the closed connection
      // throws is read as the cancel it is (design §4.3 p4#3)
      _cancelled = true;
      if (!isDelete &&
          (_status == DownloadStatus.downloading ||
              _status == DownloadStatus.audioDownloading)) {
        _status = DownloadStatus.pause;
      }
      if (!_wake.isCompleted) _wake.complete();
      for (final leg in _legs) {
        leg.client?.close(force: true);
      }
    }
    return task;
  }
}

/// `stream.json`'s only writer for one transfer (plan §3.4): read once,
/// changed in memory by both streams, each change written in turn through
/// `stream.json.tmp` + flush + rename.
class _StreamMeta {
  _StreamMeta._(
    this._dir,
    this._source,
    this.existed,
    this._fromTmp,
    this._old,
    this._now,
  );

  static const format = 'librepili-yt-stream-1';

  static Future<_StreamMeta> open(
    String dir,
    String source, {
    required YtStreamId video,
    required YtStreamId audio,
  }) async {
    final file = File(path.join(dir, 'stream.json'));
    final tmp = File('${file.path}.tmp');
    var json = await _read(file);
    var fromTmp = false;
    if (json == null) {
      // a write cut before its rename: the .tmp is the whole new value
      json = await _read(tmp);
      fromTmp = json != null;
    }
    final existed = file.existsSync() || tmp.existsSync();
    final old = {
      'video': YtStreamId.fromJson(json?['video']),
      'audio': YtStreamId.fromJson(json?['audio']),
    };
    // what is not known: the folder's name gives the itag and the track
    // (design §4.2 rule 1), the total and the version are not known
    YtStreamId stand(YtStreamId id) =>
        YtStreamId(itag: id.itag, track: id.track, isDefault: id.isDefault);
    return _StreamMeta._(dir, source, existed, fromTmp, old, {
      'video': old['video'] ?? stand(video),
      'audio': old['audio'] ?? stand(audio),
    });
  }

  /// [file] as a stream identity; null: missing, not one, or too big to be.
  static Future<Map<String, dynamic>?> _read(File file) async {
    try {
      if (!file.existsSync() || file.lengthSync() > 64 << 10) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic> && json['format'] == format) {
        return json;
      }
    } catch (_) {}
    return null;
  }

  final String _dir;
  final String _source;

  /// `stream.json` or its `.tmp` was there when the start began.
  final bool existed;

  /// What was read came from the `.tmp`: it is the only readable copy, and
  /// the first write makes it the record before writing a new `.tmp`.
  bool _fromTmp;

  final Map<String, YtStreamId?> _old;
  final Map<String, YtStreamId> _now;

  Future<void> _chain = Future.value();

  /// [stream]'s identity as read at the start; null: not read.
  YtStreamId? old(String stream) => _old[stream];

  YtStreamId now(String stream) => _now[stream]!;

  /// Completes once every write asked for so far is done.
  Future<void> get settled => _chain;

  Future<void> set(String stream, YtStreamId id) {
    _now[stream] = id;
    final write = _chain.then((_) => _write());
    _chain = write.then((_) {}, onError: (_) {});
    return write;
  }

  Future<void> _write() async {
    final file = File(path.join(_dir, 'stream.json'));
    final tmp = File('${file.path}.tmp');
    if (_fromTmp) {
      // the new .tmp must not truncate the only readable copy
      await tmp.rename(file.path);
      _fromTmp = false;
    }
    await tmp.writeAsString(
      jsonEncode({
        'format': format,
        'source': _source,
        'video': now('video').toJson(audio: false),
        'audio': now('audio').toJson(audio: true),
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
