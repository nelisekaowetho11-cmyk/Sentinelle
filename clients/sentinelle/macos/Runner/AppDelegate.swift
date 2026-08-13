import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  /// Clicking the Dock icon of an app with no window on screen.
  ///
  /// "Close to tray" hides the window rather than closing it, so the app can
  /// spend hours with a live tunnel and nothing visible. Without this, the Dock
  /// icon and a second launch from Spotlight both did nothing at all: AppKit
  /// only reopens a window it owns, and Flutter's is hidden rather than gone.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
