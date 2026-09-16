import Cocoa
import FlutterMacOS
import WebKit

// macOS app-external global lookup overlay — the macOS counterpart of
// windows/runner/global_lookup_window.cpp + FlutterWindow::
// RegisterGlobalLookupChannel().
//
// Same design as Windows (docs/specs/2026-06-25-global-lookup-webview-overlay-
// design.md): NO second Flutter engine. The main Dart engine performs the
// lookup, builds the self-contained render script and pushes it here; this
// file only hosts a bare WKWebView inside a non-activating NSPanel that renders
// the SAME popup assets (assets/popup/global_lookup_host.html + popup.html),
// and answers the reverse calls (image:// + dictmedia:// bytes, JS bridge
// messages, dismissal). The MethodChannel contract is byte-for-byte the one in
// lib/src/lookup/overlay_window_channel.dart; the JS entry points
// (window.__globalLookupHost.*, window.__fushiBridgeResolve) are the ones the
// Windows runner calls, so the host/popup JS runs unchanged.
//
// Coordinate contract: Dart speaks PHYSICAL px with a TOP-LEFT origin (the
// Win32 convention). AppKit speaks points with a BOTTOM-LEFT origin. Every
// boundary crossing goes through `topLeftPoints` / `appKitRect` below, using
// the ANCHOR screen's backingScaleFactor as the dpr (reported back to Dart as
// `monitorDpr`, mirroring BUG-859).
//
// Three "never disturb the foreground app" guarantees (design §5), mapped:
//   WS_EX_NOACTIVATE            -> NSPanel .nonactivatingPanel + canBecomeKey=false
//   HWND_TOPMOST                -> level .popUpMenu + canJoinAllSpaces
//   click-outside / foreground  -> NSEvent global+local mouse monitors +
//   hooks (armed only while shown)  NSWorkspace.didActivateApplication
//
// WebKit note (memory: hidden windows freeze rAF): the host measures itself
// with requestAnimationFrame, which WebKit suspends while the window is not on
// any screen. So the off-screen measurement of the Windows design is replaced
// by an ON-screen, fully transparent (webView.alphaValue = 0), mouse-ignoring
// parking at the anchor; reveal() just flips alpha/mouse back on.

private let kGlobalLookupChannelName = "app.fushi.reader/global_lookup"
private let kPopupAssetScheme = "fushi-popup"
private let kPopupAssetHost = "assets"
private let kPopupHostDocument = "global_lookup_host.html"
private let kScriptMessageName = "fushiOverlay"

/// Route identity bound to one lookup render (mirrors GlobalLookupWindow::
/// RouteContext). Stamped on every reverse call so a late callback from an
/// older lookup can never take ownership away from the newer render.
struct GlobalLookupRouteContext {
  var source: String = "desktop"
  var routeEpoch: Int64 = 0
  var lookupEpoch: Int64 = 0

  var envelope: [String: Any] {
    return [
      "source": source,
      "routeEpoch": NSNumber(value: routeEpoch),
      "lookupEpoch": NSNumber(value: lookupEpoch),
    ]
  }
}

/// Best-effort native diagnostic logger — appends to the SAME file the Dart
/// side uses (glog -> <systemTemp>/hibiki_glookup.log; Dart's Directory.
/// systemTemp is $TMPDIR = NSTemporaryDirectory()) so both halves correlate.
func globalLookupNativeLog(_ message: String) {
  let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("hibiki_glookup.log")
  let formatter = ISO8601DateFormatter()
  let line = "\(formatter.string(from: Date()))  [native-mac] \(message)\n"
  guard let data = line.data(using: .utf8) else { return }
  if let handle = FileHandle(forWritingAtPath: path) {
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
  } else {
    FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
  }
}

// MARK: - Panel

/// Borderless, non-activating, never-key panel: the overlay must never take
/// keyboard focus away from the app the user is reading in (design §5
/// guarantee 3). Mouse (click / scroll) still reaches the WKWebView because
/// AppKit routes mouse events to the window under the cursor regardless of
/// key status, and the web view accepts first mouse.
final class GlobalLookupOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

/// WKWebView that accepts the first click without the window being key, so
/// a card link / button works on the very first click like on Windows.
final class GlobalLookupWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(target: WKScriptMessageHandler) { self.target = target }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

// MARK: - URL scheme handlers

/// Serves the popup assets folder (flutter_assets/assets/popup) at
/// fushi-popup://assets/<file> — the WebKit stand-in for WebView2's
/// SetVirtualHostNameToFolderMapping("hibiki.popup"). A custom scheme (not
/// file://) so the host document and its popup.html iframes share ONE origin
/// (the host scripts the iframes' chrome.webview bridge) without any
/// file-access preference.
final class GlobalLookupAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  var assetsDir: String = ""

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let root = URL(fileURLWithPath: assetsDir, isDirectory: true).standardizedFileURL
    let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
    let file = root.appendingPathComponent(relative).standardizedFileURL
    // Never serve outside the assets folder (the URL is page-controlled).
    guard file.path.hasPrefix(root.path),
          let data = FileManager.default.contents(atPath: file.path)
    else {
      urlSchemeTask.didReceive(
        HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
      urlSchemeTask.didFinish()
      return
    }
    let headers = [
      "Content-Type": GlobalLookupAssetSchemeHandler.contentType(forExtension: file.pathExtension),
      "Content-Length": String(data.count),
      "Access-Control-Allow-Origin": "*",
    ]
    urlSchemeTask.didReceive(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  static func contentType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    case "mp3": return "audio/mpeg"
    case "ogg", "oga": return "audio/ogg"
    case "wav": return "audio/wav"
    default: return "application/octet-stream"
    }
  }
}

