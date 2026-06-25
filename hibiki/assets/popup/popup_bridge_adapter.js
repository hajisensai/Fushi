// TODO-617 global lookup overlay — bridge adapter.
//
// popup.js talks to the host via window.flutter_inappwebview.callHandler(name,
// ...args) -> Promise. The bare WebView2 overlay has no flutter_inappwebview
// injection, so this adapter (injected at document start by
// global_lookup_window.cpp's AddScriptToExecuteOnDocumentCreated) maps that API
// onto WebView2's window.chrome.webview.postMessage, and resolves the returned
// Promise when native replies via window.__hibikiBridgeResolve(id, jsonValue).
//
// Kept dependency-free so it can be unit-tested under node
// (test/lookup/popup_bridge_adapter_test.mjs).
(function () {
  var _seq = 0;
  var _pending = {};

  window.flutter_inappwebview = window.flutter_inappwebview || {};
  window.flutter_inappwebview.callHandler = function (name) {
    var args = Array.prototype.slice.call(arguments, 1);
    var id = ++_seq;
    return new Promise(function (resolve) {
      _pending[id] = resolve;
      window.chrome.webview.postMessage(
        JSON.stringify({ handler: name, args: args, id: id }));
    });
  };

  // Called by native with the handler's return value (JSON string, or undefined
  // for void handlers). Resolves the matching callHandler Promise.
  window.__hibikiBridgeResolve = function (id, jsonValue) {
    var resolve = _pending[id];
    if (!resolve) {
      return;
    }
    delete _pending[id];
    resolve(jsonValue === undefined || jsonValue === null
      ? null
      : JSON.parse(jsonValue));
  };
})();
