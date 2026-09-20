/// The direct InnerTube implementation of [YouTubeVideoSource], with the
/// bot-check self-heal built in.
///
/// ## The self-heal, and why it is the point
///
/// `"Sign in to confirm that you're not a bot"` is the string NewPipe maps onto
/// `SignInConfirmNotBotException` with the comment *"YouTube probably
/// temporarily blocked anonymous watch access with this IP"*. It is the obvious
/// trigger for falling back to a third party. **It is not safe.**
///
/// Measured 2026-09-20, interleaved per video and order-balanced so both arms
/// carry the same request volume: **8/8 videos succeed with a `visitorData`,
/// 1/8 without** — and the seven failures all answer with that exact string.
/// A client that treats it as an IP block falls back to a stranger's server
/// *because of its own bug*.
///
/// So a bot-check is a **suspicion, not a verdict**. [YtDirectSource] mints a
/// fresh `visitorData` and retries the same call; only a bot-check that
/// survives that is evidence about our egress IP, and only then is it reported
/// as [YtCause.ipBlocked] with the signal [YtSignals.botCheckConfirmed].
///
/// Measured in the spike's router harness: with the re-mint in place a stale
/// `visitorData` repairs itself and the fallback is never consulted (zero calls
/// to a call-counting spy source, no cooldown set); with the re-mint suppressed
/// the same scenario fell through and set a 5-minute cooldown. The mechanism is
/// exercised in both directions.
library;

import 'package:PiliPlus/services/youtube/innertube_client.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_classifier.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_identity.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_parser.dart';
import 'package:PiliPlus/services/youtube/yt_transport.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

class YtDirectSource implements YouTubeVideoSource {
  YtDirectSource(
    this.client, {
    this.streamClient = YtClients.visionOs,
  });

  /// Convenience constructor for production: owns its own transport.
  factory YtDirectSource.create() =>
      YtDirectSource(InnertubeClient(IoYtTransport()));

  final InnertubeClient client;

  /// The identity used for `player`. Search/next always use WEB — see
  /// [YtClients].
  final YtClientIdentity streamClient;

  @override
  String get id => 'direct';

  @override
  String get label => 'YouTube (direct)';

  void close() => client.close();

  // ------------------------------------------------------------- the player

