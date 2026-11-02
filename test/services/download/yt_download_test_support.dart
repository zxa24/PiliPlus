// LibrePili: what the YouTube download tests share (stage-2 plan
// feature-logs/download-platforms/phase2-plan.md §3.1): records written
// into a download root as the adapter writes them, the panel's video
// detail, a fake HttpClient (the cover), a fake server of a video's two
// streams (the pair transfer, 2d), and for the start (2e) the sources that
// really pick formats (FormatYtSource) and the service with YouTube's
// entrances set (YtHarness, over DownloadHarness).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

/// `<YT_LONG>` of the plan's §5.
const ytId = 'dQw4w9WgXcQ';

/// A thumbnail on a host the cover is fetched from.
String ytThumb(String id) => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

/// The panel's detail of [id] (no formats: 2b does not start).
YtVideoDetail ytDetail({
  String id = ytId,
  String title = 'Never Gonna Give You Up',
  String channelId = 'UCuAXFkgsw1L7xaCfnd5JJOw',
  Duration duration = const Duration(seconds: 213),
}) => YtVideoDetail(
  videoId: id,
  title: title,
  author: 'Rick Astley',
  channelId: channelId,
  duration: duration,
  thumbnails: [YtThumbnail(url: ytThumb(id), width: 480, height: 360)],
  formats: const [],
  captionTracks: const [],
  isLive: false,
  expiresIn: Duration.zero,
);

/// A record as [YtDownloadPlatform.newEntry] makes it, in [root]; [stamp]
/// in seconds.
YtDownloadEntry ytEntry(
  Directory root, {
  String id = ytId,
  int maxHeight = 360,
  bool completed = false,
  String? merged,
  bool extrasPending = false,
  int? stamp,
}) {
  final e = YtDownloadPlatform.newEntry(
    ytDetail(id: id),
    maxHeight,
    stamp == null
        ? DateTime(2026, 11)
        : DateTime.fromMillisecondsSinceEpoch(stamp * 1000),
    root.path,
  );
  return e
    ..isCompleted = completed
    ..mergedPath = merged
    ..extrasPending = extrasPending;
}

/// The record folder of [id] in [root] (made).
Directory ytFolder(Directory root, String id) =>
    Directory(path.join(root.path, 'yt_$id', 'main'))
      ..createSync(recursive: true);

/// [entry]'s record written into the folder of [folderId] (default its own
/// id), as `entry.librepili.json` or only its `.tmp` ([tmpOnly]); or [raw]
/// in place of the record.
File writeYtRecord(
  Directory root,
  YtDownloadEntry entry, {
  String? folderId,
  bool tmpOnly = false,
  String? raw,
}) {
  final dir = ytFolder(root, folderId ?? entry.videoId);
  final file = File(
    path.join(
      dir.path,
      tmpOnly
          ? '${YtDownloadEntry.recordFile}.tmp'
          : YtDownloadEntry.recordFile,
    ),
  )..writeAsStringSync(raw ?? jsonEncode(entry.toJson()));
  return file;
}

