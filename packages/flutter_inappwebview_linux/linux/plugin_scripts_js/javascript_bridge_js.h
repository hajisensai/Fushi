#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../types/plugin_script.h"
#include "../utils/string.h"

namespace flutter_inappwebview_plugin {

// Forward declaration to avoid circular dependency
class WindowIdJS;

/**
 * JavaScript bridge for communication between web content and native code.
 *
 * This implementation matches iOS JavaScriptBridgeJS.swift for consistency.
 * It uses webkit.messageHandlers to communicate with native code and includes
 * support for multi-window scenarios via _windowId.
 */
class JavaScriptBridgeJS {
 public:
  static void set_JAVASCRIPT_BRIDGE_NAME(const std::string& bridgeName) {
    _JAVASCRIPT_BRIDGE_NAME = bridgeName;
  }

  static std::string get_JAVASCRIPT_BRIDGE_NAME() { return _JAVASCRIPT_BRIDGE_NAME; }

  inline static const std::string JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME =
      "IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT";

  inline static const std::string VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET =
      "$IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_BRIDGE_SECRET";

  /**
   * Returns the JavaScript variable name for the window ID.
   * Match iOS WindowIdJS: "window._flutter_inappwebview_windowId"
   */
  static std::string WINDOW_ID_VARIABLE_JS_SOURCE() {
    return "window._" + get_JAVASCRIPT_BRIDGE_NAME() + "_windowId";
  }

  /**
   * JavaScript source code for the bridge.
   * This code sets up window.flutter_inappwebview.callHandler() function
   * which communicates with native code via webkit.messageHandlers.
   *
   * Matches iOS JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_JS_SOURCE()
   */
  static std::string JAVASCRIPT_BRIDGE_JS_SOURCE() {
    return R"JS(
window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS( = {};
window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._webMessageChannels = {};
(function(window) {
  var bridgeSecret = ')JS" +
           VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET + R"JS(';
  var _JSON_stringify;
  var _Array_slice;
  var _UserMessageHandler;
  var _postMessage;
  var _Promise_then;
  // Fushi bridge lock token (docs/specs/2026-10-23-dictionary-script-sandbox.md).
  // Lives only in this closure, never on window, so other frames (sandboxed
  // dictionary iframes have an opaque origin) cannot read it.
  var _fushiBridgeToken = null;
  
  try {
    _JSON_stringify = window.JSON.stringify;
    _Array_slice = window.Array.prototype.slice;
    _Array_slice.call = window.Function.prototype.call;
    _UserMessageHandler = window.webkit.messageHandlers['callHandler'];
    _postMessage = _UserMessageHandler.postMessage;
    _postMessage.call = window.Function.prototype.call;
    _Promise_then = window.Promise.prototype.then;
    _Promise_then.call = window.Function.prototype.call;
  } catch (_) { return; }

  // Every JS->native call goes through here so the lock token is always attached.
  function _fushiPostToNative(handlerName, argsJson) {
    return _postMessage.call(_UserMessageHandler, {
      'handlerName': handlerName,
      '_bridgeSecret': bridgeSecret,
      'args': argsJson,
      '_windowId': )JS" +
           WINDOW_ID_VARIABLE_JS_SOURCE() + R"JS(,
      '_isMainFrame': (window.top === window),
      '_fushiBridgeToken': _fushiBridgeToken
    });
  }
  
  window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(.callHandler = function() {
    var handlerName = arguments[0];
    if (handlerName === '_fushiLockBridge') {
      // Intercepted by the bridge: native answers with the new token (or false
      // when already locked / not the top frame). Resolve with the dedicated
      // value only on success; anything else means "not locked".
      return _Promise_then.call(_fushiPostToNative('_fushiLockBridge', '[]'), function(token) {
        if (_fushiBridgeToken === null && typeof token === 'string' && token.length >= 32) {
          _fushiBridgeToken = token;
          return 'fushi-bridge-locked-v1';
        }
        return false;
      });
    }
    // Use with_reply API - postMessage returns a Promise directly
    return _fushiPostToNative(handlerName, _JSON_stringify(_Array_slice.call(arguments, 1)));
  };
})(window);
)JS";
  }

  /**
   * JavaScript to dispatch the platform ready event.
   */
  static std::string PLATFORM_READY_JS_SOURCE() {
    return R"JS(
(function() {
  if ((window.top == null || window.top === window) && 
      window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS( != null && 
      window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._platformReady == null) {
    window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));
    window.)JS" +
           get_JAVASCRIPT_BRIDGE_NAME() + R"JS(._platformReady = true;
  }
})();
)JS";
  }

  /**
   * Creates a PluginScript for the JavaScript bridge.
   */
  static std::unique_ptr<PluginScript> JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT(
      const std::string& expectedBridgeSecret,
      const std::optional<std::vector<std::string>>& allowedOriginRules, bool forMainFrameOnly) {
    std::string source = JAVASCRIPT_BRIDGE_JS_SOURCE();
    // Replace the placeholder with the actual secret
    size_t pos = source.find(VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET);
    if (pos != std::string::npos) {
      source.replace(pos, VAR_JAVASCRIPT_BRIDGE_BRIDGE_SECRET.length(), expectedBridgeSecret);
    }

    return std::make_unique<PluginScript>(
        JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME, source,
        UserScriptInjectionTime::atDocumentStart, forMainFrameOnly, allowedOriginRules,
        nullptr,                                 // contentWorld
        true,                                    // requiredInAllContentWorlds
        std::vector<std::string>{"callHandler"}  // messageHandlerNames
    );
  }

 private:
  inline static std::string _JAVASCRIPT_BRIDGE_NAME = "flutter_inappwebview";
};

}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_BRIDGE_JS_H_
