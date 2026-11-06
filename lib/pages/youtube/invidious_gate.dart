/// LibrePili: an Invidious instance's gate got past in the app's own
/// browser (the web view the bilibili captcha dialogs use), never an
/// outside one (user 2026-11-06).
///
/// A gate that only a browser gets past — Gandalf on invidious.nerdvpn.de,
/// a CAPTCHA page on yt.chocolatemoo53.com — is opened at the video's
/// watch page. Without a window first: Gandalf's check runs by itself in a
/// browser and goes on to the watch page (seen in a real one, 2026-11-05).
/// In a dialog when that does not get through and the viewer asks: the
/// clicks a CAPTCHA wants are made there, in the app's window.
///
/// Once the page carries the player's data, what the instance knows the
/// browser by is taken over for the app's own requests (see
/// [InvidiousBrowserPass]): the cookies, the user agent, and the headers a
/// page request carries — both gates took their cookie only with those
/// (measured 2026-11-05).
library;

import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/app_proxy.dart';
import 'package:PiliPlus/main.dart' show webViewEnvironment;
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/youtube/invidious_source.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class InvidiousGate {
  /// How long a pass without a window is given: under the source's own
  /// limit ([YtInvidiousSource.passTimeout]), so the web view is let go here.
  static const quietFor = Duration(seconds: 30);

  /// [InvidiousGatePasser] for the app.
  static Future<InvidiousBrowserPass?> pass(
    Uri watch, {
    required bool interactive,
  }) async {
    // the web view cannot go through the 设置代理 proxy here: the instance
    // would see another address than the app's requests come from
    if (AppProxy.webViewGoesDirect) {
      EventLog.add('invidious', '${watch.host}: gate not opened, behind 设置代理');
      if (interactive) {
        SmartDialog.showToast(
          '已设置代理，但此时应用内网页无法经过代理，验证无法打开：请关闭代理，或（Windows）重启应用后再试',
        );
      }
      return null;
    }
    return interactive ? _inWindow(watch) : _withoutWindow(watch);
  }

  /// Whether the page is the watch page with the player's data: the gate is
  /// behind.
  static const _throughJs =
      'location.pathname==="/watch"&&!!document.getElementById("player_data")';

  /// What the browser sends with a page, read from the page itself.
  static const _identityJs = '''
JSON.stringify({ua:navigator.userAgent,
d:navigator.userAgentData?{b:navigator.userAgentData.brands,m:navigator.userAgentData.mobile,p:navigator.userAgentData.platform}:null})''';

  static Future<InvidiousBrowserPass?> _withoutWindow(Uri watch) async {
    final done = Completer<InvidiousBrowserPass?>();
    HeadlessInAppWebView? view;
    Timer? limit;
    void finish(InvidiousBrowserPass? pass) {
      if (done.isCompleted) return;
      limit?.cancel();
      done.complete(pass);
      // let go after this frame: not from inside its own callback
      Future(() => view?.dispose());
    }

    limit = Timer(quietFor, () => finish(null));
    view = HeadlessInAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialSettings: _settings,
      initialSize: const Size(1280, 800),
      initialUrlRequest: URLRequest(url: WebUri.uri(watch)),
      onLoadStop: (ctr, _) async {
        final pass = await _readIfThrough(ctr, watch);
        if (pass != null) finish(pass);
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame ?? true) {
          EventLog.add(
            'invidious',
            '${watch.host}: gate page not loaded: ${error.description}',
          );
          finish(null);
        }
      },
    );
    try {
      await view.run();
    } catch (e) {
      EventLog.add('invidious', '${watch.host}: in-app browser not started: $e');
      finish(null);
    }
    return done.future;
  }

  static Future<InvidiousBrowserPass?> _inWindow(Uri watch) =>
      showDialog<InvidiousBrowserPass>(
        context: Get.context!,
        builder: (context) => _GateDialog(watch),
      );

  static final _settings = InAppWebViewSettings(
    javaScriptEnabled: true,
    // its own user agent: the brands it sends must match what it says
    useHybridComposition: true,
    allowFileAccess: false,
    allowContentAccess: false,
    useOnDownloadStart: false,
    geolocationEnabled: false,
    saveFormData: false,
    mediaPlaybackRequiresUserGesture: true,
  );

  /// The pass, when [ctr] shows [watch]'s watch page with the player.
  static Future<InvidiousBrowserPass?> _readIfThrough(
    InAppWebViewController ctr,
    Uri watch,
  ) async {
    try {
      if (await ctr.evaluateJavascript(source: _throughJs) != true) return null;
      final identity = await ctr.evaluateJavascript(source: _identityJs);
      if (identity is! String) return null;
      final json = jsonDecode(identity) as Map<String, dynamic>;
      final ua = json['ua'];
      if (ua is! String || ua.isEmpty) return null;
      final cookies = await CookieManager.instance(
        webViewEnvironment: webViewEnvironment,
      ).getCookies(url: WebUri('${watch.scheme}://${watch.host}/'), webViewController: ctr);
      return InvidiousBrowserPass(
        userAgent: ua,
        headers: pageHeaders(json['d']),
        cookies: [
          for (final c in cookies)
            if (c.value?.toString() case final value? when value.isNotEmpty)
              (
                name: c.name,
                value: value,
                domain: c.domain,
                until: c.isSessionOnly == true ? null : expiry(c.expiresDate),
              ),
        ],
      );
    } catch (e) {
      EventLog.add('invidious', '${watch.host}: gate page not read: $e');
      return null;
    }
  }

  /// When a cookie the web view reports ends: milliseconds since the epoch
  /// as documented, seconds as WebView2 gives them (Gandalf's token read
  /// 1970-01-21 as milliseconds, and was dropped as run out, 2026-11-06).
  @visibleForTesting
  static DateTime? expiry(int? reported) => reported == null || reported <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          reported < 100000000000 ? reported * 1000 : reported,
        );

  /// The headers a Chromium browser sends with a page it navigates to, from
  /// its `navigator.userAgentData` ([data]: `{b: brands, m: mobile, p:
  /// platform}`, null where it has none).
  @visibleForTesting
  static Map<String, String> pageHeaders(Object? data) => {
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,image/apng,*/*;q=0.8',
    if (data case {'b': final List brands, 'm': final bool mobile, 'p': final String platform}) ...{
      'sec-ch-ua': [
        for (final b in brands)
          if (b case {'brand': final String brand, 'version': final String v})
            '"$brand";v="$v"',
      ].join(', '),
      'sec-ch-ua-mobile': mobile ? '?1' : '?0',
      'sec-ch-ua-platform': '"$platform"',
    },
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Upgrade-Insecure-Requests': '1',
  };
}

/// The gate in a window, for the viewer to get past; closes itself once the
/// watch page is reached.
class _GateDialog extends StatefulWidget {
  const _GateDialog(this.watch);

  final Uri watch;

  @override
  State<_GateDialog> createState() => _GateDialogState();
}

class _GateDialogState extends State<_GateDialog> {
  var _closed = false;

  void _close([InvidiousBrowserPass? pass]) {
    if (_closed || !mounted) return;
    _closed = true;
    Get.back(result: pass);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '验证 ${widget.watch.host}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _close,
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      content: SizedBox(
        width: 520,
        height: 640,
        child: InAppWebView(
          webViewEnvironment: webViewEnvironment,
          initialSettings: InvidiousGate._settings,
          initialUrlRequest: URLRequest(url: WebUri.uri(widget.watch)),
          onLoadStop: (ctr, _) async {
            final pass = await InvidiousGate._readIfThrough(ctr, widget.watch);
            if (pass != null) _close(pass);
          },
          onReceivedError: (_, request, error) {
            if (request.isForMainFrame ?? true) {
              EventLog.add(
                'invidious',
                '${widget.watch.host}: gate page not loaded: '
                    '${error.description}',
              );
              SmartDialog.showToast('验证页面打开失败');
              _close();
            }
          },
        ),
      ),
    );
  }
}
