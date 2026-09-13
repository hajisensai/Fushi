import ApplicationServices
import Cocoa
import FlutterMacOS
import macos_window_utils

@main
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var activeSecurityScopedURLs: [String: URL] = [:]
  private var challengeBrowser: FushiChallengeBrowser?
  private var pendingSourceUrls: [String] = []
  private var sourceUrlEventSink: FlutterEventSink?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let windowController =
        mainFlutterWindow?.contentViewController as? MacOSWindowUtilsViewController {
      let controller = windowController.flutterViewController
      // 系统自带 OCR（Vision）。与 iOS 侧同一份实现（apple/FushiSystemOcr.swift）。
      FushiSystemOcr.register(binaryMessenger: controller.engine.binaryMessenger)
      // 系统语音转录（macOS 26 的 SpeechAnalyzer）；与 iOS 同一份实现。
      FushiSpeechTranscriber.register(
        binaryMessenger: controller.engine.binaryMessenger)
      let sourceUrlChannel = FlutterEventChannel(
        name: "app.fushi.reader/source_urls/stream",
        binaryMessenger: controller.engine.binaryMessenger)
      sourceUrlChannel.setStreamHandler(self)
      challengeBrowser = FushiChallengeBrowser(
        binaryMessenger: controller.engine.binaryMessenger
      ) { [weak self] in self?.mainFlutterWindow }
      let channel = FlutterMethodChannel(
        name: "app.fushi/data_root_access",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleDataRootAccess(call, result: result)
      }

      // TODO-1030 M1 -- macOS Accessibility (AX) foreground-selection context
      // capture channel. Symmetric to the Windows UIA channel of the same name
      // (windows/runner/flutter_window.cpp RegisterForegroundSelectionChannel):
      // Dart (selection_capture_ffi.dart) calls `captureContext` when the global
      // lookup pref opts into context capture, and reuses the shared pure-Dart
      // sentence trimmer. A failure returns null so Dart falls back to the
      // clipboard capture (never break the existing lookup path).
      let foregroundSelectionChannel = FlutterMethodChannel(
        name: "app.fushi.reader/foreground_selection",
        binaryMessenger: controller.engine.binaryMessenger)
      foregroundSelectionChannel.setMethodCallHandler { call, result in
        AppDelegate.handleForegroundSelection(call, result: result)
      }

      // BUG-2508 真机取证钩子（只在 FUSHI_TEST_INPUT 环境变量存在时注册，生产
      // 启动零暴露）：把真实 NSEvent（mouseMoved / flagsChanged / 点击）送进本窗口，
      // 供 integration_test/macos_reader_shift_hover_itest.dart 驱动。ssh 起的进程
      // 没有辅助功能授权、CGEvent 投不进 WindowServer；进程内合成的 mouseMoved 经
      // NSApp.postEvent / sendEvent 也到不了 tracking area owner（AppKit 只给
      // WindowServer 产生的事件派 tracking area），故 hover 用 "flutter" 模式直接交
      // FlutterViewController——从那往下（修饰键同步、Flutter hover、MouseRegion、JS
      // selectText、真弹窗）全是真路径。点击与 flagsChanged 走 postEvent 即可到达。
      if ProcessInfo.processInfo.environment["FUSHI_TEST_INPUT"] != nil {
        let testInputChannel = FlutterMethodChannel(
          name: "app.fushi.test/input",
          binaryMessenger: controller.engine.binaryMessenger)
        testInputChannel.setMethodCallHandler { [weak self] call, result in
          self?.handleTestInput(call, result: result)
        }
      }
    } else {
      NSLog("[Fushi] macOS Flutter controller unavailable; custom channels were not registered")
    }
    super.applicationDidFinishLaunching(notification)
  }

  // BUG-2508 真机取证钩子（FUSHI_TEST_INPUT 门控）。坐标口径：Flutter 逻辑坐标
  // （窗口内容视图左上角为原点，y 向下），这里翻成 AppKit 的 locationInWindow
  // （左下角原点）。事件带真实 windowNumber。
  private func handleTestInput(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = mainFlutterWindow else {
      result(FlutterError(code: "no_window", message: "main window unavailable", details: nil))
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let shift = (args["shift"] as? Bool) ?? false
    // 真实 HID 事件的 Shift 同时带通用位 0x20000 与左 Shift 设备位 0x2；Flutter 嵌入层
    // 在每个鼠标事件上按设备位同步修饰键，鼠标事件少了 0x2 会被判成「左 Shift 抬起」。
    let flags = NSEvent.ModifierFlags(rawValue: shift ? 0x20002 : 0)
    let now = ProcessInfo.processInfo.systemUptime
    switch call.method {
    case "activate":
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.acceptsMouseMovedEvents = true
      let content = window.contentView?.bounds ?? .zero
      result([
        "isKey": window.isKeyWindow,
        "isMain": window.isMainWindow,
        "isActive": NSApp.isActive,
        "windowNumber": window.windowNumber,
        "contentWidth": content.width,
        "contentHeight": content.height,
        "firstResponder": AppDelegate.responderName(window.firstResponder),
      ])
    case "mouseMove":
      let x = (args["x"] as? Double) ?? 0
      let y = (args["y"] as? Double) ?? 0
      let contentHeight = window.contentView?.bounds.height ?? 0
      let location = NSPoint(x: x, y: contentHeight - y)
      guard let event = NSEvent.mouseEvent(
        with: .mouseMoved, location: location, modifierFlags: flags, timestamp: now,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
        pressure: 0)
      else {
        result(FlutterError(code: "event", message: "mouseMoved construction failed", details: nil))
        return
      }
      deliverTestEvent(event, mode: (args["mode"] as? String) ?? "post")
      // AppKit 的 hitTest 与 WebKit WKMouseTrackingObserver 用的是同一条命中链：
      // 回报该点命中的 NSView 及其祖先链，作「这一点 WKWebView 是不是最顶视图」的直接证据。
      var chain: [String] = []
      if let content = window.contentView,
         let hit = content.hitTest(content.superview?.convert(location, from: nil) ?? location) {
        var v: NSView? = hit
        while let cur = v { chain.append(String(describing: type(of: cur))); v = cur.superview }
      }
      result(["hit": chain.first ?? "nil", "chain": chain.joined(separator: " < ")])
    case "click":
      // 真 NSEvent 左键按下/抬起（同 mouseMove 的坐标口径），判「点击这条路
      // 到不到 WKWebView」——DropTarget 盖顶时 mouseDown 的去向就是 AppKit 的真实去向。
      let x = (args["x"] as? Double) ?? 0
      let y = (args["y"] as? Double) ?? 0
      let contentHeight = window.contentView?.bounds.height ?? 0
      let location = NSPoint(x: x, y: contentHeight - y)
      guard let down = NSEvent.mouseEvent(
        with: .leftMouseDown, location: location, modifierFlags: flags, timestamp: now,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
        pressure: 1),
        let up = NSEvent.mouseEvent(
        with: .leftMouseUp, location: location, modifierFlags: flags, timestamp: now + 0.05,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
        pressure: 0)
      else {
        result(FlutterError(code: "event", message: "click construction failed", details: nil))
        return
      }
      let mode = (args["mode"] as? String) ?? "post"
      deliverTestEvent(down, mode: mode)
      deliverTestEvent(up, mode: mode)
      result(["firstResponder": AppDelegate.responderName(window.firstResponder)])
    case "dumpViews":
      // FlutterView 的子视图（z 序自底向上）及 frame，判平台视图 / DropTarget 层序。
      var lines: [String] = []
      func walk(_ v: NSView, _ depth: Int) {
        let f = v.frame
        lines.append(String(repeating: "  ", count: depth)
          + "\(type(of: v)) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)))"
          + (v.isHidden ? " hidden" : ""))
        if depth < 4 { for c in v.subviews { walk(c, depth + 1) } }
      }
      if let content = window.contentView { walk(content, 0) }
      result(["views": lines.joined(separator: "\n")])
    case "flagsChanged":
      // Flutter macOS 嵌入层按**设备相关位**分左右 Shift（左 Shift = 0x2，与通用
      // NSEventModifierFlagShift 0x20000 并存，真实 HID 事件两位都带）；只给 0x20000
      // 引擎会判成「左 Shift 抬起」。CGEvent 构造不可用：NSEvent.characters 对
      // CGEvent 来源的 flagsChanged 会抛，卡死 FlutterKeyboardManager 的事件队列。
      guard let event = NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: now,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)
      else {
        result(FlutterError(code: "event", message: "flagsChanged construction failed", details: nil))
        return
      }
      deliverTestEvent(event, mode: (args["mode"] as? String) ?? "post")
      result([
        "firstResponder": AppDelegate.responderName(window.firstResponder),
        "flags": event.modifierFlags.rawValue,
        "keyCode": event.keyCode,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func responderName(_ r: NSResponder?) -> String {
    guard let r = r else { return "nil" }
    return String(describing: type(of: r))
  }

  /// "post" = 进 NSApp 事件队列（经 run loop 的 nextEvent → sendEvent）；
  /// "send" = 直接 NSApp.sendEvent；"window" = window.sendEvent。
  /// "flutter" = 直接交给 FlutterViewController（AppKit 只把 WindowServer 产生的
  /// mouseMoved 派给 tracking area owner，进程内合成的到不了那一跳；从 VC 往下——
  /// 修饰键同步、Flutter hover、MouseRegion、JS selectText、真弹窗——全是真路径）。
  private func deliverTestEvent(_ event: NSEvent, mode: String) {
    switch mode {
    case "send": NSApp.sendEvent(event)
    case "window": event.window?.sendEvent(event)
    case "flutter":
      guard let vc = (mainFlutterWindow?.contentViewController
        as? MacOSWindowUtilsViewController)?.flutterViewController else { return }
      switch event.type {
      case .mouseMoved: vc.mouseMoved(with: event)
      case .flagsChanged: vc.flagsChanged(with: event)
      case .leftMouseDown: vc.mouseDown(with: event)
      case .leftMouseUp: vc.mouseUp(with: event)
      default: NSApp.sendEvent(event)
      }
    default: NSApp.postEvent(event, atStart: false)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // Launch Services may deliver before the engine/channel exists. Keep source
    // links until Dart subscribes; other schemes/hosts still reach plugins.
    var remainingUrls: [URL] = []
    for url in urls {
      guard url.scheme?.lowercased() == "fushi",
        url.host?.lowercased() == "source" else {
        remainingUrls.append(url)
        continue
      }
      if let sink = sourceUrlEventSink {
        sink(url.absoluteString)
      } else {
        pendingSourceUrls.append(url.absoluteString)
      }
    }
    if !remainingUrls.isEmpty {
      super.application(application, open: remainingUrls)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sourceUrlEventSink = events
    let pending = pendingSourceUrls
    pendingSourceUrls.removeAll()
    for url in pending {
      events(url)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sourceUrlEventSink = nil
    return nil
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    for url in activeSecurityScopedURLs.values {
      url.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedURLs.removeAll()
    super.applicationWillTerminate(notification)
  }

  private func handleDataRootAccess(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(
        code: "bad_args",
        message: "Missing data root access arguments",
        details: nil))
      return
    }

    switch call.method {
    case "createBookmark":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_path", message: "Missing path", details: nil))
        return
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
          if didStart {
            url.stopAccessingSecurityScopedResource()
          }
        }
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(data.base64EncodedString())
      } catch {
        result(FlutterError(
          code: "bookmark_failed",
          message: "Failed to create data root bookmark",
          details: error.localizedDescription))
      }

    case "startAccessingBookmark":
      guard let encoded = args["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(code: "bad_bookmark", message: "Invalid bookmark", details: nil))
        return
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let key = url.path
        if activeSecurityScopedURLs[key] == nil {
          let ok = url.startAccessingSecurityScopedResource()
          guard ok else {
            result(FlutterError(
              code: "access_denied",
              message: "Failed to access security-scoped data root",
              details: key))
            return
          }
          activeSecurityScopedURLs[key] = url
        }
        result(["path": key, "stale": stale])
      } catch {
        result(FlutterError(
          code: "resolve_failed",
          message: "Failed to resolve data root bookmark",
          details: error.localizedDescription))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // TODO-1030 M1 -- macOS AX foreground-selection context capture handler.
  // The cross-process Accessibility read can block, so it runs off the main
  // thread and the FlutterResult is completed back on the main (platform)
  // thread. On any miss it replies nil so Dart falls back to the clipboard
  // capture. Static so the channel closure never retains the AppDelegate.
  private static func handleForegroundSelection(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    guard call.method == "captureContext" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any]
    let maxExpand = (args?["maxExpand"] as? Int) ?? ForegroundSelectionCapture.defaultExpand
    DispatchQueue.global(qos: .userInitiated).async {
      let start = DispatchTime.now()
      let capture = ForegroundSelectionCapture.capture(maxExpand: maxExpand)
      let elapsedMs = Int(
        (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
      DispatchQueue.main.async {
        guard let capture = capture else {
          // No AX text / no permission / non-text focus: Dart falls back.
          result(nil)
          return
        }
        // Privacy: never carry body text into logs here; only the map crosses
        // the channel. Offsets are UTF-16 code units (NSString), matching Dart
        // String indexing and the Windows UIA path.
        result([
          "contextText": capture.contextText,
          "selStart": capture.selStart,
          "selLen": capture.selLen,
          "elapsedMs": elapsedMs,
        ])
      }
    }
  }
}

// TODO-1030 M1 -- Accessibility (AX) foreground-selection context capture, the
// macOS counterpart to windows/runner/foreground_selection.cpp. Reads the
// SYSTEM-WIDE focused UI element, its selected text, and the selection range,
// then expands +/- maxExpand characters via the parameterized
// kAXStringForRange attribute to grab the surrounding neighbourhood. The pure
// sentence trimming stays in Dart (sentence_extraction.dart), shared with the
// reader and the Windows path.
//
// FAIL-OPEN CONTRACT: every failure path returns nil (never throws, never
// prompts). Without Accessibility trust (AXIsProcessTrusted() == false) we
// cannot read other apps, so we bail immediately -- no nagging permission
// dialog on every hotkey, no crash; the caller silently falls back to the
// clipboard capture. Offsets are UTF-16 code units (NSString length), the unit
// Dart String indexing uses.
//
// SANDBOX NOTE: the app ships sandboxed (see Runner/*.entitlements). The App
// Sandbox blocks cross-process AX reads even after the user grants
// Accessibility trust, so under the current entitlements this returns nil at
// runtime (fail-open). Enabling it needs a sandbox decision (drop the sandbox
// or a non-sandboxed helper) -- tracked separately; the capture logic itself
// is correct and ready.
enum ForegroundSelectionCapture {
  // Mirrors kForegroundContextExpand in foreground_selection.h (Windows): the
  // max characters to grab PAST the selection on EACH side. Bounded for privacy
  // (never scrape a whole document) and latency.
  static let defaultExpand: Int = 600

  struct Result {
    let contextText: String
    let selStart: Int
    let selLen: Int
  }

  static func capture(maxExpand: Int) -> Result? {
    // Fail-open gate: no Accessibility trust -> cannot read other apps text.
    // Do NOT prompt here (AXIsProcessTrusted, not the prompting *WithOptions
    // variant) so a hotkey never spawns a permission dialog.
    guard AXIsProcessTrusted() else { return nil }

    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedValue = focusedRef,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let focused = focusedValue as! AXUIElement

    // The selected text itself (the lookup query). Empty/absent -> nothing to
    // look up, bail so the clipboard fallback can try instead.
    var selTextRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focused, kAXSelectedTextAttribute as CFString, &selTextRef) == .success,
      let selText = selTextRef as? String, !selText.isEmpty
    else {
      return nil
    }
    let selTextLen = (selText as NSString).length

    // The selection range {location, length} inside the focused element text.
    // Without a usable range we still return the bare selection as the whole
    // context (sentence extraction treats it as one sentence).
    var selRangeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focused, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
      let selRangeValue = selRangeRef,
      CFGetTypeID(selRangeValue) == AXValueGetTypeID()
    else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }
    var selRange = CFRange()
    guard AXValueGetValue(selRangeValue as! AXValue, .cfRange, &selRange) else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }

    // Total character count, to clamp the expansion window to the buffer.
    var total = selRange.location + selRange.length
    var totalRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      focused, kAXNumberOfCharactersAttribute as CFString, &totalRef) == .success,
      let n = totalRef as? Int
    {
      total = n
    }

    let clampedExpand = max(0, maxExpand)
    let ctxStart = max(0, selRange.location - clampedExpand)
    let ctxEnd = min(total, selRange.location + selRange.length + clampedExpand)
    let ctxLength = max(0, ctxEnd - ctxStart)

    // kAXStringForRange (parameterized) -> the expanded context window. When the
    // element does not support ranged text, fall back to the bare selection.
    var ctxRange = CFRange(location: ctxStart, length: ctxLength)
    guard let ctxRangeValue = AXValueCreate(.cfRange, &ctxRange) else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }
    var ctxTextRef: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        focused, kAXStringForRangeParameterizedAttribute as CFString, ctxRangeValue,
        &ctxTextRef) == .success,
      let ctxText = ctxTextRef as? String, !ctxText.isEmpty
    else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }

    // Re-base the selection into the returned context window and clamp
    // defensively (odd AX offsets never crash the Dart consumer -- worst case
    // the whole buffer is treated as one sentence).
    let ctxTextLen = (ctxText as NSString).length
    var reSelStart = selRange.location - ctxStart
    if reSelStart < 0 { reSelStart = 0 }
    if reSelStart > ctxTextLen { reSelStart = ctxTextLen }
    var reSelLen = selRange.length
    if reSelStart + reSelLen > ctxTextLen { reSelLen = ctxTextLen - reSelStart }
    if reSelLen < 0 { reSelLen = 0 }

    return Result(contextText: ctxText, selStart: reSelStart, selLen: reSelLen)
  }
}
