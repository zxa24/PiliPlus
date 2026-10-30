import 'package:PiliPlus/http/app_proxy.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/main.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: a search's risk check passed with bilibili's own captcha
/// component, the one search.bilibili.com uses (`risk-captcha-sdk`): it
/// registers the voucher, shows whichever captcha the check asks for
/// (geetest v3 or v4, a word or image one), sends the answer and returns
/// the token the search is retried with (`gaia_vtoken`).
///
/// On 2026-10-30 the check handed out a geetest v4 captcha, which the
/// geetest dialog cannot show; and v4's answer goes to the encrypted
/// `gaia-vgate/v2/validate`, which only the component's own code writes
/// (read from search.bilibili.com's bundle that day). Its requests need to come from a bilibili.com page (they are
/// cross-origin with credentials), so a small page of the site is opened
/// and emptied first.
class GaiaWebviewDialog extends StatefulWidget {
  const GaiaWebviewDialog(this.vVoucher, {super.key});

  final String vVoucher;

  @override
  State<GaiaWebviewDialog> createState() => _GaiaWebviewDialogState();

  /// The token, or null when the captcha was closed or failed (said in a
  /// toast).
  static Future<String?> verify(String vVoucher) {
    // as for the geetest dialog: the 设置代理 setting holds here too
    if (AppProxy.webViewGoesDirect) {
      SmartDialog.showToast(
        '已设置代理，但此时应用内网页无法经过代理，验证码无法打开：请关闭代理，或（Windows）重启应用后再试',
      );
      return Future.value();
    }
    return showDialog<String>(
      context: Get.context!,
      builder: (context) => GaiaWebviewDialog(vVoucher),
    );
  }
}

class _GaiaWebviewDialogState extends State<GaiaWebviewDialog> {
  /// A small page of the site: the component's requests go out from its
  /// origin. Emptied before the component is loaded.
  static const _host = 'https://www.bilibili.com/robots.txt';
  static const _loader =
      'https://s1.hdslb.com/bfs/seed/jinkela/risk-captcha-sdk/CaptchaLoader.js';

  bool _started = false;

  static String _startJs(String vVoucher) =>
      '''
(()=>{
document.body.innerHTML='';
const R=(n,o)=>window.flutter_inappwebview.callHandler(n,o);
const s=document.createElement('script');
s.src='$_loader';
s.onload=()=>CaptchaLoader.load()
  .then(use=>{R('loaded');return use({riskParams:{v_voucher:${jsonString(vVoucher)}},fromSpmid:'333.337'})})
  .then(t=>R('token',t),e=>R('fail',String(e&&(e.tip||e.message)||e)));
s.onerror=()=>R('fail','captcha script not loaded');
document.head.appendChild(s);
})()''';

  /// [value] as a JavaScript string literal.
  static String jsonString(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  void _close([String? token]) {
    if (mounted) Get.back(result: token);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InAppWebView(
          webViewEnvironment: webViewEnvironment,
          initialSettings: InAppWebViewSettings(
            clearCache: true,
            javaScriptEnabled: true,
            forceDark: ForceDark.AUTO,
            useHybridComposition: true,
            algorithmicDarkeningAllowed: true,
            userAgent: BrowserUa.mob,
            incognito: true,
            allowFileAccess: false,
            allowsLinkPreview: false,
            allowContentAccess: false,
            useOnDownloadStart: false,
            geolocationEnabled: false,
            saveFormData: false,
            horizontalScrollBarEnabled: false,
            verticalScrollBarEnabled: false,
            overScrollMode: .NEVER,
          ),
          initialUrlRequest: URLRequest(url: WebUri(_host)),
          onWebViewCreated: (ctr) {
            ctr
              ..addJavaScriptHandler(
                handlerName: 'loaded',
                callback: (_) {
                  EventLog.add('captcha', 'risk sdk: loaded');
                  // what of the captcha is on the page, for the log
                  Future.delayed(const Duration(seconds: 3), () async {
                    if (!mounted) return;
                    try {
                      final r = await ctr.evaluateJavascript(
                        source: '"shown: "+[...document.body.querySelectorAll("*")].filter(e=>e.offsetWidth>0&&e.offsetHeight>0).length+" elements, "+innerWidth+"x"+innerHeight',
                      );
                      EventLog.add('captcha', 'risk sdk: $r');
                    } catch (_) {}
                  });
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'token',
                callback: (args) {
                  final token = args.firstOrNull;
                  EventLog.add(
                    'captcha',
                    'risk sdk: ${token is String ? 'passed' : 'no token: $args'}',
                  );
                  if (token is String && token.isNotEmpty) {
                    _close(token);
                  } else {
                    SmartDialog.showToast('验证失败，请稍后再试');
                    _close();
                  }
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'fail',
                callback: (args) {
                  EventLog.add('captcha', 'risk sdk: failed: $args');
                  if (!mounted) return;
                  SmartDialog.showToast('验证未完成：${args.firstOrNull ?? ''}');
                  _close();
                },
              );
          },
          onLoadStop: (ctr, url) {
            if (_started) return;
            _started = true;
            EventLog.add('captcha', 'risk sdk: page ${url?.host}');
            ctr.evaluateJavascript(source: _startJs(widget.vVoucher));
          },
          onReceivedError: (_, request, error) {
            EventLog.add(
              'captcha',
              'risk sdk: load failed: ${request.url} ${error.type} '
                  '${error.description}',
            );
            if (request.isForMainFrame ?? true) {
              SmartDialog.showToast('验证码页面打开失败');
              _close();
            }
          },
          onConsoleMessage: (_, message) {
            final text = message.message;
            EventLog.add(
              'captcha',
              'risk sdk console ${message.messageLevel}: '
                  '${text.length > 300 ? text.substring(0, 300) : text}',
            );
          },
        ),
        Positioned(
          left: 8,
          top: 8,
          child: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _close,
            tooltip: '关闭',
          ),
        ),
      ],
    );
  }
}