/// [file]'s text, read again a few times while Windows refuses it (the
/// service renaming a new record into place at that moment).
Future<String> readRecord(File file) async {
  for (var i = 0; ; i++) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      if (i == 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

// ---------------------------------------------------------- HttpClient

/// A fake [HttpClient]: [answer] gives each request's status and body. It
/// records the requests and whether it was closed. [redirects]: a URL
/// answered with a 302 to another; [stream]: a body given as a stream (one
/// that never ends, say) in place of [answer]'s, which ends with an error
/// once the client is closed. Only what the adapter uses is there (the
/// rest throws).
class FakeYtHttp extends Fake implements HttpClient {
  FakeYtHttp([this.answer = _ok]);

  static ({int status, List<int> body}) _ok(String method, Uri uri) =>
      (status: 200, body: utf8.encode('jpeg of $uri'));

  ({int status, List<int> body}) Function(String method, Uri uri) answer;
  final redirects = <Uri, Uri>{};
  Stream<List<int>> Function(Uri uri)? stream;
  final requests = <(String, Uri)>[];
  var closed = false;
  final _closed = Completer<void>();

  /// Completes when the client is closed.
  Future<void> get whenClosed => _closed.future;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  Duration? connectionTimeout;

  @override
  set findProxy(String Function(Uri url)? f) {}

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add((method, url));
    if (redirects[url] case final to?) {
      return _Request(this, 302, null, {'location': '$to'});
    }
    final a = answer(method, url);
    return _Request(this, a.status, stream?.call(url) ?? Stream.value(a.body));
  }

  @override
  void close({bool force = false}) {
    closed = true;
    if (!_closed.isCompleted) _closed.complete();
  }

  /// [body] until the client is closed, then an error (a closed socket).
  Stream<List<int>> _untilClosed(Stream<List<int>>? body) {
    final out = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    out.onListen = () {
      sub = (body ?? const Stream.empty()).listen(
        out.add,
        onError: out.addError,
        onDone: out.close,
      );
      whenClosed.then((_) {
        if (out.isClosed) return;
        sub?.cancel();
        out
          ..addError(const HttpException('connection closed'))
          ..close();
      });
    };
    out.onCancel = () => sub?.cancel();
    return out.stream;
  }
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this._client, this._status, this._body, [this._headers = const {}]);

  final FakeYtHttp _client;
  final int _status;
  final Stream<List<int>>? _body;
  final Map<String, String> _headers;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async {
    final response = _Response(_status, _client._untilClosed(_body));
    _headers.forEach(response.headers.set);
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _Headers extends Fake implements HttpHeaders {
  final _values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => _values[name.toLowerCase()];
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this._body);

  @override
  final int statusCode;
  final Stream<List<int>> _body;

  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ------------------------------------------------------ stream server

/// What [FakeStreamServer.script] answers one request with in place of the
/// plain range answer.
class FakeAnswer {
  const FakeAnswer._({
    this.status,
    this.contentRange,
    this.location,
    this.whole = false,
    this.body,
    this.total,
    this.cutAfter,
    this.endAfter,
    this.extra = 0,
    this.rangeHeader,
    this.noLength = false,
  });

  /// [status] with no body ([contentRange] / [location] its headers, if
  /// any).
  const FakeAnswer.status(int status, {String? contentRange, String? location})
    : this._(status: status, contentRange: contentRange, location: location);

  /// 200: the whole stream, the range ignored ([noLength]: without a
  /// Content-Length).
  const FakeAnswer.whole({bool noLength = false})
    : this._(whole: true, noLength: noLength);

  /// The range answer, but: its bytes taken from [body] (another version
  /// of the stream), its total stated as [total], the connection dropped
  /// after [cutAfter] bytes, the body ended cleanly after [endAfter],
  /// [extra] bytes more than its Content-Range says, or its Content-Range
  /// [contentRange] (`(first, last) => header`) in place of the true one
  /// (`*` totals, another start …; the body is still the bytes asked for,
  /// cut to the header's length).
  const FakeAnswer.range({
    List<int>? body,
    int? total,
    int? cutAfter,
    int? endAfter,
    int extra = 0,
    String Function(int first, int last)? rangeHeader,
  }) : this._(
         body: body,
         total: total,
         cutAfter: cutAfter,
         endAfter: endAfter,
         extra: extra,
         rangeHeader: rangeHeader,
       );

  final int? status;
  final String? contentRange;
  final String? location;
  final String Function(int first, int last)? rangeHeader;
  final bool whole;
  final bool noLength;
  final List<int>? body;
  final int? total;
  final int? cutAfter;
  final int? endAfter;
  final int extra;
}

/// A fake server of a video's two streams (stage-2 plan §3.1): each URL's
/// last path segment names a stream of [bodies]; a `Range: bytes=a-b` is
/// answered with 206 and those bytes (416 `bytes */<length>` past the end),
/// no Range with 200 and all of them. [script] answers a request its own
/// way. It records every request, and [onClose] is called as a client is
/// closed (before its open bodies fail).
class FakeStreamServer {
  FakeStreamServer(this.bodies);

  final Map<String, List<int>> bodies;

  /// `(stream, Range header)` of every request, in order.
  final requests = <(String, String?)>[];

  /// The answer to the [n]th request (from 0) of [stream]; null: the plain
  /// range answer.
  FakeAnswer? Function(String stream, int n, String? range)? script;

  /// Awaited before each piece of a body: holds a stream mid-body.
  Future<void> Function(String stream, int offset)? pace;

  /// Called as a client is closed.
  void Function()? onClose;

  /// Awaited in each `openUrl` of [stream] (a lookup or a connection that
  /// takes its time); the request it gives is only answered once closed.
  Future<void> Function(String stream)? openHold;

  /// Requests a client opened, answered or not.
  var opened = 0;

  /// Bytes per body event.
  int piece = 16 << 10;

  /// How many clients were made.
  var clients = 0;

  /// The clients made, in order.
  final made = <HttpClient>[];

  HttpClient client() {
    clients++;
    final c = _StreamClient(this);
    made.add(c);
    return c;
  }

  /// The URL of [stream] on this server.
  static String url(String stream) =>
      'https://rr1---sn-fake.googlevideo.com/$stream';

  /// The Range headers [stream] was asked with.
  List<String?> rangesOf(String stream) => [
    for (final (s, r) in requests)
      if (s == stream) r,
  ];

  _Answered _answer(String stream, String? range, Uri uri) {
    final n = requests.where((r) => r.$1 == stream).length;
    requests.add((stream, range));
    final scripted = script?.call(stream, n, range);
    final full = bodies[stream] ?? const <int>[];
    if (scripted?.status case final status?) {
      return _Answered(status, {
        'content-range': ?scripted!.contentRange,
        'location': ?scripted.location,
      }, const []);
    }
    final m = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (m == null || scripted?.whole == true) {
      return _Answered(
        200,
        {if (scripted?.noLength != true) 'content-length': '${full.length}'},
        full,
        stream: stream,
        uri: uri,
      );
    }
    final source = scripted?.body ?? full;
    final from = int.parse(m[1]!);
    if (from >= source.length) {
      return _Answered(416, {
        'content-range': 'bytes */${source.length}',
      }, const []);
    }
    var to = m[2]!.isEmpty ? source.length - 1 : int.parse(m[2]!);
    if (to > source.length - 1) to = source.length - 1;
    var bytes = source.sublist(from, to + 1);
    if (scripted != null && scripted.extra > 0) {
      bytes = [...bytes, ...List.filled(scripted.extra, 0xEE)];
    }
    var header = 'bytes $from-$to/${scripted?.total ?? source.length}';
    if (scripted?.rangeHeader case final make?) {
      header = make(from, to);
      // the body as long as the header says (from the bytes asked for)
      final m = RegExp(r'^bytes (\d+)-(\d+)/').firstMatch(header);
      if (m != null) {
        final n = int.parse(m[2]!) - int.parse(m[1]!) + 1;
        if (n >= 0 && n < bytes.length) bytes = bytes.sublist(0, n);
      }
    }
    return _Answered(
      206,
      {'content-range': header, 'content-length': '${bytes.length}'},
      bytes,
      stream: stream,
      offset: from,
      cutAfter: scripted?.cutAfter,
      endAfter: scripted?.endAfter,
      uri: uri,
    );
  }
}

class _Answered {
  _Answered(
    this.status,
    this.headers,
    this.bytes, {
    this.stream = '',
    this.offset = 0,
    this.cutAfter,
    this.endAfter,
    this.uri,
  });

  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
  final String stream;
  final int offset;
  final int? cutAfter;
  final int? endAfter;

  /// The request's: a dropped connection's error carries it, as dart:io's
  /// does.
  final Uri? uri;
}

class _StreamClient extends Fake implements HttpClient {
  _StreamClient(this.server);

  final FakeStreamServer server;
  var _isClosed = false;
  final _closed = Completer<void>();

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  Duration? connectionTimeout;

  @override
  set findProxy(String Function(Uri url)? f) {}

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (_isClosed) throw StateError('Client is closed');
    await server.openHold?.call(url.pathSegments.last);
    if (_isClosed) throw StateError('Client is closed');
    server.opened++;
    return _StreamRequest(this, url.pathSegments.last, url);
  }

  @override
  void close({bool force = false}) {
    if (_isClosed) return;
    server.onClose?.call();
    _isClosed = true;
    _closed.complete();
  }

  /// [a]'s body in pieces, held by the server's pace; an error once this
  /// client is closed, or where the answer drops the connection.
  Stream<List<int>> _body(_Answered a) {
    final out = StreamController<List<int>>();
    var cancelled = false;
    out
      ..onCancel = () {
        cancelled = true;
      }
      ..onListen = () async {
        var sent = 0;
        final stop = a.cutAfter ?? a.endAfter;
        while (sent < a.bytes.length) {
          if (stop != null && sent >= stop) break;
          if (server.pace case final pace?) {
            await Future.any([pace(a.stream, a.offset + sent), _closed.future]);
          }
          if (cancelled) return;
          if (_isClosed) {
            out
              ..addError(const HttpException('connection closed'))
              ..close();
            return;
          }
          var end = sent + server.piece;
          if (end > a.bytes.length) end = a.bytes.length;
          if (stop != null && end > stop) end = stop;
          out.add(a.bytes.sublist(sent, end));
          sent = end;
          // a turn of the event loop between pieces, as a socket gives
          await Future<void>.delayed(Duration.zero);
        }
        if (cancelled) return;
        if (a.cutAfter != null) {
          out.addError(
            HttpException('Connection closed while receiving data', uri: a.uri),
          );
        }
        await out.close();
      };
    return out.stream;
  }
}

class _StreamRequest extends Fake implements HttpClientRequest {
  _StreamRequest(this._client, this._stream, this._uri);

  final _StreamClient _client;
  final String _stream;
  final Uri _uri;
  var _aborted = false;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async {
    // an aborted request is never sent
    if (_aborted) throw const HttpException('request aborted');
    final a = _client.server._answer(
      _stream,
      headers.value(HttpHeaders.rangeHeader),
      _uri,
    );
    final response = _StreamResponse(a.status, _client._body(a));
    a.headers.forEach(response.headers.set);
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => _aborted = true;
}

class _StreamResponse extends Stream<List<int>> implements HttpClientResponse {
  _StreamResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final Stream<List<int>> _body;

  @override
  final HttpHeaders headers = _Headers();

  @override
  int get contentLength =>
      int.tryParse(headers.value(HttpHeaders.contentLengthHeader) ?? '') ?? -1;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// --------------------------------------------------------- pair transfer

/// What a [YtPairTransfer] called back, in order.
class PairCalls {
  final calls = <String>[];
  final errors = <Object>[];
  var video = 0;
  var audio = 0;
  var videoDone = 0;
  var done = 0;
  (int, int)? lastVideo;
  (int, int)? lastAudio;

  /// Set by a test to read the transfer at each call.
  void Function(String call)? onCall;

  int get count => video + audio + videoDone + done;

  final _done = Completer<void>();

  /// Completes at the first `done`.
  Future<void> get whenDone => _done.future;

  DownloadTransferReport get report => (
    video: (received, total) {
      video++;
      lastVideo = (received, total);
      calls.add('video $received/$total');
      onCall?.call('video');
    },
    audio: (received, total) {
      audio++;
      lastAudio = (received, total);
      calls.add('audio $received/$total');
      onCall?.call('audio');
    },
    videoDone: () {
      videoDone++;
      calls.add('videoDone');
      onCall?.call('videoDone');
    },
    done: ([error]) {
      done++;
      if (error != null) errors.add(error);
      calls.add(error == null ? 'done' : 'done $error');
      onCall?.call('done');
      if (!_done.isCompleted) _done.complete();
    },
  );
}

/// Bytes [n] long, a pattern of [seed]: two seeds, two versions.
List<int> ytBytes(int n, int seed) =>
    List<int>.generate(n, (i) => (i * 31 + seed * 7 + (i >> 9)) & 0xff);

/// A stream folder in [root] with a [FakeStreamServer] of its two streams
/// ([video] and [audio], default two patterns), and what a test plants in
/// it and reads back.
class PairFixture {
  PairFixture(
    this.root, {
    List<int>? video,
    List<int>? audio,
    this.tag = '137-140',
  }) : server = FakeStreamServer({
         'video': video ?? ytBytes(300 * 1024 + 5, 1),
         'audio': audio ?? ytBytes(120 * 1024 + 3, 2),
       }) {
    Directory(path.dirname(dir)).createSync(recursive: true);
  }

  final Directory root;
  final FakeStreamServer server;

  /// The stream folder's name.
  final String tag;

  static var _n = 0;

  /// The id the last [start] logged under.
  late String id;

  String get dir => path.join(root.path, 'yt_$ytId', 'main', tag);

  List<int> body(String stream) => server.bodies[stream]!;

  File file(String stream) => File(path.join(dir, '$stream.m4s'));
  File size(String stream) => File('${file(stream).path}.size');
  File get json => File(path.join(dir, 'stream.json'));
  File get jsonTmp => File('${json.path}.tmp');

  /// [stream]'s identity as the server has it now; [bytes] / [lmt] given
  /// to differ from that (null: not known).
  YtStreamId idOf(
    String stream, {
    Object? bytes = _same,
    Object? lmt = _same,
    String? track,
    bool drc = false,
  }) => YtStreamId(
    itag: stream == 'video' ? 137 : 140,
    track: track,
    drc: drc,
    bytes: identical(bytes, _same) ? body(stream).length : bytes as int?,
    lmt: identical(lmt, _same)
        ? (stream == 'video' ? 'v1' : 'a1')
        : lmt as String?,
  );

  static const _same = Object();

  /// [stream]'s first [n] bytes on disk (all of them: null).
  void plant(String stream, [int? n, List<int>? from]) {
    Directory(dir).createSync(recursive: true);
    final b = from ?? body(stream);
    file(stream).writeAsBytesSync(b.sublist(0, n ?? b.length));
  }

  /// `stream.json` as a transfer writes it, of [video] and [audio].
  void plantJson(YtStreamId video, YtStreamId audio) {
    Directory(dir).createSync(recursive: true);
    json.writeAsStringSync(jsonText(video, audio));
  }

  static String jsonText(YtStreamId video, YtStreamId audio) => jsonEncode({
    'format': 'librepili-yt-stream-1',
    'source': 'direct',
    'video': video.toJson(audio: false),
    'audio': audio.toJson(audio: true),
  });

  Map<String, dynamic> readJson() =>
      jsonDecode(json.readAsStringSync()) as Map<String, dynamic>;

  /// A transfer of this folder's two streams, logging under a fresh id.
  YtPairTransfer start(
    PairCalls calls, {
    YtStreamId? video,
    YtStreamId? audio,
    String? streamDir,
    String query = '',
  }) {
    id = 'pair${(_n++).toString().padLeft(7, '0')}';
    return YtPairTransfer(
      videoId: id,
      source: 'direct',
      streamDir: streamDir ?? dir,
      video: (
        url: '${FakeStreamServer.url('video')}$query',
        id: video ?? idOf('video'),
      ),
      audio: (
        url: '${FakeStreamServer.url('audio')}$query',
        id: audio ?? idOf('audio'),
      ),
      report: calls.report,
      httpClient: server.client,
    );
  }

  /// The transfer's lines in the event log, without the `yt:<id>: `.
  List<String> get log => [
    for (final line in EventLog.recent)
      if (line.indexOf('yt:$id: ') case final at when at >= 0)
        line.substring(at + 'yt:$id: '.length),
  ];
}

/// The transfer's knobs set for a test: small ranges, no waits between
/// attempts, no name lookups (through a "proxy").
void setUpPairTransfer() {
  setUp(() {
    YtPairTransfer.chunkSize = 100 << 10;
    YtPairTransfer.backoff = (_) => Duration.zero;
    YtPairTransfer.idleTimeout = const Duration(seconds: 5);
    YtStreamRelay.proxyFor = (_) => 'PROXY 127.0.0.1:9';
  });
  tearDown(() {
    YtPairTransfer.chunkSize = 4 << 20;
    YtPairTransfer.backoff = (n) => Duration(seconds: n);
    YtPairTransfer.idleTimeout = const Duration(seconds: 30);
    YtPairTransfer.selfTestOnBytes = null;
    YtPairTransfer.selfTestOnRequest = null;
    YtPairTransfer.selfTestInject = null;
    YtStreamRelay.proxyFor = null;
  });
}

// ------------------------------------------------- sources and harness

/// A video format of [FakeStreamServer]'s `video` stream: [bytes] its
/// `contentLength`, [lmt] its `lastModified` (null: not given).
Map<String, dynamic> ytVideoFormat(
  int itag, {
  int width = 1920,
  int height = 1080,
  String codec = 'avc1.640028',
  int? bytes,
  String? lmt = 'v1',
  String? label,
  int bitrate = 2000000,
}) => {
  'itag': itag,
  'mimeType': 'video/mp4; codecs="$codec"',
  'url': '${FakeStreamServer.url('video')}?itag=$itag',
  'bitrate': bitrate,
  'width': width,
  'height': height,
  'qualityLabel': ?label,
  'contentLength': ?bytes?.toString(),
  'lastModified': ?lmt,
};

/// An audio format of [FakeStreamServer]'s `audio` stream.
Map<String, dynamic> ytAudioFormat(
  int itag, {
  int? bytes,
  String? lmt = 'a1',
  String? track,
  bool isDefault = true,
  bool drc = false,
  int bitrate = 128000,
}) => {
  'itag': itag,
  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
  'url': '${FakeStreamServer.url('audio')}?itag=$itag${drc ? '&drc' : ''}',
  'bitrate': bitrate,
  'contentLength': ?bytes?.toString(),
  'lastModified': ?lmt,
  if (track != null) 'audioTrack': {'id': track, 'audioIsDefault': isDefault},
  if (drc) 'isDrc': true,
};

/// A [YouTubeVideoSource] holding [formats] (stage-2 plan §3.1): its
/// `detail` gives them (with [liveNow]); its `streams` really picks with
/// `selectYtFormats` and the preference it is given, answering
/// `no-pinned-pair` / `no-playable-pair` as the direct source does. The
/// next calls fail with [detailFailures] / [streamFailures], in order. It
/// records each preference.
class FormatYtSource implements YouTubeVideoSource {
  FormatYtSource(this.id, this.formats, {this.liveNow = false});

  @override
  final String id;

  List<Map<String, dynamic>> formats;
  bool liveNow;

  /// A live stream's replay: `isLive` (`isLiveContent`) without [liveNow].
  bool replay = false;

  /// Videos live now (or upcoming), beside [liveNow] for all.
  final liveIds = <String>{};

  final detailFailures = <YtVerdict>[];
  final streamFailures = <YtVerdict>[];

  /// Awaited at the start of each `detail` / `streams` call.
  Future<void> Function()? holdDetail;
  Future<void> Function()? holdStreams;
  final preferences = <YtFormatPreference>[];
  var detailCalls = 0;
  var streamCalls = 0;

  @override
  String get label => id;

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) async {
    detailCalls++;
    await holdDetail?.call();
    if (detailFailures.isNotEmpty) {
      return YtResult.failed(detailFailures.removeAt(0));
    }
    return YtResult.ok(
      YtVideoDetail(
        videoId: videoId,
        title: 'Never Gonna Give You Up',
        author: 'Rick Astley',
        channelId: 'UCuAXFkgsw1L7xaCfnd5JJOw',
        duration: const Duration(seconds: 213),
        thumbnails: const [],
        formats: [for (final f in formats) YtFormat(f)],
        captionTracks: const [],
        isLive: liveNow || liveIds.contains(videoId) || replay,
        liveNow: liveNow || liveIds.contains(videoId),
        expiresIn: const Duration(hours: 6),
      ),
    );
  }

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async {
    streamCalls++;
    preferences.add(preference);
    await holdStreams?.call();
    if (streamFailures.isNotEmpty) {
      return YtResult.failed(streamFailures.removeAt(0));
    }
    final all = [for (final f in formats) YtFormat(f)];
    final picked = selectYtFormats(all, preference);
    if (picked == null) {
      if (preference.strict && selectYtFormats(all, preference.loose) != null) {
        return const YtResult.failed(
          YtVerdict(YtCause.contentUnavailable, 'no-pinned-pair'),
        );
      }
      final offered =
          preference.listedCodecsOnly && selectYtFormats(all) != null;
      return YtResult.failed(
        YtVerdict(
          offered ? YtCause.contentUnavailable : YtCause.clientBroken,
          'no-playable-pair',
        ),
      );
    }
    return YtResult.ok(
      YtStreamPair(
        videoUrl: picked.video.url!,
        audioUrl: picked.audio.url!,
        sourceId: id,
        expiresIn: const Duration(hours: 6),
        video: picked.video,
        audio: picked.audio,
      ),
    );
  }

  @override
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId) async =>
      const YtResult.failed(YtVerdict(YtCause.clientBroken, 'not here'));

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) async =>
      const YtResult.failed(YtVerdict(YtCause.clientBroken, 'not here'));

  @override
  Future<YtVerdict> probe() async => YtVerdict.ok;
}

