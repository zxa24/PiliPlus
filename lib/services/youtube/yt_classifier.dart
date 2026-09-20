/// The four-way classifier: given a response, which of (a) content gone,
/// (b) our IP is walled off, (c) transient, (d) our client is broken, is it?
///
/// Ported from `research/youtube-direct-spike.md` §6 and the spike's
/// `lib/yt_direct.dart`. Reason-string matching follows NewPipeExtractor
/// (GPL-3.0) `services/youtube/extractors/YoutubeStreamExtractor.java`.
///
/// Two invariants, both of which a naive port gets wrong:
///
///  1. **A status code is never trusted on its own.** InnerTube answers `200`
///     for "this video is private", "sign in to confirm you're not a bot" and
///     "your request shape is wrong" alike, so every response is classified
///     from its BODY as well.
///
///  2. **The Google-RPC `error` envelope is checked BEFORE the HTTP status.**
///     A retired `clientVersion` answers **404** with
///     `{"error":{"code":404,"message":"Requested entity was not found.",
///     "status":"NOT_FOUND"}}`. A status-first client reads that as "video
///     gone" and hands it to the fallback — i.e. hides its own breakage behind
///     a third party. Measured 2026-09-20 with `VISIONOS 0.01`.
library;

import 'package:PiliPlus/services/youtube/yt_transport.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

/// Signal tokens the router and the self-heal path match on by name.
abstract final class YtSignals {
  /// A bot wall that has NOT yet been retested with a fresh visitorData.
  /// [YtDirectSource] treats this as a suspicion, not a verdict.
  static const String botCheck = 'playability:bot-check';

  /// A bot wall that survived a freshly minted visitorData. Now it is evidence
  /// about our IP.
  static const String botCheckConfirmed = 'playability:bot-check-confirmed';
}

