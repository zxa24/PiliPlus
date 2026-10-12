/// LibrePili: `inv.nadeko.net` as a [YouTubeVideoSource] — the second source
/// the router's fallback slot was left for, for when YouTube refuses this
/// network (its bot wall on `player`).
///
/// ## What it asks, and of whom
///
/// Per video, of the instance: its watch page (`/watch?v=`, the page its own
/// player reads; `/api/v1/videos` answers `403 Endpoint disabled` for
/// everyone) and the caption list (`/api/v1/captions/<id>`); of its
/// companion: the DASH manifest and the caption text. The video itself comes
/// from googlevideo directly — the manifest is asked for without
/// `local=true`, so none of it goes through the instance (see
/// `invidious_parser.dart`).
///
/// The watch page sits behind go-away (`go_away.dart`): a proof of work and
/// a refresh, a few milliseconds of hashing, once a week — the same the
/// instance's own page has a browser do. One page per video opened, kept
/// for the URLs' life, is what a browser on that page costs it, and less:
/// the browser would stream the video through the instance as well.
///
/// ## What it sends
///
/// A plain [HttpClient] of its own, like [IoYtTransport]: nothing of
/// bilibili's, a browser user agent, and go-away's own cookies back to the
/// instance (in memory only). Only the bare video id leaves this file.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/go_away.dart';
import 'package:PiliPlus/services/youtube/invidious_parser.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

class YtInvidiousSource implements YouTubeVideoSource {
  YtInvidiousSource({this.host = defaultHost});

  static const defaultHost = 'https://inv.nadeko.net';

  /// The one the video pages share: go-away's cookie is earned once.
  static final shared = YtInvidiousSource();

  /// The page's own user agent: go-away binds its challenge to it, and turns
  /// away the bare ones (curl's, an empty one — measured 2026-09-20).
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  /// How long a resolved video is kept: its URLs live hours, and a quality
  /// change or a caption should not cost the instance another page.
  static const keep = Duration(minutes: 20);

  final String host;

  /// Where each request's outcome is written (the event log, from the
  /// video page): this file stays free of the app.
  static void Function(String line)? log;

  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = userAgent;

  /// go-away's cookies (and the instance's own), for [host] only.
  final _cookies = <String, String>{};

  final _resolved = <String, ({YtVideoDetail detail, DateTime until})>{};
  final _pending = <String, Future<YtResult<YtVideoDetail>>>{};

  @override
  String get id => 'invidious';

  @override
  String get label => 'Invidious (${Uri.parse(host).host})';

  void close() => _client.close(force: true);

