import Cocoa
import FlutterMacOS
import app_links

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// "Open with" (see CFBundleDocumentTypes in Info.plist): Finder sends the
  /// file as a `file:` url here. `FlutterAppDelegate` only offers these to
  /// plugins implementing `handleOpenURLs:`, and app_links implements none
  /// (it claims kAEGetURL for custom schemes instead), so they would be
  /// dropped. Feeding them into app_links' own stream is what the Dart side
  /// already expects: `PiliScheme.init` turns a `file:` link into a path and
  /// opens it with `LocalPlayer` (the same path Linux takes). A url received
  /// before the engine is up is replayed to the first subscriber.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter { $0.isFileURL }
    let others = urls.filter { !$0.isFileURL }
    if !others.isEmpty {
      super.application(application, open: others)
    }
    for url in files {
      AppLinks.shared.handleLink(link: url.absoluteString)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in NSApp.windows {
        if !window.isVisible {
          window.setIsVisible(true)
        }
        window.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    return true
  }
}
