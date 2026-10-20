/// The 设置代理 setting, for every connection the app opens (user
/// 2026-10-19: all of them, the player included).
///
/// One rule, read at each request so a change applies at once: the app's
/// own servers on the loopback (the parallel fetch, the Invidious relay, the
/// command-line reader) are reached directly; everything else goes through
/// the proxy while the setting is on and complete, and as the environment
/// says otherwise. The bilibili HTTP/2 pool takes the proxy when it is
/// built instead, and is built again on a change (Request.onProxyChanged).
///
/// Where it is applied: every `dart:io` [HttpClient] through the app's
/// [HttpOverrides] (main.dart); the bilibili clients that set their own
/// (http/init.dart, ParallelFetch.proxyFor); mpv per file (`http-proxy`,
/// [mpvFor]), the player's and the transcription extractor's.
library;

import 'dart:io';

import 'package:PiliPlus/utils/storage_pref.dart';

abstract final class AppProxy {
  /// `host:port` while the setting is on and both are filled in; null
  /// otherwise.
  static String? get hostPort {
    if (!Pref.enableSystemProxy) return null;
    return hostPortOf(Pref.systemProxyHost, Pref.systemProxyPort);
  }

  static String? hostPortOf(String host, String port) {
    host = host.trim();
    final p = int.tryParse(port.trim());
    if (host.isEmpty || p == null) return null;
    return '$host:$p';
  }

  /// The proxy's host and port, for a raw socket (the network check).
  static ({String host, int port})? get address {
    final hp = hostPort;
    if (hp == null) return null;
    final at = hp.lastIndexOf(':');
    return (host: hp.substring(0, at), port: int.parse(hp.substring(at + 1)));
  }

  /// This machine, by name or address.
  static bool isLoopback(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    var h = host;
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    return InternetAddress.tryParse(h)?.isLoopback ?? false;
  }

  /// For [HttpClient.findProxy].
  static String findProxy(Uri uri) => findProxyWith(uri, hostPort);

  /// [findProxy] with the setting given, for tests.
  static String findProxyWith(Uri uri, String? hostPort) {
    if (isLoopback(uri.host)) return 'DIRECT';
    if (hostPort != null) return 'PROXY $hostPort';
    return HttpClient.findProxyFromEnvironment(uri);
  }

  /// mpv's `http-proxy` for a file that reads [media] (a URL, or an EDL of
  /// several): empty — mpv's default, the environment's — when the setting
  /// is off, or when any of its URLs is the app's own loopback server,
  /// which a proxy elsewhere cannot reach. mpv has no list of hosts to
  /// leave out of its proxy (ffmpeg reads the `no_proxy` environment
  /// variable, which the app does not set), so the whole file goes one way.
  static String mpvFor(String media) => mpvWith(media, hostPort);

  /// [mpvFor] with the setting given, for tests.
  static String mpvWith(String media, String? hostPort) {
    if (hostPort == null) return '';
    for (final m in _urlHost.allMatches(media)) {
      if (isLoopback(m[1]!)) return '';
    }
    // mpv takes only an http:// proxy URL, and ignores anything else
    return 'http://$hostPort';
  }

  static final _urlHost = RegExp(
    r'https?://(\[[0-9a-fA-F:.]+\]|[^/:\s;%?#\]]+)',
  );
}
