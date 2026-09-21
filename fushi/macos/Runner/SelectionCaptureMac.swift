import ApplicationServices
import Cocoa
import FlutterMacOS

// macOS foreground-selection capture for the app-external global lookup — the
// macOS counterpart of lib/src/lookup/selection_capture_ffi.dart's Windows
// user32 keybd_event path (inject a clean copy shortcut, read the clipboard,
// restore it). Registered on the SAME `app.fushi.reader/foreground_selection`
// channel as the AX context capture in AppDelegate.swift (captureContext).
//
// Methods:
//   captureSelection          -> {text, method: ax|clipboard|pasteboard,
//                                 trusted: Bool}
//   isAccessibilityTrusted    -> Bool   (AXIsProcessTrusted, never prompts)
//   requestAccessibilityTrust -> Bool   (prompting variant + opens the
//                                 Privacy > Accessibility pane; called by the
//                                 settings action or the first explicit
//                                 global-lookup trigger)
//
// Why Accessibility trust matters: both reading another app's selection over
// AX and posting a synthetic Cmd+C (CGEvent) need the app in System Settings
// > Privacy & Security > Accessibility. Without it we cannot touch the
// foreground app at all, so the capture degrades to "whatever is on the
// pasteboard right now" (the user copies first, then presses the hotkey) and
// reports trusted=false so the Dart side can log the degraded mode.
enum MacSelectionCapture {
  /// Returns true when the call was one of ours (and `result` was, or will be,
  /// completed); false lets the caller fall through to MethodNotImplemented.
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    switch call.method {
    case "isAccessibilityTrusted":
      result(AXIsProcessTrusted())
      return true
    case "requestAccessibilityTrust":
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      if !trusted,
         let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
      result(trusted)
      return true
    case "captureSelection":
      // The synthetic copy + pasteboard poll sleeps up to ~600 ms; keep it off
      // the platform thread and complete the FlutterResult back on it.
      DispatchQueue.global(qos: .userInitiated).async {
        let reply = captureSelection()
        DispatchQueue.main.async {
          result(reply)
        }
      }
      return true
    default:
      return false
    }
  }

  static func captureSelection() -> [String: Any] {
    let trusted = AXIsProcessTrusted()
    if trusted, let text = axSelectedText(), !text.isEmpty {
      return ["text": text, "method": "ax", "trusted": true]
    }
    if trusted {
      return ["text": copyViaKeystroke() ?? "", "method": "clipboard", "trusted": true]
    }
    // Degraded mode: no trust -> the current pasteboard text (copy-then-hotkey).
    let current = NSPasteboard.general.string(forType: .string) ?? ""
    return ["text": current, "method": "pasteboard", "trusted": false]
  }

  /// The focused element's selected text over AX (no clipboard involved).
  /// nil when the focused element has no selection attribute (e.g. a
  /// non-AX-text web view or a canvas app) so the keystroke path can try.
  private static func axSelectedText() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focusedValue = focusedRef,
          CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else { return nil }
    let focused = focusedValue as! AXUIElement
    var selTextRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &selTextRef) == .success,
          let text = selTextRef as? String
    else { return nil }
    return text
  }

  // Virtual key codes (Carbon HIToolbox Events.h).
  private static let kVK_ANSI_C: CGKeyCode = 0x08
  private static let modifierKeyCodes: [CGKeyCode] = [
    0x37, 0x36,  // Command, right Command
    0x3A, 0x3D,  // Option, right Option
    0x3B, 0x3E,  // Control, right Control
    0x38, 0x3C,  // Shift, right Shift
  ]

  /// Snapshot -> release held modifiers -> clean Cmd+C -> poll changeCount ->
  /// read -> restore the full previous pasteboard contents (all types, so a
  /// copied image is not wiped like a text-only restore would).
  private static func copyViaKeystroke() -> String? {
    let pasteboard = NSPasteboard.general
    let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
      var bag: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          bag[type] = data
        }
      }
      return bag
    }
    let baseline = pasteboard.changeCount

    func restorePasteboard() {
      pasteboard.clearContents()
      let items: [NSPasteboardItem] = saved.compactMap { bag in
        guard !bag.isEmpty else { return nil }
        let item = NSPasteboardItem()
        for (type, data) in bag {
          item.setData(data, forType: type)
        }
        return item
      }
      if !items.isEmpty {
        pasteboard.writeObjects(items)
      }
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    // The global hotkey fires while the user still physically holds its
    // modifiers; a naive Cmd+C would arrive as Cmd+Option+C. Release them
    // first (the same trick as the Windows keybd_event path).
    for code in modifierKeyCodes {
      if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
        up.flags = []
        up.post(tap: .cghidEventTap)
      }
    }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: false)
    else {
      restorePasteboard()
      return nil
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)

    // 30 x 20 ms = 600 ms, the Windows poll budget.
    var changed = false
    for _ in 0..<30 {
      usleep(20_000)
      if pasteboard.changeCount != baseline {
        changed = true
        break
      }
    }
    guard changed else {
      restorePasteboard()
      return nil
    }
    let text = pasteboard.string(forType: .string)
    restorePasteboard()
    return text
  }
}
