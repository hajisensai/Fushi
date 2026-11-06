package com.pichillilorenzo.flutter_inappwebview_android.plugin_scripts_js;

import com.pichillilorenzo.flutter_inappwebview_android.types.PluginScript;
import com.pichillilorenzo.flutter_inappwebview_android.types.UserScriptInjectionTime;

public class PluginScriptsUtil {

  public static final String VAR_PLACEHOLDER_VALUE = "$IN_APP_WEBVIEW_PLACEHOLDER_VALUE";
  public static final String VAR_CONTENT_WORLD_NAME_ARRAY = "$IN_APP_WEBVIEW_CONTENT_WORLD_NAME_ARRAY";
  public static final String VAR_CONTENT_WORLD_NAME = "$IN_APP_WEBVIEW_CONTENT_WORLD_NAME";
  public static final String VAR_JSON_SOURCE_ENCODED = "$IN_APP_WEBVIEW_JSON_SOURCE_ENCODED";
  public static final String VAR_FUNCTION_ARGUMENT_NAMES = "$IN_APP_WEBVIEW_FUNCTION_ARGUMENT_NAMES";
  public static final String VAR_FUNCTION_ARGUMENT_VALUES = "$IN_APP_WEBVIEW_FUNCTION_ARGUMENT_VALUES";
  public static final String VAR_FUNCTION_ARGUMENTS_OBJ = "$IN_APP_WEBVIEW_FUNCTION_ARGUMENTS_OBJ";
  public static final String VAR_FUNCTION_BODY = "$IN_APP_WEBVIEW_FUNCTION_BODY";
  public static final String VAR_RESULT_UUID = "$IN_APP_WEBVIEW_RESULT_UUID";
  public static final String VAR_RANDOM_NAME = "$IN_APP_WEBVIEW_VARIABLE_RANDOM_NAME";

  public static final String CALL_ASYNC_JAVA_SCRIPT_WRAPPER_JS_SOURCE = "(function(obj) {" +
          "  (async function(" + VAR_FUNCTION_ARGUMENT_NAMES + ") {" +
          "    \n" + VAR_FUNCTION_BODY + "\n" +
          "  })(" + VAR_FUNCTION_ARGUMENT_VALUES + ").then(function(value) {" +
          "    window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + ".callHandler('callAsyncJavaScript', {'value': value, 'error': null, 'resultUuid': '" + VAR_RESULT_UUID + "'});" +
          "  }).catch(function(error) {" +
          "    window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + ".callHandler('callAsyncJavaScript', {'value': null, 'error': error + '', 'resultUuid': '" + VAR_RESULT_UUID + "'});" +
          "  });" +
          "  return null;" +
          "})(" + VAR_FUNCTION_ARGUMENTS_OBJ + ");";

  public static final String EVALUATE_JAVASCRIPT_WITH_CONTENT_WORLD_WRAPPER_JS_SOURCE = "var $IN_APP_WEBVIEW_VARIABLE_RANDOM_NAME = null;" +
          "try {" +
          "  $IN_APP_WEBVIEW_VARIABLE_RANDOM_NAME = eval(" + VAR_PLACEHOLDER_VALUE + ");" +
          "} catch(e) {" +
          "  console.error(e);" +
          "}" +
          "window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + ".callHandler('evaluateJavaScriptWithContentWorld', {'value': $IN_APP_WEBVIEW_VARIABLE_RANDOM_NAME, 'resultUuid': '" + VAR_RESULT_UUID + "'});";

  public static final String IS_ACTIVE_ELEMENT_INPUT_EDITABLE_JS_SOURCE =
          "var activeEl = document.activeElement;" +
                  "var nodeName = (activeEl != null) ? activeEl.nodeName.toLowerCase() : '';" +
                  "var isActiveElementInputEditable = activeEl != null && " +
                  "(activeEl.nodeType == 1 && (nodeName == 'textarea' || (nodeName == 'input' && /^(?:text|email|number|search|tel|url|password)$/i.test(activeEl.type != null ? activeEl.type : 'text')))) && " +
                  "!activeEl.disabled && !activeEl.readOnly;" +
                  "var isActiveElementEditable = isActiveElementInputEditable || (activeEl != null && activeEl.isContentEditable) || document.designMode === 'on';";

  // android Workaround to hide context menu when selected text is empty
  // and the document active element is not an input element.
  public static final String CHECK_CONTEXT_MENU_SHOULD_BE_HIDDEN_JS_SOURCE = "(function(){" +
          "  var txt;" +
          "  if (window.getSelection) {" +
          "    txt = window.getSelection().toString();" +
          "  } else if (window.document.getSelection) {" +
          "    txt = window.document.getSelection().toString();" +
          "  } else if (window.document.selection) {" +
          "    txt = window.document.selection.createRange().text;" +
          "  }" +
          IS_ACTIVE_ELEMENT_INPUT_EDITABLE_JS_SOURCE +
          "  return txt === '' && !isActiveElementEditable;" +
          "})();";