/// image:// (gaiji / <img>) and dictmedia:// (dictionary <link> stylesheets +
/// their fonts) — routed to the main Dart engine over the channel's reverse
/// `getMedia` call, exactly like the Windows WebResourceRequested handler.
/// Content-Type mirrors global_lookup_window.cpp MediaContentTypeHeader.
final class GlobalLookupMediaSchemeHandler: NSObject, WKURLSchemeHandler {
  typealias Resolver = (_ url: String, _ respond: @escaping (Data?) -> Void) -> Void
  var resolver: Resolver?
  private var live = Set<ObjectIdentifier>()

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, let resolver = resolver else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let id = ObjectIdentifier(urlSchemeTask)
    live.insert(id)
    let contentType = GlobalLookupMediaSchemeHandler.contentType(for: url)
    resolver(url.absoluteString) { [weak self] data in
      guard let self = self, self.live.contains(id) else { return }
      self.live.remove(id)
      let bytes = data ?? Data()
      let status = bytes.isEmpty ? 404 : 200
      let headers = [
        "Content-Type": contentType,
        "Content-Length": String(bytes.count),
        "Access-Control-Allow-Origin": "*",
      ]
      urlSchemeTask.didReceive(
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
      if !bytes.isEmpty {
        urlSchemeTask.didReceive(bytes)
      }
      urlSchemeTask.didFinish()
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    live.remove(ObjectIdentifier(urlSchemeTask))
  }

  static func contentType(for url: URL) -> String {
    if url.scheme?.lowercased() == "dictmedia" {
      return "text/css"
    }
    let ext = (url.path as NSString).pathExtension
    switch ext.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    default: return "application/octet-stream"
    }
  }
}

// MARK: - Overlay controller

