import Cocoa
import FlutterMacOS
import macos_window_utils

/// Background test mode switch, same contract as the Dart side (lib/main.dart)
/// and windows/runner/win32_window.cpp: FUSHI_TEST_HIDDEN set to anything
/// non-empty. The pre-rename HIBIKI_TEST_HIDDEN (presence only) is still
/// honoured so older local runners keep working.
func fushiHiddenTestMode() -> Bool {
  let env = ProcessInfo.processInfo.environment
  if let value = env["FUSHI_TEST_HIDDEN"], !value.isEmpty { return true }
  return env["HIBIKI_TEST_HIDDEN"] != nil
}

class MainFlutterWindow: NSWindow {
  // Background test mode: when FUSHI_TEST_HIDDEN is set, the window is parked
  // far off-screen and never becomes key/main, and the app runs as an
  // .accessory (no Dock icon / menu bar, never auto-activated). This lets
  // automated integration tests drive the real macOS app — focus moves,
  // settings changes, WebView DOM probes — while the Flutter engine keeps
  // rendering (the window stays ordered-in, just off every screen) without it
  // appearing or stealing keyboard/foreground focus from whatever the user is
  // doing. Mirrors windows/runner/win32_window.cpp (FUSHI_TEST_HIDDEN).
  private var hiddenTestMode: Bool {
    return fushiHiddenTestMode()
  }

  /// Off-screen parking spot for hidden test mode (same value as the Windows
  /// runner's kOffscreenOrigin).
  private static let hiddenTestOrigin = NSPoint(x: -32000, y: -32000)

  // Hidden test mode owns the window position at the native layer. AppKit's
  // orderFront screen constraint, window state restoration and
  // window_manager's setBounds (Dart startup placement) all route through
  // setFrame and each pulls the parked window back onto a screen (BUG-3751,
  // measured on macOS 26). Keep whatever size they ask for, pin the origin.
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    guard hiddenTestMode else {
      super.setFrame(frameRect, display: flag)
      return
    }
    super.setFrame(
      NSRect(origin: MainFlutterWindow.hiddenTestOrigin, size: frameRect.size),
      display: flag)
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
    guard hiddenTestMode else {
      super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
      return
    }
    super.setFrame(
      NSRect(origin: MainFlutterWindow.hiddenTestOrigin, size: frameRect.size),
      display: displayFlag, animate: false)
  }

  override func setFrameOrigin(_ point: NSPoint) {
    super.setFrameOrigin(hiddenTestMode ? MainFlutterWindow.hiddenTestOrigin : point)
  }

  // AppKit also constrains the frame so part of the title bar stays on a
  // screen, outside the setFrame overrides above (measured: the parked window
  // ended up at a 261x110 sliver in the bottom-left corner). Hidden mode wants
  // it entirely off-screen, so skip the constraint.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    guard hiddenTestMode else {
      return super.constrainFrameRect(frameRect, to: screen)
    }
    return frameRect
  }

  func hideForStartupPresentation() {
    // MainMenu.xib has visibleAtLaunch="NO", so nothing else orders this window
    // in. Hidden test mode must still order it in (already parked off-screen
    // by awakeFromNib, never key/main, app is .accessory): a window that was
    // never ordered in leaves the Flutter view unattached and the engine never
    // starts (BUG-3751). showStartupWindow is a no-op in hidden mode, so this
    // is the only place that puts it on screen.
    if hiddenTestMode {
      orderFront(nil)
      return
    }
    // Keep the view attached to an ordered window so Flutter can rasterize
    // its first frame before Dart asks us to reveal it.
    animationBehavior = .none
    alphaValue = 0
    orderFront(nil)
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
      windowFrame.origin = MainFlutterWindow.hiddenTestOrigin
      // Don't pull the app to the foreground or show a Dock icon / menu bar.
      NSApp.setActivationPolicy(.accessory)
      // A test run must not restore (or persist) the previous run's window
      // state; restoration also moves the window (see setFrame above).
      isRestorable = false
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