  public static final String GET_SELECTED_TEXT_JS_SOURCE = "(function(){" +
          "  var txt;" +
          "  if (window.getSelection) {" +
          "    txt = window.getSelection().toString();" +
          "  } else if (window.document.getSelection) {" +
          "    txt = window.document.getSelection().toString();" +
          "  } else if (window.document.selection) {" +
          "    txt = window.document.selection.createRange().text;" +
          "  }" +
          "  return txt;" +
          "})();";

  public static final String CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_PLUGIN_SCRIPT_GROUP_NAME = "CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_PLUGIN_SCRIPT";
  public static final PluginScript CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_PLUGIN_SCRIPT = new PluginScript(
          PluginScriptsUtil.CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_PLUGIN_SCRIPT_GROUP_NAME,
          PluginScriptsUtil.CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_SOURCE,
          UserScriptInjectionTime.AT_DOCUMENT_START,
          null,
          false,
          null
  );

  // Fushi patch (BUG-4135, see PATCHES.md): close the plugin's floating context menu when the
  // text selection ends. The menu is a native view the plugin draws itself after finishing the
  // system ActionMode, so WebView's own "selection cleared -> finish ActionMode" no longer reaches
  // it; upstream only closes it on a touch tap, a menu-item click, an in-page keydown (texture mode
  // only) or a delayed poll (texture mode only). With hybrid composition and no touch screen
  // (Android TV, D-pad) none of those fire and the menu stays up for the life of the WebView.
  // Runs in the top frame and treats the page as "nothing selected" only when the top document and
  // every same-origin descendant frame have no selection (and no editable element is focused, the
  // same rule as CHECK_CONTEXT_MENU_SHOULD_BE_HIDDEN_JS_SOURCE): a selection that just ended in one
  // frame must not close the menu of a selection still alive in another.
  public static final String FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT_GROUP_NAME = "FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT";
  public static final String FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_SOURCE = "(function(){" +
          "  var isTop = false;" +
          "  try { isTop = (window.top == null || window.top === window); } catch (e) { isTop = false; }" +
          "  if (!isTop || window.__fushiHideMenuOnSelectionEnd === true) { return; }" +
          "  window.__fushiHideMenuOnSelectionEnd = true;" +
          "  var hasSelection = function(win, depth) {" +
          "    try {" +
          "      var sel = win.getSelection ? win.getSelection() : null;" +
          "      if (sel != null && !sel.isCollapsed && String(sel.toString()) !== '') { return true; }" +
          "      if (depth > 8) { return false; }" +
          "      for (var i = 0; i < win.frames.length; i++) {" +
          "        if (hasSelection(win.frames[i], depth + 1)) { return true; }" +
          "      }" +
          "    } catch (e) {}" +
          "    return false;" +
          "  };" +
          "  var onSelectionChange = function() {" +
          "    if (hasSelection(window, 0)) { return; }" +
          IS_ACTIVE_ELEMENT_INPUT_EDITABLE_JS_SOURCE +
          "    if (isActiveElementEditable) { return; }" +
          "    var b = window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + ";" +
          "    if (b == null) { return; }" +
          "    if (typeof b._fushiHideContextMenuCall === 'function') { b._fushiHideContextMenuCall(); } else { b._hideContextMenu(); }" +
          "  };" +
          "  document.addEventListener('selectionchange', onSelectionChange);" +
          // Same-origin child frames fire selectionchange on their own document: hook each child
          // document when its iframe loads (iframe load events reach the top document's capture
          // phase). Opaque-origin (sandboxed) frames throw on contentDocument and stay unhooked.
          "  document.addEventListener('load', function(e) {" +
          "    var t = e.target;" +
          "    if (t == null || t.tagName == null || String(t.tagName).toLowerCase() !== 'iframe') { return; }" +
          "    try {" +
          "      var doc = t.contentDocument;" +
          "      if (doc != null && doc.__fushiHideMenuWatched !== true) {" +
          "        doc.__fushiHideMenuWatched = true;" +
          "        doc.addEventListener('selectionchange', onSelectionChange);" +
          "      }" +
          "    } catch (err) {}" +
          "  }, true);" +
          "})();";
  public static final PluginScript FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT = new PluginScript(
          PluginScriptsUtil.FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT_GROUP_NAME,
          PluginScriptsUtil.FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_SOURCE,
          UserScriptInjectionTime.AT_DOCUMENT_START,
          null,
          false,
          null
  );

  // android Workaround to hide context menu when user emit a keydown event
  public static final String CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_SOURCE = "(function(){" +
          "  document.addEventListener('keydown', function(e) {" +
          // Fushi patch (bridge lock): go through the bridge script's token-attaching wrapper so the
          // call still works after the page locked the bridge. See PATCHES.md.
          "    var b = window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + ";" +
          "    if (b == null) { return; }" +
          "    if (typeof b._fushiHideContextMenuCall === 'function') { b._fushiHideContextMenuCall(); } else { b._hideContextMenu(); }" +
          "  });" +
          "})();";
}
