import Cocoa
import FlutterMacOS

/// Bridges macOS's "the app is about to quit" into Dart.
///
/// The app's own teardown — stop the core, put the system proxy back, remove
/// the pid file — hangs off `onWindowClose`, which is the only exit Windows
/// has. macOS has three more (⌘Q, the app menu's Quit, and Dock → Quit) and
/// all of them go straight to `NSApplication.terminate:` without ever closing
/// a window. Quitting that way left sing-box running and the machine still
/// pointed at it: a tunnel with no app on screen to explain it.
final class AppLifecycle {
  static let shared = AppLifecycle()

  private var channel: FlutterMethodChannel?
  private var asked = false
  private var replied = false

  func attach(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "app.veil/lifecycle", binaryMessenger: messenger)
  }

  func shouldTerminate() -> NSApplication.TerminateReply {
    // With no engine to ask — or asked once already — quitting must not stall.
    guard let channel = channel, !asked else { return .terminateNow }
    asked = true

    channel.invokeMethod("shutdown", arguments: nil) { [weak self] _ in
      self?.reply()
    }
    // Dart normally never answers: its shutdown ends in exit(0), which is the
    // intended path. This is the safety net for an engine that is wedged or
    // already gone — without it a failure here would make the app unquittable,
    // which is far worse than the leak being fixed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.reply()
    }
    return .terminateLater
  }

  private func reply() {
    guard !replied else { return }
    replied = true
    NSApp.reply(toApplicationShouldTerminate: true)
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return AppLifecycle.shared.shouldTerminate()
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
