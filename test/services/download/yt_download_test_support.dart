// LibrePili: what the YouTube download tests share (stage-2 plan
// feature-logs/download-platforms/phase2-plan.md §3.1): records written
// into a download root as the adapter writes them, the panel's video
// detail, a fake HttpClient (the cover) and a fake server of a video's
// two streams (the pair transfer, 2d).
//
// Stage 2b: no stream source or YtHarness yet (they come with the start,
// 2e); the tests here run the service through DownloadHarness, whose
// `before` plants the records before the list is read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_pair_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

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
    this.whole = false,
    this.body,
    this.total,
    this.cutAfter,
    this.endAfter,
    this.extra = 0,
  });

  /// [status] with no body ([contentRange] its header, if any).
  const FakeAnswer.status(int status, {String? contentRange})
    : this._(status: status, contentRange: contentRange);

  /// 200: the whole stream, the range ignored.
  const FakeAnswer.whole() : this._(whole: true);

  /// The range answer, but: its bytes taken from [body] (another version
  /// of the stream), its total stated as [total], the connection dropped
  /// after [cutAfter] bytes, the body ended cleanly after [endAfter], or
  /// [extra] bytes more than its Content-Range says.
  const FakeAnswer.range({
    List<int>? body,
    int? total,
    int? cutAfter,
    int? endAfter,
    int extra = 0,
  }) : this._(
         body: body,
         total: total,
         cutAfter: cutAfter,
         endAfter: endAfter,
         extra: extra,
       );

  final int? status;
  final String? contentRange;
  final bool whole;
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

  /// Bytes per body event.
  int piece = 16 << 10;

  /// How many clients were made.
  var clients = 0;

  HttpClient client() {
    clients++;
    return _StreamClient(this);
  }

  /// The URL of [stream] on this server.
  static String url(String stream) =>
      'https://rr1---sn-fake.googlevideo.com/$stream';

  /// The Range headers [stream] was asked with.
  List<String?> rangesOf(String stream) => [
    for (final (s, r) in requests)
      if (s == stream) r,
  ];

  _Answered _answer(String stream, String? range) {
    final n = requests.where((r) => r.$1 == stream).length;
    requests.add((stream, range));
    final scripted = script?.call(stream, n, range);
    final full = bodies[stream] ?? const <int>[];
    if (scripted?.status case final status?) {
      return _Answered(status, {
        'content-range': ?scripted!.contentRange,
      }, const []);
    }
    final m = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (m == null || scripted?.whole == true) {
      return _Answered(200, {'content-length': '${full.length}'}, full);
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
    return _Answered(
      206,
      {
        'content-range': 'bytes $from-$to/${scripted?.total ?? source.length}',
        'content-length': '${bytes.length}',
      },
      bytes,
      stream: stream,
      offset: from,
      cutAfter: scripted?.cutAfter,
      endAfter: scripted?.endAfter,
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
  });

  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
  final String stream;
  final int offset;
  final int? cutAfter;
  final int? endAfter;
}

class _StreamClient extends Fake implements HttpClient {
  _StreamClient(this.server);

  final FakeStreamServer server;
  var _isClosed = false;
  final _closed = Completer<void>();

  @override
  Duration idleTimeout = const Duration(seconds: 15);

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
    return _StreamRequest(this, url.pathSegments.last);
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
            const HttpException('Connection closed while receiving data'),
          );
        }
        await out.close();
      };
    return out.stream;
  }
}

class _StreamRequest extends Fake implements HttpClientRequest {
  _StreamRequest(this._client, this._stream);

  final _StreamClient _client;
  final String _stream;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async {
    final a = _client.server._answer(
      _stream,
      headers.value(HttpHeaders.rangeHeader),
    );
    final response = _StreamResponse(a.status, _client._body(a));
    a.headers.forEach(response.headers.set);
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
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
  PairFixture(this.root, {List<int>? video, List<int>? audio})
    : server = FakeStreamServer({
        'video': video ?? ytBytes(300 * 1024 + 5, 1),
        'audio': audio ?? ytBytes(120 * 1024 + 3, 2),
      }) {
    Directory(path.dirname(dir)).createSync(recursive: true);
  }

  final Directory root;
  final FakeStreamServer server;

  static var _n = 0;

  /// The id the last [start] logged under.
  late String id;

  String get dir => path.join(root.path, 'yt_$ytId', 'main', '137-140');

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
  }) => YtStreamId(
    itag: stream == 'video' ? 137 : 140,
    track: track,
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
  }) {
    id = 'pair${(_n++).toString().padLeft(7, '0')}';
    return YtPairTransfer(
      videoId: id,
      source: 'direct',
      streamDir: streamDir ?? dir,
      video: (url: FakeStreamServer.url('video'), id: video ?? idOf('video')),
      audio: (url: FakeStreamServer.url('audio'), id: audio ?? idOf('audio')),
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
