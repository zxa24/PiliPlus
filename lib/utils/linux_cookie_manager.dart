import 'dart:convert' show jsonEncode;
import 'dart:io' show Cookie, Platform;

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart' as dww;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

abstract final class LinuxCookieManager {
  static bool isBiliDomain(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'bilibili.com' || host.endsWith('.bilibili.com');
  }

  static List<Cookie> getCookies([Account? account]) {
    final targetAccount = account ?? Accounts.main;
    return targetAccount.cookieJar.toList();
  }

  static Future<void> deleteAllCookies() async {
    if (!Platform.isLinux) return;
    try {
      await dww.WebviewWindow.clearAll();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LinuxCookieManager: deleteAllCookies failed: $e');
      }
    }
  }

  /// [session]: no max-age, so the cookies do not outlive the WebKit
  /// session if the store is not cleared (used for account cookies)
  static String generateCookieInjectionJs([
    List<Cookie>? cookieList,
    bool session = false,
  ]) {
    final cookies = cookieList ?? getCookies();
    final maxAge = session ? '' : '; max-age=31536000';
    if (cookies.isEmpty) return '';

    final cookieMaps = cookies.map((c) {
      final rawDomain = c.domain ?? 'bilibili.com';
      final domain = rawDomain.startsWith('.') ? rawDomain : '.$rawDomain';
      return {
        'name': c.name,
        'value': c.value,
        'domain': domain,
        'path': c.path ?? '/',
        'secure': c.secure,
      };
    }).toList();

    final jsonStr = jsonEncode(cookieMaps);

    return '''
(function() {
  try {
    var cookies = $jsonStr;
    for (var i = 0; i < cookies.length; i++) {
      var c = cookies[i];
      var str = c.name + '=' + c.value + '; path=' + (c.path || '/') + '; domain=' + c.domain + '$maxAge; SameSite=Lax';
      if (c.secure) str += '; Secure';
      document.cookie = str;
    }
  } catch (e) {
    console.error('[LinuxWebview] Cookie injection error:', e);
  }
})();
''';
  }
}
