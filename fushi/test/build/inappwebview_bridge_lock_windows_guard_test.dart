import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for the Windows bridge lock (BUG-3705, contract in
/// `docs/specs/2026-10-23-dictionary-script-sandbox.md`).
///
/// Two independent Windows hosts implement the same `_fushiLockBridge`
/// semantics:
///
/// - A. vendored `packages/flutter_inappwebview_windows` (every in-app
///   `InAppWebView`, incl. the in-app dictionary popup);
/// - B. the app-external global lookup overlay
///   (`fushi/windows/runner/global_lookup_window.cpp` + the injected host
///   `fushi/assets/popup/global_lookup_host.js`), where the locking popup
///   document lives in a same-origin iframe and native only hears the host's
///   top-level `chrome.webview.postMessage`.
///
/// None of the native code is on any Dart test's compile surface, so this guard
/// pins the pieces whose loss silently re-opens the native bridge to sandboxed
/// dictionary iframes: lock interception, a CSPRNG token, the token + Source
/// gate on every message, the dedicated success value, and unlock on a new
/// top-level document.

/// Test cwd is always `fushi/`; the repository root is its parent.
final Directory _repoRoot = Directory.current.parent;

String _read(String relative) => File(
  '${_repoRoot.path}/$relative',
).readAsStringSync().replaceAll('\r\n', '\n');

/// Returns the brace-balanced body of the function whose signature starts with
/// [signature] (C++ and JavaScript).
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

/// The body of the lambda registered with `add_<event>(` (its first `{` after
/// the registration opens the lambda body: the capture lists hold no braces).
String _handlerBody(String source, String registration) {
  expect(
    source.indexOf(registration),
    isNonNegative,
    reason: 'missing registration: $registration',
  );
  return _functionBody(source, registration);
}

void main() {
  group('A. vendored flutter_inappwebview_windows', () {
    const String root = 'packages/flutter_inappwebview_windows/windows';

    test('bridge script intercepts the lock, keeps the token in a closure and '
        'attaches it to every call', () {
      final String js = _read('$root/plugin_scripts_js/javascript_bridge_js.h');
      expect(
        js,
        contains(
          'const std::string FUSHI_BRIDGE_LOCK_HANDLER_NAME = '
          '"_fushiLockBridge";',
        ),
      );
      expect(
        js,
        contains(
          'const std::string FUSHI_BRIDGE_LOCKED_VALUE = '
          '"fushi-bridge-locked-v1";',
        ),
      );
      expect(js, contains('var _fushiBridgeToken = null;'));
      expect(
        js,
        isNot(contains('window._fushiBridgeToken')),
        reason: 'the token must never be reachable from window',
      );
      final String post = _functionBody(
        js,
        'function _fushiPostCallHandler(handlerName, callHandlerID, argsJson)',
      );
      expect(post, contains("body['_fushiBridgeToken'] = _fushiBridgeToken;"));
      expect(post, contains('window.chrome.webview.postMessage('));
      // The ONLY direct callHandler post is the token helper; the lock request
      // itself is the one other postMessage, and it carries no handler args.
      expect(
        'window.chrome.webview.postMessage('.allMatches(js).length,
        2,
        reason: 'every JS->native post must go through _fushiPostCallHandler',
      );
      expect(js, contains("'name': ')JS\" + FUSHI_BRIDGE_LOCK_HANDLER_NAME"));
      // Only the top frame may lock, once per document.
      expect(js, contains('isTop = (window.top === window);'));
      expect(js, contains('if (!isTop || _fushiLockState !== 0) {'));
      // Calls issued while the lock is in flight are queued, then flushed with
      // the token (native rejects tokenless messages once it locked).
      expect(js, contains('if (_fushiLockState === 1) {'));
      expect(
        js,
        contains(
          '_fushiQueue.push([handlerName, _callHandlerID, '
          'argsJson]);',
        ),
      );
      final String finish = _functionBody(
        js,
        'function _fushiFinishLock(token)',
      );
      expect(finish, contains('_fushiPostCallHandler(queued[i][0]'));
      expect(
        finish,
        contains(
          "resolve(_fushiLockState === 2 ? ')JS\" + "
          'FUSHI_BRIDGE_LOCKED_VALUE',
        ),
      );
      expect(
        js,
        contains(
          'bridge._fushiLockResult = function(callHandlerID, '
          'token) {',
        ),
      );
    });

    test('native mints a BCryptGenRandom token and refuses a second lock', () {
      final String cpp = _read('$root/in_app_webview/in_app_webview.cpp');
      final String gen = _functionBody(
        cpp,
        'bool fushiGenerateBridgeLockToken(std::string* out)',
      );
      expect(gen, contains('unsigned char bytes[32]'));
      expect(gen, contains('BCryptGenRandom('));
      expect(gen, contains('BCRYPT_USE_SYSTEM_PREFERRED_RNG'));
      expect(cpp, contains('#pragma comment(lib, "bcrypt.lib")'));

      final String lock = _functionBody(
        cpp,
        'void InAppWebView::handleBridgeLockRequest(',
      );
      expect(lock, contains('if (!bridgeLockToken_.empty()) {'));
      expect(lock, contains('source.rfind(L"about:srcdoc", 0) == 0'));
      expect(lock, contains('bridgeLockSource_ = source;'));
      expect(lock, contains('._fushiLockResult('));
    });

    test('every message on a locked WebView needs the token and the locking '
        'document as Source', () {
      final String cpp = _read('$root/in_app_webview/in_app_webview.cpp');
      final String received = _handlerBody(cpp, 'add_WebMessageReceived(');
      expect(received, contains('args->get_Source(&sourceRaw)'));
      expect(
        received,
        contains('name.compare(FUSHI_BRIDGE_LOCK_HANDLER_NAME) == 0'),
      );
      expect(received, contains('handleBridgeLockRequest(messageSource,'));
      // The gate runs BEFORE any dispatch to Dart.
      final int gate = received.indexOf('isBridgeMessageAuthorized(');
      final int dispatch = received.indexOf(
        'channelDelegate->onCallJsHandler(',
      );
      expect(gate, isNonNegative);
      expect(dispatch, greaterThan(gate));
      expect(received, contains('"_fushiBridgeToken"'));

      final String authorized = _functionBody(
        cpp,
        'bool InAppWebView::isBridgeMessageAuthorized(',
      );
      expect(
        authorized,
        contains('fushiTokensEqual(*token, bridgeLockToken_)'),
      );
      expect(authorized, contains('source == bridgeLockSource_'));
      expect(authorized, contains('webView->get_Source(&topSource)'));
      expect(cpp, contains('fushiBridgeLockWarn("dropped JS->native message'));
    });

    test('a new top-level document unlocks (ContentLoading)', () {
      final String cpp = _read('$root/in_app_webview/in_app_webview.cpp');
      final String loading = _handlerBody(cpp, 'add_ContentLoading(');
      expect(loading, contains('bridgeLockToken_.clear();'));
      expect(loading, contains('bridgeLockSource_.clear();'));
      final String header = _read('$root/in_app_webview/in_app_webview.h');
      expect(header, contains('std::string bridgeLockToken_;'));
    });
  });

  group('B. app-external global lookup overlay', () {
    test(
      'native locks once per host document with a BCryptGenRandom token',
      () {
        final String cpp = _read(
          'fushi/windows/runner/global_lookup_window.cpp',
        );
        final String gen = _functionBody(
          cpp,
          'bool GenerateBridgeLockToken(std::string* out)',
        );
        expect(gen, contains('unsigned char bytes[32]'));
        expect(gen, contains('BCryptGenRandom('));
        expect(gen, contains('BCRYPT_USE_SYSTEM_PREFERRED_RNG'));
        expect(
          cpp,
          contains('L"https://hibiki.popup/global_lookup_host.html";'),
        );

        final String lock = _functionBody(
          cpp,
          'void GlobalLookupWindow::HandleBridgeLockRequest(',
        );
        expect(lock, contains('if (!bridge_lock_token_.empty()) {'));
        expect(lock, contains('!IsExpectedBridgeLockSource(source)'));
        expect(lock, contains('bridge_lock_source_ = source;'));
        expect(lock, contains('window.__fushiBridgeLockResult('));
      },
    );

    test('locked messages need the token and the host document Source, and '
        'the gate precedes every native consumer', () {
      final String cpp = _read('fushi/windows/runner/global_lookup_window.cpp');
      final String received = _handlerBody(
        cpp,
        'webview_->add_WebMessageReceived(',
      );
      expect(received, contains('args->get_Source(&source_raw)'));
      expect(received, contains('bridge_handler == "_fushiLockBridge"'));
      final int lock = received.indexOf(
        'HandleBridgeLockRequest(message_source)',
      );
      final int gate = received.indexOf(
        'AuthorizeLockedBridgeMessage(message_source, &body)',
      );
      final int firstConsumer = received.indexOf(
        '"\\"handler\\":\\"shellRects\\""',
      );
      final int dart = received.indexOf('message_cb_(body,');
      expect(lock, isNonNegative);
      expect(gate, greaterThan(lock));
      expect(firstConsumer, greaterThan(gate));
      expect(dart, greaterThan(gate));

      // Sliced up to the next definition: the body builds a `"{\""` literal,
      // so a plain brace count cannot find its end.
      final int authorizeStart = cpp.indexOf(
        'bool GlobalLookupWindow::AuthorizeLockedBridgeMessage(',
      );
      expect(authorizeStart, isNonNegative);
      final String authorize = cpp.substring(
        authorizeStart,
        cpp.indexOf('\nvoid GlobalLookupWindow::', authorizeStart),
      );
      expect(authorize, contains('source != bridge_lock_source_'));
      expect(
        authorize,
        contains('ReadTopLevelJsonString(*body, kBridgeTokenField, &token)'),
      );
      expect(
        authorize,
        contains('BridgeTokensEqual(token, bridge_lock_token_)'),
      );
      expect(authorize, contains('[bridge-lock][warn] dropped message'));
    });

    test('ConfigureWebView and every new top-level document unlock', () {
      final String cpp = _read('fushi/windows/runner/global_lookup_window.cpp');
      final int configure = cpp.indexOf(
        'void GlobalLookupWindow::ConfigureWebView() {',
      );
      final int registration = cpp.indexOf('webview_->add_ContentLoading(');
      final int nextDefinition = cpp.indexOf(
        '\nvoid GlobalLookupWindow::',
        configure + 1,
      );
      expect(configure, isNonNegative);
      expect(registration, greaterThan(configure));
      expect(
        registration,
        lessThan(nextDefinition),
        reason:
            'the unlock handler must be registered by ConfigureWebView, '
            'the single funnel for every (re)built surface',
      );
      final String loading = _handlerBody(cpp, 'webview_->add_ContentLoading(');
      expect(loading, contains('bridge_lock_token_.clear();'));
      expect(loading, contains('bridge_lock_source_.clear();'));
    });

    test('host JS holds the token, stamps every top-level post and answers the '
        'popup realm with the dedicated value', () {
      final String js = _read('fushi/assets/popup/global_lookup_host.js');
      expect(js, contains("var BRIDGE_LOCK_HANDLER = '_fushiLockBridge';"));
      expect(
        js,
        contains("var BRIDGE_LOCKED_VALUE = 'fushi-bridge-locked-v1';"),
      );
      expect(
        js,
        isNot(contains('window.__fushiBridgeToken')),
        reason: 'the token must never be reachable from window',
      );
      final String locked = _functionBody(
        js,
        'function bridgeLockedPost(message)',
      );
      expect(locked, contains('message.handler === BRIDGE_LOCK_HANDLER'));
      expect(locked, contains("bridgeLock.state === 'pending'"));
      expect(locked, contains('bridgeLock.queue.push(message);'));
      expect(
        locked,
        contains('var stamped = {__fushiBridgeToken: bridgeLock.token};'),
      );
      // The top-level postMessage itself is replaced, so host, popup frames,
      // native-injected scripts and the top adapter all get stamped.
      expect(js, contains('webview.postMessage = bridgeLockedPost;'));
      expect(
        js,
        contains('window.__fushiBridgeLockResult = function (token) {'),
      );
      final String answer = _functionBody(
        js,
        'function answerFrameBridgeLock(win, message, realmLock)',
      );
      expect(answer, contains('JSON.stringify(BRIDGE_LOCKED_VALUE)'));
      expect(answer, contains('if (realmLock.requested) {'));
      // The popup realm's lock request is intercepted before the parked-realm
      // gate and before any forwarding.
      final String wrap = _functionBody(js, 'function wrapFrameBridge(record)');
      final int intercept = wrap.indexOf(
        'answerFrameBridgeLock(win, message, realmLock);',
      );
      final int parked = wrap.indexOf('if (!record.active) {');
      final int forward = wrap.indexOf('topPost(out);');
      expect(intercept, isNonNegative);
      expect(parked, greaterThan(intercept));
      expect(forward, greaterThan(intercept));
    });
  });
}
