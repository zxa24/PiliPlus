import 'dart:convert' show base64, jsonDecode, jsonEncode, utf8;
import 'dart:io' show Platform;

import 'package:PiliPlus/http/app_proxy.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/main.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class GeetestWebviewDialog extends StatefulWidget {
  const GeetestWebviewDialog(this.gt, this.challenge, {super.key});

  final String gt;
  final String challenge;

  @override
  State<GeetestWebviewDialog> createState() => _GeetestWebviewDialogState();

  static Future<Map<String, dynamic>?> geetest(String gt, String challenge) {
    // the 设置代理 setting holds for the captcha too (user 2026-10-20); it
    // cannot go to the browser, which would not hand the result back
    if (AppProxy.webViewGoesDirect) {
      SmartDialog.showToast(
        '已设置代理，但此时应用内网页无法经过代理，验证码无法打开：请关闭代理，或（Windows）重启应用后再试',
      );
      return Future.value();
    }
    return showDialog<Map<String, dynamic>>(
      context: Get.context!,
      builder: (context) => GeetestWebviewDialog(gt, challenge),
    );
  }
}

class _GeetestWebviewDialogState extends State<GeetestWebviewDialog> {
  static const _geetestJsUri =
      'https://static.geetest.com/static/js/fullpage.0.0.0.js';

  late final Future<LoadingState<String>> _future;
  Webview? _linuxWebview;
  late bool _linuxWebviewLoading = true;

  static String _showJs(String response) =>
      't=Geetest($response).onSuccess(()=>R("success",t.getValidate())).onError(o=>R("error",o)).onClose(o=>R("close",o));t.onReady(()=>{R("ready");t.verify()})';

  /// What of the captcha is on the page, for the log: a dialog that came up
  /// empty said nothing of why (its errors went to debugPrint only)
  static const _probeJs =
      '(()=>{const v=[...document.querySelectorAll("[class*=geetest_]")].filter(e=>e.offsetWidth>0&&e.offsetHeight>0);return "geetest boxes shown: "+v.length+", page "+innerWidth+"x"+innerHeight+", body "+document.body.scrollWidth+"x"+document.body.scrollHeight})()';

  @override
  void initState() {
    super.initState();
    _future = _getConfig(widget.gt, widget.challenge);
    if (Platform.isLinux) {
      _initLinuxWebview();
    } else {
      // closed with the reason as soon as the config fails, not left blank
      // until (or after) the page loads
      _future.then((config) {
        if (config is Error && mounted) {
          EventLog.add('captcha', 'not shown: ${config.errMsg}');
          config.toast();
          Get.back();
        }
      });
    }
  }

  static Future<LoadingState<String>> _getConfig(
    String gt,
    String challenge,
  ) async {
    final res = await Request().get<String>(
      'https://api.geetest.com/gettype.php',
      queryParameters: {'gt': gt},
      options: Options(
        responseType: ResponseType.plain,
        extra: {'account': const NoAccount()},
      ),
    );
    if (res.data case final String data) {
      // a JSONP answer in parentheses; an error comes as bare JSON
      final body = data.startsWith('(') && data.endsWith(')')
          ? data.substring1
          : data;
      final Object? config;
      try {
        config = jsonDecode(body);
      } catch (e) {
        return Error('验证码配置无法读取：$e');
      }
      if (config is Map<String, dynamic>) {
        if (config['status'] == 'success') {
          return Success(
            jsonEncode(
              config['data'] as Map<String, dynamic>..addAll({
                "gt": gt,
                "challenge": challenge,
                "offline": false,
                "new_captcha": true,
                "product": "bind",
                "width": "100%",
                "https": true,
                "protocol": "https://",
              }),
            ),
          );
        }
        EventLog.add('captcha', 'gettype: $body');
        // error_34 "captcha not found": the id is geetest v4's (a search's
        // risk check sent one on 2026-10-30; v4's gcaptcha4 answered it),
        // which this dialog cannot show. It used to hang here, blank
        if (config['error_code'] == 'error_34') {
          return const Error('B站这次要求的验证码类型暂不支持，请稍后再试');
        }
        return Error('验证码加载失败：${config['user_error'] ?? config['error']}');
      }
      return Error('验证码加载失败：$body');
    }
    return Error(switch (res.data) {
      {'message': final Object message} => '验证码加载失败：$message',
      _ => '验证码加载失败',
    });
  }

