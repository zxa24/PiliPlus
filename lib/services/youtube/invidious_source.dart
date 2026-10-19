/// LibrePili: public Invidious instances as a [YouTubeVideoSource] — the
/// second source the router's fallback slot was left for, for when YouTube
/// refuses this network (its bot wall on `player`).
///
/// ## Which instances
///
/// Invidious' own registry (`api.invidious.io`, [InvidiousInstances]),
/// fetched when first needed and every six hours: every clearnet `https`
/// entry in its health order, whatever its monitor says (the monitor does not
/// check the route used here). The one that served last is asked first. One
/// that puts up a gate this cannot pass (a CAPTCHA, an unknown challenge) or
/// answers with something that is not Invidious is set aside for six hours;
/// one that fails otherwise, for ten minutes. Only when the registry is out
/// of reach are [knownHosts] used — the three measured to work on
/// 2026-10-12.
///
/// ## What it asks, and of whom
///
/// Per video, of an instance: its watch page (`/watch?v=`, the page its own
/// player reads; `/api/v1/videos` answers `403 Endpoint disabled` on every
/// instance measured) and the caption list (`/api/v1/captions/<id>`); of its
/// companion: the DASH manifest and the caption text. The video comes from
/// googlevideo directly where googlevideo serves this machine the
/// instance's URLs — found out with a few bytes of the audio — and through
/// the companion (`local=true`) where it refuses them, which was 9 videos of
/// 10 measured (2026-10-12; Rick Astley the one served). The companion's
/// streams are tried with a few bytes too: its manifest answering is not its
/// streams answering (inv-de1.nadeko.net listed them and answered every one
/// with a 502, 2026-10-16). When an instance cannot serve a video, the next
/// is asked: at most [triesPerVideo] per video. One whose streams the player
/// could not open ([playbackFailed]) is set aside like one that failed here.
///
/// The watch pages sit behind go-away (`inv.nadeko.net`, `go_away.dart`) or
/// Anubis (`invidious.f5.si`, `invidious.tiekoetter.com`, `anubis.dart`):
/// a proof of work, a few milliseconds of hashing, once a week — what the
/// instance's own page has a browser do. One page per video opened, kept
/// for the URLs' life, and the video through its companion only when
/// googlevideo will not hand it over directly: what a browser on that page
/// costs the instance, or less (its player streams through the companion
/// every time).
///
/// ## What it sends
///
/// A plain [HttpClient] of its own, like [IoYtTransport]: nothing of
/// bilibili's, a browser user agent, and the gates' own cookies back to the
/// hosts that set them (in memory only). Only the bare video id leaves this
/// file.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/youtube/anubis.dart';
import 'package:PiliPlus/services/youtube/go_away.dart';
import 'package:PiliPlus/services/youtube/invidious_instances.dart';
import 'package:PiliPlus/services/youtube/invidious_parser.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

/// One answer, read whole. Redirects are never followed: the gates' cookies
/// arrive on the redirect, and a client that follows it sees only the last
/// response's headers (measured on Anubis, 2026-09-20).
class InvidiousAnswer {
  const InvidiousAnswer(
    this.status,
    this.body, {
    this.location,
    this.cookies = const [],
    this.error = '',
  });

  final int status;
  final String body;
  final String? location;
  final List<Cookie> cookies;

  /// Why there is no answer (status 0).
  final String error;
}

/// How a request goes out: [IoInvidiousFetch] in the app, a script in tests.
typedef InvidiousFetch = Future<InvidiousAnswer> Function(
  Uri uri, {
  required String method,
  required Map<String, String> headers,
});

class YtInvidiousSource implements YouTubeVideoSource {
  YtInvidiousSource({
    InvidiousFetch? fetch,
    List<String>? hosts,
    DateTime Function()? clock,
    this.relayed = false,
  }) : _fetch = fetch ?? IoInvidiousFetch().call,
       _fixedHosts = hosts,
       _now = clock ?? DateTime.now;

  /// The one the video pages share: a gate's cookie is earned once.
  static final shared = YtInvidiousSource();

