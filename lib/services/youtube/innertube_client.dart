/// The InnerTube client: visitorData bootstrap, `player`, `search`, `next`
/// (related + comments continuations) and caption fetch.
///
/// Request shapes are ported verbatim from the measured spike
/// (`research/youtube-direct-spike.md` §1), which in turn ported them from
/// NewPipeExtractor (GPL-3.0, the same licence as this app):
/// `services/youtube/YoutubeStreamHelper.java`, `YoutubeParsingHelper.java`,
/// `InnertubeClientRequestInfo.java`.
///
/// ## The whole player request, for reference
///
/// ```
/// POST https://youtubei.googleapis.com/youtubei/v1/player
///          ?prettyPrint=false&t=<12 random>&id=<videoId>
/// Content-Type: application/json
/// User-Agent: com.google.visionos.youtube/1.04(RealityDevice17,1; U; …)
/// X-Goog-Api-Format-Version: 2
///
/// {"context":{"client":{…},"request":{…},"user":{…}},
///  "videoId":"<11 chars>","cpn":"<16 random>",
///  "contentCheckOk":true,"racyCheckOk":true}
/// ```
///
/// No API key, no `Authorization`, no cookie, no `Origin`/`Referer`, no
/// `X-YouTube-Client-*`. Two headers, one JSON body.
///
/// ## visitorData
///
/// NewPipe: *"We must always pass a valid visitorData to get valid player
/// responses."* Measured, interleaved and order-balanced: **8/8 videos succeed
/// with one, 1/8 without** — and the failures wear the bot-wall string, which
/// is why [YtDirectSource] re-mints before believing it.
///
/// **visitorData is CLIENT-SCOPED.** Measured 2026-09-20: a blob minted with
/// the VISIONOS context (560 chars) makes a WEB player call answer
/// `404 NOT_FOUND`, and WEB mints an 88-char blob of its own. So one is held
/// per identity, not one per client object.
library;

import 'dart:convert';
import 'dart:math';

import 'package:PiliPlus/services/youtube/yt_classifier.dart';
import 'package:PiliPlus/services/youtube/yt_identity.dart';
import 'package:PiliPlus/services/youtube/yt_json.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_transport.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

/// `contentPlaybackNonce`: 16 chars, sent in the player body and appended to
/// every stream URL as `&cpn=` when the media is fetched
/// (NewPipe `YoutubeStreamExtractor.java:1235`).
typedef YtNonce = String Function(int length);

const String _nonceAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

final Random _secureRandom = Random.secure();

/// The production nonce source. Injected rather than called directly so a
/// fixture-driven test can produce a stable request body.
String defaultYtNonce(int length) => String.fromCharCodes([
  for (var i = 0; i < length; i++)
    _nonceAlphabet.codeUnitAt(_secureRandom.nextInt(_nonceAlphabet.length)),
]);

/// A `player` call's response plus the `cpn` that was sent with it. The same
/// `cpn` must be appended to the stream URLs, so it travels with the response.
class YtPlayerResponse {
  const YtPlayerResponse(this.response, this.verdict, this.cpn);

  final YtResponse response;
  final YtVerdict verdict;
  final String cpn;
}

/// A thin, stateless-except-for-visitorData wrapper over the InnerTube API.
class InnertubeClient {
  InnertubeClient(
    this.transport, {
    String? hl,
    String? gl,
    this._nonce = defaultYtNonce,
  }) : hl = hl ?? ytHl,
       gl = gl ?? ytGl;

  final YtTransport transport;
  final String hl;
  final String gl;
  final YtNonce _nonce;

  /// One anonymous visitor blob per client identity. In memory only; never
  /// written to disk, never shared with the bilibili stack, dropped on
  /// [close]. See the library doc for why it is per-identity.
  final Map<String, String> _visitorData = {};

  String? visitorDataFor(YtClientIdentity c) => _visitorData[c.name];

  /// Forget the blob for [c] so the next call mints a fresh one. This is the
  /// bot-check self-heal's first step.
  void invalidateVisitorData(YtClientIdentity c) => _visitorData.remove(c.name);

  void close() {
    _visitorData.clear();
    transport.close();
  }

  /// The `context` object every InnerTube POST carries. Ported verbatim from
  /// `YoutubeParsingHelper.prepareJsonBuilder`.
  Map<String, dynamic> buildContext(YtClientIdentity c) => {
    'context': {
      'client': c.clientContext(
        visitorData: _visitorData[c.name],
        hl: hl,
        gl: gl,
      ),
      'request': {'internalExperimentFlags': <dynamic>[], 'useSsl': true},
      'user': {'lockedSafetyMode': false},
    },
  };

  /// POST one InnerTube endpoint. Callers apply the semantics.
  Future<YtResponse> post(
    String endpoint,
    YtClientIdentity c,
    Map<String, dynamic> body, {
    String? extraQuery,
    bool? gapis,
  }) {
    final base = (gapis ?? c.gapis) ? youtubeiGapisBase : youtubeiWebBase;
    final query = StringBuffer('prettyPrint=false');
    if (extraQuery != null) query.write('&$extraQuery');
    return transport.send(
      'POST',
      Uri.parse('$base$endpoint?$query'),
      headers: c.headers(gl),
      body: utf8.encode(jsonEncode({...buildContext(c), ...body})),
    );
  }