final class GlobalLookupOverlayController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private let channel: FlutterMethodChannel
  private let mainWindow: () -> NSWindow?
  private let assetHandler = GlobalLookupAssetSchemeHandler()
  private let mediaHandler = GlobalLookupMediaSchemeHandler()

  private var panel: GlobalLookupOverlayPanel?
  private var webView: GlobalLookupWebView?
  private var assetsDir: String = ""
  private var webViewReady = false
  private var recovering = false
  private var pendingScript: String?

  private var route = GlobalLookupRouteContext()
  private var routeBound = false

  // Anchor for the next reveal: PHYSICAL px in the top-left screen domain, in
  // the anchor screen's scale (see file header).
  private var pendingX: CGFloat = 0
  private var pendingY: CGFloat = 0
  private var anchorScale: CGFloat = 1
  private var anchorScreen: NSScreen?

  private var visible = false
  private var revealed = false
  private var measuring = false
  private var blockCapture = false
  private var latestGeometryEpoch: Int64 = 0

  private var captureSuppressed = false
  private var captureGeneration: Int64 = 0

  private var globalClickMonitor: Any?
  private var localClickMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var mouseTriggerMonitor: Any?
  private var mouseTriggerButton: Int = 0

  private var resizeMonitor: Any?
  private var resizeStartFrame = NSRect.zero
  private var resizeStartMouse = NSPoint.zero

  /// Test hooks (debugEvaluateJs / debugSnapshot) are registered only under
  /// the same env gate the Mac input hook uses (FUSHI_TEST_INPUT), so a
  /// production build exposes no script-evaluation surface.
  private let testHooksEnabled: Bool =
    ProcessInfo.processInfo.environment["FUSHI_TEST_INPUT"] != nil

  init(binaryMessenger: FlutterBinaryMessenger, mainWindow: @escaping () -> NSWindow?) {
    self.mainWindow = mainWindow
    channel = FlutterMethodChannel(name: kGlobalLookupChannelName, binaryMessenger: binaryMessenger)
    super.init()
    mediaHandler.resolver = { [weak self] url, respond in
      guard let self = self else {
        respond(nil)
        return
      }
      self.channel.invokeMethod("getMedia", arguments: ["url": url]) { reply in
        if let typed = reply as? FlutterStandardTypedData {
          respond(typed.data)
        } else {
          respond(nil)
        }
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "overlay_unavailable", message: "overlay released", details: nil))
        return
      }
      self.handle(call, result: result)
    }
  }

  // MARK: Channel dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    // The in-game (galCard) off-screen card window is a Windows-only galgame
    // surface (native/galgame_hook is Windows-only by CLAUDE.md rule).
    if (args["target"] as? String) == "galCard" {
      result(FlutterError(
        code: "gal_card_unavailable",
        message: "in-game lookup card window is not available on macOS",
        details: nil))
      return
    }
    bindRouteContext(args)

    switch call.method {
    case "prepare":
      assetsDir = args["assetsDir"] as? String ?? ""
      assetHandler.assetsDir = assetsDir
      result(nil)
    case "prewarmWebView":
      prewarm(width: intArg(args, "width", 420), height: intArg(args, "height", 600))
      result(nil)
    case "isWebViewReady":
      result(webViewReady)
    case "showAt":
      result(showAt(args))
    case "render":
      render(args["json"] as? String ?? "")
      result(nil)
    case "gamepadAction":
      dispatchGamepadAction(args["action"] as? String ?? "", dy: doubleArg(args, "dy", 0))
      result(nil)
    case "resize":
      resizeTo(width: intArg(args, "width", 0), height: intArg(args, "height", 0))
      result(nil)
    case "resolveBridge":
      resolveBridge(id: int64Arg(args, "id", 0), jsValue: args["value"] as? String ?? "null")
      result(nil)
    case "reveal":
      reveal(width: intArg(args, "width", 0), height: intArg(args, "height", 0))
      result(nil)
    case "revealStack":
      revealStack(
        dx: intArg(args, "dx", 0), dy: intArg(args, "dy", 0),
        width: intArg(args, "width", 0), height: intArg(args, "height", 0),
        bboxLeft: doubleArg(args, "left", 0), bboxTop: doubleArg(args, "top", 0),
        geometryEpoch: int64Arg(args, "geometryEpoch", 0))
      result(nil)
    case "hide":
      hide(notify: (args["notify"] as? Bool) ?? true)
      result(nil)
    case "isShowing":
      result(isShowing)
    case "suspendForCapture":
      result(suspendForCapture(int64Arg(args, "captureGeneration", 0)))
    case "restoreAfterCapture":
      result(restoreAfterCapture(int64Arg(args, "captureGeneration", 0)))
    case "setBlockCapture":
      blockCapture = (args["block"] as? Bool) ?? false
      applyBlockCapture()
      result(nil)
    case "setOutsideClickOwner":
      // attached galgame glyph surface only (Windows); accepted as a no-op.
      result(nil)
    case "setGlobalMouseTrigger":
      result(setGlobalMouseTrigger(intArg(args, "button", 0)))
    case "debugEvaluateJs" where testHooksEnabled:
      debugEvaluate(args["script"] as? String ?? "", result: result)
    case "debugSnapshot" where testHooksEnabled:
      debugSnapshot(path: args["path"] as? String ?? "", result: result)
    case "debugWindowState" where testHooksEnabled:
      result(debugWindowState())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func bindRouteContext(_ args: [String: Any]) {
    var next = GlobalLookupRouteContext()
    next.source = (args["source"] as? String) == "galCard" ? "galCard" : "desktop"
    next.routeEpoch = int64Arg(args, "routeEpoch", 0)
    next.lookupEpoch = int64Arg(args, "lookupEpoch", 0)
    route = next
    routeBound = true
  }

  private func intArg(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int {
    return (args[key] as? NSNumber)?.intValue ?? fallback
  }

  private func int64Arg(_ args: [String: Any], _ key: String, _ fallback: Int64) -> Int64 {
    return (args[key] as? NSNumber)?.int64Value ?? fallback
  }

  private func doubleArg(_ args: [String: Any], _ key: String, _ fallback: Double) -> Double {
    return (args[key] as? NSNumber)?.doubleValue ?? fallback
  }

  // MARK: Coordinates

  /// Height of the primary screen in points: the top-left domain flips y
  /// against it (AppKit's global origin is the primary screen's bottom-left).
  private var primaryScreenHeight: CGFloat {
    return NSScreen.screens.first?.frame.maxY ?? 0
  }

  private func topLeftPoint(fromAppKit p: NSPoint) -> NSPoint {
    return NSPoint(x: p.x, y: primaryScreenHeight - p.y)
  }

  /// AppKit frame for a window whose TOP-LEFT corner sits at `topLeft`
  /// (points, top-left domain) with the given size.
  private func appKitRect(topLeft: NSPoint, size: NSSize) -> NSRect {
    return NSRect(
      x: topLeft.x, y: primaryScreenHeight - topLeft.y - size.height,
      width: size.width, height: size.height)
  }

  private func screen(containingTopLeft p: NSPoint) -> NSScreen {
    let appKit = NSPoint(x: p.x, y: primaryScreenHeight - p.y)
    return NSScreen.screens.first { NSMouseInRect(appKit, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens[0]
  }

  /// Work area (menu bar + Dock excluded) of `screen` in the top-left domain.
  private func workArea(of screen: NSScreen) -> NSRect {
    let vf = screen.visibleFrame
    return NSRect(
      x: vf.minX, y: primaryScreenHeight - vf.maxY, width: vf.width, height: vf.height)
  }

  /// Clamps a top-left rect (points) into the anchor screen's work area the
  /// way Reveal/RevealStack/ResizeTo do on Windows: shrink to fit, then nudge
  /// back on-screen if the bottom/right would overflow.
  private func clampToWorkArea(topLeft: NSPoint, size: NSSize) -> (NSPoint, NSSize) {
    guard let screen = anchorScreen ?? NSScreen.main else { return (topLeft, size) }
    let work = workArea(of: screen)
    var w = min(size.width, work.width)
    var h = min(size.height, work.height)
    var x = topLeft.x
    var y = topLeft.y
    if x + w > work.maxX { x = work.maxX - w }
    if y + h > work.maxY { y = work.maxY - h }
    if x < work.minX { x = work.minX }
    if y < work.minY { y = work.minY }
    w = max(w, 1)
    h = max(h, 1)
    return (NSPoint(x: x, y: y), NSSize(width: w, height: h))
  }

  // MARK: Window + WebView lifecycle

  @discardableResult
  private func ensurePanel(width: Int, height: Int) -> Bool {
    if panel != nil {
      return true
    }
    let scale = anchorScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let size = NSSize(width: max(CGFloat(width) / scale, 1), height: max(CGFloat(height) / scale, 1))
    let panel = GlobalLookupOverlayPanel(
      contentRect: NSRect(origin: NSPoint(x: -32000, y: -32000), size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = true
    panel.title = "Fushi Lookup"

    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(assetHandler, forURLScheme: kPopupAssetScheme)
    config.setURLSchemeHandler(mediaHandler, forURLScheme: "image")
    config.setURLSchemeHandler(mediaHandler, forURLScheme: "dictmedia")
    // BUG-1091 parity: the card auto-plays word audio from its own <audio>.
    config.mediaTypesRequiringUserActionForPlayback = []
    let ucc = config.userContentController
    ucc.add(WeakScriptMessageProxy(target: self), name: kScriptMessageName)
    // 1) chrome.webview shim: popup_bridge_adapter.js and global_lookup_host.js
    //    post through window.chrome.webview.postMessage (WebView2 API). Map it
    //    onto the WKScriptMessageHandler in EVERY frame (the host wraps the
    //    iframe-level postMessage, so each frame needs its own object).
    ucc.addUserScript(WKUserScript(
      source: GlobalLookupOverlayController.chromeWebViewShim,
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
    // 2) bridge adapter, 3) nested-stack host — same order and same
    //    all-frames injection as AddScriptToExecuteOnDocumentCreated (host.js
    //    bails on sub-frames itself via window.top !== window.self).
    for name in ["popup_bridge_adapter.js", "global_lookup_host.js"] {
      let path = (assetsDir as NSString).appendingPathComponent(name)
      if let source = try? String(contentsOfFile: path, encoding: .utf8), !source.isEmpty {
        ucc.addUserScript(WKUserScript(
          source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
      } else {
        reportError("overlay script missing: \(path)")
      }
    }

    let webView = GlobalLookupWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    webView.autoresizingMask = [.width, .height]
    webView.navigationDelegate = self
    // Transparent page background so the card's rounded shell + the gaps
    // between cascade cards show the desktop (the per-pixel transparency the
    // Windows composition mode provides).
    webView.setValue(false, forKey: "drawsBackground")
    if #available(macOS 12.0, *) {
      webView.underPageBackgroundColor = .clear
    }
    webView.alphaValue = 0
    panel.contentView = webView

    self.panel = panel
    self.webView = webView
    applyBlockCapture()
    loadHostDocument()
    return true
  }

  private func loadHostDocument() {
    guard let webView = webView else { return }
    webViewReady = false
    guard let url = URL(string: "\(kPopupAssetScheme)://\(kPopupAssetHost)/\(kPopupHostDocument)") else {
      return
    }
    webView.load(URLRequest(url: url))
  }

  private func prewarm(width: Int, height: Int) {
    // TODO-1079 parity: build the panel + WKWebView now so the first hotkey
    // lookup hits a WARM surface. Parked far off-screen and ordered OUT (no
    // measurement happens until showAt moves it on-screen).
    guard panel == nil else { return }
    ensurePanel(width: width, height: height)
    globalLookupNativeLog("prewarm: panel created \(width)x\(height)")
  }

  private func applyBlockCapture() {
    // NSWindowSharingNone: visible to the user, excluded from screenshots /
    // screen recording / screen sharing — the macOS counterpart of
    // SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE).
    panel?.sharingType = blockCapture ? .none : .readOnly
  }

  // MARK: showAt / reveal / resize / hide

  private func showAt(_ args: [String: Any]) -> [String: Any] {
    let widthPx = intArg(args, "width", 420)
    let heightPx = intArg(args, "height", 600)
    let atCursor = (args["atCursor"] as? Bool) ?? false

    var anchorTL: NSPoint
    let screen: NSScreen
    if atCursor {
      // NSEvent.mouseLocation is points, bottom-left. Same +8px cursor offset
      // as the Windows GetCursorPos path.
      let loc = NSEvent.mouseLocation
      screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        ?? NSScreen.main ?? NSScreen.screens[0]
      let scale = screen.backingScaleFactor
      anchorTL = topLeftPoint(fromAppKit: loc)
      anchorTL.x += 8 / scale
      anchorTL.y += 8 / scale
    } else {
      // Dart converted the anchor with the MAIN window's dpr; undo with the
      // same scale, then re-anchor on the screen that point lands on.
      let guess = mainWindow()?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
      anchorTL = NSPoint(x: CGFloat(intArg(args, "x", 0)) / guess, y: CGFloat(intArg(args, "y", 0)) / guess)
      screen = self.screen(containingTopLeft: anchorTL)
    }
    anchorScreen = screen
    anchorScale = screen.backingScaleFactor
    pendingX = anchorTL.x * anchorScale
    pendingY = anchorTL.y * anchorScale
    revealed = false

    // Cursor-screen work area in PHYSICAL px + the window-local origin's
    // offset inside it (TODO-893 / BUG-859 reply contract).
    let work = workArea(of: screen)
    var workW = work.width * anchorScale
    var workH = work.height * anchorScale
    var cursorWorkX = (anchorTL.x - work.minX) * anchorScale
    var cursorWorkY = (anchorTL.y - work.minY) * anchorScale
    let capW = intArg(args, "capW", 0)
    let capH = intArg(args, "capH", 0)
    if capW > 0 && capH > 0 {
      workW = CGFloat(capW)
      workH = CGFloat(capH)
      cursorWorkX = CGFloat(intArg(args, "capX", 0))
      cursorWorkY = CGFloat(intArg(args, "capY", 0))
    }

    let ok = ensurePanel(width: widthPx, height: heightPx)
    if ok, let panel = panel, let webView = webView {
      // On-screen, invisible, mouse-transparent measurement parking (see the
      // file header for why not off-screen).
      let size = NSSize(width: CGFloat(widthPx) / anchorScale, height: CGFloat(heightPx) / anchorScale)
      webView.alphaValue = 0
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.setFrame(appKitRect(topLeft: anchorTL, size: size), display: true)
      panel.orderFrontRegardless()
      measuring = true
      visible = false
    }
    globalLookupNativeLog(
      "showAt: ok=\(ok) atCursor=\(atCursor) pending=(\(Int(pendingX)),\(Int(pendingY))) "
        + "scale=\(anchorScale) work=\(Int(workW))x\(Int(workH))")
    return [
      "ok": ok,
      "workW": Double(workW),
      "workH": Double(workH),
      "cursorWorkX": Double(cursorWorkX),
      "cursorWorkY": Double(cursorWorkY),
      "monitorDpr": Double(anchorScale),
    ]
  }

  /// Makes the parked panel visible + interactive and arms the dismissal
  /// monitors (the Windows Reveal/RevealStack tail).
  private func present() {
    guard let panel = panel, let webView = webView else { return }
    webView.alphaValue = 1
    panel.ignoresMouseEvents = false
    panel.hasShadow = true
    panel.orderFrontRegardless()
    panel.invalidateShadow()
    measuring = false
    visible = true
    revealed = true
    armDismissMonitors()
  }

  private func reveal(width: Int, height: Int) {
    guard !captureSuppressed, let panel = panel else { return }
    var size = panel.frame.size
    if width > 0 { size.width = CGFloat(width) / anchorScale }
    if height > 0 { size.height = CGFloat(height) / anchorScale }
    let topLeft = NSPoint(x: pendingX / anchorScale, y: pendingY / anchorScale)
    let (clampedTL, clampedSize) = clampToWorkArea(topLeft: topLeft, size: size)
    panel.setFrame(appKitRect(topLeft: clampedTL, size: clampedSize), display: true)
    present()
    // BUG-2123 parity: this legacy path places the window at the cursor at the
    // single-card size; undo the host's pre-shift so the root card is not
    // pushed outside the window.
    evaluate(
      "(function(){var h=window.__globalLookupHost;"
        + "if(h&&typeof h.resetLayerOffsetForLegacyReveal==='function'){"
        + "h.resetLayerOffsetForLegacyReveal();}})();")
  }

  private func beginGeometryRequest(_ epoch: Int64) -> Bool {
    if epoch < 0 { return false }
    if epoch == 0 { return latestGeometryEpoch == 0 }
    if epoch < latestGeometryEpoch { return false }
    if epoch > latestGeometryEpoch { latestGeometryEpoch = epoch }
    return true
  }

  private func revealStack(
    dx: Int, dy: Int, width: Int, height: Int, bboxLeft: Double, bboxTop: Double,
    geometryEpoch: Int64
  ) {
    guard !captureSuppressed, beginGeometryRequest(geometryEpoch), let panel = panel,
          width > 0, height > 0
    else { return }
    let intended = NSPoint(
      x: (pendingX + CGFloat(dx)) / anchorScale, y: (pendingY + CGFloat(dy)) / anchorScale)
    let size = NSSize(width: CGFloat(width) / anchorScale, height: CGFloat(height) / anchorScale)
    let (clampedTL, clampedSize) = clampToWorkArea(topLeft: intended, size: size)
    panel.setFrame(appKitRect(topLeft: clampedTL, size: clampedSize), display: true)
    present()
    // TODO-1231 P2 / BUG-859 parity: content shift AFTER the window move, with
    // any work-area clamp delta folded in. Points == CSS px here (the WKWebView
    // rasterizes at the anchor screen's scale, which is the dpr the host uses).
    let clampDx = Double(clampedTL.x - intended.x)
    let clampDy = Double(clampedTL.y - intended.y)
    evaluate(
      "window.__globalLookupHost && window.__globalLookupHost.commitLayerShift("
        + "\(bboxLeft + clampDx), \(bboxTop + clampDy), \(geometryEpoch));")
  }

  private func resizeTo(width: Int, height: Int) {
    guard let panel = panel, width > 0, height > 0 else { return }
    let topLeft = topLeftPoint(fromAppKit: NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
    let size = NSSize(width: CGFloat(width) / anchorScale, height: CGFloat(height) / anchorScale)
    let (clampedTL, clampedSize) = clampToWorkArea(topLeft: topLeft, size: size)
    panel.setFrame(appKitRect(topLeft: clampedTL, size: clampedSize), display: true)
    panel.invalidateShadow()
  }

  private var isShowing: Bool {
    return visible && (panel?.isVisible ?? false)
  }

  /// The single dismissal funnel (TODO-1233): every genuine dismissal
  /// (click-outside / app switch / JS dismiss) and the programmatic
  /// between-lookups reset (notify=false) go through here.
  private func hide(notify: Bool) {
    let wasShowing = visible
    let hiddenRoute = route
    captureSuppressed = false
    captureGeneration = 0
    visible = false
    revealed = false
    measuring = false
    disarmDismissMonitors()
    endResizeTracking(report: false)
    if let panel = panel {
      panel.orderOut(nil)
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      webView?.alphaValue = 0
    }
    if notify && wasShowing {
      channel.invokeMethod("overlayHidden", arguments: hiddenRoute.envelope)
    }
  }

  private func suspendForCapture(_ generation: Int64) -> Bool {
    guard generation > 0, routeBound, !captureSuppressed, visible else { return false }
    captureSuppressed = true
    captureGeneration = generation
    panel?.orderOut(nil)
    return true
  }

  private func restoreAfterCapture(_ generation: Int64) -> Bool {
    guard generation > 0, captureSuppressed, captureGeneration == generation else { return false }
    captureSuppressed = false
    captureGeneration = 0
    if visible {
      panel?.orderFrontRegardless()
    }
    return true
  }

  // MARK: Dismissal monitors (armed only while the card is on-screen)

  private func armDismissMonitors() {
    if globalClickMonitor == nil {
      // Clicks in OTHER apps never reach our own event queue: a global monitor
      // fires only for them, so any hit is by definition outside the card.
      globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] _ in
        self?.hide(notify: true)
      }
    }
    if localClickMonitor == nil {
      // Clicks in our own process: inside the panel -> forward to the host,
      // which owns the per-shell geometry and decides card-vs-gap (TODO-867
      // C4/E2); any other own window (the main Flutter window) -> dismiss.
      localClickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self = self, self.visible, let panel = self.panel else { return event }
        if event.window === panel {
          let p = event.locationInWindow
          let localX = Double(p.x)
          let localY = Double(panel.frame.height - p.y)
          self.evaluate(
            "window.__globalLookupHost && window.__globalLookupHost.handleGlobalClick("
              + "\(localX), \(localY));")
        } else {
          self.hide(notify: true)
        }
        return event
      }
    }
    if activationObserver == nil {
      // The user switched to another app (Cmd-Tab etc.) — the Windows
      // EVENT_SYSTEM_FOREGROUND hook; own-process activation is skipped.
      activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
          return
        }
        self?.hide(notify: true)
      }
    }
  }

  private func disarmDismissMonitors() {
    if let m = globalClickMonitor {
      NSEvent.removeMonitor(m)
      globalClickMonitor = nil
    }
    if let m = localClickMonitor {
      NSEvent.removeMonitor(m)
      localClickMonitor = nil
    }
    if let o = activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(o)
      activationObserver = nil
    }
  }

  // MARK: Global mouse side-button trigger (TODO-1066)

  /// button = DOM MouseEvent.button (3 = back, 4 = forward; same numbering as
  /// NSEvent.buttonNumber); 0 = unregister. Observe-only, like the Windows
  /// RawInput listener: the click still reaches the app under the cursor.
  /// Registered only while a side button is actually bound (BUG-1077 spirit:
  /// no system-wide listener for users who never use the feature).
  private func setGlobalMouseTrigger(_ button: Int) -> Bool {
    if let m = mouseTriggerMonitor {
      NSEvent.removeMonitor(m)
      mouseTriggerMonitor = nil
    }
    mouseTriggerButton = 0
    guard button == 3 || button == 4 else { return button == 0 }
    mouseTriggerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) {
      [weak self] event in
      guard let self = self, event.buttonNumber == self.mouseTriggerButton else { return }
      self.channel.invokeMethod("globalMouseTrigger", arguments: nil)
    }
    mouseTriggerButton = button
    return mouseTriggerMonitor != nil
  }

  // MARK: Host-chrome window resize (Phase C grip)

  private func beginWindowResize() {
    guard let panel = panel, visible else { return }
    endResizeTracking(report: false)
    resizeStartFrame = panel.frame
    resizeStartMouse = NSEvent.mouseLocation
    resizeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) {
      [weak self] event in
      guard let self = self, let panel = self.panel else { return event }
      if event.type == .leftMouseDragged {
        let loc = NSEvent.mouseLocation
        let dx = loc.x - self.resizeStartMouse.x
        let dy = self.resizeStartMouse.y - loc.y
        let w = max(120, self.resizeStartFrame.width + dx)
        let h = max(80, self.resizeStartFrame.height + dy)
        panel.setFrame(
          NSRect(x: self.resizeStartFrame.minX, y: self.resizeStartFrame.maxY - h, width: w, height: h),
          display: true)
      } else {
        self.endResizeTracking(report: true)
      }
      return event
    }
  }

  /// Ends the drag; `report` mirrors WM_EXITSIZEMOVE: endLiveResize first, then
  /// windowMoved [left, top, w, h, startW, startH] in physical px for Dart to
  /// persist the overlay size.
  private func endResizeTracking(report: Bool) {
    guard let m = resizeMonitor else { return }
    NSEvent.removeMonitor(m)
    resizeMonitor = nil
    guard report, let panel = panel else { return }
    panel.invalidateShadow()
    evaluate("window.__globalLookupHost && window.__globalLookupHost.endLiveResize();")
    let tl = topLeftPoint(fromAppKit: NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
    let s = anchorScale
    let body = "{\"handler\":\"windowMoved\",\"args\":["
      + "\(Int(tl.x * s)),\(Int(tl.y * s)),\(Int(panel.frame.width * s)),\(Int(panel.frame.height * s)),"
      + "\(Int(resizeStartFrame.width * s)),\(Int(resizeStartFrame.height * s))]}"
    channel.invokeMethod("jsMessage", arguments: routedPayload(body, route: route))
  }

  // MARK: JS execution

  private func evaluate(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
    guard let webView = webView else {
      completion?(nil, nil)
      return
    }
    webView.evaluateJavaScript(script) { value, error in
      completion?(value, error)
    }
  }

  /// `script` is the COMPLETE render script built in Dart (settings +
  /// lookupEntries + renderPopup). Cached until the host document finished
  /// loading (renderPopup must exist) — last-wins, like pending_json_.
  private func render(_ script: String) {
    if recovering || !webViewReady || webView == nil {
      pendingScript = script
      return
    }
    evaluate(script) { [weak self] _, error in
      // A JS exception still completes normally; only an infra-level failure
      // (dead content process) surfaces as an error here.
      if let error = error as NSError?, error.domain == WKError.errorDomain,
         error.code == WKError.webContentProcessTerminated.rawValue {
        self?.recoverDeadWebView(replay: script)
      }
    }
  }

  private static let allowedGamepadActions: Set<String> = ["next", "prev", "mine", "audio", "scroll"]

  private func dispatchGamepadAction(_ action: String, dy: Double) {
    guard webViewReady, !recovering,
          GlobalLookupOverlayController.allowedGamepadActions.contains(action)
    else { return }
    evaluate(
      "window.__globalLookupHost && window.__globalLookupHost.gamepadAction('\(action)', \(dy));")
  }

  /// `jsValue` is a ready JS string literal (Dart double-encodes it); the
  /// adapter JSON.parses it. Spliced verbatim like the Windows runner.
  private func resolveBridge(id: Int64, jsValue: String) {
    evaluate("window.__fushiBridgeResolve && window.__fushiBridgeResolve(\(id), \(jsValue));")
  }

  /// TODO-1268 parity: rebuild a dead content process in place, replaying the
  /// last render once the host document has reloaded.
  private func recoverDeadWebView(replay: String?) {
    if let replay = replay, !replay.isEmpty {
      pendingScript = replay
    }
    webViewReady = false
    latestGeometryEpoch = 0
    if recovering { return }
    recovering = true
    reportError("overlay web content process died; reloading host document")
    loadHostDocument()
  }

  private func reportError(_ message: String) {
    globalLookupNativeLog("ERROR: \(message)")
    channel.invokeMethod("nativeError", arguments: message)
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webViewReady = true
    recovering = false
    if let script = pendingScript {
      pendingScript = nil
      render(script)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    reportError("overlay host navigation failed: \(error.localizedDescription)")
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    reportError("overlay host provisional navigation failed: \(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    recoverDeadWebView(replay: pendingScript)
  }

  // MARK: WKScriptMessageHandler (chrome.webview.postMessage stand-in)

  /// Bridge handlers whose Promise is settled by the main Dart engine
  /// (ResolveBridge) instead of the immediate `null` — the exact list the
  /// Windows router keeps (see global_lookup_window.cpp WebMessageReceived).
  private static let deferredHandlers: Set<String> = [
    "resolveWordAudio", "queryLocalAudio", "favoriteEntry", "favoriteCheck",
    "mineEntry", "duplicateCheck", "overwriteTargetNoteId", "updateEntry",
    "findMinedMatches", "openMinedNote", "openInAnki",
  ]

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == kScriptMessageName, let body = message.body as? String else { return }
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any]
    else { return }
    let handler = dict["handler"] as? String ?? ""
    let messageRoute = routeForMessage(dict)

    switch handler {
    case "shellRects":
      // Window-region truth for the Win32 HRGN clip. The WKWebView is
      // per-pixel transparent already, so nothing to apply; not forwarded
      // (Windows does not forward it either).
      return
    case "beginWindowResize":
      beginWindowResize()
      return
    default:
      break
    }

    channel.invokeMethod("jsMessage", arguments: routedPayload(body, route: messageRoute))

    // Resolve the callHandler promise so popup.js await-points never hang;
    // deferred handlers get their real reply via resolveBridge from Dart.
    if !GlobalLookupOverlayController.deferredHandlers.contains(handler),
       let bridgeId = (dict["__bridgeId"] as? NSNumber)?.int64Value {
      evaluate("window.__fushiBridgeResolve && window.__fushiBridgeResolve(\(bridgeId), null);")
    }
  }

  private func routeForMessage(_ dict: [String: Any]) -> GlobalLookupRouteContext {
    var r = route
    if let source = dict["__source"] as? String, source == "desktop" || source == "galCard" {
      r.source = source
    }
    if let epoch = (dict["__routeEpoch"] as? NSNumber)?.int64Value, epoch >= 0 {
      r.routeEpoch = epoch
    }
    if let epoch = (dict["__lookupEpoch"] as? NSNumber)?.int64Value, epoch >= 0 {
      r.lookupEpoch = epoch
    }
    return r
  }

  private func routedPayload(_ json: String, route: GlobalLookupRouteContext) -> [String: Any] {
    var envelope = route.envelope
    envelope["payload"] = json
    return envelope
  }

  /// Installed at document start in every frame: the WebView2 API surface the
  /// popup adapter + host post through. Objects are serialized here (the
  /// Windows side receives them as JSON via get_WebMessageAsJson).
  private static let chromeWebViewShim = """
    (function () {
      if (window.chrome && window.chrome.webview &&
          typeof window.chrome.webview.postMessage === 'function') {
        return;
      }
      window.chrome = window.chrome || {};
      window.chrome.webview = {
        postMessage: function (message) {
          try {
            window.webkit.messageHandlers.\(kScriptMessageName).postMessage(
                JSON.stringify(message));
          } catch (e) {
            // No bridge in this realm: drop (matches the adapter's own guard).
          }
        }
      };
    })();
    """

  // MARK: Test hooks (FUSHI_TEST_INPUT only)

  private func debugEvaluate(_ script: String, result: @escaping FlutterResult) {
    evaluate(script) { value, error in
      if let error = error {
        result(FlutterError(code: "js_error", message: error.localizedDescription, details: nil))
        return
      }
      if let value = value {
        result(String(describing: value))
      } else {
        result(nil)
      }
    }
  }

  /// Native-side visibility facts for the itest: whether AppKit/WindowServer
  /// consider the panel on-screen (WebKit derives document.visibilityState —
  /// and therefore requestAnimationFrame — from the window's occlusion state).
  private func debugWindowState() -> String {
    guard let panel = panel, let webView = webView else { return "panel=nil" }
    let occluded = !panel.occlusionState.contains(.visible)
    let screenDesc = panel.screen.map {
      "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)"
    } ?? "none"
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    return "isVisible=\(panel.isVisible) occluded=\(occluded) onScreen=\(panel.isOnActiveSpace) "
      + "frame=\(NSStringFromRect(panel.frame)) screen=\(screenDesc) "
      + "webAlpha=\(webView.alphaValue) webHidden=\(webView.isHiddenOrHasHiddenAncestor) "
      + "ignoresMouse=\(panel.ignoresMouseEvents) level=\(panel.level.rawValue) "
      + "displayAsleep=\(displayAsleep) visible=\(visible) measuring=\(measuring)"
  }

  private func debugSnapshot(path: String, result: @escaping FlutterResult) {
    guard let webView = webView, !path.isEmpty else {
      result(false)
      return
    }
    let config = WKSnapshotConfiguration()
    webView.takeSnapshot(with: config) { image, error in
      guard let image = image, error == nil,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
      else {
        result(false)
        return
      }
      do {
        try png.write(to: URL(fileURLWithPath: path))
        result(true)
      } catch {
        result(false)
      }
    }
  }
}
