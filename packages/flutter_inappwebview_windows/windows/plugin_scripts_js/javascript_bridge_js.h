#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_

#include <memory>
#include <string>

#include "../types/plugin_script.h"

namespace flutter_inappwebview_plugin
{
  const std::string JAVASCRIPT_BRIDGE_NAME = "flutter_inappwebview";

  // Fushi bridge lock (docs/specs/2026-10-23-dictionary-script-sandbox.md).
  // The page asks for a lock with callHandler('_fushiLockBridge'); the request
  // is handled HERE (never dispatched to an app handler). Native answers with a
  // random token through _fushiLockResult; the token lives only in this
  // closure, and every later JS->native message carries it. Until the lock
  // reply arrives, other callHandler posts are queued so they are sent WITH the
  // token (native starts rejecting tokenless messages as soon as it locked).
  const std::string FUSHI_BRIDGE_LOCK_HANDLER_NAME = "_fushiLockBridge";
  const std::string FUSHI_BRIDGE_LOCKED_VALUE = "fushi-bridge-locked-v1";

  const std::string JAVASCRIPT_BRIDGE_JS_SOURCE = "window." + JAVASCRIPT_BRIDGE_NAME + " = {}; (function(bridge) {" + R"JS(
    var _fushiBridgeToken = null;
    // 0 = unlocked, 1 = lock request in flight, 2 = locked, 3 = lock refused.
    var _fushiLockState = 0;
    var _fushiLockId = null;
    var _fushiLockResolve = null;
    var _fushiQueue = [];
    // Single JS->native entry point: always attaches the lock token once held.
    function _fushiPostCallHandler(handlerName, callHandlerID, argsJson) {
      var body = { 'handlerName': handlerName, '_callHandlerID': callHandlerID, 'args': argsJson };
      if (_fushiBridgeToken !== null) {
        body['_fushiBridgeToken'] = _fushiBridgeToken;
      }
      window.chrome.webview.postMessage({ 'name': 'callHandler', 'body': body });
    }
    function _fushiFinishLock(token) {
      if (typeof token === 'string' && token.length >= 32) {
        _fushiBridgeToken = token;
        _fushiLockState = 2;
      } else {
        _fushiLockState = 3;
      }
      var resolve = _fushiLockResolve;
      _fushiLockResolve = null;
      _fushiLockId = null;
      var queued = _fushiQueue;
      _fushiQueue = [];
      for (var i = 0; i < queued.length; i++) {
        try {
          _fushiPostCallHandler(queued[i][0], queued[i][1], queued[i][2]);
        } catch (e) {}
      }
      if (resolve) {
        resolve(_fushiLockState === 2 ? ')JS" + FUSHI_BRIDGE_LOCKED_VALUE + R"JS(' : false);
      }
    }
    bridge.callHandler = function() {
      var handlerName = arguments[0];
      var _callHandlerID = setTimeout(function() {});
      if (handlerName === ')JS" + FUSHI_BRIDGE_LOCK_HANDLER_NAME + R"JS(') {
        var isTop = false;
        try { isTop = (window.top === window); } catch (e) { isTop = false; }
        if (!isTop || _fushiLockState !== 0) {
          return Promise.resolve(false);
        }
        _fushiLockState = 1;
        _fushiLockId = _callHandlerID;
        return new Promise(function(resolve) {
          _fushiLockResolve = resolve;
          try {
            window.chrome.webview.postMessage({ 'name': ')JS" + FUSHI_BRIDGE_LOCK_HANDLER_NAME + R"JS(', 'body': { '_callHandlerID': _callHandlerID } });
          } catch (e) {
            _fushiFinishLock(null);
          }
        });
      }
      var argsJson = JSON.stringify(Array.prototype.slice.call(arguments, 1));
      var promise = new Promise(function(resolve, reject) {
        bridge[_callHandlerID] = { resolve: resolve, reject: reject };
      });
      if (_fushiLockState === 1) {
        _fushiQueue.push([handlerName, _callHandlerID, argsJson]);
      } else {
        _fushiPostCallHandler(handlerName, _callHandlerID, argsJson);
      }
      return promise;
    };
    // Native (in_app_webview.cpp handleBridgeLockRequest) calls this in the top
    // document with the token, or false when the lock was refused.
    bridge._fushiLockResult = function(callHandlerID, token) {
      if (_fushiLockState !== 1 || callHandlerID !== _fushiLockId) {
        return;
      }
      _fushiFinishLock(token);
    };
  )JS" + "})(window." + JAVASCRIPT_BRIDGE_NAME + ");";
  const std::string JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME = "IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT";
  const std::string PLATFORM_READY_JS_SOURCE = "(function() { \
     if ((window.top == null || window.top === window) && window." + JAVASCRIPT_BRIDGE_NAME + " != null && window." + JAVASCRIPT_BRIDGE_NAME + "._platformReady == null) { \
       window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady')); \
       window." + JAVASCRIPT_BRIDGE_NAME + "._platformReady = true; \
     } \
   })();";

  std::unique_ptr<PluginScript> createJavaScriptBridgePluginScript();
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
