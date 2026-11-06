import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for BUG-4135 (feedback 5Sj-bzv_rm): the vendored
/// `flutter_inappwebview_android` draws its own floating context menu (the
/// dictionary popup's search / copy) after finishing the system ActionMode, and
/// under Hybrid Composition upstream gives that menu no close path tied to the
/// selection ending. On Android TV (no touch) the menu then never closes and the
/// reused popup WebView keeps it over the popup's buttons. The fix lives in Java
/// and a plugin JS string, which no Dart test can execute, so this guard pins
/// every piece of the close path.
const String _pluginRoot =
    '../third_party/flutter_inappwebview_android/android/src/main/java/'
    'com/pichillilorenzo/flutter_inappwebview_android';

String _read(String relativePath) =>
    File('$_pluginRoot/$relativePath').readAsStringSync();

/// Returns the body of the Java method whose signature starts with [signature].
String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing method: $signature');
  final int open = source.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced braces in $signature');
}

/// Returns the Java string-concatenation expression assigned to [constant].
String _constantExpression(String source, String constant) {
  final int start = source.indexOf('$constant = ');
  expect(start, isNonNegative, reason: 'missing constant: $constant');
  final int end = source.indexOf(';\n', start);
  return source.substring(start, end);
}

void main() {
  test('selection-end script hides the menu through the token-aware call', () {
    final String util = _read('plugin_scripts_js/PluginScriptsUtil.java');
    final String js = _constantExpression(
      util,
      'FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_SOURCE',
    );

    expect(
      js,
      contains("addEventListener('selectionchange', onSelectionChange)"),
    );
    // Same-origin child frames report selectionchange on their own document.
    expect(js, contains("addEventListener('load'"));
    expect(js, contains('contentDocument'));
    expect(
      js,
      contains("doc.addEventListener('selectionchange', onSelectionChange)"),
    );
    // Only a page with no selection anywhere reachable closes the menu, so a
    // selection ending in one frame cannot close another frame's live menu.
    expect(js, contains('win.frames'));
    expect(js, contains('isCollapsed'));
    final String handler = js.substring(js.indexOf('var onSelectionChange'));
    final int guard = handler.indexOf(
      'if (hasSelection(window, 0)) { return; }',
    );
    final int hide = handler.indexOf('b._fushiHideContextMenuCall()');
    expect(guard, isNonNegative);
    expect(hide, isNonNegative);
    expect(guard, lessThan(hide));
    // Same editable-element rule as upstream's hide check.
    expect(js, contains('IS_ACTIVE_ELEMENT_INPUT_EDITABLE_JS_SOURCE'));
    expect(js, contains('if (isActiveElementEditable) { return; }'));
    // Installed once per document, from the top frame only.
    expect(js, contains('window.top === window'));
    // Event driven: no polling / timers in the close path.
    expect(js, isNot(contains('setTimeout')));
    expect(js, isNot(contains('setInterval')));

    expect(
      util,
      contains(
        'FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT = new PluginScript(',
      ),
    );
  });

  test('the script is installed in every composition mode', () {
    final String webView = _read('webview/in_app_webview/InAppWebView.java');
    const String install =
        'userContentController.addPluginScript(PluginScriptsUtil.'
        'FUSHI_HIDE_CONTEXT_MENU_ON_SELECTION_END_JS_PLUGIN_SCRIPT);';
    final int at = webView.indexOf(install);
    expect(
      at,
      isNonNegative,
      reason: 'selection-end close script not installed',
    );

    // Not nested inside the texture-only `if (!customSettings.useHybridComposition)`
    // block that guards the keydown workaround.
    const String textureOnly =
        'if (!customSettings.useHybridComposition) {\n'
        '      userContentController.addPluginScript(PluginScriptsUtil.'
        'CHECK_GLOBAL_KEY_DOWN_EVENT_TO_HIDE_CONTEXT_MENU_JS_PLUGIN_SCRIPT);\n'
        '    }';
    final int block = webView.indexOf(textureOnly);
    expect(block, isNonNegative);
    expect(at, greaterThan(block + textureOnly.length));
  });

  test('native hide stays a no-op without a menu', () {
    final String bridge = _read('webview/JavaScriptBridgeInterface.java');
    final String hide = _methodBody(
      bridge,
      'public void _fushiHideContextMenu(',
    );
    expect(hide, contains('inAppWebView.floatingContextMenu != null'));
  });

  test('a new top-level document closes the menu in both clients', () {
    for (final String client in <String>[
      'webview/in_app_webview/InAppWebViewClient.java',
      'webview/in_app_webview/InAppWebViewClientCompat.java',
    ]) {
      final String body = _methodBody(
        _read(client),
        'public void onPageStarted(',
      );
      expect(
        body,
        contains(
          'if (webView.floatingContextMenu != null) {\n'
          '      webView.hideContextMenu();',
        ),
        reason: '$client must close the floating menu on page start',
      );
    }
  });
}
