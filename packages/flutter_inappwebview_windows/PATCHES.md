# Fushi patches

This package is Fushi's fork of `flutter_inappwebview_windows` 0.6.0 (see
`CLAUDE.md`). This file records the security-relevant deviations from upstream
so a future rebase can carry them over deliberately.

## Bridge lock (`_fushiLockBridge`, 2026-10-23)

Contract: `docs/specs/2026-10-23-dictionary-script-sandbox.md`, section
"JS ↔ 原生契约：桥锁定". The dictionary popup runs dictionary scripts in a
`<iframe sandbox="allow-scripts" srcdoc>` and then locks the bridge so that
nothing but its own top-level document can reach native handlers.

- `windows/plugin_scripts_js/javascript_bridge_js.h`: `callHandler` is now a
  closure. `callHandler('_fushiLockBridge')` is intercepted there (never
  dispatched to an app handler): only the top frame may ask, once per document.
  It posts `{name: '_fushiLockBridge'}`; native replies through
  `flutter_inappwebview._fushiLockResult(id, token|false)`. The token stays in
  the closure (never on `window`); the Promise resolves to
  `'fushi-bridge-locked-v1'` on success and `false` otherwise. `callHandler`
  posts issued while the lock request is in flight are queued and flushed with
  the token, because native rejects tokenless messages as soon as it locked.
  Every `callHandler` message carries `body._fushiBridgeToken` once locked.
  This is the plugin's only JS→native call site (`callAsyncJavaScript` and
  `evaluateJavascript` go through CDP / `ExecuteScript`, not `postMessage`).
- `windows/in_app_webview/in_app_webview.cpp`:
  - `handleBridgeLockRequest`: 32 random bytes from `BCryptGenRandom`
    (system-preferred RNG) → 64-char hex token; refused (reply `false`, keep
    the old token) when already locked, when the sender's
    `ICoreWebView2WebMessageReceivedEventArgs::get_Source` is empty or
    `about:srcdoc`, or when the RNG fails. The reply is evaluated in the top
    document only.
  - `add_WebMessageReceived`: once locked, a message is dispatched only if its
    token matches (constant-time compare) **and** its Source equals the
    locking document's Source or the current top-level `get_Source` (same
    document `pushState`). Everything else is dropped with a
    `[bridge-lock][warn]` line on stderr / `OutputDebugString` (also in
    release builds). Unlocked WebViews behave exactly as before. JSON parsing
    of the message no longer throws on malformed input.
  - `add_ContentLoading` clears the token: it fires only when the top-level
    frame commits a new document (not for fragment / `pushState`, not for
    sub-frames). It is deliberately not cleared on `NavigationStarting`, since
    a started navigation can be cancelled or become a download while the
    locked document stays alive.

### Do sub-frame `chrome.webview.postMessage` calls reach `WebMessageReceived`?

Per the WebView2 SDK 1.0.2792.45 docs shipped in the NuGet package
(`lib/net462/Microsoft.Web.WebView2.Core.xml`): `CoreWebView2.WebMessageReceived`
"is raised when … the top-level document of the WebView runs
`window.chrome.webview.postMessage`", while an iframe's `postMessage` raises
`CoreWebView2Frame.WebMessageReceived` instead. This plugin never subscribes to
`FrameCreated` / frame message events, so sub-frame calls are not delivered at
all (which is also why sub-frame `callHandler` never worked on Windows). The
Source check is therefore defence in depth, not the primary gate. Not yet
verified at runtime on this machine.

## No Flutter focus request on mouse down (BUG-3858, 2026-10-28)

- `custom_platform_view.dart` `onPointerDown`: upstream called
  `_focusNode.requestFocus()` (plus a 50 ms retry) whenever the platform-view
  focus node lacked focus. Since Flutter's multi-view focus API, a focus request
  inside a view whose native window lost focus makes the framework call
  `requestViewFocusChange(focused)`, and the Windows engine answers with
  `SetFocus` on the Flutter view HWND. WebView2 has just moved Win32 focus to
  Chromium for the same click, so the two fight; the page sees a `window` blur
  on every click and focus-sensitive popups (the YouTube settings menu's
  sub-panels) close. Removed: clicking web content leaves keyboard focus with
  WebView2, and Flutter parks focus at the root scope via the engine's
  `unfocused` view event. Test: `test/pointer_down_view_focus_test.dart`.