  // ------------------------------------------------------------- the video

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) {
    final kept = _resolved[videoId];
    if (kept != null && DateTime.now().isBefore(kept.until)) {
      return Future.value(YtResult.ok(kept.detail));
    }
    // the page asks for the detail and then the streams: one page for both
    // a block body: `=> _pending.remove(…)` would hand whenComplete this
    // very future to wait for, and it would never complete (2026-10-12)
    return _pending[videoId] ??= _resolve(videoId).whenComplete(() {
      _pending.remove(videoId);
    });
  }

  Future<YtResult<YtVideoDetail>> _resolve(String videoId) async {
    final page = await _watchPage(videoId);
    if (!page.ok) return page.castFailure();
    final watch = parseInvidiousWatch(page.value!, videoId);
    if (watch == null) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-player',
          'the watch page carries no player data',
        ),
      );
    }
    if (watch.isLive) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:live',
          'a live stream: not from this source',
        ),
      );
    }
    final dashUrl = watch.dashUrl;
    if (dashUrl == null) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-streams',
          'the watch page offers no manifest',
        ),
      );
    }

    final (manifest, captionList) = await (
      _get(Uri.parse(dashUrl), cookies: false),
      _get(Uri.parse('$host/api/v1/captions/$videoId')),
    ).wait;
    if (manifest.status != HttpStatus.ok || manifest.body.isEmpty) {
      return YtResult.failed(_verdictOf(manifest, 'manifest'));
    }
    final formats = parseInvidiousDash(manifest.body);
    if (formats.isEmpty) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.transient,
          'invidious:empty-manifest',
          'the manifest lists no stream',
        ),
      );
    }

    Map<String, String> codes = const {};
    if (captionList.status == HttpStatus.ok && captionList.body.isNotEmpty) {
      try {
        codes = invidiousCaptionCodes(jsonDecode(captionList.body));
      } catch (_) {}
    }

    final now = DateTime.now();
    final expiry = invidiousExpiry(formats);
    final lasts = expiry == null ? keep : expiry.difference(now);
    final detail = YtVideoDetail(
      videoId: videoId,
      title: watch.title,
      author: watch.author,
      channelId: watch.channelId,
      description: watch.description,
      viewCount: watch.viewCount,
      duration: watch.duration,
      isLive: false,
      thumbnails: invidiousThumbnails(videoId),
      formats: formats,
      captionTracks: invidiousCaptionTracks(watch, codes),
      expiresIn: lasts,
    );
    // kept until well before the URLs end
    final until = now.add(
      lasts - const Duration(minutes: 30) < keep
          ? lasts ~/ 2
          : keep,
    );
    _resolved[videoId] = (detail: detail, until: until);
    return YtResult.ok(detail);
  }

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async {
    final r = await detail(videoId);
    if (!r.ok) return r.castFailure();
    final detail_ = r.value!;
    final picked = selectYtFormats(detail_.formats, preference);
    if (picked == null) {
      return YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-playable-pair',
          'codecs offered: '
              '${detail_.formats.map((f) => f.codecFamily).toSet().join(', ')}',
        ),
      );
    }
    return YtResult.ok(
      YtStreamPair(
        videoUrl: picked.video.url!,
        audioUrl: picked.audio.url!,
        sourceId: id,
        expiresIn: detail_.expiresIn,
        video: picked.video,
        audio: picked.audio,
      ),
    );
  }

  /// Forgets [videoId]'s resolved URLs: they stopped working before their
  /// time.
  void forget(String videoId) => _resolved.remove(videoId);

  // ------------------------------------------------------------- captions

  @override
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId) async {
    final r = await detail(videoId);
    if (!r.ok) return r.castFailure();
    return YtResult.ok(r.value!.captionTracks);
  }

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) async {
    if (translateTo != null) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-translation',
          "the companion serves a track's own text only",
        ),
      );
    }
    final uri = Uri.tryParse(track.baseUrl);
    if (uri == null) {
      return const YtResult.failed(
        YtVerdict(YtCause.clientBroken, 'invidious:caption-url'),
      );
    }
    final r = await _get(uri, cookies: false);
    if (r.status == HttpStatus.ok && r.body.trimLeft().startsWith('WEBVTT')) {
      return YtResult.ok(r.body);
    }
    return YtResult.failed(_verdictOf(r, 'caption'));
  }

  @override
  Future<YtVerdict> probe() async {
    final r = await _get(Uri.parse('$host/api/v1/stats'));
    return r.status == HttpStatus.ok ? YtVerdict.ok : _verdictOf(r, 'stats');
  }

  // ------------------------------------------------------------- the page

  /// The watch page, through go-away's challenges when they are in the way.
  Future<YtResult<String>> _watchPage(String videoId) async {
    var path = '/watch?v=${Uri.encodeQueryComponent(videoId)}';
    for (var step = 0; step < 5; step++) {
      final r = await _get(Uri.parse('$host$path'));
      if (r.status == HttpStatus.ok) return YtResult.ok(r.body);
      if (r.status != 418 || !GoAway.isChallenge(r.body)) {
        return YtResult.failed(_verdictOf(r, 'watch'));
      }
      if (GoAway.powScript(r.body) case final script?) {
        final passed = await _passPow(script, '$host$path');
        if (passed != null) return YtResult.failed(passed);
        continue;
      }
      if (GoAway.refreshUrl(r.body) case final url?) {
        final answer = await _get(Uri.parse(host).resolve(url));
        final next = answer.location;
        if (answer.status ~/ 100 != 3 || next == null) {
          return YtResult.failed(_verdictOf(answer, 'go-away-refresh'));
        }
        // back to the watch page, with what go-away added to its query
        final back = Uri.parse(host).resolve(next);
        path = back.hasQuery ? '${back.path}?${back.query}' : back.path;
        continue;
      }
      return YtResult.failed(
        YtVerdict(
          YtCause.clientBroken,
          'invidious:go-away:${GoAway.challengeName(r.body) ?? 'unknown'}',
          'a challenge this client does not know',
        ),
      );
    }
    return const YtResult.failed(
      YtVerdict(
        YtCause.clientBroken,
        'invidious:go-away-loop',
        'still challenged after five steps',
      ),
    );
  }

  /// One `js-pow-sha256`: null when passed, why when not.
  Future<YtVerdict?> _passPow(String script, String page) async {
    final base = Uri.parse(host);
    final js = await _get(base.resolve(script), referer: page);
    final challengeId = js.status == HttpStatus.ok ? GoAway.powId(js.body) : null;
    if (challengeId == null) return _verdictOf(js, 'go-away-script');
    final made = await _get(
      base.resolve('${GoAway.powPath}/make-challenge'),
      method: 'POST',
      referer: page,
    );
    Map? challenge;
    try {
      challenge = jsonDecode(made.body) as Map?;
    } catch (_) {}
    final data = challenge?['challenge'];
    final target = challenge?['target'];
    if (data is! String || target is! String) {
      return _verdictOf(made, 'go-away-make');
    }
    final watch = Stopwatch()..start();
    final token = GoAway.solve(data, target);
    if (token == null) {
      return YtVerdict(
        YtCause.clientBroken,
        'invidious:go-away-difficulty',
        'no nonce within the budget (difficulty ${challenge?['difficulty']})',
      );
    }
    final verified = await _get(
      base
          .resolve('${GoAway.powPath}/verify-challenge')
          .replace(
            queryParameters: GoAway.powVerifyQuery(
              token: token,
              id: challengeId,
              redirect: page,
              // the page waits half a second before it sends it
              elapsedMs: watch.elapsedMilliseconds + 500,
            ),
          ),
      referer: page,
    );
    return verified.status ~/ 100 == 3 ? null : _verdictOf(verified, 'go-away-verify');
  }

  // ------------------------------------------------------------- transport

  /// One request, redirects not followed: go-away's cookie arrives on the
  /// redirect, and following it would see only the last response's headers
  /// (measured on Anubis, 2026-09-20).
  Future<_Answer> _get(
    Uri uri, {
    String method = 'GET',
    String? referer,
    bool cookies = true,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final request = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.acceptHeader, 'text/html,application/json,*/*')
        ..headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      if (referer != null) request.headers.set(HttpHeaders.refererHeader, referer);
      final ours = cookies && uri.host == Uri.parse(host).host;
      if (ours && _cookies.isNotEmpty) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        );
      }
      if (method == 'POST') request.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (ours) {
        for (final c in response.cookies) {
          if (c.value.isEmpty || c.maxAge == 0) {
            _cookies.remove(c.name);
          } else {
            _cookies[c.name] = c.value;
          }
        }
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      log?.call(
        '$method ${uri.host}${_short(uri.path)} -> ${response.statusCode} '
        '${body.length} B in ${watch.elapsedMilliseconds} ms',
      );
      return _Answer(
        response.statusCode,
        body,
        response.headers.value(HttpHeaders.locationHeader),
      );
    } catch (e) {
      log?.call('$method ${uri.host}${uri.path}: $e');
      return _Answer(0, '', null, '$e');
    }
  }

  static String _short(String path) =>
      path.length > 60 ? '${path.substring(0, 60)}…' : path;

  static YtVerdict _verdictOf(_Answer r, String what) => switch (r.status) {
    0 => YtVerdict(YtCause.transient, 'invidious:$what:transport', r.error),
    401 || 403 || 429 => YtVerdict(
      YtCause.ipBlocked,
      'invidious:$what:http-${r.status}',
      r.body.length > 80 ? r.body.substring(0, 80) : r.body,
    ),
    _ => YtVerdict(
      YtCause.transient,
      'invidious:$what:http-${r.status}',
      r.body.length > 80 ? r.body.substring(0, 80) : r.body,
    ),
  };
}

class _Answer {
  const _Answer(this.status, this.body, this.location, [this.error = '']);

  final int status;
  final String body;
  final String? location;
  final String error;
}
