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

    test('TODO-1231 P1: __hasChildPopup rides its own channel, not the body',
        () {
      // Baking the flag into the per-frame body made the parent settingsJs change
      // on every nested open/close, so the host re-eval'd the WHOLE body (a
      // renderPopup() card rebuild) = the "父弹窗闪烁". It now rides a dedicated
      // descriptor field + a host applyHasChildPopup one-liner, so the body stays
      // byte-identical and renderPayload can SKIP the re-render. BUG-434 behaviour
      // (parent-card tap closes the child) is preserved (popup.js reads it live).
      expect(render.contains("map['hasChildPopup'] = i < payloads.length - 1"),
          isTrue,
          reason:
              'has-child is a per-frame descriptor field (index<len-1), NOT '
              'baked into settingsJs');
      expect(render.contains('window.__hasChildPopup ='), isFalse,
          reason: 'the settings body must NOT bake __hasChildPopup anymore '
              '(that forced a full re-render on every nested open/close)');
      expect(hostJs.contains('function applyHasChildPopup('), isTrue,
          reason: 'the host applies __hasChildPopup on its own cheap channel');
      expect(hostJs.contains('window.__hasChildPopup ='), isTrue,
          reason:
              'applyHasChildPopup evals the boolean inside the frame realm');
      // renderPayload must gate the full re-eval on a real body change.
      expect(
          hostJs
              .contains('record.injectedSettingsJs !== descriptor.settingsJs'),
          isTrue,
          reason:
              'renderPayload re-evals the body ONLY when it actually changed '
              '(otherwise a nested open/close rebuilt the parent card)');
    });

    test('TODO-1231 P2: layer shift is C++-ordered after SetWindowPos', () {
      // measureAndReport must NOT shift the layer synchronously (that raced the
      // window move across vsync -> the parent card lurched then snapped back).
      // The shift rides commitLayerShift, which C++ RevealStack calls AFTER
      // SetWindowPos so the window move and content shift are causally ordered.
      expect(hostJs.contains('function commitLayerShift('), isTrue,
          reason:
              'the host exposes a commit hook for the deferred layer shift');
      final int mAt = hostJs.indexOf('function measureAndReport(');
      final int mEnd = hostJs.indexOf('function measureContentHeight(', mAt);
      expect(mAt >= 0 && mEnd > mAt, isTrue);
      final String measureBody = hostJs.substring(mAt, mEnd);
      expect(measureBody.contains('layerEl.style.left'), isFalse,
          reason: 'measureAndReport must not shift the layer synchronously '
              '(TODO-1231 P2: it races the window move across vsync)');
      // C++ RevealStack triggers the commit AFTER SetWindowPos.
      final int rsAt = cpp.indexOf('void GlobalLookupWindow::RevealStack(');
      expect(rsAt, greaterThan(-1));
      final int rsEnd = cpp.indexOf('void GlobalLookupWindow::ResizeTo(', rsAt);
      expect(rsEnd, greaterThan(rsAt));
      final String rsBody = cpp.substring(rsAt, rsEnd);
      expect(rsBody.contains('commitLayerShift'), isTrue,
          reason: 'RevealStack calls commitLayerShift via ExecuteScript');
      expect(
          rsBody.indexOf('SetWindowPos') < rsBody.indexOf('commitLayerShift'),
          isTrue,
          reason: 'the window moves FIRST, then the layer shift is applied');
      // The bbox origin (CSS px) is carried to native so the host negates it.
      expect(channel.contains("'left': left"), isTrue,
          reason: 'revealStack forwards the bbox origin (CSS px) to native');
    });

    test(
        'TODO-1231 (BUG-583): beginLookup re-gates WITHOUT observing the stale '
        'card (no premature reveal off the previous lookup)', () {
      // beginLookup used to call observeContent, which synchronously re-satisfied
      // content-ready off the reused iframe's still-present old .glossary-content
      // and fired a premature overlaySize -> the OLD card flashed at the cursor
      // before the fresh render ("第一个弹窗出现时闪"). It must now only re-gate
      // content-ready=false + tear down the stale observer/timer; the fresh
      // content-ready comes from the FOLLOWING renderStack, never here.
      final int bAt = hostJs.indexOf('function beginLookup(');
      expect(bAt, greaterThan(-1), reason: 'beginLookup must exist');
      final int bEnd = hostJs.indexOf('function renderStack(', bAt);
      expect(bEnd, greaterThan(bAt));
      final String beginBody = hostJs.substring(bAt, bEnd);
      expect(beginBody.contains('observeContent('), isFalse,
          reason:
              'beginLookup must NOT re-observe the stale card (that fired a '
              'premature overlaySize off the previous lookup — BUG-583)');
      expect(beginBody.contains("setAttribute(ATTR_CONTENT_READY, 'false')"),
          isTrue,
          reason:
              'beginLookup still re-gates the content half of the reveal gate');
      // renderPayload re-marks content-ready for an UNCHANGED body that already
      // rendered, so a same-word re-lookup is not left waiting for a popupRendered
      // that never comes now that beginLookup no longer re-observes.
      final int rAt = hostJs.indexOf('function renderPayload(');
      expect(rAt, greaterThan(-1));
      final int rEnd = hostJs.indexOf('function removeMissing(', rAt);
      expect(rEnd, greaterThan(rAt));
      final String renderBody = hostJs.substring(rAt, rEnd);
      expect(renderBody.contains('} else if (hasContent(record)) {'), isTrue,
          reason:
              'an unchanged body with rendered content re-marks the gate so a '
              'same-word re-lookup reveals (no stuck gate — BUG-583)');
    });

    test(
        'TODO-1231 (BUG-583): the overlay window origin is ratcheted '
        'outward-only (nested close does not lurch the pinned root)', () {
      // A nested up/left cascade CLOSE moved the window top-left back inward while
      // the host layer shift lagged ~1 frame across the DWM/WebView2 boundary ->
      // the pinned root card lurched ("消失第二个弹窗时闪"). _applyOverlayBox now
      // ratchets the origin so the min-corner only ever moves OUTWARD within a
      // session; on close the window top-left + layer shift hold and only the far
      // edges shrink. The ratchet lives in a pure, unit-tested layout helper.
      final String layout = read('lib/src/lookup/global_lookup_layout.dart');
      expect(
          layout.contains('RatchetedOverlayBox ratchetOverlayOrigin('), isTrue,
          reason: 'the outward-only origin ratchet is a pure layout helper');
      expect(controller.contains('ratchetOverlayOrigin('), isTrue,
          reason: '_applyOverlayBox must route the bbox through the ratchet');
      final int aAt = controller.indexOf('void _applyOverlayBox(');
      expect(aAt, greaterThan(-1));
      final int aEnd = controller.indexOf('void _applyOverlayScalar(', aAt);
      expect(aEnd, greaterThan(aAt));
      final String applyBody = controller.substring(aAt, aEnd);
      expect(applyBody.contains('ratchetOverlayOrigin('), isTrue,
          reason:
              '_applyOverlayBox uses the ratchet to compute the window box');
      expect(
          applyBody.contains('ratcheted.left') &&
              applyBody.contains('ratcheted.top'),
          isTrue,
          reason:
              'revealStack is fed the ratcheted origin (window + layer shift '
              'both use the held outward min-corner)');
      // The ratchet is reset per fresh lookup + on dismiss so a session starts
      // unconstrained (origin re-anchors at the cursor).
      expect(controller.contains('_ratchetLeft = double.infinity'), isTrue,
          reason: 'the ratchet is reset to no-constraint per session');
    });

    test(
        'TODO-1231 v2 (BUG-583): the bbox MIN-corner (window origin) follows '
        'only content-ready shells so a hidden child never lurches the parent',
        () {
      // The residual "父弹窗出现子弹窗时闪一下": a freshly-opened, still-gated-
      // hidden child that cascades up/left used to drag the union bbox MIN-corner
      // outward, moving the window origin (SetWindowPos) while the compensating
      // commitLayerShift lands ~1 frame later across the DWM/WebView2 boundary ->
      // the pinned parent card lurched. measureAndReport now sources the MIN-
      // corner (origin -> window position + layer shift) ONLY from content-ready
      // (visible) shells, while the MAX-corner (window size, which never moves the
      // parent) still includes EVERY placed shell so the window pre-grows to cover
      // the hidden child. A bootstrap fallback (no shell content-ready yet) keeps
      // the first reveal byte-identical.
      final int mAt = hostJs.indexOf('function measureAndReport(');
      expect(mAt, greaterThan(-1));
      final int mEnd = hostJs.indexOf('function measureContentHeight(', mAt);
      expect(mEnd, greaterThan(mAt));
      final String measureBody = hostJs.substring(mAt, mEnd);
      // The MIN-corner assignment must be gated on the shell being content-ready.
      expect(measureBody.contains('if (record.contentReady) {'), isTrue,
          reason:
              'the window origin (min-corner) only follows content-ready shells '
              '(a hidden child must not move the pinned parent — BUG-583)');
      // The MAX-corner / bootstrap fallback tracks every placed shell.
      expect(
          measureBody.contains('minLeftAll') &&
              measureBody.contains('minTopAll'),
          isTrue,
          reason:
              'the far edges (window size) + the bootstrap origin fallback see '
              'ALL placed shells so the window pre-grows to cover a hidden child');
      // Bootstrap: before any shell is content-ready the origin falls back to all
      // shells so the FIRST reveal geometry is unchanged (Never break userspace).
      expect(
          measureBody.contains('minLeft = minLeftAll') &&
              measureBody.contains('minTop = minTopAll'),
          isTrue,
          reason:
              'no-content-ready bootstrap falls back to all shells so the first '
              'root reveal is byte-identical to the pre-fix behaviour');
    });

    test(
        'TODO-1231 v3 (BUG-583): reveal-ready is gated on the committed window '
        'origin covering the shell so an up/left child never paints clipped',
        () {
      // The residual "子弹窗闪": an up/left-cascading child is placed at negative
      // window-local coords, but the window origin only moves to cover it when it
      // becomes content-ready (the MIN-corner split). Its CSS reveal gate opened at
      // content-ready — BEFORE the window round-trips to cover it — so it painted
      // CLIPPED at the window edge, then jumped in when commitLayerShift landed.
      // reveal-ready now flips ONLY once the committed origin (layerOffsetLeft/Top,
      // set by commitLayerShift = the window origin C++ actually moved to) covers
      // the shell; commitLayerShift re-checks held shells so an up/left child first
      // paints IN PLACE. Down-right / root shells stay covered-from-placement.
      expect(hostJs.contains('function shellCoveredByOrigin('), isTrue,
          reason:
              'a shell is revealed only when the committed origin covers it');
      expect(hostJs.contains('function maybeFlipRevealReady('), isTrue,
          reason: 'reveal-ready flips through the coverage-gated helper');
      // renderPayload must route reveal-ready through the gate, NOT flip it
      // unconditionally (the old setGateFlag(..., ATTR_REVEAL_READY, ...) call).
      final int rAt = hostJs.indexOf('function renderPayload(');
      expect(rAt, greaterThan(-1));
      final int rEnd = hostJs.indexOf('function removeMissing(', rAt);
      expect(rEnd, greaterThan(rAt));
      final String renderBody = hostJs.substring(rAt, rEnd);
      expect(renderBody.contains('maybeFlipRevealReady(record)'), isTrue,
          reason: 'renderPayload flips reveal-ready via the coverage gate');
      expect(renderBody.contains('setGateFlag(record, ATTR_REVEAL_READY,'),
          isFalse,
          reason: 'renderPayload must NOT flip reveal-ready unconditionally '
              '(an up/left child would paint clipped — BUG-583)');
      // commitLayerShift re-checks held shells so a child covered by the new
      // origin reveals coincident with the window/layer settling.
      final int cAt = hostJs.indexOf('function commitLayerShift(');
      expect(cAt, greaterThan(-1));
      final int cEnd = hostJs.indexOf('function dismissRootWithSlide(', cAt);
      expect(cEnd, greaterThan(cAt));
      final String commitBody = hostJs.substring(cAt, cEnd);
      expect(commitBody.contains('maybeFlipRevealReady(record)'), isTrue,
          reason:
              'commitLayerShift flips reveal-ready for shells the new origin '
              'now covers (child appears in place, not clipped-then-jump)');
      // beginLookup resets the committed origin so a stale negative origin from a
      // previous up/left cascade cannot falsely mark the next child as covered.
      final int bAt = hostJs.indexOf('function beginLookup(');
      expect(bAt, greaterThan(-1));
      final int bEnd = hostJs.indexOf('function renderStack(', bAt);
      expect(bEnd, greaterThan(bAt));
      final String beginBody = hostJs.substring(bAt, bEnd);
      expect(
          beginBody.contains('layerOffsetLeft = 0') &&
              beginBody.contains('layerOffsetTop = 0'),
          isTrue,
          reason:
              'beginLookup resets the committed origin per fresh lookup so a '
              'stale negative origin cannot falsely mark a new child covered');
    });

    test(
        'TODO-1345 (BUG-583 deeper): a reserved origin FLOOR freezes the window '
        'origin so an up/left child never lurches the pinned parent', () {
      // The residual "第二个弹窗出现导致第一个弹窗位置变动": rounds 1-4 let the union
      // bbox MIN-corner move outward ONCE when an up/left child became content-ready,
      // which still lurched the pinned parent across the DWM/WebView2 boundary. The
      // fix reserves cascade headroom toward the screen interior at the FIRST reveal
      // (Dart computes it from the real screen edges) so the child lands INSIDE the
      // committed origin and never moves it — zero parent displacement, extending the
      // down-right zero-lurch guarantee to up/left.
      final String layout = read('lib/src/lookup/global_lookup_layout.dart');
      expect(layout.contains('}) computeCascadeHeadroomSeed('), isTrue,
          reason:
              'the screen-edge-aware headroom seed is a pure layout helper');
      // The controller computes the floor from the real work area + pushes it.
      expect(controller.contains('computeCascadeHeadroomSeed('), isTrue,
          reason: 'the controller computes the reserved floor after showAt');
      expect(
          controller.contains('originFloorLeft: _originFloorLeft') &&
              controller.contains('originFloorTop: _originFloorTop'),
          isTrue,
          reason: '_renderStack pushes the floor on the renderStack payload');
      // The render builder only carries the floor when it actually reserves.
      expect(render.contains("payloadObj['originFloor']"), isTrue,
          reason:
              'buildStackRenderScript carries the origin floor to the host');
      // host.js applies the floor as an OUTWARD-only lower bound on the origin.
      expect(hostJs.contains('function applyOriginFloor('), isTrue,
          reason: 'the host reads the reserved floor from the render payload');
      final int mAt = hostJs.indexOf('function measureAndReport(');
      final int mEnd = hostJs.indexOf('function measureContentHeight(', mAt);
      final String measureBody = hostJs.substring(mAt, mEnd);
      expect(
          measureBody.contains('if (originFloorLeft < minLeft)') &&
              measureBody.contains('if (originFloorTop < minTop)'),
          isTrue,
          reason: 'measureAndReport pulls the origin OUT to at least the floor '
              '(a lower bound, never a cap — freezes the origin for an up/left '
              'child within the floor)');
      // beginLookup drops the previous lookup\'s floor so it cannot leak.
      final int bAt = hostJs.indexOf('function beginLookup(');
      final int bEnd = hostJs.indexOf('function renderStack(', bAt);
      final String beginBody = hostJs.substring(bAt, bEnd);
      expect(
          beginBody.contains('originFloorLeft = 0') &&
              beginBody.contains('originFloorTop = 0'),
          isTrue,
          reason: 'beginLookup resets the reserved floor per fresh lookup');
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
