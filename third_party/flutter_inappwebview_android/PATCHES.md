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