  Future<void> _initLinuxWebview() async {
    final config = await _future;

    if (!mounted) {
      return;
    }

    if (config is Error) {
      config.toast();
      Get.back();
      return;
    }

    final webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 300,
        windowHeight: 400,
        title: "验证码",
        proxy: AppProxy.linuxWebview,
      ),
    );

    _linuxWebview = webview;

    if (!mounted) {
      _closeLinuxWebview();
      return;
    }

    webview.addOnWebMessageReceivedCallback((msg) {
      final msgStr = msg.toString();
      if (msgStr.startsWith("success:")) {
        final dataStr = msgStr.substring("success:".length);
        try {
          final data = jsonDecode(dataStr);
          Get.back(result: data);
        } catch (e) {
          debugPrint('geetest decode error: $e');
        }
      } else if (msgStr.startsWith("error:")) {
        debugPrint('geetest error: $msgStr');
      } else if (msgStr.startsWith('close:')) {
        Get.back();
      }
    });

    webview.onClose.whenComplete(() {
      if (mounted) {
        Get.back();
      }
    });

    final html =
        '''
<!DOCTYPE html><html><head></head><body>
<script src="$_geetestJsUri"></script>
<script>
  R=(n,o)=>webkit.messageHandlers.msgToNative.postMessage(n+':'+JSON.stringify(o))
  ${_showJs(config.data)}
</script>
</body></html>
''';

    webview.launch(
      'data:text/html;base64,${base64.encode(utf8.encode(html))}',
    );

    if (mounted) {
      setState(() {
        _linuxWebviewLoading = false;
      });
    }
  }

  void _closeLinuxWebview() {
    _linuxWebview?.close();
    _linuxWebview = null;
  }

  @override
  void dispose() {
    _closeLinuxWebview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isLinux) {
      return AlertDialog(
        title: const Text('验证码'),
        content: SizedBox(
          width: 300,
          height: 400,
          child: Center(
            child: _linuxWebviewLoading
                ? const CircularProgressIndicator()
                : const Text('请在弹出的新窗口中完成验证'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
        ],
      );
    }

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
            useShouldOverrideUrlLoading: true,
            userAgent: BrowserUa.mob,
            // this runs during login: https images/media are still loaded
            // over http, but http scripts/xhr are not
            mixedContentMode: .MIXED_CONTENT_COMPATIBILITY_MODE,

            incognito: true,
            allowFileAccess: false,
            allowsLinkPreview: false,
            allowContentAccess: false,
            useOnDownloadStart: false,
            geolocationEnabled: false,
            thirdPartyCookiesEnabled: false,
            enterpriseAuthenticationAppLinkPolicyEnabled: false,
            saveFormData: false,
            safeBrowsingEnabled: false,
            isFraudulentWebsiteWarningEnabled: false,
            domStorageEnabled: false,
            databaseEnabled: false,
            cacheEnabled: false,
            cacheMode: .LOAD_NO_CACHE,

            horizontalScrollBarEnabled: false,
            verticalScrollBarEnabled: false,
            overScrollMode: .NEVER,

            pageZoom: Platform.isIOS ? 3 : 1,
          ),
          initialData: InAppWebViewInitialData(
            data:
                '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width"></head><body><script src="$_geetestJsUri"></script><script>R=flutter_inappwebview.callHandler</script></body></html>',
          ),
          onWebViewCreated: (ctr) {
            ctr
              ..addJavaScriptHandler(
                handlerName: 'success',
                callback: (args) {
                  if (args.isNotEmpty) {
                    if (args[0] case Map<String, dynamic> data) {
                      Get.back(result: data);
                      return;
                    }
                  }
                  debugPrint('geetest invalid result: $args');
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'error',
                callback: (args) {
                  // the captcha cannot go on (an expired challenge, its
                  // scripts not loading): said, and closed, not left blank
                  EventLog.add('captcha', 'geetest error: $args');
                  if (!mounted) return;
                  SmartDialog.showToast('验证码出错，请稍后再试');
                  Get.back();
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'ready',
                callback: (_) {
                  EventLog.add('captcha', 'geetest ready: shown');
                  Future.delayed(const Duration(seconds: 2), () async {
                    if (!mounted) return;
                    try {
                      final r = await ctr.evaluateJavascript(source: _probeJs);
                      EventLog.add('captcha', '$r');
                    } catch (e) {
                      EventLog.add('captcha', 'probe failed: $e');
                    }
                  });
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'close',
                callback: (args) => Get.back(),
              );
          },
          onLoadStop: (ctr, _) async {
            final config = await _future;
            if (!mounted) return;
            // a failed config has closed the dialog already (initState)
            if (config case Success(:final response)) {
              final loaded = await ctr.evaluateJavascript(
                source: 'typeof Geetest',
              );
              EventLog.add('captcha', 'page loaded: Geetest is $loaded');
              ctr.evaluateJavascript(source: _showJs(response));
            }
          },
          onReceivedError: (_, request, error) => EventLog.add(
            'captcha',
            'load failed: ${request.url} ${error.type} ${error.description}',
          ),
          onReceivedHttpError: (_, request, response) => EventLog.add(
            'captcha',
            'http ${response.statusCode}: ${request.url}',
          ),
          onConsoleMessage: (_, message) {
            final text = message.message;
            EventLog.add(
              'captcha',
              'console ${message.messageLevel}: '
                  '${text.length > 300 ? text.substring(0, 300) : text}',
            );
          },
        ),
        Positioned(
          left: 8,
          top: 8,
          child: IconButton(
            icon: const Icon(Icons.close),
            onPressed: Get.back,
            tooltip: '关闭',
          ),
        ),
      ],
    );
  }
}