/// A router [YtHarness] made: its mode, whether it was a download's own,
/// and whether its health table was the pages' shared one.
typedef YtRouterMade = ({YtSourceMode mode, bool own, bool shared});

/// The download service with YouTube's entrances set (stage-2 plan §3.1):
/// a [DownloadHarness] with no bilibili entries unless asked, the records
/// [records] makes planted before the list is read, the two sources
/// ([direct], [invidious]) behind every router, the real pair transfer on
/// [server], the merge's remux recorded (and failed with [remuxError]),
/// `beforeMergeForTest` recorded and held by [mergeGate].
class YtHarness {
  final base = DownloadHarness();

  DownloadService get service => base.service;
  Directory get root => base.root;
  List<String> get log => base.log;
  List<String> get toasts => base.toasts;

  late FakeStreamServer server;
  late FormatYtSource direct;
  late FormatYtSource invidious;

  final routers = <YtRouterMade>[];
  final playbackFailed = <String>[];

  /// The remux's inputs, per merge.
  final remuxed = <List<String>>[];

  /// What `beforeMergeForTest` was called with.
  final beforeMerge = <DownloadEntry>[];

  /// Held in `beforeMergeForTest`.
  Future<void>? Function(DownloadEntry entry)? mergeGate;

  /// Thrown by the next remux instead of writing the output (once).
  Object? remuxError;

