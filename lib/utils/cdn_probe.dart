/// LibrePili: how fast each CDN host actually delivers, for choosing one.
///
/// The host a stream plays from used to be whichever Bilibili listed first,
/// with nothing measured: on a network routed abroad that was Akamai's
/// overseas mirror, and the alternative a failover moved to (cosov)
/// delivered 1.8 Mbps for a 3.8 Mbps stream — slower than the video, so a
/// switch made playback worse.
library;

import 'dart:io' show HttpClient, HttpHeaders, HttpStatus;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';

abstract final class CdnProbe {
  /// Bytes per second [url] delivers over [length] bytes from [offset],
  /// asked as the player asks (its user agent and referer, no cookies).
  ///
  /// Counted from the first byte, not the request: this is compared with a
  /// bitrate, and a short probe timed from the request measured the TLS
  /// handshake — Akamai came out at 2.1 Mbps over 384 KB, and at 11 Mbps
  /// over 2 MB. [timeout] still covers the whole request.
  ///
  /// Null when it does not deliver: an error, an answer other than the
  /// range, or a connection closed short of it (a copy cut there). Running
  /// out of [timeout] is a slow host, not a broken one: what arrived counts,
  /// if anything did.
  static Future<double?> speed(
    String url, {
    int offset = 0,
    int length = 384 << 10,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = BrowserUa.pc;
    final clock = Stopwatch()..start();
    // from the first byte on (see above)
    final transfer = Stopwatch();
    var received = 0;
    var first = 0;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
        ..set(HttpHeaders.refererHeader, HttpString.baseUrl)
        ..set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + length - 1}');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final left = timeout - clock.elapsed;
      if (left <= Duration.zero) return null;
      try {
        await for (final chunk in response.timeout(left)) {
          received += chunk.length;
          if (!transfer.isRunning) {
            // the clock starts as the first chunk is in, so the rate is of
            // what came after it
            transfer.start();
            first = chunk.length;
          }
          if (received >= length) break;
          if (clock.elapsed >= timeout) break;
        }
      } on Exception {
        // out of time: a slow host, measured as far as it got
        return received > 0 ? _rate(received - first, transfer) : null;
      }
      // closed before the range was done: a cut copy, not a slow one
      if (received < length && clock.elapsed < timeout) return null;
      return _rate(received - first, transfer);
    } catch (_) {
      return received > 0 && clock.elapsed >= timeout
          ? _rate(received - first, transfer)
          : null;
    } finally {
      client.close(force: true);
    }
  }

  static double _rate(int bytes, Stopwatch clock) {
    final seconds = clock.elapsedMicroseconds / 1e6;
    return seconds <= 0 ? 0 : bytes / seconds;
  }

  /// The host to play from among [speeds] (bytes per second, null for one
  /// that did not deliver): the fastest — unless [current] is within
  /// [keepRatio] of it, since a switch is not free and a probe is noisy.
  /// Null when none delivered.
  static String? pick(
    Map<String, double?> speeds, {
    String? current,
    double keepRatio = 0.8,
  }) {
    String? best;
    var bestSpeed = 0.0;
    for (final MapEntry(key: host, value: speed) in speeds.entries) {
      if (speed != null && speed > bestSpeed) {
        best = host;
        bestSpeed = speed;
      }
    }
    if (best == null) return null;
    final now = current == null ? null : speeds[current];
    if (now != null && now >= bestSpeed * keepRatio) return current;
    return best;
  }

  /// Whether [bytesPerSecond] keeps up with a stream of [bitsPerSecond]
  /// with [margin] to spare.
  static bool keepsUp(
    double? bytesPerSecond,
    int? bitsPerSecond, {
    double margin = 1.2,
  }) {
    if (bytesPerSecond == null) return false;
    if (bitsPerSecond == null || bitsPerSecond <= 0) return true;
    return bytesPerSecond * 8 >= bitsPerSecond * margin;
  }
}