  /// A `player` call with the bot-check self-heal applied.
  ///
  /// Public because the router's diagnostics and the caption path both need
  /// the raw response, not just the parsed model.
  Future<YtPlayerResponse> playerWithSelfHeal(String videoId) async {
    final visitor = await client.ensureVisitorData(streamClient);
    if (!visitor.isOk) {
      return YtPlayerResponse(
        YtResponse.transportFailure('visitorData unavailable'),
        visitor,
        '',
      );
    }

    final first = await client.player(videoId, client: streamClient);
    if (first.verdict.signal != YtSignals.botCheck) return first;

    // Suspicion, not verdict: mint a fresh visitorData and ask again.
    final reminted = await client.ensureVisitorData(streamClient, force: true);
    if (!reminted.isOk) {
      return YtPlayerResponse(first.response, reminted, first.cpn);
    }
    final second = await client.player(videoId, client: streamClient);
    if (second.verdict.signal != YtSignals.botCheck) return second;

    // It survived a freshly minted visitorData. NOW it is about our IP.
    return YtPlayerResponse(
      second.response,
      const YtVerdict(
        YtCause.ipBlocked,
        YtSignals.botCheckConfirmed,
        'bot wall persisted across a freshly minted visitorData',
      ),
      second.cpn,
    );
  }

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) async {
    final r = await playerWithSelfHeal(videoId);
    if (!r.verdict.isOk) return YtResult.failed(r.verdict);
    return YtResult.ok(parseYtPlayerResponse(r.response));
  }

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async {
    final r = await playerWithSelfHeal(videoId);
    if (!r.verdict.isOk) return YtResult.failed(r.verdict);

    final detail = parseYtPlayerResponse(r.response);

    // A format that needs JavaScript is (d), not a format to skip: its
    // appearance means YouTube moved our identity onto a cipher-bearing path,
    // and the whole zero-JS premise of this layer no longer holds. Measured
    // 0/852 today — this branch exists so the day it changes is loud.
    final needsJs = ytFormatsNeedingJavaScript(detail.formats);
    if (needsJs.isNotEmpty && needsJs.length == detail.formats.length) {
      return YtResult.failed(
        YtVerdict(
          YtCause.clientBroken,
          'needs-javascript',
          '${needsJs.length}/${detail.formats.length} formats carry a '
              'signatureCipher or an &n= throttle parameter',
        ),
      );
    }

    final picked = selectYtFormats(detail.formats, preference);
    if (picked == null) {
      return YtResult.failed(
        YtVerdict(
          YtCause.clientBroken,
          'no-playable-pair',
          'codecs offered: '
              '${detail.formats.map((f) => f.codecFamily).toSet().join(', ')}',
        ),
      );
    }

    // NewPipe appends the same contentPlaybackNonce the player call carried to
    // every stream URL (`YoutubeStreamExtractor.java:1235`).
    final suffix = r.cpn.isEmpty ? '' : '&cpn=${r.cpn}';
    return YtResult.ok(
      YtStreamPair(
        videoUrl: '${picked.video.url}$suffix',
        audioUrl: '${picked.audio.url}$suffix',
        sourceId: id,
        expiresIn: detail.expiresIn,
        video: picked.video,
        audio: picked.audio,
      ),
    );
  }

  @override
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId) async {
    final r = await playerWithSelfHeal(videoId);
    if (!r.verdict.isOk) return YtResult.failed(r.verdict);
    return YtResult.ok(ytCaptionTracksOf(r.response));
  }

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) => client.captionContent(
    track,
    format: format,
    translateTo: translateTo,
    client: streamClient,
  );

  @override
  Future<YtVerdict> probe() =>
      client.ensureVisitorData(streamClient, force: true);

  // ----------------------------------------------------- browse-side calls
  //
  // These use the WEB identity and are NOT part of [YouTubeVideoSource]: an
  // Invidious instance answers them over a completely different API, and
  // pretending otherwise now would bake in the wrong shape. Stage 1 exposes
  // them on the direct source only.

  /// A page of search results.
  Future<YtResult<YtPage<YtSearchItem>>> search(String query) async {
    final r = await client.search(query);
    final verdict = classifyYtTransport(r);
    if (verdict != null) return YtResult.failed(verdict);
    final page = parseSearchResults(r.json);
    if (page.items.isEmpty && page.continuation == null) {
      // A search that parses to nothing at all is far more likely to be a
      // renderer rename than a query with no hits.
      return const YtResult.failed(
        YtVerdict(
          YtCause.clientBroken,
          'search-no-items',
          'no videoRenderer and no continuation token in the response',
        ),
      );
    }
    return YtResult.ok(page);
  }

  /// The next page of search results.
  Future<YtResult<YtPage<YtSearchItem>>> searchContinuation(
    String token,
  ) async {
    final r = await client.searchContinuation(token);
    final verdict = classifyYtTransport(r);
    if (verdict != null) return YtResult.failed(verdict);
    return YtResult.ok(parseSearchResults(r.json));
  }

  /// Related videos plus the token that loads the comments section.
  Future<YtResult<YtRelatedAndComments>> related(String videoId) async {
    final r = await client.next(videoId);
    final verdict = classifyYtTransport(r);
    if (verdict != null) return YtResult.failed(verdict);
    return YtResult.ok(
      YtRelatedAndComments(
        parseRelatedVideos(r.json),
        parseCommentsContinuationToken(r.json),
      ),
    );
  }

  /// One page of comments, from a token produced by [related] or by a previous
  /// page's [YtPage.continuation].
  Future<YtResult<YtPage<YtComment>>> comments(String token) async {
    final r = await client.nextContinuation(token);
    final verdict = classifyYtTransport(r);
    if (verdict != null) return YtResult.failed(verdict);
    return YtResult.ok(parseComments(r.json));
  }
}

/// What a `next` call yields: the related shelf, and the door to the comments.
class YtRelatedAndComments {
  const YtRelatedAndComments(this.related, this.commentsToken);

  final List<YtSearchItem> related;

  /// Null when the video has comments disabled — or when the section moved and
  /// we no longer recognise it. Stage 1 cannot tell those apart from one
  /// response; a caller that sees it null on every video should suspect (d).
  final String? commentsToken;

  @override
  String toString() =>
      'YtRelatedAndComments(${related.length} related, '
      'comments=${commentsToken != null})';
}
