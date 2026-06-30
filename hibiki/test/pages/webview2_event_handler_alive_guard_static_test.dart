import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guard for BUG-457 / TODO-964 — WebView2 event handlers in the
/// Windows inappwebview fork dereferencing a freed `this` after
/// `~InAppWebView()` (use-after-free, same pattern as TODO-931/BUG-450).
///
/// The crash: a WebView2 event handler captured a bare `[this]`, never saved its
/// `EventRegistrationToken`, and the destructor never `remove_`d it. WebView2's
/// `Stop()`/`Close()` does not synchronously flush in-flight events, so a late
/// callback fires after the object is destroyed and dereferences memory that has
/// already been reused (a cdb dump showed `rcx` holding a `{ "name" ...` JSON
/// message buffer — the WebMessageReceived path). The fix generalizes the
/// TODO-931 pattern: every handler captures a copy of the `alive_` shared flag,
/// guards its entry with `if (!*alive)` before touching `this`, saves a token,
/// and the destructor flips `*alive_=false` then `remove_`s every handler.
///
/// This is a C++ lifecycle bug that can only crash with a live WebView2 native
/// layer (no headless C++ unit harness exists in this repo), so we lock the
/// contract at the strongest feasible layer for CI: a source scan that asserts
/// every registered WebView2 event has a matching deregistration plus an
/// `alive` guard. See docs/bugs/BUG-457-webmessage-uaf.md.
void main() {
  const String forkSrc =
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp';

  // Every WebView2 event whose handler captures `this`. Each must have a paired
  // `remove_<Event>` (deregistration in the destructor) so no late callback can
  // fire after destruction.
  const List<String> guardedEvents = <String>[
    'NavigationStarting',
    'ContentLoading',
    'NavigationCompleted',
    'DocumentTitleChanged',
    'HistoryChanged',
    'WebMessageReceived',
    'NewWindowRequested',
    'WindowCloseRequested',
    'PermissionRequested',
    'WebResourceRequested',
    'DOMContentLoaded',
    'CursorChanged',
  ];

  late String code;

  setUpAll(() {
    final File file = File(forkSrc);
    expect(file.existsSync(), isTrue,
        reason: 'guarded fork file moved or renamed: $forkSrc — update this '
            'test to keep covering every WebView2 event handler');
    code = _stripCppComments(file.readAsStringSync());
  });

  group('BUG-457 · WebView2 handlers deregister + alive-guard on dispose', () {
    for (final String event in guardedEvents) {
      test('$event has both add_ and remove_ (deregistered in destructor)', () {
        expect(code.contains('add_$event('), isTrue,
            reason: '$forkSrc no longer registers $event — remove it from '
                'guardedEvents');
        expect(code.contains('remove_$event('), isTrue,
            reason: '$forkSrc registers add_$event but never remove_$event — '
                'late callbacks can fire after ~InAppWebView() and '
                'use-after-free this (BUG-457/TODO-964)');
      });
    }

    test('DevToolsProtocolEventReceived listeners are deregistered', () {
      // Static (Fetch.requestPaused / Runtime.consoleAPICalled) and dynamic
      // (addDevToolsProtocolEventListener) DevTools receivers all capture this.
      expect(code.contains('add_DevToolsProtocolEventReceived('), isTrue);
      expect(code.contains('remove_DevToolsProtocolEventReceived('), isTrue,
          reason: 'DevTools event receivers capture [this] but are never '
              'remove_d — late callbacks UAF after dispose');
    });

    test('destructor flips the alive flag before deregistering', () {
      // Scope to the destructor body so the public removeDevToolsProtocolEventListener
      // method (which also contains remove_) does not skew the ordering check.
      final int dtorIdx = code.indexOf('InAppWebView::~InAppWebView()');
      expect(dtorIdx, isNonNegative,
          reason: 'destructor not found — fork file restructured');
      final String dtor = code.substring(dtorIdx);

      final int aliveFalseIdx = dtor.indexOf('*alive_ = false');
      expect(aliveFalseIdx, isNonNegative,
          reason: 'destructor must flip *alive_=false so in-flight async '
              'callbacks take the dead branch (TODO-931/964)');
      final int firstRemoveIdx = dtor.indexOf('remove_');
      expect(firstRemoveIdx, isNonNegative,
          reason: 'destructor must deregister handlers (remove_*)');
      expect(aliveFalseIdx, lessThan(firstRemoveIdx),
          reason: '*alive_=false must come before the remove_ calls so any '
              'callback already past the gate still sees the dead flag');
    });

    test('every WebView2 event handler captures the alive flag by copy', () {
      // The whole point: handlers must capture a *copy* of the alive_ shared_ptr
      // (via `alive = alive_` init-capture or a local `auto alive = alive_;`),
      // not deref `this->alive_` (which would itself be the UAF). Assert the
      // copy-capture idiom appears for as many handlers as we hardened.
      final int initCaptureCount = 'alive = alive_'.allMatches(code).length;
      final int localCopyCount = 'auto alive = alive_'.allMatches(code).length;
      // 9 webView handlers + DOMContentLoaded + CursorChanged + dynamic DevTools
      // use init-capture; Fetch/console receivers use the local-copy form.
      expect(initCaptureCount + localCopyCount, greaterThanOrEqualTo(12),
          reason: 'too few handlers capture an alive_ copy — a bare [this] '
              'handler will UAF after ~InAppWebView() (BUG-457/TODO-964). '
              'init-captures=$initCaptureCount local-copies=$localCopyCount');
    });

    test('handlers guard their entry with if (!*alive)', () {
      final int guardCount = RegExp(r'if \(!\*alive\)').allMatches(code).length;
      expect(guardCount, greaterThanOrEqualTo(12),
          reason: 'each hardened handler/async callback must early-return on '
              'the dead branch before touching this (found $guardCount '
              'guards)');
    });
  });
}

/// Strips `//` line comments and `/* ... */` block comments so assertions match
/// real code, not the prose documenting the guards (which mentions the very
/// symbols we assert on, e.g. a commented-out add_ServerCertificateErrorDetected
/// block).
String _stripCppComments(String source) {
  final String noBlock =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlock
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
