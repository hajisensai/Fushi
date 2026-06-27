import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-867 P3b/P3c — guards isolating the app-OUTSIDE nested-stack host
/// (global_lookup_host.js + buildStackRenderScript) from the in-app popup.
///
/// The nested stack is built entirely in NEW files
/// (global_lookup_host.js / global_lookup_host.html /
/// global_lookup_render.buildStackRenderScript / global_lookup_controller).
/// popup.js / popup.html / popup.css are SHARED with the in-app popup and MUST
/// stay byte-for-byte on their single-frame path. These source guards lock that
/// contract so a later refactor cannot:
///   - leak renderStack / __globalLookupHost / a frames Map into popup.js;
///   - wire host.js into popup.html OR global_lookup_host.html (it is injected
///     ONLY into the top-level WebView2 document by C++, never <script>-loaded);
///   - resurrect a TOP-LEVEL direct renderPopup (P3c retired
///     buildOverlayRenderScript: the single frame is stack depth 1 rendered
///     through window.__globalLookupHost.renderStack, like a nested card);
///   - run host.js on a child iframe (it must bail via window.top!==window.self);
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

    test(
        'single-frame path goes through renderStack (no top-level direct render)',
        () {
      // TODO-867 P3c: the single-frame TOP-LEVEL direct-render path
      // (buildOverlayRenderScript) is RETIRED. The top document is now
      // global_lookup_host.html (zero popup.js instance), so the single frame is
      // stack depth 1 rendered through the host iframe — NOT a bare top-level
      // renderPopup(). These assertions lock that new contract (a refactor must
      // not resurrect a top-level direct render).
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(render.contains('String buildOverlayRenderScript('), isFalse,
          reason: 'the retired top-level direct-render entry must not exist '
              '(single-frame = stack depth 1 via renderStack)');
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      // The controller must not call renderPopup() against the TOP-LEVEL
      // document anymore (only the in-iframe buildFrameSettingsJs body, which
      // lives in render.dart, may call renderPopup inside its own realm).
      expect(controller.contains('window.renderPopup'), isFalse,
          reason:
              'the controller must not direct-render window.renderPopup at the '
              'top level — single-frame goes through _renderStack -> renderStack '
              '(only the in-iframe buildFrameSettingsJs body may)');
      expect(controller.contains('_renderResult'), isFalse,
          reason: 'the retired single-frame _renderResult helper must be gone');
    });
  });

  group('P3c top-level host wiring', () {
    test('global_lookup_host.html links popup.css but NOT popup.js', () {
      final String html = read('assets/popup/global_lookup_host.html');
      expect(html.contains('popup.css'), isTrue,
          reason:
              'the host document needs popup.css for the shell/card chrome');
      expect(html.contains('popup.js'), isFalse,
          reason: 'the top-level host holds ZERO popup.js instance — popup.js '
              'lives only inside each per-layer iframe (popup.html)');
      expect(html.contains('global_lookup_host.js'), isFalse,
          reason: 'host.js is C++-injected only (AddScriptToExecuteOn'
              'DocumentCreated), never <script>-referenced in the host document');
    });

    test('host.js only installs on the TOP-LEVEL frame (window.top guard)', () {
      final String hostJs = read('assets/popup/global_lookup_host.js');
      expect(hostJs.contains('window.top !== window.self'), isTrue,
          reason:
              'AddScriptToExecuteOnDocumentCreated runs on every frame incl. '
              'child iframes; host.js must bail on sub-frames so only the host '
              'document installs the frames Map / renderStack');
    });

    test('cpp navigates to global_lookup_host.html (not popup.html)', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(
          cpp.contains(
              'Navigate(L"https://hibiki.popup/global_lookup_host.html")'),
          isTrue,
          reason:
              'the bare window top document must be the host, not popup.html');
      expect(
          cpp.contains('Navigate(L"https://hibiki.popup/popup.html")'), isFalse,
          reason: 'popup.html is the per-iframe document now, not the top doc');
    });

    test('cpp loads + injects host.js at document start', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('LoadHostScript'), isTrue,
          reason:
              'host.js is read from disk like the adapter (LoadHostScript)');
      // host.js injected via AddScriptToExecuteOnDocumentCreated (the `host`
      // wide-string built from LoadHostScript()).
      expect(cpp.contains('AddScriptToExecuteOnDocumentCreated(host.c_str()'),
          isTrue,
          reason: 'host.js must be injected at document start so '
              'window.__globalLookupHost exists before navigation');
      final String h = read('windows/runner/global_lookup_window.h');
      expect(h.contains('std::wstring LoadHostScript() const;'), isTrue,
          reason: 'the header must declare LoadHostScript');
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