  /// [YtDownloadPlatform.newTransferForTest]; null: the real transfer.
  DownloadTransfer Function(YtTransferSpec spec, DownloadTransferReport r)?
  newTransfer;

  Future<void> start({
    List<YtDownloadEntry Function(Directory root)> records = const [],
    List<String> bili = const [],
    List<Map<String, dynamic>>? formats,
    FutureOr<void> Function(Directory root)? before,
    Map<String, Object?> Function(String entry, Map<String, dynamic> json)?
    patch,
  }) async {
    server = FakeStreamServer({
      'video': ytBytes(300 * 1024 + 5, 1),
      'audio': ytBytes(120 * 1024 + 3, 2),
    });
    final all =
        formats ??
        [
          ytVideoFormat(137, bytes: server.bodies['video']!.length),
          ytVideoFormat(
            136,
            width: 1280,
            height: 720,
            bytes: server.bodies['video']!.length,
          ),
          ytAudioFormat(140, bytes: server.bodies['audio']!.length),
        ];
    direct = FormatYtSource('direct', all);
    invidious = FormatYtSource('invidious', all);
    YtPairTransfer.chunkSize = 100 << 10;
    YtPairTransfer.backoff = (_) => Duration.zero;
    YtPairTransfer.idleTimeout = const Duration(seconds: 5);
    YtStreamRelay.proxyFor = (_) => 'PROXY 127.0.0.1:9';
    YtDownloadPlatform.routerForTest = (mode, {required own, required health}) {
      routers.add((
        mode: mode,
        own: own,
        shared: identical(health, YtSourceRouter.sharedHealth),
      ));
      return YtSourceRouter(
        direct,
        fallback: invidious,
        mode: mode,
        health: health,
        sleep: (_) async {},
      );
    };
    YtDownloadPlatform.playbackFailedForTest = playbackFailed.add;
    YtDownloadPlatform.toastForTest = base.toasts.add;
    YtDownloadPlatform.httpClientForTest = () => server.client();
    YtDownloadPlatform.newTransferForTest = newTransfer;
    YtDownloadPlatform.remuxForTest = (inputs, output) async {
      remuxed.add(inputs);
      if (remuxError case final e?) {
        remuxError = null;
        throw e;
      }
      await File(output).writeAsBytes([
        for (final i in inputs) ...File(i).readAsBytesSync(),
      ]);
    };
    DownloadService.beforeMergeForTest = (entry) async {
      beforeMerge.add(entry);
      await mergeGate?.call(entry);
    };
    await base.start(
      entries: bili,
      patch: patch,
      before: (root) async {
        for (final make in records) {
          writeYtRecord(root, make(root));
        }
        await before?.call(root);
      },
    );
  }