/// Classify a response at the TRANSPORT level, before any InnerTube semantics.
///
/// Returns `null` when the response is healthy enough to look inside — that is
/// the only "keep going" answer.
///
/// [expectJson] must be false for the non-InnerTube fetches: caption content is
/// `vtt` (plain text) or `ttml`/`srv3` (XML). Leaving it true reports a
/// perfectly good caption as `unparseable`, and an XML one as `html-where-json`
/// because it starts with `<`. Found by running the ported client against the
/// live service, which is exactly what that check is for.
YtVerdict? classifyYtTransport(YtResponse r, {bool expectJson = true}) {
  if (r.status == 0) {
    return YtVerdict(YtCause.transient, 'transport', r.transportError);
  }

  // ---- (d), highest confidence: the Google-RPC error envelope. ------------
  // InnerTube emits this ONLY for requests it could not interpret. Measured:
  //   {"error":{"code":400,…,"status":"FAILED_PRECONDITION"}}  (no context)
  //   {"error":{"code":400,…,"status":"INVALID_ARGUMENT"}}     (bad clientName)
  //   {"error":{"code":404,…,"status":"NOT_FOUND"}}            (retired version)
  // CHECKED BEFORE THE STATUS CODE — see the library doc.
  final err = r.obj['error'];
  if (err is Map) {
    return YtVerdict(
      YtCause.clientBroken,
      'rpc-error:${err['status']}',
      '${err['code']} ${err['message']}',
    );
  }

  if (r.status == 404) {
    // No envelope and nothing to parse: the endpoint path itself is wrong.
    // Measured: `youtubei/v1/playerz` answers 404 text/html with zero bytes.
    return YtVerdict(
      YtCause.clientBroken,
      'http-404',
      r.byteCount == 0 ? 'empty 404 (endpoint path wrong?)' : r.snippet,
    );
  }
  if (r.status == 429) {
    // Measured: Google's `/sorry/` interstitial, text/html, 1103 bytes, NO
    // Retry-After. Note this condemns ONE CALL, not the source — in the one
    // real 429 seen, the player endpoint kept answering 200 in the same second.
    // The router requires a second, independent (b) before a cooldown.
    return const YtVerdict(
      YtCause.ipBlocked,
      'http-429',
      'explicit rate limit',
    );
  }
  if (r.status == 403) {
    // Google's own 403s on youtubei are shape errors far more often than
    // blocks; a WAF/captcha 403 carries HTML. Split on the body, not the code.
    if (_looksLikeCaptcha(r)) {
      return YtVerdict(YtCause.ipBlocked, 'http-403+html', r.snippet);
    }
    return YtVerdict(YtCause.clientBroken, 'http-403+json', r.snippet);
  }
  if (r.status == 400) {
    return YtVerdict(YtCause.clientBroken, 'http-400', r.snippet);
  }
  if (r.status >= 500) {
    return YtVerdict(YtCause.transient, 'http-${r.status}', '5xx');
  }
  if (r.status >= 300 && r.status < 400) {
    final loc = r.headers['location'] ?? '';
    if (loc.contains('consent.')) {
      return const YtVerdict(
        YtCause.clientBroken,
        'redirect-consent',
        'missing/stale SOCS cookie',
      );
    }
    if (loc.contains('/sorry/')) {
      return YtVerdict(YtCause.ipBlocked, 'redirect-sorry', loc);
    }
    return YtVerdict(YtCause.clientBroken, 'redirect-${r.status}', loc);
  }
  if (r.byteCount == 0) {
    return const YtVerdict(
      YtCause.transient,
      'empty-200',
      '200 with zero bytes',
    );
  }
  // A 200 that is really the /sorry/ interstitial. Checked whatever the caller
  // expected: the one real rate limit measured arrived on a caption fetch.
  if (r.contentType.contains('html') || r.text.trimLeft().startsWith('<')) {
    if (_looksLikeCaptcha(r)) {
      return const YtVerdict(
        YtCause.ipBlocked,
        'html-captcha',
        'Google /sorry/ interstitial',
      );
    }
    if (expectJson) {
      return YtVerdict(YtCause.clientBroken, 'html-where-json', r.snippet);
    }
  }
  if (expectJson && r.json == null) {
    return YtVerdict(YtCause.clientBroken, 'unparseable', r.snippet);
  }
  return null;
}

bool _looksLikeCaptcha(YtResponse r) {
  final t = r.text;
  return t.contains('/sorry/') ||
      t.contains('unusual traffic') ||
      t.contains('detected unusual') ||
      t.contains('g-recaptcha') ||
      t.contains('captcha');
}

