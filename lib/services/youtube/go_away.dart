/// LibrePili: the two challenges go-away (git.gammaspectra.live/git/go-away)
/// puts in front of `inv.nadeko.net/watch`, measured 2026-10-12.
///
/// 1. **`js-pow-sha256`** — the 418 page loads
///    `…/challenge/js-pow-sha256/script.mjs`, which names the challenge id;
///    a POST to `…/make-challenge` answers `{challenge, target, difficulty}`
///    (hex); the client looks for an 8-byte little-endian nonce whose
///    `sha256(challenge ‖ nonce)` is below `target`, and sends
///    `challenge ‖ nonce` as `__goaway_token` to `…/verify-challenge`. The
///    answer is a 307 with the clearance cookie on it. Difficulty 12 (bits):
///    3 398 iterations, a few milliseconds.
/// 2. **`js-refresh`** — the next 418 page sets `window.location` to a
///    `verify-challenge` URL that already carries its token; following it is
///    the whole challenge.
///
/// After both, `/watch` answers 200 and the cookie (a week, measured) serves
/// the next videos without a challenge.
///
/// Pure functions only: the requests are [YtInvidiousSource]'s.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract final class GoAway {
  /// Where go-away serves its challenges from.
  static const prefix = '/.well-known/.git.gammaspectra.live/git/go-away/cmd/go-away';

  static const powPath = '$prefix/challenge/js-pow-sha256';

  static final _escapedAmp = RegExp(r'\\u0026');

  /// Whether [html] is one of go-away's challenge pages.
  static bool isChallenge(String html) => html.contains('$prefix/');

  /// The challenge a page is loading (`js-pow-sha256`, `js-refresh`, …), for
  /// a report when it is one this does not know.
  static String? challengeName(String html) =>
      RegExp(r'Loading challenge <em>([^<]+)</em>').firstMatch(html)?.group(1);

  /// The `script.mjs` a `js-pow-sha256` page loads, or null.
  static String? powScript(String html) => RegExp(
    r'src="([^"]*/challenge/js-pow-sha256/script\.mjs[^"]*)"',
  ).firstMatch(html)?.group(1)?.replaceAll('&amp;', '&');

  /// The challenge id `script.mjs` sends back with the token, or null.
  static String? powId(String script) =>
      RegExp(r'__goaway_id:\s*"([0-9a-f]+)"').firstMatch(script)?.group(1);

  /// The URL a `js-refresh` page sends the browser to, or null.
  static String? refreshUrl(String html) {
    final raw = RegExp(
      r'window\.location\s*=\s*"([^"]+)"',
    ).firstMatch(html)?.group(1);
    if (raw == null || !raw.contains('verify-challenge')) return null;
    // the script's string escapes `&` as `\u0026`
    return raw.replaceAll(_escapedAmp, '&').replaceAll('&amp;', '&');
  }

  /// The challenge's token: `challenge ‖ nonce` in hex, for the first nonce
  /// whose hash is below [targetHex] — null when none is found in
  /// [maxIterations] (a difficulty far above the 12 seen).
  static String? solve(
    String challengeHex,
    String targetHex, {
    int maxIterations = 1 << 24,
  }) {
    final data = _hex(challengeHex);
    final target = _hex(targetHex);
    if (data == null || target == null || target.length != 32) return null;
    final buf = Uint8List(data.length + 8)..setAll(0, data);
    final nonce = ByteData.sublistView(buf, data.length);
    for (var n = 0; n < maxIterations; n++) {
      nonce.setUint64(0, n, Endian.little);
      if (_below(sha256.convert(buf).bytes, target)) return _toHex(buf);
    }
    return null;
  }

  /// The `verify-challenge` query for a solved `js-pow-sha256`.
  static Map<String, String> powVerifyQuery({
    required String token,
    required String id,
    required String redirect,
    required int elapsedMs,
  }) => {
    '__goaway_token': token,
    '__goaway_challenge': 'js-pow-sha256',
    '__goaway_redirect': redirect,
    '__goaway_id': id,
    '__goaway_elapsedTime': '$elapsedMs',
  };

  static bool _below(List<int> hash, Uint8List target) {
    for (var i = 0; i < hash.length; i++) {
      if (hash[i] < target[i]) return true;
      if (hash[i] > target[i]) return false;
    }
    return false;
  }

  static Uint8List? _hex(String s) {
    if (s.length.isOdd) return null;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