  Future<void> stop() async {
    await base.stop();
    YtPairTransfer.chunkSize = 4 << 20;
    YtPairTransfer.backoff = (n) => Duration(seconds: n);
    YtPairTransfer.idleTimeout = const Duration(seconds: 30);
    YtPairTransfer.selfTestOnBytes = null;
    YtPairTransfer.selfTestOnRequest = null;
    YtPairTransfer.selfTestInject = null;
    YtStreamRelay.proxyFor = null;
    YtDownloadPlatform.routerForTest = null;
    YtDownloadPlatform.playbackFailedForTest = null;
    YtDownloadPlatform.newTransferForTest = null;
    YtDownloadPlatform.remuxForTest = null;
    DownloadService.beforeMergeForTest = null;
    YtSourceStore.debugMode = YtSourceMode.auto;
    YtSourceRouter.sharedHealth.clear();
    routers.clear();
    playbackFailed.clear();
    remuxed.clear();
    beforeMerge.clear();
    mergeGate = null;
    remuxError = null;
    newTransfer = null;
  }

  /// The service's own object for the YouTube download of [id].
  YtDownloadEntry entry([String id = ytId]) =>
      [...service.waitDownloadQueue, ...service.downloadList].firstWhere(
        (e) => e.key == 'yt:$id',
      ) as YtDownloadEntry;

