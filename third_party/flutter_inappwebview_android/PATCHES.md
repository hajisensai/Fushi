# Hibiki patches

This package vendors `flutter_inappwebview_android` 1.1.3 because the hosted
release does not compile with the current Android SDK setup used by Hibiki.

## compileSdk 36 WebChromeClient access fix

`InAppWebViewChromeClient.openFileChooser(...)` overloads are declared
`protected` upstream. With compileSdk 36, these legacy `WebChromeClient`
overloads are public, so Java rejects the narrower access level:

```text
attempting to assign weaker access privileges; was public
```

The three overloads are changed to `public`, preserving the existing
implementation and file-picker behavior.

## JavaScript bridge handler-id injection fix

`JavaScriptBridgeInterface._callHandler(handlerName, _callHandlerID, args)` is a
`@JavascriptInterface`, so every frame of the page (including third-party ad
iframes) can call it with arbitrary strings. Upstream concatenates
`_callHandlerID` verbatim into the JavaScript it then evaluates in the top
frame (`window.flutter_inappwebview[<id>].resolve(...)`), which lets any frame
run script in the top-level page's origin (`_callHandlerID = '0]&&evil()//'`).
The bridge script only ever passes a `setTimeout()` handle, so the call is now
dropped unless the id is a plain integer (1-15 digits) and `handlerName` is
non-null. The Windows fork already validates the id the same way
(`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp`).

## JavaScript bridge lock (BUG-3705)

`addJavascriptInterface` exposes `window.flutter_inappwebview` to every frame,
including `<iframe sandbox="allow-scripts">` frames that run dictionary-supplied
scripts in the lookup popup, and native code cannot tell which frame is calling.
A page can therefore opt into a per-document lock (contract:
`docs/specs/2026-10-23-dictionary-script-sandbox.md`, "JS ↔ 原生契约：桥锁定"):

- `callHandler('_fushiLockBridge')` is intercepted by the bridge script
  (`JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_JS_SOURCE`) and never reaches app
  handlers (a raw `_callHandler` with that name is dropped natively). From the
  top frame only (`window.top === window`, inside try/catch) it calls the new
  `@JavascriptInterface _fushiLockBridge()`, which issues a 256-bit
  `SecureRandom` hex token, keeps it in `JavaScriptBridgeInterface`, and
  returns it synchronously to the calling frame. The bridge script keeps the
  token in its IIFE closure (never on `window`) and resolves the Promise with
  `'fushi-bridge-locked-v1'`. Subframes, an already-locked WebView, or a
  native refusal resolve `false`; the original token is kept.
- Once locked, `_callHandler` / `_hideContextMenu` (the upstream token-less
  entry points) and the new `_fushiCallHandler(..., token)` /
  `_fushiHideContextMenu(token)` are only dispatched when the token matches
  (constant-time compare); otherwise the call is dropped with `Log.w`, without
  dispatch or callback. Unlocked, all of them behave exactly as upstream.
- Every JS→native call site of the plugin goes through the bridge script's
  token-attaching internal functions: `callHandler` (used by every plugin
  script: Ajax/Fetch interception, onLoadResource, window focus/blur, print,
  `callAsyncJavaScript`, content-world `evaluateJavascript`, web message ports,
  injected script load/error) → `_fushiInvoke`; the keydown context-menu
  workaround in `PluginScriptsUtil` → `_fushiHideContextMenuCall`. Same-origin
  subframes (content worlds) forward through the top frame's `_fushiInvoke`
  (no wider than their existing access to `window.top.flutter_inappwebview.callHandler`);
  opaque-origin frames cannot read `window.top` and stay token-less.
- `onPageStarted` (both `InAppWebViewClient` and `InAppWebViewClientCompat`;
  Android only reports main-frame cross-document navigations there) and
  `dispose()` clear the token, so a new top-level document starts unlocked.

Known limits: the native side cannot verify the caller frame, so a frame that
reaches `_fushiLockBridge()` before the page locks gets the token (the page's
lock then resolves `false` and it must not run untrusted scripts). The reset
runs on the UI thread while bridge calls arrive on the JavaBridge thread, so the
bridge script itself defers a lock request until `flutterInAppWebViewPlatformReady`
(`_platformReady`, dispatched from `onPageFinished`, i.e. after `onPageStarted`'s
reset): the reset can no longer wipe a fresh lock, whenever the page asks.

Remove when upstream ships an equivalent per-frame / per-page bridge
authorization (e.g. `WebViewCompat.addWebMessageListener` with `isMainFrame`)
and Fushi's popup moves to it.
