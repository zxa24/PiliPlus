/// LibrePili: end the process without crashing on the way out.
///
/// On Windows, Dart's `exit()` runs the normal process teardown, and during
/// it flutter_inappwebview's DLL releases a WinRT Compositor it keeps in a
/// static (`InAppWebViewManager::compositor_`) from inside DllMain. By then
/// the thread that owned it is gone; CoreMessaging refuses the call and
/// fail-fasts with 0xe0464645 in dcomp.dll — a Windows Error Reporting crash
/// on every exit.
///
/// Upstream already avoids it on window close (`_onClose` in
/// pages/main/view.dart, citing flutter_inappwebview#2482 and #2512) by
/// calling TerminateProcess, which skips DLL teardown. The other exits did
/// not: the sleep timer's "退出应用", the storage-init failure path and the
/// self-test all went through `exit()`. Measured: a self-test started the way
/// Explorer starts the app crashed on exit 5 times out of 5.
///
/// Anything that must reach disk has to be written *before* calling this;
/// TerminateProcess does not flush or run finalizers, and neither does
/// `exit()`.
library;

import 'dart:io';

import 'package:win32/win32.dart' as kernel32;

Never appExit([int code = 0]) {
  if (Platform.isWindows) {
    kernel32.TerminateProcess(kernel32.GetCurrentProcess(), code);
  }
  exit(code);
}
