import 'dart:convert';
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

  group('P3c nested-stack host wiring (C1/C3/E2/D2/E1)', () {
    late String hostJs;
    late String cpp;
    late String controller;
    late String render;
    late String channel;
    setUpAll(() {
      hostJs = read('assets/popup/global_lookup_host.js');
      cpp = read('windows/runner/global_lookup_window.cpp');
      controller = read('lib/src/lookup/global_lookup_controller.dart');
      render = read('lib/src/lookup/global_lookup_render.dart');
      channel = read('lib/src/lookup/global_lookup_channel.dart');
    });

    test('C1: host re-anchors a child onLinkClick rect + stamps the frame id',
        () {
      expect(hostJs.contains('function anchorRectToScreen('), isTrue,
          reason:
              'the host converts a child LOCAL rect to window-local CSS px');
      expect(hostJs.contains('function transformFrameMessage('), isTrue);
      expect(hostJs.contains('__frameId'), isTrue,
          reason: 'every bubbled message is stamped with its source frame id');
      expect(hostJs.contains('function wrapFrameBridge('), isTrue,
          reason: 'the host wraps each iframe chrome.webview.postMessage');
      expect(hostJs.contains('var FRAME_CONTENT_TOP = 0;'), isTrue,
          reason: 'Hibiki iframe fills its shell -> content-top offset is 0 '
              '(not hoshi 74); explicit + testable per plan section 8');
    });

    test('C3: host dismisses on a backdrop pointerdown / forwarded click', () {
      expect(hostJs.contains('function onHostPointerDown('), isTrue,
          reason:
              'capture-phase pointerdown outside all shells dismisses root');
      expect(hostJs.contains("postToHost('dismissPopupAt', [0])"), isTrue,
          reason: 'a click outside all shells dismisses the root (index 0)');
      expect(hostJs.contains('function handleGlobalClick('), isTrue,
          reason: 'E2: C++ forwards a global click; the host hit-tests shells');
      final String c = controller;
      expect(c.contains('_layerIndexForFrameId('), isTrue,
          reason:
              'controller maps a stamped tapOutside to its layer index (C3)');
      expect(
          c.contains('closeChildPopupsAndClearSelection(_stack, layerIndex)'),
          isTrue,
          reason: 'tapping a layer closes its children (point a layer -> close '
              'the cards above it)');
    });

    test(
        'C4/E2: MouseHookProc no longer unconditionally hides; forwards inside',
        () {
      // The old coarse "PtInRect outside -> Hide" is replaced: outside the whole
      // window -> Hide; inside -> ForwardGlobalClickToHost (the host owns the
      // per-shell hit-test). Lock that the forward path exists and the hook is
      // not a bare always-hide anymore.
      expect(cpp.contains('ForwardGlobalClickToHost'), isTrue,
          reason: 'a click inside the stack window is forwarded to the host');
      expect(cpp.contains('handleGlobalClick('), isTrue,
          reason: 'C++ calls the host hit-test entry via ExecuteScript');
      // The MouseHookProc body must reach the forward branch (else-of PtInRect),
      // i.e. it is no longer "PtInRect -> Hide" with nothing else.
      final int hookAt = cpp.indexOf('GlobalLookupWindow::MouseHookProc');
      expect(hookAt, greaterThan(-1));
      final String hookBody =
          cpp.substring(hookAt, cpp.indexOf('CallNextHookEx', hookAt));
      expect(hookBody.contains('ForwardGlobalClickToHost'), isTrue,
          reason: 'the hook forwards an in-window click instead of hiding it');
    });

    test('D2/E1: host reports a union bbox; Dart reveals the window to it', () {
      expect(hostJs.contains('function measureAndReport('), isTrue);
      expect(hostJs.contains("postToHost('overlaySize'"), isTrue,
          reason: 'the host reports the union bbox as overlaySize');
      expect(hostJs.contains('LAYER_ID'), isTrue);
      expect(render.contains('computeFrameRect('), isTrue,
          reason: 'the stack renderer computes real cascade geometry');
      expect(render.contains('Rect? anchorRect'), isTrue,
          reason: 'each frame payload carries its anchor rect (C2)');
      expect(channel.contains("invokeMethod<void>('revealStack'"), isTrue,
          reason: 'E1: a revealStack channel reveals/resizes to the bbox');
      expect(cpp.contains('void GlobalLookupWindow::RevealStack('), isTrue,
          reason:
              'native RevealStack positions + sizes the window to the bbox');
    });

    test('D1: two-flag reveal gate hides a shell until content + geometry', () {
      // The gate is a declarative CSS attribute selector (single visibility
      // source) flipped by two independent flags; JS never sets inline
      // visibility on the shell, so the gate cannot be bypassed by a stray
      // style write.
      expect(hostJs.contains("var ATTR_CONTENT_READY = 'data-content-ready';"),
          isTrue,
          reason: 'content-ready flag attribute is named + explicit');
      expect(hostJs.contains("var ATTR_REVEAL_READY = 'data-reveal-ready';"),
          isTrue,
          reason: 'reveal-ready flag attribute is named + explicit');
      expect(hostJs.contains('function ensureStyle('), isTrue,
          reason:
              'host injects the reveal-gate stylesheet (it owns the shell)');
      expect(hostJs.contains('.global-lookup-frame-shell{visibility:hidden'),
          isTrue,
          reason: 'shells default hidden so an empty frame never flashes');
      expect(hostJs.contains('function observeContent('), isTrue,
          reason: 'host watches the same-origin iframe DOM for content-ready '
              '(no popup.js change)');
      expect(hostJs.contains('window.MutationObserver'), isTrue,
          reason: 'content-ready uses a MutationObserver on contentDocument');
      // The shell visibility must NOT be driven by an inline style write — only
      // the two data-* attributes flip (the CSS selector reveals). Guard that
      // the shell visibility is declarative.
      expect(hostJs.contains('shell.style.visibility'), isFalse,
          reason: 'shell visibility is the CSS gate, never an inline JS write');
      expect(hostJs.contains('function scheduleMeasure('), isTrue,
          reason: 'D2 convergence: content-ready bursts coalesce one measure');
    });

    test('coordinate-domain rule: host.js + computeFrameRect carry NO dpr math',
        () {
      // The layout math is CSS / logical px throughout; the only dpr boundary is
      // C++ window geometry / the WH_MOUSE_LL hook. So neither host.js nor the
      // pure layout function may multiply/divide by a device pixel ratio.
      // Strip // line comments first (the Chinese docs legitimately mention
      // "dpr" to EXPLAIN the rule); the CODE must carry no dpr arithmetic.
      final String layoutRaw = read('lib/src/lookup/global_lookup_layout.dart');
      final StringBuffer codeOnly = StringBuffer();
      for (final String line in const LineSplitter().convert(layoutRaw)) {
        final int c = line.indexOf('//');
        codeOnly.writeln(c >= 0 ? line.substring(0, c) : line);
      }
      final String layoutCode = codeOnly.toString();
      for (final String token in <String>[
        'dpr',
        'devicePixelRatio',
        'pixelRatio'
      ]) {
        expect(layoutCode.contains(token), isFalse,
            reason: 'global_lookup_layout CODE must stay unit-agnostic CSS px '
                '(no "$token") — the dpr boundary is the C++ window only');
      }
      // host.js forwards devicePixelRatio to C++ but performs NO dpr arithmetic
      // on shell geometry (it only reads window.devicePixelRatio to report it).
      expect(
          hostJs.contains('* dpr') ||
              hostJs.contains('/ dpr') ||
              hostJs.contains('*dpr') ||
              hostJs.contains('/dpr'),
          isFalse,
          reason:
              'host.js must not scale shell geometry by dpr; geometry stays '
              'CSS px and the dpr is converted at the C++ window boundary');
    });
  });

  group('JS harness (node) — renderStack diff + reveal gate', () {
    test('global_lookup_host_test.mjs executes host.js end-to-end', () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping host JS harness');
        return;
      }
      final File jsTest = File('test/lookup/global_lookup_host_test.mjs');
      expect(jsTest.existsSync(), isTrue);
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'global_lookup_host JS harness failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
          result.stdout.toString(), contains('global_lookup_host_test: PASS'));
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

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
