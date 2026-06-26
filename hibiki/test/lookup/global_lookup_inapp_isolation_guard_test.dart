import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-867 P3b — guards isolating the app-OUTSIDE nested-stack host
/// (global_lookup_host.js + buildStackRenderScript) from the in-app popup.
///
/// The nested stack is built entirely in NEW files
/// (global_lookup_host.js / global_lookup_render.buildStackRenderScript /
/// global_lookup_controller). popup.js / popup.html / popup.css are SHARED with
/// the in-app popup and MUST stay byte-for-byte on their single-frame path. These
/// source guards lock that contract so a later refactor cannot:
///   - leak renderStack / __globalLookupHost / a frames Map into popup.js;
///   - wire host.js into popup.html (it is injected ONLY into the top-level
///     WebView2 document by C++, never loaded in-app);
///   - make the stack renderer call bare renderPopup() instead of renderStack();
///   - add a bridge-killing `sandbox` to the host iframes (a sandbox without
///     allow-same-origin makes the iframe opaque-origin, which throws on
///     contentWindow injection and blocks the document-created adapter).
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('in-app popup zero pollution', () {
    late String popupJs;
    setUpAll(() => popupJs = read('assets/popup/popup.js'));

    test('popup.js must NOT contain the host stack symbols', () {
      expect(popupJs.contains('renderStack'), isFalse,
          reason: 'renderStack lives only in global_lookup_host.js');
      expect(popupJs.contains('__globalLookupHost'), isFalse,
          reason: 'the host singleton must never appear in the in-app popup');
      // (popup.js may legitimately use `new Map()` for its own media cache; the
      // host-only contract is renderStack + __globalLookupHost above.)
    });

    test('popup.html does NOT load global_lookup_host.js', () {
      final String html = read('assets/popup/popup.html');
      expect(html.contains('global_lookup_host.js'), isFalse,
          reason: 'host.js is injected ONLY into the top-level WebView2 '
              'document by C++ (AddScriptToExecuteOnDocumentCreated); the '
              'iframes load popup.html WITHOUT the host script');
    });
  });

  group('stack renderer calls renderStack (not bare renderPopup)', () {
    test('buildStackRenderScript invokes window.__globalLookupHost.renderStack',
        () {
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      // buildStackRenderScript must end by calling the host renderStack entry.
      final int at = render.indexOf('String buildStackRenderScript(');
      expect(at, greaterThan(-1), reason: 'buildStackRenderScript must exist');
      final String fn = render.substring(at);
      expect(fn.contains('window.__globalLookupHost.renderStack('), isTrue,
          reason: 'the stack renderer drives the host renderStack diff, not a '
              'bare single-frame renderPopup()');
    });

    test('buildOverlayRenderScript (single-frame path) is untouched', () {
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      // The single-frame overlay renderer must still exist and still end in the
      // bare renderPopup() call (zero regression to the live overlay window).
      expect(render.contains('String buildOverlayRenderScript('), isTrue);
      final int at = render.indexOf('String buildOverlayRenderScript(');
      final int next = render.indexOf('String buildFrameSettingsJs(');
      final String fn = render.substring(at, next > at ? next : render.length);
      expect(fn.contains('window.renderPopup && window.renderPopup();'), isTrue,
          reason: 'the single-frame overlay must keep its renderPopup() path');
    });
  });

  group('host.js iframe bridge contract', () {
    late String hostJs;
    setUpAll(() => hostJs = read('assets/popup/global_lookup_host.js'));

    test('host iframes carry NO bridge-killing sandbox attribute', () {
      // A sandbox without allow-same-origin forces an opaque origin -> the host
      // can no longer inject per-frame settings via contentWindow (SecurityError)
      // and document-created adapter injection is blocked. The frames are
      // same-origin trusted, so there must be NO setAttribute('sandbox', ...).
      expect(hostJs.contains("setAttribute('sandbox'"), isFalse,
          reason:
              'no sandbox on the same-origin host iframes (bridge contract)');
      expect(hostJs.contains('sandbox ='), isFalse,
          reason: 'no sandbox property assignment either');
    });

    test('host iframes load popup.html (same-origin) for per-frame injection',
        () {
      expect(hostJs.contains('https://hibiki.popup/popup.html'), isTrue,
          reason: 'each frame loads the same-origin popup document so the host '
              'can inject its settings via contentWindow');
    });

    test('host.js is the ONLY place renderStack/frames live (not popup.js)',
        () {
      expect(hostJs.contains('function renderStack('), isTrue);
      expect(hostJs.contains('window.__globalLookupHost'), isTrue);
    });
  });
}
