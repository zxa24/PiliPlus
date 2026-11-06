/// LibrePili: a public Invidious instance that answers now, for opening a
/// video there in the browser when YouTube refuses this network (its bot
/// wall). Not the source the app plays from — that is [YtInvidiousSource],
/// in the router's fallback slot, which walks every https instance of the
/// registry; this only hands the viewer somewhere the video can be watched
/// in a browser.
///
/// Plain [HttpClient] requests: nothing of bilibili's (cookies, referer, user
/// agent) goes to either the list or the instances.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

abstract final class InvidiousInstances {
  /// The public list, healthiest first.
  static const listUrl =
      'https://api.invidious.io/instances.json?sort_by=health';

  /// How many of the healthiest are tried, all at once.
  static const tried = 6;

  static String? _picked;
  static DateTime? _pickedAt;

  /// The `https` instances in [json] (the list's shape: `[[name, info], …]`)
  /// not marked down by its monitor, in the list's order.
  @visibleForTesting
  static List<String> candidates(Object? json) {
    if (json is! List) return const [];
    final out = <String>[];
    for (final entry in json) {
      if (entry is! List || entry.length < 2) continue;
      final info = entry[1];
      if (info is! Map) continue;
      final uri = info['uri'];
      if (info['type'] != 'https' || uri is! String || !uri.startsWith('https://')) {
        continue;
      }
      final monitor = info['monitor'];
      if (monitor is Map && monitor['down'] == true) continue;
      out.add(uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri);
    }
    return out;
  }

  /// Every clearnet `https` instance in [json], in the list's order,
  /// whatever its monitor says: the monitor checks something other than the
  /// watch page the app plays from (2026-10-12: `invidious.f5.si` marked down
  /// while its watch page served; `inv.nadeko.net` 99.7 % up with its API
  /// off for everyone).
  ///
  /// Not the ones the registry has never reached (no `stats`, no `monitor`):
  /// `inv-ygg.nadeko.net` and `inv.nadeko.ygg`, Yggdrasil addresses listed
  /// as `https`, were all that was left once the clearnet ones were set
  /// aside, and a failed lookup of each every 12 s was the user's copy's
  /// whole "playback" for minutes (2026-11-05).
  ///
  /// [rules] says which version of these rules a list was made by.
  static List<String> allHttps(Object? json) {
    if (json is! List) return const [];
    final out = <String>[];
    for (final entry in json) {
      if (entry is! List || entry.length < 2) continue;
      final info = entry[1];
      if (info is! Map) continue;
      final uri = info['uri'];
      if (info['type'] != 'https' || uri is! String || !uri.startsWith('https://')) {
        continue;
      }
      if (info['stats'] == null && info['monitor'] == null) continue;
      if (Uri.tryParse(uri)?.host.endsWith('.ygg') ?? true) continue;
      out.add(uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri);
    }
    return out;
  }

  /// The version of [allHttps]'s rules, kept with a list made by them: one
  /// made by others is not taken back at the next launch, but asked for
  /// again. Raised with every rule that leaves out more. 2: never reached,
  /// and `.ygg` (2026-11-05) — a list kept from before still held
  /// `inv-ygg.nadeko.net` and `inv.nadeko.ygg` after the update, for up to
  /// six hours (the user's copy, 2026-11-06).
  static const rules = 2;

  /// The first of the healthiest instances that answers within [timeout],
  /// kept for half an hour; null when none does or the list is out of reach.
  static Future<String?> pick({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final now = DateTime.now();
    if (_picked != null &&
        _pickedAt != null &&
        now.difference(_pickedAt!) < const Duration(minutes: 30)) {
      return _picked;
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Mozilla/5.0';
    try {
      final list = await _get(client, listUrl, const Duration(seconds: 8));
      if (list == null) return null;
      final hosts = candidates(jsonDecode(list)).take(tried).toList();
      // all at once; the first in the list's order that answered wins
      final answered = await Future.wait([
        for (final host in hosts) _answers(client, host, timeout),
      ]);
      for (var i = 0; i < hosts.length; i++) {
        if (answered[i]) {
          _picked = hosts[i];
          _pickedAt = DateTime.now();
          return _picked;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The watch page for [videoId] on [instance].
  static String watchUrl(String instance, String videoId) =>
      '$instance/watch?v=${Uri.encodeQueryComponent(videoId)}';

  static Future<String?> _get(HttpClient client, String url, Duration limit) async {
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(limit);
      final response = await request.close().timeout(limit);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join().timeout(limit);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _answers(
    HttpClient client,
    String host,
    Duration limit,
  ) async {
    try {
      final request = await client.getUrl(Uri.parse('$host/')).timeout(limit);
      final response = await request.close().timeout(limit);
      await response.drain<void>().timeout(limit);
      return response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }
}
