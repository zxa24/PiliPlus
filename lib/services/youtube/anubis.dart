/// LibrePili: the Anubis gate (github.com/TecharoHQ/anubis) in front of
/// `invidious.f5.si` and `invidious.tiekoetter.com`'s watch pages (v1.28,
/// measured 2026-10-12), ported from webread's solver.
///
/// The page carries `<script id="anubis_challenge">` —
/// `{rules: {algorithm, difficulty}, challenge: {id, randomData, …}}` — and
/// `anubis_base_prefix`. For the `fast` and `slow` algorithms the client
/// looks for the first decimal nonce whose `sha256(randomData + nonce)`
/// starts with `difficulty` zero hex digits, and sends it to
/// `{prefix}/.within.website/x/cmd/anubis/api/pass-challenge`, which answers
/// a 302 carrying the clearance cookie. Difficulty 4 on both: 6 000–123 000
/// hashes, tens of milliseconds.
///
/// Any other algorithm counts bits rather than digits and hashes something
/// else: not solvable here, by construction rather than by budget.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One Anubis challenge, as its page states it.
class AnubisChallenge {
  const AnubisChallenge({
    required this.id,
    required this.randomData,
    required this.algorithm,
    required this.difficulty,
    required this.basePrefix,
  });

  final String id;
  final String randomData;
  final String algorithm;
  final int difficulty;

  /// Where the gate's own paths live: '' for both instances. Only a plain
  /// path is taken — it comes from the page, and anything else could send
  /// the answer to another host.
  final String basePrefix;

  bool get solvable => algorithm == 'fast' || algorithm == 'slow';
}

abstract final class Anubis {
  /// The challenge on [html], or null when it is not an Anubis page.
  static AnubisChallenge? parse(String html) {
    if (!html.contains('anubis_challenge')) return null;
    final m = RegExp(
      r'id="anubis_challenge"[^>]*>(.{0,65536}?)</script>',
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;
    try {
      final json = jsonDecode(m.group(1)!) as Map;
      final challenge = json['challenge'] as Map;
      final rules = (json['rules'] as Map?) ?? const {};
      final data = challenge['randomData'];
      if (data is! String || data.isEmpty) return null;
      var prefix = '';
      final p = RegExp(
        r'id="anubis_base_prefix"[^>]*>(.{0,4096}?)</script>',
        dotAll: true,
      ).firstMatch(html);
      if (p != null) {
        final value = jsonDecode(p.group(1)!);
        if (value is String && _plainPath.hasMatch(value)) prefix = value;
      }
      return AnubisChallenge(
        id: (challenge['id'] ?? '').toString(),
        randomData: data,
        algorithm: (rules['algorithm'] ?? challenge['method'] ?? '').toString(),
        difficulty: switch (rules['difficulty']) {
          final int d => d,
          final String s => int.tryParse(s) ?? 0,
          _ => 0,
        },
        basePrefix: prefix,
      );
    } catch (_) {
      return null;
    }
  }

  /// `/a/b` segments only, none of them all dots (webread's rule).
  static final _plainPath = RegExp(r'^(/(?!\.+(?:/|$))[A-Za-z0-9._~-]+)*$');

  /// The first nonce, and its hash in hex, meeting [difficulty] leading zero
  /// hex digits — null past [maxHashes] (difficulty 6 would need ~17 M).
  static ({int nonce, String hash})? solve(
    String randomData,
    int difficulty, {
    int maxHashes = 4000000,
  }) {
    // a SHA-256 hash has 64 hex digits: a difficulty outside them is a
    // challenge that cannot be met (and would index past the hash)
    if (difficulty < 0 || difficulty > 64) return null;
    final zeroBytes = difficulty ~/ 2;
    final halfByte = difficulty.isOdd;
    for (var nonce = 0; nonce < maxHashes; nonce++) {
      final h = sha256.convert(utf8.encode('$randomData$nonce')).bytes;
      var ok = true;
      for (var i = 0; i < zeroBytes; i++) {
        if (h[i] != 0) {
          ok = false;
          break;
        }
      }
      if (!ok || (halfByte && h[zeroBytes] >> 4 != 0)) continue;
      return (
        nonce: nonce,
        hash: h.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      );
    }
    return null;
  }

  /// The pass-challenge request for a solved [challenge], from [host].
  static Uri passUrl(
    String host,
    AnubisChallenge challenge, {
    required ({int nonce, String hash}) solution,
    required String redirect,
    required int elapsedMs,
  }) => Uri.parse(
    '$host${challenge.basePrefix}/.within.website/x/cmd/anubis/api/pass-challenge',
  ).replace(
    queryParameters: {
      'id': challenge.id,
      'response': solution.hash,
      'nonce': '${solution.nonce}',
      'redir': redirect,
      'elapsedTime': '$elapsedMs',
    },
  );
}
