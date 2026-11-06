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

## Composition host HWND is a hidden child, not an owned top-level (BUG-3871, 2026-10-28)

- `in_app_webview_manager.cpp` `createInAppWebView`: upstream created the
  WebView2 host window with style `0` and the Flutter view as "parent", which
  makes it an **owned top-level** window. Chromium parks its keyboard-focus
  window (`Chrome_WidgetWin_0`) under that host, so as soon as the page takes
  focus the active window switches to the hidden host and the app window
  deactivates. The user's next real mouse click has to re-activate the app
  window; the runner's `WM_ACTIVATE` handler restores focus to the Flutter view,
  so the page gets `blur` before `mousedown` and focus-sensitive popups close
  (every YouTube settings sub-menu). Composition mode now creates the host with
  `WS_CHILD` (still not `WS_VISIBLE`), keeping Chromium's focus window inside
  the app window's tree. Flutter-synthesised pointers bypass Windows activation
  and could not see this; evidence comes from the real-mouse mode of
  `fushi/integration_test/web_browser_youtube_menu_probe_itest.dart`.
  Test: `test/composition_host_child_window_test.dart`.

## Capacity-sized shared texture and WGC frame pool (BUG-3913, 2026-10-31)

- `texture_bridge_gpu.cc` / `texture_bridge.cc`: upstream recreated both the
  WGC capture frame pool (`RecreateFramePoolLocked`, exact-size compare) and the
  shared destination texture handed to Flutter (`EnsureSurface`, exact-size
  compare) on every WebView resize. Neither is reclaimed: the Flutter engine /
  ANGLE keeps what it opened for each retired DXGI share handle, and every
  closed frame pool leaves roughly one pool buffer behind in the system. At 4K
  200% every resize cost ~130 MB of fushi.exe dedicated VRAM, forever.
- Dart (`texture_capacity.dart`) now computes a grow-only capacity (256 px
  steps, ×1.5 growth, capped at the display size) and sends it as the 4th/5th
  `setSize` argument. The frame pool is created at `max(capture size,
  capacity)` and only recreated when that no longer fits; frames carry their
  `ContentSize`. The shared texture is allocated at the capacity, the content is
  copied into its top-left corner (`CopySubresourceRegion`), and the rest is
  cleared to transparent whenever the content size changes.
- The engine always maps the whole texture onto the `Texture` widget's box
  (`visible_width` is not a crop), so `CustomPlatformView` lays the `Texture`
  out at `capacity / scale` inside `ClipRect` + top-left `OverflowBox`: texels
  stay 1:1 with physical pixels and only the visible content shows.
  `SelectSurfaceSize` keeps serving the old-capacity texture while the engine
  still paints a frame laid out for it (the request size it passes is the
  `Texture` box), so a capacity switch never draws one stretched frame.
- `GetSurfaceDescriptor` no longer rewrites `output_size_` from the engine
  request: that request is the capacity box now, not the visible size.
- Shader chains (libplacebo) render into private, non-shared intermediates and
  are then copied into the shared texture.
- Tests: `test/texture_capacity_test.dart` (policy), source guard
  `fushi/test/build/webview_texture_capacity_guard_test.dart`.

## WGC frames pulled on a compositor-clocked worker thread (BUG-4108, 2026-11-05)

- `texture_bridge.cc`: frames used to be pulled by a `DispatcherQueueTimer` on
  the platform thread (merged with the Dart UI thread), with a single-buffer
  frame pool, and the raster callback copied straight out of the WGC buffer.
  The tick phase had nothing to do with DWM frames, so `MarkTextureFrameAvailable`
  landed before or after the next Flutter vsync at random: ~10 of every ~57
  captured frames per second were overwritten or repeated (raster interval p95
  33.8 ms during lyrics wheel scrolling, page rAF a steady 16.7 ms).
- Each frame pool now has its own worker thread (`RunFrameWorker`) that waits
  on `DCompositionWaitForCompositorClock` (high-resolution waitable timer at the
  DWM refresh period as a fallback) together with a stop event, drains a
  free-threaded 2-buffer pool keeping only the newest frame, copies it into a
  private staging texture (`WgcFrameMailbox`) and releases the WGC frame at
  once. There is still no `FrameArrived` subscription (BUG-209/BUG-163).
- Delivery hops back to the platform thread through an agile
  `IDispatcherQueueHandler`: `DeliverFrameLocked` keeps every old check
  (invalidation gate, resize/recreate, fps limit, `IsProcessExiting`) before
  `frame_available_()`. The raster callback copies staging → the fixed-handle
  shared texture under the mailbox lock. The plugin D3D11 device has
  `SetMultithreadProtected(TRUE)`.
- Retire order: invalidate delivery → signal stop → join the worker → close
  session → close pool → registry `MarkRetired`.
- Diagnostics: `windows/utils/wgc_pacing_probe.h` (`FUSHI_WGC_PACING_PROBE=1`,
  off by default) writes a once-per-second `evt=pacing` line to
  `wgc_capture.log`.
- Tests: source guards `fushi/test/widgets/texture_bridge_stop_guard_test.dart`,
  `wgc_pump_tick_agile_guard_test.dart`, `wgc_pump_interval_guard_test.dart`,
  `wgc_capture_logging_guard_test.dart`, `inappwebview_windows_native_guards_test.dart`.

## `contentEncoding` is the charset (BUG-4108, 2026-11-05)

- `windows/utils/content_type.h` `contentTypeWithCharset`, used by
  `types/web_resource_response.cpp` and `types/custom_scheme_response.cpp`.
  Upstream appended `contentEncoding` as an HTTP `Content-Encoding` header. In
  the platform interface it is the response charset (Android
  `WebResourceResponse`'s `encoding`, iOS `textEncodingName`), so it now rides
  as the `charset=` parameter of `Content-Type` and no `Content-Encoding` header
  is emitted. Without it WebView2 decoded intercepted documents lacking
  `<meta charset>` with the system ANSI code page (GBK on zh-CN): EPUB chapters
  showed UTF-8 curly quotes as mojibake. Unchanged when the type already has a
  `charset=` parameter, or when `contentEncoding` is empty or `binary`.
  The Linux fork carries the same helper (`linux/utils/content_type.h`).
- Keep `content_type.h` pure ASCII: MSVC reads sources in the system code page
  and the plugin builds with `/WX`, so a non-ASCII comment fails with C4819.