  /// Starts [entry] and waits until it has [status] (or one of [any]);
  /// with neither, until it is complete (in the list of downloads, its
  /// merge over: the status a completion passes through is replaced in the
  /// same turn).
  Future<void> run(
    YtDownloadEntry entry, {
    DownloadStatus? status,
    Set<DownloadStatus>? any,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    unawaited(service.startDownload(entry));
    await untilStatus(entry, status: status, any: any, timeout: timeout);
  }

  Future<void> untilStatus(
    YtDownloadEntry entry, {
    DownloadStatus? status,
    Set<DownloadStatus>? any,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final want = any ?? {?status};
    return until(
      () => want.isEmpty
          ? service.downloadList.contains(entry)
          : want.contains(entry.status),
      timeout: timeout,
      reason: want.isEmpty
          ? 'yt:${entry.videoId} complete'
          : 'yt:${entry.videoId} in $want',
    );
  }

  /// The stream folder [entry] uses now.
  String streamDir(YtDownloadEntry entry) =>
      path.join(entry.entryDirPath, entry.streamTypeTag);

  /// [entry]'s record as it is on disk.
  Future<Map<String, dynamic>> record(YtDownloadEntry entry) async =>
      jsonDecode(
        await readRecord(
          File(path.join(entry.entryDirPath, YtDownloadEntry.recordFile)),
        ),
      ) as Map<String, dynamic>;
}
