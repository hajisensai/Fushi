import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for the Linux / iOS / macOS bridge lock (BUG-3762, contract in
/// `docs/specs/2026-10-23-dictionary-script-sandbox.md`).
///
/// - Linux: vendored `packages/flutter_inappwebview_linux` (C++ + bridge JS).
/// - iOS / macOS: pub-cache whole-file overlays under
///   `ci/patches/hosted/flutter_inappwebview_{ios,macos}-1.1.2/`, copied over the
///   pub cache by `ci/apply-patches.sh` (bootstrap and every CI build job).
///
/// None of this native code is on any Dart test's compile surface, so the guard
/// pins the pieces whose loss silently re-opens the native bridge to sandboxed
/// dictionary iframes: lock interception, a CSPRNG token, the token / main-frame
/// gate on every call, the dedicated success value, and unlock on top-level
/// commit.

/// Test cwd is always `fushi/`; the repository root is its parent.
final Directory _repoRoot = Directory.current.parent;

String _read(String relative) => File(
  '${_repoRoot.path}/$relative',
).readAsStringSync().replaceAll('\r\n', '\n');

/// Returns the brace-balanced body of the function whose signature starts with
/// [signature] (works for both C++ and Swift sources).
String _functionBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing function: $signature');
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

const String _lockedValue = "'fushi-bridge-locked-v1'";

void main() {
  group('Linux (vendored flutter_inappwebview_linux)', () {
    const String root = 'packages/flutter_inappwebview_linux/linux';

    test('bridge script keeps the token in a closure and attaches it to every '
        'call', () {
      final String js = _read('$root/plugin_scripts_js/javascript_bridge_js.h');
      expect(js, contains('var _fushiBridgeToken = null;'));
      expect(
        js,
        isNot(contains('window._fushiBridgeToken')),
        reason: 'the token must never be reachable from window',
      );
      final String post = _functionBody(
        js,
        'function _fushiPostToNative(handlerName, argsJson)',
      );
      expect(post, contains("'_fushiBridgeToken': _fushiBridgeToken"));
      // Both the lock request and ordinary calls go through the token helper.
      expect(js, contains("_fushiPostToNative('_fushiLockBridge', '[]')"));
      expect(
        js,
        contains(
          '_fushiPostToNative(handlerName, '
          '_JSON_stringify(_Array_slice.call(arguments, 1)))',
        ),
      );
      expect(js, contains(_lockedValue));
      expect(
        js,
        isNot(
          contains(
            '_postMessage.call(_UserMessageHandler, {\n'
            "      'handlerName': arguments[0]",
          ),
        ),
        reason: 'the upstream token-less postMessage must be gone',
      );
    });

    test('every plugin script reaches native through callHandler', () {
      // The token is attached by the callHandler wrapper; a plugin script that
      // posted to webkit.messageHandlers directly would bypass it.
      final Directory scripts = Directory(
        '${_repoRoot.path}/$root/plugin_scripts_js',
      );
      for (final FileSystemEntity entity in scripts.listSync()) {
        if (entity is! File || entity.path.endsWith('javascript_bridge_js.h')) {
          continue;
        }
        expect(
          entity.readAsStringSync(),
          isNot(contains('messageHandlers')),
          reason: '${entity.path} must call callHandler, not post directly',
        );
      }
    });

    test('native side issues a CSPRNG token and gates every call', () {
      final String cc = _read('$root/in_app_webview/in_app_webview.cc');
      final String gen = _functionBody(
        cc,
        'bool GenerateBridgeLockToken(std::string* out)',
      );
      expect(gen, contains('getrandom('));
      expect(gen, contains('unsigned char bytes[32]'));
      expect(gen, isNot(contains('mt19937')));
      expect(
        _functionBody(cc, 'bool BridgeLockTokenEquals('),
        contains('diff |='),
      );

      final String handler = _functionBody(
        cc,
        'bool InAppWebView::handleScriptMessageWithReply(',
      );
      final int lock = handler.indexOf(
        'if (handlerName == kFushiLockBridgeHandlerName) {',
      );
      final int gate = handler.indexOf('if (!bridge_lock_token_.empty()) {');
      final int firstInternal = handler.indexOf(
        'if (handlerName == "onConsoleMessage")',
      );
      final int external = handler.indexOf('// === External Handler');
      expect(lock, isNonNegative, reason: 'lock request must be intercepted');
      expect(gate, isNonNegative, reason: 'locked calls must be gated');
      expect(lock < gate, isTrue);
      expect(
        gate < firstInternal && gate < external,
        isTrue,
        reason: 'the gate must run before internal and Dart handlers',
      );

      final String lockBlock = handler.substring(lock, gate);
      expect(
        lockBlock,
        contains('if (!bridge_lock_token_.empty() || !isMainFrame) {'),
        reason: 'already locked / non-main frame must resolve false',
      );
      expect(
        lockBlock,
        contains('ResolveInternalHandlerWithReply(reply, "false")'),
      );
      expect(lockBlock, contains('GenerateBridgeLockToken(&newToken)'));
      expect(lockBlock, contains('webkit_script_message_reply_ref(reply)'));

      final String gateBlock = handler.substring(gate, firstInternal);
      expect(
        gateBlock,
        contains(
          '!isMainFrame || '
          '!BridgeLockTokenEquals(bridge_lock_token_, receivedLockToken)',
        ),
      );
      expect(gateBlock, contains('g_warning('));
      expect(gateBlock, contains('return false;'));
    });

    test('a new top-level document commit clears the token', () {
      final String cc = _read('$root/in_app_webview/in_app_webview.cc');
      final String onLoad = _functionBody(
        cc,
        'void InAppWebView::OnLoadChanged(',
      );
      final int clear = onLoad.indexOf(
        'if (load_event == WEBKIT_LOAD_COMMITTED) {\n'
        '    self->bridge_lock_token_.clear();',
      );
      expect(clear, isNonNegative);
      expect(
        clear < onLoad.indexOf('if (self->channel_delegate_ == nullptr)'),
        isTrue,
        reason: 'clearing must not be skipped when no channel delegate exists',
      );
    });

    test('UPSTREAM.md records the patch', () {
      expect(
        _read('packages/flutter_inappwebview_linux/UPSTREAM.md'),
        contains('_fushiLockBridge'),
      );
    });
  });

  for (final String platform in <String>['ios', 'macos']) {
    group('$platform (ci/patches overlay)', () {
      final String root =
          'ci/patches/hosted/flutter_inappwebview_$platform-1.1.2/'
          '$platform/Classes';

      test('pubspec.lock pins the patched version', () {
        final RegExpMatch? m = RegExp(
          'flutter_inappwebview_$platform:\\n(?:\\s{4}.*\\n)*?'
          '\\s{4}version: "([^"]+)"',
        ).firstMatch(_read('pubspec.lock'));
        expect(m, isNotNull);
        expect(
          m!.group(1),
          '1.1.2',
          reason:
              'version drift makes apply-patches.sh skip the overlay with a '
              'warning: move the overlay to the new version',
        );
      });

      test('bridge script attaches the closure token to every message', () {
        final String js = _read(
          '$root/PluginScriptsJS/JavaScriptBridgeJS.swift',
        );
        expect(
          js,
          contains('let FUSHI_LOCK_BRIDGE_HANDLER_NAME = "_fushiLockBridge"'),
        );
        expect(js, contains('var _fushiBridgeToken = null;'));
        expect(js, isNot(contains('window._fushiBridgeToken')));
        // Direct messageHandlers posts (console, find, web message ports and
        // listeners, callAsyncJavaScript < 14) are covered by the prototype wrap.
        expect(
          js,
          contains(
            "Object.getPrototypeOf(window.webkit.messageHandlers['callHandler'])",
          ),
        );
        expect(
          js,
          contains("tokenBody['_fushiBridgeToken'] = _fushiBridgeToken;"),
        );
        expect(js, contains("_body['_fushiBridgeToken'] = _fushiBridgeToken;"));
        expect(
          js,
          contains(
            "if (_handlerName === '_fushiLockBridge' && !_fushiTokenAttached)",
          ),
          reason: 'without the wrap the lock must be refused, not half-applied',
        );
        expect(js, contains(_lockedValue));
      });

      test('native side gates every message on token and isMainFrame', () {
        final String swift = _read('$root/InAppWebView/InAppWebView.swift');
        final String didReceive = _functionBody(
          swift,
          'public func userContentController(_ userContentController: '
          'WKUserContentController, didReceive message: WKScriptMessage)',
        );
        final int lock = didReceive.indexOf(
          'handlerName == FUSHI_LOCK_BRIDGE_HANDLER_NAME',
        );
        final int gate = didReceive.indexOf(
          'if let lockToken = fushiBridgeLockToken {',
        );
        final int firstDispatch = didReceive.indexOf(
          'if ["consoleLog", "consoleDebug"',
        );
        expect(lock, isNonNegative);
        expect(gate, isNonNegative);
        expect(
          lock < gate && gate < firstDispatch,
          isTrue,
          reason: 'lock handling, then the gate, then all dispatch',
        );
        final String gateBlock = didReceive.substring(gate, firstDispatch);
        expect(gateBlock, contains('if !message.frameInfo.isMainFrame {'));
        expect(
          gateBlock,
          contains(
            'InAppWebView.fushiBridgeLockTokenMatches(lockToken, receivedToken)',
          ),
        );

        final String handle = _functionBody(
          swift,
          'private func handleFushiLockBridgeRequest(',
        );
        expect(handle, contains('guard message.frameInfo.isMainFrame else'));
        expect(handle, contains('message.world == WKContentWorld.page'));
        expect(handle, contains('var json = "false"'));
        expect(handle, contains('if fushiBridgeLockToken == nil {'));

        expect(
          _functionBody(swift, 'static func generateFushiBridgeLockToken()'),
          contains(
            'SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)',
          ),
        );
        expect(swift, contains('import Security'));
      });

      test('top-level commit and content-process death clear the token', () {
        final String swift = _read('$root/InAppWebView/InAppWebView.swift');
        expect(
          _functionBody(swift, 'didCommit navigation: WKNavigation!)'),
          contains('fushiBridgeLockToken = nil'),
        );
        expect(
          _functionBody(
            swift,
            'public func webViewWebContentProcessDidTerminate(',
          ),
          contains('fushiBridgeLockToken = nil'),
        );
      });
    });
  }
}
