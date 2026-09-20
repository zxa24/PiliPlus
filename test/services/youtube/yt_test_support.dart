/// Shared helpers for the YouTube data-layer tests.
///
/// Every fixture under `test/fixtures/youtube/` is a REAL response recorded
/// from the live service on 2026-09-20, then pruned:
///
///   * only the top-level sections the parsers read are kept
///     (`playabilityStatus`, `videoDetails`, `streamingData`, `captions`,
///     `error` for player responses; `contents` / `onResponseReceived*` /
///     `frameworkUpdates` for list responses). `responseContext` is dropped,
///     which also drops the recorded session's `visitorData`;
///   * long lists are truncated (see each fixture's note below);
///   * every `url` / `baseUrl` has `ip=` and `ipbits=` redacted and is cut to
///     110 characters. The tests only ever ask "is a plain `url` present?",
///     never fetch one, and the recorder's egress IP has no business sitting
///     in a file.
///
/// **No test in this directory touches the network.**
library;

import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/youtube.dart';

const String _fixtureDir = 'test/fixtures/youtube';

/// Load a recorded fixture as decoded JSON.
Object? loadYtFixture(String name) =>
    jsonDecode(File('$_fixtureDir/$name').readAsStringSync());

/// Load a recorded fixture wrapped as a 200 JSON [YtResponse].
YtResponse loadYtResponse(String name, {int status = 200}) =>
    YtResponse.recorded(loadYtFixture(name), status: status);

/// The recorded player responses, and what each one is evidence of.
abstract final class YtFixtures {
  /// `dQw4w9WgXcQ`, VISIONOS, healthy. Lists NOT capped: all 27 adaptive
  /// formats (22 video, 5 audio) and 6 caption tracks, one auto-generated.
  static const String playerOk = 'player_ok.json';

  /// `xQlKGiIwhF4`, VISIONOS, healthy. **Lists NOT capped**: all 120 adaptive
  /// formats, including avc1/vp9/av01 video and 21 dubbed audio languages of
  /// which exactly one is `audioIsDefault`. This is the format-selection
  /// fixture.
  static const String playerFormats = 'player_formats.json';

  /// `AAAAAAAAAAA` — a genuinely dead id. `status=ERROR`,
  /// `reason="This video is unavailable"`, **no `videoDetails`**.
  static const String playerDead = 'player_dead.json';

  /// `HtVdAasjOgU` — age-restricted. `status=LOGIN_REQUIRED`,
  /// `reason="Sign in to confirm your age"`, `videoDetails` PRESENT.
  /// The disambiguation trap: the first five words match the bot wall.
  static const String playerAgeGate = 'player_age_gate.json';

  /// `xQlKGiIwhF4` fetched with NO `visitorData`. `status=LOGIN_REQUIRED`,
  /// `reason="Sign in to confirm that you're not a bot"`. Produced by our own
  /// omission, not by a block — which is the whole point.
  static const String playerBotCheck = 'player_bot_check.json';

  /// `dQw4w9WgXcQ` on the WEB identity: `status=UNPLAYABLE`,
  /// `reason="Video unavailable"`, `videoDetails` PRESENT with the correct
  /// title. A healthy video that a wrong client identity calls unavailable.
  static const String playerWebGeneric = 'player_web_generic.json';

  /// `dQw4w9WgXcQ` on the ANDROID identity: `status=OK`, formats present,
  /// **none carrying a `url` or a `signatureCipher`**, `serverAbrStreamingUrl`
  /// alongside. The SABR-only shape.
  static const String playerSabr = 'player_sabr.json';

  /// `VISIONOS 0.01` — a retired client version. **HTTP 404** carrying the
  /// Google-RPC error envelope. Must classify as (d), never as "video gone".
  static const String playerRpc404 = 'player_rpc_404.json';

  /// `search` for "flutter tutorial", WEB. Lists capped at 4.
  static const String search = 'search.json';

  /// `next` for `dQw4w9WgXcQ`, WEB. Lists capped at 5.
  static const String next = 'next.json';

  /// The comments continuation of that `next`. Lists capped at 30.
  static const String nextComments = 'next_comments.json';
}

/// One request a [FakeYtTransport] saw.
class FakeYtRequest {
  FakeYtRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;

  /// The last path segment, e.g. `player`, `visitor_id`, `search`.
  String get endpoint => url.pathSegments.isEmpty ? '' : url.pathSegments.last;

  Map<String, dynamic> get jsonBody => body == null
      ? const {}
      : (jsonDecode(utf8.decode(body!)) as Map).cast<String, dynamic>();