  /// Used only when the registry cannot be read: measured to serve the
  /// watch-page route on 2026-10-12.
  static const knownHosts = [
    'https://inv.nadeko.net',
    'https://invidious.f5.si',
    'https://invidious.tiekoetter.com',
  ];

  /// The page's own user agent: the gates bind their challenge to it, and
  /// turn away the bare ones (curl's, an empty one — measured 2026-09-20).
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  /// How long a resolved video is kept: its URLs live hours, and a quality
  /// change or a caption should not cost the instance another page.
  static const keep = Duration(minutes: 20);

  /// How many instances one video is asked of before giving up.
  static const triesPerVideo = 4;

  /// How long the registry's list is used before it is read again.
  static const registryLasts = Duration(hours: 6);

  /// Where each request's outcome is written (the event log, from the
  /// video page): this file stays free of the app.
  static void Function(String line)? log;

  /// The streams always through the instance's companion (`local=true`).
  /// Off, they come from googlevideo directly wherever it serves this
  /// machine, and through the companion only for a video it refuses.
  final bool relayed;

  final InvidiousFetch _fetch;
  final List<String>? _fixedHosts;
  final DateTime Function() _now;

  List<String>? _registry;
  DateTime? _registryAt;

  /// The instance that served last: asked first.
  String? _preferred;

  /// Instances set aside, until when, and why.
  final _benched = <String, ({DateTime until, String why})>{};

  /// The gates' cookies: `(domain, name) → value`, with whether the domain
  /// is the setting host alone.
  final _cookies = <(String, String), ({String value, bool hostOnly})>{};

  /// [ends]: when its URLs stop being served, as their `expire` says (the
  /// detail's own `expiresIn` is the time left when it was resolved).
  final _resolved =
      <String, ({YtVideoDetail detail, DateTime until, DateTime ends})>{};

  /// The instance each video was served by, for [playbackFailed].
  final _servedBy = <String, String>{};
  final _pending = <String, Future<YtResult<YtVideoDetail>>>{};

  @override
  String get id => 'invidious';

  @override
  String get label =>
      'Invidious${_preferred == null ? '' : ' (${Uri.parse(_preferred!).host})'}';

  /// The instance that served last, if any.
  String? get preferredHost => _preferred;

