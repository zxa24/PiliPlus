// LibrePili: what the YouTube download tests share (stage-2 plan
// feature-logs/download-platforms/phase2-plan.md §3.1): records written
// into a download root as the adapter writes them, the panel's video
// detail, and a fake HttpClient (the cover now; the transfers in 2e).
//
// Stage 2b: no stream source or YtHarness yet (they come with the start,
// 2e); the tests here run the service through DownloadHarness, whose
// `before` plants the records before the list is read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
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
/// records the requests and whether it was closed. Only what the adapter
/// uses is there (the rest throws).
class FakeYtHttp extends Fake implements HttpClient {
  FakeYtHttp([this.answer = _ok]);

  static ({int status, List<int> body}) _ok(String method, Uri uri) =>
      (status: 200, body: utf8.encode('jpeg of $uri'));

  ({int status, List<int> body}) Function(String method, Uri uri) answer;
  final requests = <(String, Uri)>[];
  var closed = false;

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
    return _Request(answer(method, url));
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this._answer);

  final ({int status, List<int> body}) _answer;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async => _Response(_answer);

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
  _Response(this._answer);

  final ({int status, List<int> body}) _answer;

  @override
  int get statusCode => _answer.status;

  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(_answer.body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