  /// `context.client` out of the request body.
  Map<String, dynamic> get clientContext =>
      ((jsonBody['context'] as Map?)?['client'] as Map?)
          ?.cast<String, dynamic>() ??
      const {};

  @override
  String toString() => '$method $endpoint';
}

/// A [YtTransport] that answers from a closure instead of the network.
class FakeYtTransport implements YtTransport {
  FakeYtTransport(this.respond);

  /// Called for every request. Return the response it should get.
  final YtResponse Function(FakeYtRequest request) respond;

  final List<FakeYtRequest> requests = [];
  bool closed = false;

  /// Requests seen for one endpoint, e.g. `player`.
  List<FakeYtRequest> to(String endpoint) =>
      requests.where((r) => r.endpoint == endpoint).toList();

  @override
  Future<YtResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    String? contentType,
    bool parseJson = true,
    bool followRedirects = false,
  }) async {
    final r = FakeYtRequest(method, url, headers, body);
    requests.add(r);
    return respond(r);
  }

  @override
  void close() => closed = true;
}

/// A minimal `visitor_id` response body.
YtResponse fakeVisitorIdResponse([String visitorData = 'VISITOR_0']) =>
    YtResponse.recorded({
      'responseContext': {'visitorData': visitorData},
    });

/// A [YouTubeVideoSource] whose every method returns a scripted result, and
/// which counts the calls it receives. Used to observe that the router did NOT
/// consult the fallback.
class ScriptedYtSource implements YouTubeVideoSource {
  ScriptedYtSource(this.id, this._script, {this.probeVerdict = YtVerdict.ok});

  @override
  final String id;

  /// One verdict per call, consumed in order; the last one repeats.
  final List<YtVerdict> _script;

  final YtVerdict probeVerdict;

  int calls = 0;
  int probes = 0;

  @override
  String get label => id;

  YtVerdict _nextVerdict() {
    final v = _script[calls < _script.length ? calls : _script.length - 1];
    calls++;
    return v;
  }

  YtResult<T> _result<T>(T value) {
    final v = _nextVerdict();
    return v.cause == YtCause.ok
        ? YtResult<T>(value, v)
        : YtResult<T>.failed(v);
  }

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) async => _result(
    YtVideoDetail(
      videoId: videoId,
      title: 'scripted',
      author: '',
      channelId: '',
      duration: Duration.zero,
      thumbnails: const [],
      formats: const [],
      captionTracks: const [],
      isLive: false,
      expiresIn: Duration.zero,
    ),
  );

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async => _result(
    YtStreamPair(
      videoUrl: 'https://example.invalid/v?id=$videoId',
      audioUrl: 'https://example.invalid/a?id=$videoId',
      sourceId: id,
      expiresIn: const Duration(hours: 6),
    ),
  );

  @override
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId) async =>
      _result(const <YtCaptionTrack>[]);

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) async => _result('WEBVTT');

  @override
  Future<YtVerdict> probe() async {
    probes++;
    return probeVerdict;
  }
}

/// Build a synthetic player body, for the branches no recorded response
/// covers.
YtResponse syntheticPlayer({
  String? status,
  String? reason,
  Map<String, dynamic>? videoDetails,
  Map<String, dynamic>? streamingData,
  Map<String, dynamic>? extraPlayability,
  Map<String, dynamic>? root,
}) => YtResponse.recorded({
  if (status != null || reason != null || extraPlayability != null)
    'playabilityStatus': {
      'status': ?status,
      'reason': ?reason,
      ...?extraPlayability,
    },
  'videoDetails': ?videoDetails,
  'streamingData': ?streamingData,
  ...?root,
});

/// A minimal adaptive format map.
Map<String, dynamic> fakeFormat({
  required int itag,
  required String mimeType,
  String? url = 'https://rr1.googlevideo.invalid/videoplayback?itag=1',
  String? signatureCipher,
  int bitrate = 100000,
  int? width,
  int? height,
  int? fps,
  String? qualityLabel,
  String? audioTrackId,
  bool audioIsDefault = false,
}) => {
  'itag': itag,
  'mimeType': mimeType,
  'url': ?url,
  'signatureCipher': ?signatureCipher,
  'bitrate': bitrate,
  'width': ?width,
  'height': ?height,
  'fps': ?fps,
  'qualityLabel': ?qualityLabel,
  if (audioTrackId != null)
    'audioTrack': {'id': audioTrackId, 'audioIsDefault': audioIsDefault},
};