/// Classify a `player` response BODY. [r] must already have passed
/// [classifyYtTransport] with a `null` result.
///
/// This is where (a) and (b) are told apart, and it is the part a
/// status-code-only client gets wrong: every case below arrives as HTTP 200.
YtVerdict classifyYtPlayer(YtResponse r) {
  final root = r.obj;
  if (root.isEmpty) {
    return const YtVerdict(YtCause.clientBroken, 'not-an-object', '');
  }

  final ps = (root['playabilityStatus'] as Map?)?.cast<String, dynamic>() ?? {};
  final status = (ps['status'] ?? '').toString();
  final reason = (ps['reason'] ?? '').toString();
  final subreason = _errorScreenText(ps);
  final messages = (ps['messages'] as List?)?.join(' ') ?? '';
  final all = '$reason $subreason $messages';
  final lower = all.toLowerCase();

  // Measured 2026-09-20. Two responses that both say "unavailable":
  //   dead id AAAAAAAAAAA  -> status=ERROR,      videoDetails ABSENT
  //   healthy video on WEB -> status=UNPLAYABLE, videoDetails PRESENT (+title)
  // Whether the server still described the video to us separates "the video is
  // gone" from "we are not allowed to play it".
  final hasDetails = root['videoDetails'] != null;

  // ---- (b) first: an IP signal can wear a content-shaped status. ----------
  //
  // THE TRAP. YouTube's AGE gate reads "Sign in to confirm your age"; the bot
  // wall reads "Sign in to confirm that you're not a bot" — the same five
  // opening words. PipePipeExtractor raises AntiBotException on any body
  // containing "Sign in to confirm"
  // (.../extractors/YoutubeStreamExtractor.java:2428,2505), which classifies
  // EVERY age-restricted video as an IP block and would fall back to a third
  // party on all of them. Measured: 3/3 age-restricted videos hit that bug.
  //
  // NewPipe's narrower test — reason.contains("a bot") — is the correct one.
  // We use it AND require the absence of "your age", so a future wording that
  // mentions both cannot be read as a block.
  if (lower.contains('a bot') && !lower.contains('your age')) {
    return YtVerdict(
      YtCause.ipBlocked,
      YtSignals.botCheck,
      '$status: ${reason.isEmpty ? subreason : reason}',
    );
  }
  if (lower.contains('unusual traffic') ||
      lower.contains('too many requests')) {
    return YtVerdict(
      YtCause.ipBlocked,
      'playability:throttle',
      '$status: $reason',
    );
  }

  // ---- (a) the video itself. ---------------------------------------------
  if (status.isNotEmpty && status.toLowerCase() != 'ok') {
    final s = status.toLowerCase();
    if (s == 'login_required') {
      // NewPipe HEAD's age-gate branch only matches "inappropriate for some
      // users" (YoutubeStreamExtractor.java:843). Measured 2026-09-20: three
      // age-restricted videos all answered "Sign in to confirm your age",
      // which that test MISSES — NewPipe reports them as a generic
      // ContentNotAvailableException. Match both strings.
      if (lower.contains('inappropriate for some users') ||
          lower.contains('confirm your age') ||
          ps['desktopLegacyAgeGateReason'] != null) {
        return YtVerdict(
          YtCause.contentUnavailable,
          'playability:age-gate',
          reason,
        );
      }
      if (lower.contains('private')) {
        return YtVerdict(
          YtCause.contentUnavailable,
          'playability:private',
          reason,
        );
      }
      // login_required with no recognised reason is ambiguous: EITHER an age
      // gate whose wording changed OR a soft bot wall. Treat it as (a). (b)
      // must be proven, never assumed — otherwise a broken client hides behind
      // the fallback forever.
      return YtVerdict(
        YtCause.contentUnavailable,
        'playability:login_required',
        reason.isEmpty ? '(no reason)' : reason,
      );
    }
    if (s == 'unplayable' || s == 'error' || s == 'content_check_required') {
      for (final e in _reasonSignals.entries) {
        if (all.contains(e.key)) {
          return YtVerdict(
            YtCause.contentUnavailable,
            'playability:${e.value}',
            reason,
          );
        }
      }
      // Nothing specific matched. If the server nevertheless handed us the
      // video's own metadata, "unavailable" is a statement about US.
      return YtVerdict(
        YtCause.contentUnavailable,
        hasDetails ? 'playability:$s-generic' : 'playability:$s',
        reason.isEmpty ? '(no reason)' : reason,
        hasDetails,
      );
    }
    return YtVerdict(
      YtCause.contentUnavailable,
      'playability:$s',
      reason,
      hasDetails,
    );
  }

  // ---- status == OK. The response must now carry what we asked for. -------
  final sd = (root['streamingData'] as Map?)?.cast<String, dynamic>();
  final vd = root['videoDetails'];

  if (vd == null) {
    // No videoDetails on an OK playability: this is not the document we think
    // it is. That is (d), not (b).
    return const YtVerdict(
      YtCause.clientBroken,
      'ok-but-no-videoDetails',
      'shape changed',
    );
  }
  if (sd == null) {
    // OK + videoDetails + no streamingData is the SABR-only / attestation
    // shape. The video is fine; our identity no longer earns URL formats.
    return const YtVerdict(
      YtCause.clientBroken,
      'ok-but-no-streamingData',
      'SABR-only / client no longer served URL formats',
    );
  }
  final adaptive = (sd['adaptiveFormats'] as List?) ?? const [];
  final muxed = (sd['formats'] as List?) ?? const [];
  if (adaptive.isEmpty && muxed.isEmpty) {
    return const YtVerdict(
      YtCause.clientBroken,
      'streamingData-empty',
      'no formats at all',
    );
  }
  // Measured on the ANDROID identity: a full `adaptiveFormats` array in which
  // not one entry carries a `url` or a `signatureCipher` — just
  // itag/mimeType/contentLength next to a `serverAbrStreamingUrl`. A client
  // that only asks "are there formats?" calls this a success and then has
  // nothing to play.
  //
  // The test is on the ADAPTIVE array specifically, not on adaptive+muxed
  // pooled. Measured 2026-09-20 while porting: that same ANDROID response
  // still carries ONE muxed format (itag 18, 360p avc1+mp4a) with a plain
  // url. Pooling the two arrays — which is what the spike's classifier did —
  // lets a single 360p leftover mask the fact that the entire adaptive
  // pipeline has gone URL-less, and this app plays adaptive pairs. So: if
  // there are adaptive formats and none of them is addressable, that is (d),
  // whatever the muxed array says.
  bool addressable(Map f) =>
      f['url'] != null || f['signatureCipher'] != null || f['cipher'] != null;

  final adaptiveMaps = adaptive.whereType<Map>();
  if (adaptiveMaps.isNotEmpty && !adaptiveMaps.any(addressable)) {
    return YtVerdict(
      YtCause.clientBroken,
      'sabr-only',
      '${adaptiveMaps.length} adaptive formats, none with url or '
          'signatureCipher'
          '${muxed.isEmpty ? '' : ' (${muxed.length} muxed format(s) remain)'}',
    );
  }
  // Nothing addressable anywhere: the same failure without an adaptive array.
  final allMaps = <Object?>[...adaptive, ...muxed].whereType<Map>();
  if (!allMaps.any(addressable)) {
    return YtVerdict(
      YtCause.clientBroken,
      'sabr-only',
      '${allMaps.length} formats, none with url or signatureCipher',
    );
  }
  return YtVerdict.ok;
}

