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
/// [mpvFor]), the player's and the transcription extractor's; and the
/// in-app web pages (user 2026-10-20: those too, the captcha's included),
/// as each platform's WebView allows: Android through
/// [ProxyController], at start-up and on each change ([applyToWebViews]);
/// Windows through WebView2's arguments, read once when its environment is
/// created at start-up ([webView2ArgsFor]), so a change takes a restart;
/// Linux per window ([linuxWebview]). A page whose WebView cannot take the
/// proxy while it is set ([webViewGoesDirect]: iOS and macOS, an Android
/// WebView without PROXY_OVERRIDE, Windows after a change until the
/// restart) is opened in the browser instead, the captcha not at all;
/// never loaded directly.
library;

import 'dart:io';

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart'
    show ProxyConfiguration;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show ProxyController, ProxyRule, ProxySettings, WebViewFeature;

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

  /// The proxy the in-app web pages go through now: Android's override as
  /// last applied, Windows' WebView2 as created at start-up. Null is none.
  static String? _webViewProxy;

  /// Whether a page opened now would reach the network without the proxy
  /// that is set: such a page goes to the browser instead.
  static bool get webViewGoesDirect => webViewGoesDirectWith(
    hostPort,
    _webViewProxy,
    perWindow: Platform.isLinux,
  );

  /// [webViewGoesDirect] with the setting and the WebView's proxy given,
  /// for tests. [perWindow]: each window takes the setting as it opens
  /// (Linux).
  static bool webViewGoesDirectWith(
    String? hostPort,
    String? webViewProxy, {
    bool perWindow = false,
  }) {
    if (hostPort == null || perWindow) return false;
    return webViewProxy != hostPort;
  }

  /// WebView2's `additionalBrowserArguments` for the setting as it is at
  /// start-up (main.dart); null when it is off. The browser process reads
  /// them once, so a change takes a restart. The app's loopback servers stay
  /// direct (Chromium leaves loopback out of a proxy anyway).
  static String? webView2ArgsFor() {
    final args = webView2ArgsWith(hostPort);
    if (args != null) _webViewProxy = hostPort;
    return args;
  }

  /// [webView2ArgsFor] with the setting given, for tests. A value that would
  /// break the command line is no proxy.
  static String? webView2ArgsWith(String? hostPort) {
    if (hostPort == null || hostPort.contains(RegExp(r'[\s"]'))) return null;
    return '--proxy-server=http://$hostPort '
        '--proxy-bypass-list=localhost;127.0.0.1;[::1]';
  }

  /// The setting for a Linux WebKit window (desktop_webview_window), given
  /// when it is created; null for none. The plugin sets it on the shared
  /// WebKit context each time, so every window takes the setting as it is
  /// when it opens.
  static ProxyConfiguration? get linuxWebview {
    final a = address;
    if (a == null) return null;
    return ProxyConfiguration(host: a.host, port: a.port);
  }

  /// Android: the setting for every WebView of the app (ProxyController is
  /// process-wide), set at start-up and on each change; cleared when it is
  /// off. The WebView keeps localhost and the loopback addresses out of the
  /// proxy itself (its implicit rules, left on). A WebView without
  /// PROXY_OVERRIDE takes none, and its pages go to the browser. At
  /// [start] with the setting off there is nothing to clear (the override
  /// lives with the process), and the WebView is not loaded for nothing.
  static Future<void> applyToWebViews({bool start = false}) async {
    if (!Platform.isAndroid) return;
    final hp = hostPort;
    if (start && hp == null) return;
    try {
      if (!await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      )) {
        _webViewProxy = null;
        return;
      }
      final controller = ProxyController.instance();
      if (hp == null) {
        await controller.clearProxyOverride();
      } else {
        await controller.setProxyOverride(
          settings: ProxySettings(proxyRules: [ProxyRule(url: 'http://$hp')]),
        );
      }
      _webViewProxy = hp;
    } catch (e) {
      // unknown: the pages go to the browser while a proxy is set
      _webViewProxy = null;
      debugPrint('WebView proxy: $e');
    }
  }
}