  // ------------------------------------------------------------- the video

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) {
    final kept = _resolved[videoId];
    if (kept != null && _now().isBefore(kept.until)) {
      return Future.value(YtResult.ok(kept.detail));
    }
    // the page asks for the detail and then the streams: one walk for both.
    // A block body: `=> _pending.remove(…)` would hand whenComplete this
    // very future to wait for, and it would never complete (2026-10-12)
    return _pending[videoId] ??= _resolve(videoId).whenComplete(() {
      _pending.remove(videoId);
    });
  }

  Future<YtResult<YtVideoDetail>> _resolve(String videoId) async {
    final hosts = await _order();
    if (hosts.isEmpty) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.transient,
          'invidious:no-instance',
          'every instance is set aside for now',
        ),
      );
    }
    YtVerdict? last;
    var unavailable = 0;
    var tried = 0;
    // Instances not reached at all are set aside only if another answered
    // in the same walk: with this machine offline none is reached, and
    // every one was set aside for 10 min — just as the network came back.
    final unreached = <(String, YtVerdict)>[];
    var answered = false;
    void benchUnreached() {
      if (!answered) return;
      for (final (host, why) in unreached) {
        _bench(host, why);
      }
    }

    for (final host in hosts) {
      if (tried == triesPerVideo) break;
      tried++;
      final r = await _resolveOn(host, videoId);
      if (r.ok) {
        _preferred = host;
        _servedBy[videoId] = host;
        answered = true;
        benchUnreached();
        return r;
      }
      final verdict = r.verdict;
      last = verdict;
      log?.call('${Uri.parse(host).host}: $verdict');
      if (verdict.signal.endsWith(':transport')) {
        unreached.add((host, verdict));
        continue;
      }
      answered = true;
      switch (verdict.signal) {
        // the same for every instance: no use asking the next
        case 'invidious:live':
          benchUnreached();
          return r;
        // this instance, this video (measured per video, 2026-09-20)
        case 'invidious:no-player' || 'invidious:no-streams':
          unavailable++;
        // this video on this instance, for now: the next, nobody set aside
        case 'invidious:cannot-load':
          break;
        default:
          _bench(host, verdict);
      }
    }
    benchUnreached();
    if (unavailable == tried) {
      // every instance asked found no such video
      return YtResult.failed(last!);
    }
    return YtResult.failed(
      YtVerdict(
        YtCause.transient,
        'invidious:no-instance-served',
        '$tried asked; last: ${last ?? '-'}',
      ),
    );
  }

  /// One video on one instance.
  Future<YtResult<YtVideoDetail>> _resolveOn(
    String host,
    String videoId,
  ) async {
    final page = await _watchPage(host, videoId);
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
    final dash = relayed ? watch.relayedDashUrl : watch.dashUrl;
    if (dash == null) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-streams',
          'the watch page offers no manifest',
        ),
      );
    }

    final base = Uri.parse(host);
    switch (await _isPublic(base.resolve(dash))) {
      case null:
        return YtResult.failed(
          YtVerdict(
            YtCause.transient,
            'invidious:manifest:transport',
            'no address for ${base.resolve(dash).host}',
          ),
        );
      case false:
        return YtResult.failed(
          YtVerdict(
            YtCause.transient,
            'invidious:foreign-manifest',
            'the page points the manifest at ${base.resolve(dash).host}',
          ),
        );
      case true:
    }
    final (listed, captionList) = await (
      _formatsFrom(base.resolve(dash)),
      _get(base.resolve('/api/v1/captions/$videoId')),
    ).wait;
    if (!listed.ok) return listed.castFailure();
    var formats = listed.value!;

    // googlevideo serves the instance's URLs to this machine for few videos
    // (1 in 10, 2026-10-12): asked once with a few bytes, and through the
    // companion only when it refuses
    final relayedDash = watch.relayedDashUrl;
    var throughCompanion = relayed;
    if (!relayed &&
        relayedDash != null &&
        relayedDash != dash &&
        await _isPublic(base.resolve(relayedDash)) == true) {
      final probe = selectYtAudioFormat(formats)?.url;
      if (probe != null && await _refusedHere(probe)) {
        final through = await _formatsFrom(base.resolve(relayedDash));
        if (!through.ok) return through.castFailure();
        formats = through.value!;
        throughCompanion = true;
        log?.call(
          '$videoId: googlevideo refuses it here, '
          'through ${base.resolve(relayedDash).host}',
        );
      }
    }
    if (throughCompanion) {
      if (selectYtAudioFormat(formats)?.url case final probe?) {
        final status = await _companionRefuses(probe);
        if (status != null) {
          return YtResult.failed(
            YtVerdict(
              YtCause.transient,
              'invidious:companion-down',
              '${Uri.parse(probe).host} answers its streams with $status',
            ),
          );
        }
      }
    }

    // refused on some instances (tiekoetter: 403): the labels then
    Map<String, String> codes = const {};
    if (captionList.status == HttpStatus.ok && captionList.body.isNotEmpty) {
      try {
        codes = invidiousCaptionCodes(jsonDecode(captionList.body));
      } catch (_) {}
    }

    final tracks = [
      for (final t in invidiousCaptionTracks(watch, codes, base))
        if (Uri.tryParse(t.baseUrl) case final u?)
          if (await _isPublic(u) == true) t,
    ];

    final now = _now();
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
      captionTracks: tracks,
      expiresIn: lasts,
    );
    // kept until well before the URLs end
    final until = now.add(
      lasts - const Duration(minutes: 30) < keep ? lasts ~/ 2 : keep,
    );
    _resolved[videoId] = (detail: detail, until: until, ends: now.add(lasts));
    return YtResult.ok(detail);
  }

  /// [_isPublic], for the downloader: a stream URL is checked when the
  /// manifest is read, and the hops a download is redirected to with this.
  static Future<bool?> isPublicUrl(Uri uri) => _isPublic(uri);

  /// How a host name is resolved for [_isPublic]: tests put their own.
  static Future<List<InternetAddress>> Function(String host) lookup =
      InternetAddress.lookup;

  /// Whether [uri], named by an instance's watch page, may be asked for:
  /// `https`, to a host that is not — and does not resolve to — this
  /// machine or the local network (loopback, private, link-local,
  /// unique-local, carrier-grade NAT, unspecified, multicast). An instance
  /// already picks which public hosts the streams come from; what its page
  /// must not do is send this machine to a service beside it. Redirects are
  /// not followed ([_get]). Null when the host has no address.
  static Future<bool?> _isPublic(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty) return false;
    final literal = InternetAddress.tryParse(uri.host);
    if (literal != null) return !_isLocal(literal);
    final List<InternetAddress> addresses;
    try {
      addresses = await lookup(uri.host);
    } catch (_) {
      return null;
    }
    if (addresses.isEmpty) return null;
    return !addresses.any(_isLocal);
  }

  static bool _isLocal(InternetAddress address) {
    var b = address.rawAddress;
    if (b.length == 16) {
      // an IPv4 address written as IPv6 (::ffff:a.b.c.d)
      final mapped =
          b.take(10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
      if (!mapped) {
        final zero = b.take(15).every((x) => x == 0);
        return (zero && (b[15] == 0 || b[15] == 1)) || // :: and ::1
            b[0] & 0xfe == 0xfc || // fc00::/7
            (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || // fe80::/10
            b[0] == 0xff; // ff00::/8
      }
      b = b.sublist(12);
    }
    if (b.length != 4) return true;
    return b[0] == 0 || // 0.0.0.0/8
        b[0] == 127 ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] & 0xf0 == 16) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 100 && b[1] & 0xc0 == 64) || // 100.64.0.0/10
        b[0] >= 224; // multicast, and the reserved range above it
  }

  /// The formats of the manifest at [manifest]. Relative stream paths are
  /// the companion's, where the manifest is.
  Future<YtResult<List<YtFormat>>> _formatsFrom(Uri manifest) async {
    final r = await _get(manifest);
    if (r.status != HttpStatus.ok || r.body.isEmpty) {
      return YtResult.failed(_verdictOf(r, 'manifest'));
    }
    // a stream URL is named by the manifest as the manifest is by the page:
    // the same rule ([_isPublic]), each host looked up once
    final public = <String, Future<bool?>>{};
    final formats = [
      for (final f in parseInvidiousDash(r.body, base: manifest))
        if (Uri.tryParse(f.url ?? '') case final u?)
          if (await (public[u.host] ??= _isPublic(u)) == true) f,
    ];
    if (formats.isEmpty) {
      return const YtResult.failed(
        YtVerdict(
          YtCause.transient,
          'invidious:empty-manifest',
          'the manifest lists no stream',
        ),
      );
    }
    return YtResult.ok(formats);
  }

  /// Whether googlevideo refuses [url] to this machine: a few bytes asked
  /// for, its redirects followed (the refusal comes after `ipbypass=yes`'s).
  /// Anything but a 403 leaves it to the player — except a redirect it may
  /// not follow, which counts as refused.
  Future<bool> _refusedHere(String url) async {
    var uri = Uri.parse(url);
    for (var hop = 0; hop < 4; hop++) {
      // every hop as the stream URL itself ([_isPublic]): a redirect to
      // this machine or the local network is not followed — and not left to
      // mpv either, which would follow it there: refused, so the streams go
      // through the companion or not at all
      if (await _isPublic(uri) != true) return true;
      final r = await _fetch(
        uri,
        method: 'GET',
        headers: {
          HttpHeaders.userAgentHeader: userAgent,
          HttpHeaders.rangeHeader: 'bytes=0-1023',
        },
      );
      log?.call('probe ${uri.host} -> ${r.status}');
      final next = r.location;
      if (r.status ~/ 100 != 3 || next == null) return r.status == 403;
      uri = uri.resolve(next);
    }
    return false;
  }

  /// What the companion answers a few bytes of [url] with, when it is not
  /// them (0: no answer); null when it serves them.
  Future<int?> _companionRefuses(String url) async {
    var uri = Uri.parse(url);
    for (var hop = 0; hop < 4; hop++) {
      // as in [_refusedHere]: a hop that is not public is no answer
      if (await _isPublic(uri) != true) return 0;
      final r = await _fetch(
        uri,
        method: 'GET',
        headers: {
          HttpHeaders.userAgentHeader: userAgent,
          HttpHeaders.rangeHeader: 'bytes=0-1023',
        },
      );
      log?.call('probe ${uri.host} -> ${r.status}');
      final next = r.location;
      if (r.status ~/ 100 == 3 && next != null) {
        uri = uri.resolve(next);
        continue;
      }
      return r.status ~/ 100 == 2 ? null : r.status;
    }
    return 0;
  }

  @override
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference = YtFormatPreference.standard,
  }) async {
    final r = await detail(videoId);
    if (!r.ok) return r.castFailure();
    final resolved = r.value!;
    final picked = selectYtFormats(resolved.formats, preference);
    if (picked == null) {
      return YtResult.failed(
        YtVerdict(
          YtCause.contentUnavailable,
          'invidious:no-playable-pair',
          'codecs offered: '
              '${resolved.formats.map((f) => f.codecFamily).toSet().join(', ')}',
        ),
      );
    }
    return YtResult.ok(
      YtStreamPair(
        videoUrl: picked.video.url!,
        audioUrl: picked.audio.url!,
        sourceId: id,
        // the time left now: a detail kept up to 20 min claimed its URLs
        // lived that much longer than they did
        expiresIn:
            _resolved[videoId]?.ends.difference(_now()) ?? resolved.expiresIn,
        video: picked.video,
        audio: picked.audio,
      ),
    );
  }

  /// Forgets [videoId]'s resolved URLs: they stopped working before their
  /// time.
  void forget(String videoId) => _resolved.remove(videoId);

  /// The player could not open the streams [videoId] was served with: the
  /// instance that served them is set aside (for ten minutes) and the video
  /// is asked anew. Without it the player asked again, got the same
  /// instance's same broken companion, and went round for good
  /// (2026-10-16, a phone: inv-de1.nadeko.net's 502s).
  void playbackFailed(String videoId) {
    forget(videoId);
    final host = _servedBy.remove(videoId);
    if (host == null) return;
    _bench(
      host,
      const YtVerdict(
        YtCause.transient,
        'invidious:playback-failed',
        'the player could not open its streams',
      ),
    );
  }

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
    if (uri == null || !uri.hasScheme) {
      return const YtResult.failed(
        YtVerdict(YtCause.clientBroken, 'invidious:caption-url'),
      );
    }
    final r = await _get(uri);
    if (r.status == HttpStatus.ok && r.body.trimLeft().startsWith('WEBVTT')) {
      return YtResult.ok(r.body);
    }
    return YtResult.failed(_verdictOf(r, 'caption'));
  }

  @override
  Future<YtVerdict> probe() async {
    final hosts = await _order();
    if (hosts.isEmpty) {
      return const YtVerdict(YtCause.transient, 'invidious:no-instance');
    }
    final r = await _get(Uri.parse('${hosts.first}/api/v1/stats'));
    return r.status == HttpStatus.ok ? YtVerdict.ok : _verdictOf(r, 'stats');
  }

  // ------------------------------------------------------------- instances

  /// The instances to ask, in order: the one that served last, then the
  /// registry's health order; none that is set aside.
  Future<List<String>> _order() async {
    final now = _now();
    _benched.removeWhere((_, b) => !now.isBefore(b.until));
    final all = _fixedHosts ?? await _registryHosts();
    final open = all.where((h) => !_benched.containsKey(h)).toList();
    final first = _preferred;
    if (first != null && open.remove(first)) open.insert(0, first);
    return open;
  }

  Future<List<String>> _registryHosts() async {
    final at = _registryAt;
    if (_registry != null &&
        at != null &&
        _now().difference(at) < registryLasts) {
      return _registry!;
    }
    final r = await _get(Uri.parse(InvidiousInstances.listUrl));
    List<String> hosts = const [];
    if (r.status == HttpStatus.ok) {
      try {
        hosts = InvidiousInstances.allHttps(jsonDecode(r.body));
      } catch (_) {}
    }
    if (hosts.isEmpty) {
      log?.call(
        'the registry gave no instance (${r.status}): '
        '${_registry == null ? 'the known ones' : 'the last list'}',
      );
      // tried again in ten minutes rather than six hours
      _registryAt = _now().subtract(
        registryLasts - const Duration(minutes: 10),
      );
      return _registry ??= knownHosts;
    }
    log?.call(
      'the registry: ${hosts.map((h) => Uri.parse(h).host).join(', ')}',
    );
    _registryAt = _now();
    return _registry = hosts;
  }

  void _bench(String host, YtVerdict why) {
    final long =
        why.signal.startsWith('invidious:gate') ||
        why.signal.startsWith('invidious:not-invidious') ||
        why.signal.endsWith(':moved');
    final until = _now().add(
      long ? const Duration(hours: 6) : const Duration(minutes: 10),
    );
    _benched[host] = (until: until, why: why.signal);
    if (_preferred == host) _preferred = null;
    log?.call(
      '${Uri.parse(host).host} set aside '
      '${long ? 'for 6 h' : 'for 10 min'}: ${why.signal}',
    );
  }

  // ------------------------------------------------------------- the page

  /// The watch page, through the gate in front of it.
  Future<YtResult<String>> _watchPage(String host, String videoId) async {
    final base = Uri.parse(host);
    var path = '/watch?v=${Uri.encodeQueryComponent(videoId)}';
    for (var step = 0; step < 5; step++) {
      final page = base.resolve(path);
      final r = await _get(page);

      if (Anubis.parse(r.body) case final challenge?) {
        final passed = await _passAnubis(host, challenge, page.toString());
        if (passed != null) return YtResult.failed(passed);
        continue;
      }
      if (r.status == 418 && GoAway.isChallenge(r.body)) {
        if (GoAway.powScript(r.body) case final script?) {
          final passed = await _passGoAwayPow(host, script, page.toString());
          if (passed != null) return YtResult.failed(passed);
          continue;
        }
        if (GoAway.refreshUrl(r.body) case final url?) {
          // named by the gate's page: the rule the page's manifest follows
          if (await _isPublic(base.resolve(url)) != true) {
            return YtResult.failed(_foreignGate(base.resolve(url)));
          }
          final answer = await _get(base.resolve(url));
          final next = answer.location;
          if (answer.status ~/ 100 != 3 || next == null) {
            return YtResult.failed(_verdictOf(answer, 'go-away-refresh'));
          }
          // back to the watch page, with what go-away added to its query
          final back = base.resolve(next);
          path = back.hasQuery ? '${back.path}?${back.query}' : back.path;
          continue;
        }
        return YtResult.failed(
          YtVerdict(
            YtCause.ipBlocked,
            'invidious:gate:go-away:${GoAway.challengeName(r.body) ?? 'unknown'}',
            'a challenge this client does not know',
          ),
        );
      }
      if (r.status == HttpStatus.ok) {
        if (r.body.contains('id="player_data"')) return YtResult.ok(r.body);
        // Invidious' own page without a player (a video it cannot show), or
        // something else: a CAPTCHA (yt.chocolatemoo53.com, protokolla.fi),
        // an antibot of the instance's own (yewtu.be)
        return YtResult.failed(
          _isInvidious(r.body)
              ? const YtVerdict(
                  YtCause.contentUnavailable,
                  'invidious:no-player',
                  'the watch page carries no player data',
                )
              : YtVerdict(
                  YtCause.ipBlocked,
                  'invidious:gate:${_titleOf(r.body)}',
                  'a page this client cannot get past',
                ),
        );
      }
      if (r.status ~/ 100 == 3 && r.location != null) {
        final to = base.resolve(r.location!);
        // a check of the instance's own (nerdvpn.de's Gandalf), or moved
        return YtResult.failed(
          YtVerdict(
            YtCause.ipBlocked,
            to.host == base.host
                ? 'invidious:gate:${to.path}'
                : 'invidious:${r.status}:moved',
            'sent to $to',
          ),
        );
      }
      if (r.status >= 500 && _isInvidious(r.body)) {
        // Invidious' own error page: this video, on this instance, now
        // (tiekoetter 2026-10-12: "Can't load the video on this Invidious
        // instance", while other videos played) — not the instance
        return YtResult.failed(
          YtVerdict(
            YtCause.transient,
            'invidious:cannot-load',
            _textOf(r.body),
          ),
        );
      }
      return YtResult.failed(_verdictOf(r, 'watch'));
    }
    return const YtResult.failed(
      YtVerdict(
        YtCause.ipBlocked,
        'invidious:gate:loop',
        'still challenged after five steps',
      ),
    );
  }

  /// Invidious' own page: its stylesheets, and no CAPTCHA (the one on
  /// yt.chocolatemoo53.com is titled "Invidious").
  static bool _isInvidious(String html) =>
      html.contains('href="/css/pure-min.css') &&
      !html.toLowerCase().contains('captcha');

  /// The page's words, for a log line.
  static String _textOf(String html) {
    final text = html
        .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 120 ? text.substring(0, 120) : text;
  }

  static String _titleOf(String html) {
    final t = RegExp(r'<title>\s*([^<]{0,60})').firstMatch(html)?.group(1);
    return (t ?? 'untitled').trim();
  }

  /// One Anubis challenge: null when passed, why when not.
  Future<YtVerdict?> _passAnubis(
    String host,
    AnubisChallenge challenge,
    String page,
  ) async {
    if (!challenge.solvable) {
      return YtVerdict(
        YtCause.ipBlocked,
        'invidious:gate:anubis:${challenge.algorithm}',
        'an Anubis algorithm this client does not solve',
      );
    }
    final watch = Stopwatch()..start();
    final solution = await _solveAnubis(
      challenge.randomData,
      challenge.difficulty,
    );
    if (solution == null) {
      return YtVerdict(
        YtCause.ipBlocked,
        'invidious:gate:anubis-difficulty',
        'difficulty ${challenge.difficulty} is past the budget',
      );
    }
    final passed = await _get(
      Anubis.passUrl(
        host,
        challenge,
        solution: solution,
        redirect: page,
        elapsedMs: watch.elapsedMilliseconds + 1,
      ),
      referer: page,
    );
    return passed.status ~/ 100 == 3 ? null : _verdictOf(passed, 'anubis-pass');
  }

  /// The solvers off the UI isolate: the difficulty is the server's, and
  /// their budgets are seconds of hashing (a frozen page, an ANR on
  /// Android). Static, so the closure carries nothing but its arguments.
  static Future<({int nonce, String hash})?> _solveAnubis(
    String randomData,
    int difficulty,
  ) => Isolate.run(() => Anubis.solve(randomData, difficulty));

  static Future<String?> _solveGoAway(String challenge, String target) =>
      Isolate.run(() => GoAway.solve(challenge, target));

  /// A gate's page that names a script or a refresh this machine must not
  /// ask for (see [_isPublic]).
  static YtVerdict _foreignGate(Uri to) => YtVerdict(
    YtCause.transient,
    'invidious:gate:foreign',
    'the gate points at ${to.host}',
  );

  /// One go-away `js-pow-sha256`: null when passed, why when not.
  Future<YtVerdict?> _passGoAwayPow(
    String host,
    String script,
    String page,
  ) async {
    final base = Uri.parse(host);
    // named by the gate's page: the rule the page's manifest follows
    if (await _isPublic(base.resolve(script)) != true) {
      return _foreignGate(base.resolve(script));
    }
    final js = await _get(base.resolve(script), referer: page);
    final challengeId = js.status == HttpStatus.ok
        ? GoAway.powId(js.body)
        : null;
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
    final token = await _solveGoAway(data, target);
    if (token == null) {
      return YtVerdict(
        YtCause.ipBlocked,
        'invidious:gate:go-away-difficulty',
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
    return verified.status ~/ 100 == 3
        ? null
        : _verdictOf(verified, 'go-away-verify');
  }

  // ------------------------------------------------------------- transport

  Future<InvidiousAnswer> _get(
    Uri uri, {
    String method = 'GET',
    String? referer,
  }) async {
    final watch = Stopwatch()..start();
    final cookie = _cookieFor(uri.host);
    final r = await _fetch(
      uri,
      method: method,
      headers: {
        HttpHeaders.userAgentHeader: userAgent,
        HttpHeaders.acceptHeader: 'text/html,application/json,*/*',
        HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9',
        HttpHeaders.refererHeader: ?referer,
        HttpHeaders.cookieHeader: ?cookie,
      },
    );
    _keepCookies(uri.host, r.cookies);
    log?.call(
      r.status == 0
          ? '$method ${uri.host}${_short(uri.path)}: ${r.error}'
          : '$method ${uri.host}${_short(uri.path)} -> ${r.status} '
                '${r.body.length} B in ${watch.elapsedMilliseconds} ms',
    );
    return r;
  }

  String? _cookieFor(String host) {
    final pairs = [
      for (final MapEntry(key: (domain, name), :value) in _cookies.entries)
        if (host == domain || (!value.hostOnly && host.endsWith('.$domain')))
          '$name=${value.value}',
    ];
    return pairs.isEmpty ? null : pairs.join('; ');
  }

  void _keepCookies(String host, List<Cookie> cookies) {
    for (final c in cookies) {
      final set = c.domain;
      final domain = set == null || set.isEmpty
          ? host
          : (set.startsWith('.') ? set.substring(1) : set);
      // a host sets cookies for itself and its parents only — and not for a
      // bare suffix: `Domain=net` was replayed to every `*.net` instance,
      // companion and caption host, one instance tagging the viewer across
      // the others
      if (domain != host && !host.endsWith('.$domain')) continue;
      if (domain != host && !domain.contains('.')) continue;
      final key = (domain, c.name);
      if (c.value.isEmpty || c.maxAge == 0) {
        _cookies.remove(key);
      } else {
        _cookies[key] = (value: c.value, hostOnly: set == null || set.isEmpty);
      }
    }
  }

  static String _short(String path) =>
      path.length > 60 ? '${path.substring(0, 60)}…' : path;

  static YtVerdict _verdictOf(InvidiousAnswer r, String what) =>
      switch (r.status) {
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

/// The app's [InvidiousFetch]: a bare [HttpClient], nothing of bilibili's.
class IoInvidiousFetch {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  /// The most of a ranged answer that is read.
  static const _probeCap = 64 << 10;

  Future<InvidiousAnswer> call(
    Uri uri, {
    required String method,
    required Map<String, String> headers,
  }) async {
    try {
      final request = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (method == 'POST') request.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      // a probe asks for a few bytes ([_refusedHere]): a server that ignores
      // the range is not read to the end of a whole stream
      final String body;
      if (headers.containsKey(HttpHeaders.rangeHeader)) {
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          bytes.addAll(chunk);
          if (bytes.length >= _probeCap) break;
        }
        body = utf8.decode(bytes, allowMalformed: true);
      } else {
        body = await const Utf8Decoder(allowMalformed: true)
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 20));
      }
      return InvidiousAnswer(
        response.statusCode,
        body,
        location: response.headers.value(HttpHeaders.locationHeader),
        cookies: _cookiesOf(response.headers),
      );
    } catch (e) {
      return InvidiousAnswer(0, '', error: '$e');
    }
  }

  /// The cookies set, each on its own: `response.cookies` throws on one it
  /// cannot parse (`Expires=0`, a value with a space or comma), and that
  /// dropped the whole answer as a transport failure. Only the bad ones go.
  static List<Cookie> _cookiesOf(HttpHeaders headers) {
    final cookies = <Cookie>[];
    for (final value in headers[HttpHeaders.setCookieHeader] ?? const []) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } catch (_) {}
    }
    return cookies;
  }
}