/// Reason substrings that name a specific, real content state.
///
/// From NewPipeExtractor `YoutubeStreamExtractor.java:827-882`. Note that plain
/// "unavailable" is deliberately NOT here: it is the generic bucket, and a
/// stale client identity returns it for healthy videos.
const Map<String, String> _reasonSignals = {
  'Music Premium': 'music-premium',
  'payment': 'paid',
  'members': 'members-only',
  'country': 'geo-blocked',
  'closed': 'account-terminated',
  'terminated': 'account-terminated',
  'removed': 'removed',
  // A real, temporary content state — not a client problem, so it must not be
  // flagged suspect.
  'processing this video': 'processing',
};

/// Flatten the human-readable text out of `playabilityStatus.errorScreen`,
/// where the interesting second half of a reason usually lives.
String _errorScreenText(Map<String, dynamic> ps) {
  final buf = StringBuffer();
  void walk(Object? o, int depth) {
    if (depth > 8) return;
    if (o is Map) {
      for (final e in o.entries) {
        if (e.key == 'simpleText' && e.value is String) {
          buf.write('${e.value} ');
        } else if (e.key == 'runs' && e.value is List) {
          for (final run in e.value as List) {
            if (run is Map && run['text'] is String) {
              buf.write('${run['text']} ');
            }
          }
        } else {
          walk(e.value, depth + 1);
        }
      }
    } else if (o is List) {
      for (final x in o) {
        walk(x, depth + 1);
      }
    }
  }

  walk(ps['errorScreen'], 0);
  return buf.toString().trim();
}