  /// Mint a visitorData for [c] and remember it.
  ///
  /// The endpoint is on `www.youtube.com` for every identity, including the
  /// ones whose player calls go to the gapis host — that is what NewPipe does
  /// (`YoutubeStreamHelper.java:87`) and it works.
  Future<YtVerdict> bootstrapVisitorData(YtClientIdentity c) async {
    final r = await post(
      visitorIdEndpoint,
      c,
      const {},
      gapis: false,
    );
    final transportVerdict = classifyYtTransport(r);
    if (transportVerdict != null) return transportVerdict;
    final v = ((r.obj['responseContext'] as Map?)?['visitorData'])?.toString();
    if (v == null || v.isEmpty) {
      return const YtVerdict(
        YtCause.clientBroken,
        'no-visitorData',
        'visitor_id answered without responseContext.visitorData',
      );
    }
    _visitorData[c.name] = v;
    return YtVerdict.ok;
  }

  /// Mint a visitorData only if we do not already hold one for [c].
  Future<YtVerdict> ensureVisitorData(
    YtClientIdentity c, {
    bool force = false,
  }) {
    if (!force && _visitorData.containsKey(c.name)) {
      return Future.value(const YtVerdict(YtCause.ok, 'cached'));
    }
    if (force) _visitorData.remove(c.name);
    return bootstrapVisitorData(c);
  }

  /// The `player` call — the request shape this whole layer exists to make.
  ///
  /// [videoId] must already be the bare 11 characters; see
  /// `yt_video_id.dart`. Nothing else about the user is sent.
  Future<YtPlayerResponse> player(
    String videoId, {
    YtClientIdentity client = YtClients.visionOs,
  }) async {
    final cpn = _nonce(16);
    final r = await post(
      'player',
      client,
      {
        'videoId': videoId,
        if (client.gapis) 'cpn': cpn,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      // The `t` parameter is 12 random characters. NewPipe's own comment
      // admits nobody knows how the real one is generated and YouTube does not
      // appear to validate it; the mobile clients send one, so we do too.
      extraQuery: client.gapis ? 't=${_nonce(12)}&id=$videoId' : null,
    );
    final transportVerdict = classifyYtTransport(r);
    return YtPlayerResponse(
      r,
      transportVerdict ?? classifyYtPlayer(r),
      cpn,
    );
  }

  /// `search`. `params: "8AEB"` is NewPipe's "all types, no filter" value.
  Future<YtResponse> search(String query, {String params = '8AEB'}) =>
      post('search', YtClients.web, {'query': query, 'params': params});

  /// Any list continuation on the `search` endpoint.
  Future<YtResponse> searchContinuation(String token) =>
      post('search', YtClients.web, {'continuation': token});

  /// `next`: related videos plus the comments-section bootstrap token.
  Future<YtResponse> next(String videoId) => post('next', YtClients.web, {
    'videoId': videoId,
    'contentCheckOk': true,
    'racyCheckOk': true,
  });

  /// Any list continuation on the `next` endpoint (comments, replies, related).
  Future<YtResponse> nextContinuation(String token) =>
      post('next', YtClients.web, {'continuation': token});

  /// `browse`, e.g. a channel. Not exercised by stage 1.
  Future<YtResponse> browse(String browseId, {String? params}) =>
      post('browse', YtClients.web, {
        'browseId': browseId,
        'params': ?params,
      });

  /// The next page of a `browse` list (a channel's uploads, for instance).
  Future<YtResponse> browseContinuation(String token) =>
      post('browse', YtClients.web, {'continuation': token});

  /// Fetch one caption track's content.
  ///
  /// The track list comes out of the *player* response — no extra request is
  /// needed to discover it. This is a plain GET of the signed `baseUrl`, so it
  /// carries no InnerTube context at all.
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
    YtClientIdentity client = YtClients.visionOs,
  }) async {
    final r = await transport.send(
      'GET',
      Uri.parse(track.urlFor(format, translateTo: translateTo)),
      headers: client.headers(gl),
      parseJson: false,
      followRedirects: true,
    );
    // expectJson: false — vtt is plain text and ttml/srv3 are XML.
    //
    // A 200 with an empty body — the characteristic Invidious failure, and the
    // one thing that must never be silently returned as an empty caption — is
    // already caught here as `transient<empty-200>`, before the format checks.
    final transportVerdict = classifyYtTransport(r, expectJson: false);
    if (transportVerdict != null) return YtResult.failed(transportVerdict);
    return YtResult.ok(r.text);
  }
}

/// Parse a player response that has already been classified [YtCause.ok].
YtVideoDetail parseYtPlayerResponse(YtResponse r) =>
    YtVideoDetail.fromPlayerJson(r.obj);

/// Caption tracks straight out of a player response, without building the
/// whole detail object.
List<YtCaptionTrack> ytCaptionTracksOf(YtResponse r) => mapList(
  ((r.obj['captions'] as Map?)?['playerCaptionsTracklistRenderer']
      as Map?)?['captionTracks'],
  YtCaptionTrack.fromJson,
);
