import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for the Android bridge lock (BUG-3762, contract in
/// `docs/specs/2026-10-23-dictionary-script-sandbox.md`). The lock lives in the
/// vendored `flutter_inappwebview_android` plugin; losing any piece of it
/// silently re-opens the native bridge to sandboxed dictionary iframes.
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

void main() {
  test(
    'native side issues a SecureRandom token and verifies it on every call',
    () {
      final String bridge = _read('webview/JavaScriptBridgeInterface.java');

      expect(bridge, contains('new SecureRandom()'));
      expect(bridge, contains('FUSHI_BRIDGE_TOKEN_BYTES = 32'));
      expect(bridge, contains('MessageDigest.isEqual('));

      final String lock = _methodBody(
        bridge,
        'public String _fushiLockBridge()',
      );
      expect(
        lock,
        contains('if (fushiBridgeToken != null)'),
        reason: 'an already-locked bridge must refuse a second lock',
      );
      expect(lock, contains('return null;'));

      // Both upstream token-less entry points funnel into the checked path.
      expect(
        _methodBody(bridge, 'public void _callHandler('),
        contains(
          'fushiDispatchCallHandler(handlerName, _callHandlerID, args, null)',
        ),
      );
      expect(
        _methodBody(bridge, 'public void _hideContextMenu()'),
        contains('_fushiHideContextMenu(null)'),
      );

      final String dispatch = _methodBody(
        bridge,
        'private void fushiDispatchCallHandler(',
      );
      final int check = dispatch.indexOf('fushiAcceptsBridgeCall(token');
      final int post = dispatch.indexOf('handler.post(');
      expect(check, isNonNegative);
      expect(post, isNonNegative);
      expect(
        check,
        lessThan(post),
        reason: 'the token must be checked before anything is dispatched',
      );
      expect(
        dispatch,
        contains('FUSHI_LOCK_BRIDGE_HANDLER_NAME.equals(handlerName)'),
      );

      final String hide = _methodBody(
        bridge,
        'public void _fushiHideContextMenu(',
      );
      expect(hide, contains('fushiAcceptsBridgeCall(token'));

      final String accepts = _methodBody(
        bridge,
        'private boolean fushiAcceptsBridgeCall(',
      );
      expect(accepts, contains('Log.w('));
      expect(
        accepts,
        contains('if (fushiBridgeToken == null)'),
        reason: 'unlocked must keep upstream behaviour',
      );

      expect(
        _methodBody(bridge, 'public void dispose()'),
        contains('fushiResetBridgeLock()'),
      );
    },
  );

  test('bridge script intercepts _fushiLockBridge and keeps the token private', () {
    final String js = _read('plugin_scripts_js/JavaScriptBridgeJS.java');
    final String bridge = _read('webview/JavaScriptBridgeInterface.java');

    expect(
      bridge,
      contains('FUSHI_LOCK_BRIDGE_HANDLER_NAME = "_fushiLockBridge"'),
    );
    expect(
      js,
      contains('FUSHI_BRIDGE_LOCKED_VALUE = "fushi-bridge-locked-v1"'),
    );
    expect(
      js,
      contains('JavaScriptBridgeInterface.FUSHI_LOCK_BRIDGE_HANDLER_NAME'),
    );
    expect(
      js,
      contains('"(function() {"'),
      reason: 'token must live in an IIFE closure, not on window',
    );
    expect(js, contains('var _fushiBridgeToken = null;'));
    expect(js, isNot(contains('window._fushiBridgeToken')));
    expect(js, isNot(contains('._fushiBridgeToken')));
    expect(
      js,
      contains(
        '_fushiIsTopFrame = (window.top == null || window.top === window)',
      ),
    );
    expect(
      js,
      contains(
        'if (!_fushiIsTopFrame || _fushiBridgeToken != null) { resolve(false); return; }',
      ),
    );
    expect(js, contains("resolve('\" + FUSHI_BRIDGE_LOCKED_VALUE + \"')"));
    expect(
      js,
      contains(
        '_fushiBridge._fushiCallHandler(handlerName, callHandlerID, argsJson, _fushiBridgeToken)',
      ),
    );
    expect(
      js,
      contains('_fushiBridge._fushiHideContextMenu(_fushiBridgeToken)'),
    );

    // callHandler must route through the token-attaching invoker, never call
    // the raw Java entry point itself.
    final int wrapper = js.indexOf('_fushiBridge.callHandler = function()');
    expect(wrapper, isNonNegative);
    final int wrapperEnd = js.indexOf(
      'window.top != null && window.top !== window',
      wrapper,
    );
    final String wrapperBody = js.substring(wrapper, wrapperEnd);
    expect(wrapperBody, contains('_fushiBridge._fushiInvoke('));
    expect(wrapperBody, isNot(contains('._callHandler(')));
  });

  test(
    'every plugin JS->native call goes through the token-attaching wrappers',
    () {
      final Directory scripts = Directory('$_pluginRoot/plugin_scripts_js');
      final Directory root = Directory(_pluginRoot);
      final RegExp rawCall = RegExp(r'\._(callHandler|hideContextMenu)\(');
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.java')) continue;
        final String normalized = entity.path.replaceAll('\\', '/');
        if (normalized.endsWith('plugin_scripts_js/JavaScriptBridgeJS.java')) {
          continue; // the wrappers themselves
        }
        if (normalized.endsWith('webview/JavaScriptBridgeInterface.java')) {
          continue; // native definitions
        }
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          if (!rawCall.hasMatch(lines[i])) continue;
          // The keydown workaround keeps a token-less fallback for a bridge
          // script that failed to install; it must prefer the wrapper.
          if (lines[i].contains('_fushiHideContextMenuCall')) continue;
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
      expect(scripts.existsSync(), isTrue);
      expect(
        offenders,
        isEmpty,
        reason: 'raw JS->native bridge calls bypass the bridge lock token',
      );

      expect(
        _read('plugin_scripts_js/PluginScriptsUtil.java'),
        contains('b._fushiHideContextMenuCall()'),
      );
    },
  );

  test('a new top-level document clears the lock', () {
    for (final String client in <String>[
      'webview/in_app_webview/InAppWebViewClient.java',
      'webview/in_app_webview/InAppWebViewClientCompat.java',
    ]) {
      final String source = _read(client);
      expect(
        _methodBody(source, 'public void onPageStarted('),
        contains('javaScriptBridgeInterface.fushiResetBridgeLock()'),
        reason: '$client must reset the bridge lock on main-frame navigation',
      );
    }
  });
}
