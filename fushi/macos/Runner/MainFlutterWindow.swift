import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  // Background test mode: when HIBIKI_TEST_HIDDEN is set, the window is parked
  // far off-screen and never becomes key/main, and the app runs as an
  // .accessory (no Dock icon / menu bar, never auto-activated). This lets
  // automated integration tests drive the real macOS app — focus moves,
  // settings changes, WebView DOM probes — while the Flutter engine keeps
  // rendering (the window stays ordered-in, just off every screen) without it
  // appearing or stealing keyboard/foreground focus from whatever the user is
  // doing. Mirrors windows/runner/win32_window.cpp (HIBIKI_TEST_HIDDEN).
  private var hiddenTestMode: Bool {
    return ProcessInfo.processInfo.environment["HIBIKI_TEST_HIDDEN"] != nil
  }

  override func awakeFromNib() {
    var windowFrame = self.frame
    // macos_ui needs the window's content view managed by macos_window_utils so
    // the transparent titlebar / full-size-content view / sidebar vibrancy work.
    // MacOSWindowUtilsViewController() creates its own internal
    // FlutterViewController; plugins must be registered against that one. This
    // is the package's documented MainFlutterWindow.swift setup and is
    // orthogonal to the test-hidden frame / activation-policy overrides below.
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController

    if hiddenTestMode {
      // Park far off every physical screen; keep the size so layout is
      // unchanged and the engine produces the same frames it normally would.
      windowFrame.origin = NSPoint(x: -32000, y: -32000)
      // Don't pull the app to the foreground or show a Dock icon / menu bar.
      NSApp.setActivationPolicy(.accessory)
    }
    self.setFrame(windowFrame, display: true)

    // Initialize the macos_window_utils plugin (native side of WindowManipulator).
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(
      registry: macOSWindowUtilsViewController.flutterViewController)

    super.awakeFromNib()
  }

  // In hidden test mode the window must never become key/main, so it can't take
  // keyboard or foreground focus from the user. Focus-driven tests inject
  // synthetic key events at the Flutter framework level, so they don't need the
  // OS window to be key.
  override var canBecomeKey: Bool {
    return hiddenTestMode ? false : super.canBecomeKey
  }

  override var canBecomeMain: Bool {
    return hiddenTestMode ? false : super.canBecomeMain
  }
}
