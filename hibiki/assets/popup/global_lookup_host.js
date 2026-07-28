// TODO-867 P3b/P3c — app-OUTSIDE global lookup nested-stack HOST (Windows only).
//
// Ported from hoshi reader-popup-host.js frames model. Injected ONLY into the
// top-level WebView2 document of the bare global-lookup window
// (global_lookup_window.cpp AddScriptToExecuteOnDocumentCreated). NEVER loaded
// in-app, so in-app popup rendering is byte-for-byte unchanged.
//
// Why iframes: popup.js is a page-level SINGLETON. To stack N lookup cards we
// host N iframes, each loading popup.html unchanged, so each frame keeps the
// single-frame assumptions inside its own document. The host owns the OUTER
// shell layout + frame diff.
//
// NO sandbox on the iframes (same-origin contentWindow injection needs a
// non-opaque origin). Frames load https://hibiki.popup/popup.html and the host
// injects per-frame settings + entries via iframe.contentWindow.
//
// renderStack(payload) is the single Dart entry point. payload =
//   { popups: [ { id, parentIndex, frame:{left,top,width,height}, settingsJs } ] }
// built by global_lookup_render.buildStackRenderScript. The host diffs the
// payload against its live frames Map.
//
// P3c (this file) adds, on top of P3b:
//   - C1: re-anchor a child iframe onLinkClick LOCAL rect to full-screen CSS px
//         (shell.left/top + FRAME_CONTENT_TOP) + stamp source frame id, before
//         the message reaches C++ -> Dart (child cascades off the clicked word).
//   - C3: capture-phase pointerdown outside ALL shells dismisses the root (whole
//         stack); an iframe tapOutside dismisses that layer children.
//   - D2: measure each iframe same-origin content height + report the UNION
//         bounding box (overlaySize) so C++ sizes the window to the whole stack.
//   - E2: handleGlobalClick(x,y) lets the C++ WH_MOUSE_LL hook push a global
//         click into the host for shell hit-testing (host owns geometry truth).
//   - D1: a two-flag reveal gate per shell (data-content-ready +
//         data-reveal-ready). Each shell starts invisible; it only paints once
//         BOTH its iframe content has arrived (host MutationObserver on the
//         same-origin contentDocument.body) AND its geometry is placed +
//         measured. Kills the "empty frame -> content fills in" flash. The
//         coalesced re-measure (rAF/microtask) keeps the union bbox convergence
//         stable when several layers report content height at once.
// Window enlargement + the mouse hooks live in C++ (global_lookup_window.cpp).

(function () {
  'use strict';

  // Only run on the TOP-LEVEL host document. AddScriptToExecuteOnDocumentCreated
  // injects this into EVERY frame (incl. child popup.html iframes); sub-frames
  // have window.top !== window.self, so bail there.
  if (window.top !== window.self) {
    return;
  }

  if (window.__globalLookupHost && window.__globalLookupHost.__installed) {
    return;
  }

  var POPUP_SRC = 'https://hibiki.popup/popup.html';
  var LAYER_ID = 'global-lookup-host-layer';
  var STYLE_ID = 'global-lookup-host-style';

  // D1 — reveal gate. A shell paints only when BOTH flags are 'true'. The
  // attribute selector below is the single source of truth for visibility; JS
  // only flips the two data-* attributes, never the inline visibility, so the
  // gate stays declarative + testable.
  var ATTR_CONTENT_READY = 'data-content-ready';
  var ATTR_REVEAL_READY = 'data-reveal-ready';
  // Host-side safety: if an iframe never reports content (render failure), force
  // content-ready after this budget so the card is not stuck invisible. Mirrors
  // the Dart 450ms reveal safety (controller.dart) one layer down.
  var CONTENT_READY_SAFETY_MS = 450;
  // TODO-1231 v3 (BUG-583) — reveal-ready safety. A shell held hidden because the
  // committed window origin does not YET cover it (an up/left-cascading child whose
  // covering commitLayerShift is still round-tripping through Dart) must never be
  // stuck: force reveal-ready after this budget so a lost/late commitLayerShift
  // still shows the card (mildly-clipped fallback, never invisible). Mirrors
  // CONTENT_READY_SAFETY_MS.
  var REVEAL_READY_SAFETY_MS = 450;
  // Sub-pixel slack for the origin-coverage compare (device-pixel-ratio
  // rounding at the C++ window boundary) so an on-edge shell counts as covered.
  var COVER_EPS = 0.5;

  // C1 — vertical offset (CSS px) from a frame shell top-left to the popup
  // CONTENT top. In Hibiki the iframe FILLS its shell and the star/audio header
  // lives INSIDE popup.html body, so popup.js getBoundingClientRect is already
  // relative to the shell top-left -> offset 0 (hoshi reader-popup-host.js uses a
  // conditional actionBar(37)+sasayaki(37)=74 band ABOVE the iframe; Hibiki has
  // neither). Named + explicit so the coordinate contract is testable.
  var FRAME_CONTENT_TOP = 0;

  var frames = new Map();
  var frameSources = new WeakMap();
  var wrappedWindows = new WeakSet();
  // TODO-1188 — bridge round-trip routing. popup.js runs inside a CHILD iframe,
  // so its window.flutter_inappwebview.callHandler Promise lives in THAT iframe's
  // popup_bridge_adapter realm (each iframe adapter mints its own _seq from 1, so
  // the frame-LOCAL bridge ids collide across frames). Native
  // (global_lookup_window.cpp) only ever ExecuteScripts the TOP-LEVEL document,
  // whose window.__hibikiBridgeResolve is a DIFFERENT adapter realm — so a native
  // reply used to never reach the source iframe and every AWAITED callHandler
  // (audio ♪ / favorite ☆) hung forever. Fix: the host rewrites each outbound
  // frame-local __bridgeId to a HOST-GLOBAL id (transformFrameMessage) and records
  // the route here; the top-level __hibikiBridgeResolve (installBridgeRouter) then
  // forwards the native reply back to EXACTLY the source frame's adapter with its
  // own local id — no cross-frame id collision, no broadcast to the wrong card.
  var bridgeSeq = 0;
  var bridgeRoutes = new Map();
  var lastBBoxKey = '';
  // BUG-749 — last posted shell-rects payload (window-relative CSS px CSV).
  // De-duped independently of lastBBoxKey: a nested child that lands INSIDE the
  // reserved-floor bbox leaves the bbox key unchanged (overlaySize suppressed)
  // but MUST still refresh the native hit/paint region, or clicks on the new
  // card would fall through the stale region hole.
  var lastShellRectsKey = '';
  // TODO-1079 (C) / TODO-1095 — the root frame id of the currently-rendered
  // stack. TODO-1095 makes the root frame id STABLE across hotkey lookups (the
  // root iframe is REUSED, not rebuilt per lookup — see beginLookup), so the
  // authoritative "new lookup" bbox-dedup reset + content-gate re-arm now arrive
  // via beginLookup(). This changed-root-id path stays as belt-and-braces for any
  // caller that still rotates the root id (nested-only rebuilds, tests).
  var lastRootId = null;

  // TODO-1189 — the layer translation applied by measureAndReport so the union
  // bbox top-left maps to the window origin. The layer element is shifted by
  // (-minLeft, -minTop); a shell's REAL position relative to the window is
  // therefore (shell.style.left - layerOffsetLeft, shell.style.top -
  // layerOffsetTop). Hit-testing (frameIdAtPoint) compares C++-forwarded clicks
  // in WINDOW coordinates, so it MUST subtract these offsets — otherwise nested
  // sub-popups pushed up/left off the cursor (screen-edge second lookup, minLeft/
  // minTop < 0) hit-test against un-shifted shell coords and a click ON the card
  // is misread as an empty gap, dismissing the whole stack. Kept as host-scope
  // fields (minLeft/minTop are locals inside measureAndReport). Default 0 = no
  // shift (single popup / down-right cascade), matching the un-shifted layer.
  var layerOffsetLeft = 0;
  var layerOffsetTop = 0;

  // TODO-1345 (BUG-583 深层根因续) — reserved cascade origin FLOOR (window-local
  // CSS px, always <= 0). Dart computes it per lookup from the REAL screen edges
  // (headroom toward the screen interior, bounded so the window stays on-screen)
  // and pushes it on the renderStack payload (applyOriginFloor). measureAndReport
  // pulls the union bbox MIN-corner (origin) OUT to at least this floor, so the
  // window is revealed already covering the region an up/left cascade child will
  // occupy. The child then lands INSIDE the committed origin and never moves it —
  // no SetWindowPos + commitLayerShift round-trip across the DWM/WebView2 boundary
  // when the child appears, so the pinned PARENT card has ZERO displacement (the
  // residual BUG-583 rounds 1-4 could only mask by coinciding the origin move with
  // the child's appearance frame). 0 = no reservation (down-right cascade, or the
  // cursor sits against an edge) -> the origin is byte-identical to the pre-fix
  // behaviour, so the common cascade + first reveal are unchanged.
  var originFloorLeft = 0;
  var originFloorTop = 0;

  // spec 2026-07-10 — host layout mode. 'cascade' (default) = the transient
  // global-lookup geometry (content-sized window, off-screen self-measure ->
  // overlaySize -> reveal). 'panel' = the persistent clipboard panel: the
  // window rect is FIXED (user-remembered), the ROOT shell fills the viewport
  // below the panel bar (content scrolls inside the iframe), measureAndReport
  // is short-circuited (no reveal-resize loop) and a blank click never
  // dismisses (persistent semantics). Carried per renderStack payload so a
  // cascade payload without the key is byte-identical to the pre-panel host.
  var layoutMode = 'cascade';
  // Panel top bar height (CSS px): grip + pin + close. Root shell top offset.
  var PANEL_BAR_HEIGHT = 28;
  // Panel pin VISUAL state. The truth source is the Dart-side pref (native
  // SetTopmost applies it); Dart syncs this visual via setPanelPinnedVisual on
  // panel show so the bar icon matches the remembered pref.
  var panelPinnedVisual = true;
  // Panel block-capture VISUAL state（防截屏）. Truth source is the Dart pref
  // clipboardPanelBlockCapture (native SetWindowDisplayAffinity applies it);
  // Dart syncs this visual via setPanelBlockCaptureVisual. Default true =
  // capture blocked (shield bright); toggled off dims the shield (panel-block-off).
  var panelBlockCaptureVisual = true;

  // Post a message to C++ (and on to Dart) via the TOP-LEVEL chrome.webview
  // bridge. Mirrors the adapter envelope { handler, args } so _onJsMessage routes
  // it identically to popup.js-originated messages. Read-only host messages need
  // no __bridgeId.
  function postToHost(handler, args) {
    try {
      if (window.chrome && window.chrome.webview &&
          typeof window.chrome.webview.postMessage === 'function') {
        window.chrome.webview.postMessage({ handler: handler, args: args || [] });
      }
    } catch (e) {
      // No bridge (node harness) -> swallow; tests stub postToHost.
    }
  }

  // setTimeout / cancel that degrade when the host (node harness) has no timer
  // API: returns null and the caller treats the deferred work as "do it now"
  // is NOT applied here — instead the caller relies on the synchronous content
  // check / direct measure. Returns an opaque handle or null.
  function setTimerSafe(fn, ms) {
    if (typeof window.setTimeout === 'function') {
      try {
        return window.setTimeout(fn, ms);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  function clearTimerSafe(handle) {
    if (handle != null && typeof window.clearTimeout === 'function') {
      try {
        window.clearTimeout(handle);
      } catch (e) {
        // no-op
      }
    }
  }

  // D2 convergence — coalesce re-measure requests. Several layers can report
  // content-ready in the same tick (multi-layer stack filling at once); without
  // coalescing each would call measureAndReport and thrash the union-bbox
  // postMessage. Batch them into ONE measure per frame via requestAnimationFrame
  // (falling back to a microtask, then to a synchronous call when neither timer
  // API exists, e.g. the node harness). measureAndReport itself de-dupes on the
  // bbox key, so the worst case is a single redundant measure, never a loop.
  var measureScheduled = false;
  function scheduleMeasure() {
    if (measureScheduled) {
      return;
    }
    var raf = (typeof window.requestAnimationFrame === 'function')
        ? window.requestAnimationFrame
        : null;
    var runner = function () {
      measureScheduled = false;
      measureAndReport();
    };
    if (raf) {
      measureScheduled = true;
      try {
        raf(runner);
        return;
      } catch (e) {
        measureScheduled = false;
      }
    }
    if (typeof window.queueMicrotask === 'function') {
      measureScheduled = true;
      try {
        window.queueMicrotask(runner);
        return;
      } catch (e) {
        measureScheduled = false;
      }
    }
    // No deferral primitive (node harness): measure synchronously. De-dup on the
    // bbox key in measureAndReport keeps this from over-posting.
    measureAndReport();
  }

  // Insertion-order index of a frame id (0 = root). -1 when unknown.
  function layerIndexOf(frameId) {
    var i = 0;
    var found = -1;
    frames.forEach(function (record, id) {
      if (id === frameId) {
        found = i;
      }
      i++;
    });
    return found;
  }

  // D1 — inject the reveal-gate stylesheet once. The shell defaults to hidden;
  // it only becomes visible when BOTH data-content-ready and data-reveal-ready
  // are 'true'. Injected here (not host.html / popup.css) because host.js owns
  // the shell DOM and the gate must ship with the host even though host.html is
  // C++-injected-only and carries no <style>. Scoped to .global-lookup-frame-
  // shell so it never leaks into the in-app popup (which never loads host.js).
  function ensureStyle() {
    if (!document || typeof document.createElement !== 'function') {
      return;
    }
    if (document.getElementById(STYLE_ID)) {
      return;
    }
    var style = document.createElement('style');
    style.id = STYLE_ID;
    // F2 — outer SHELL chrome (ported from hoshi reader-popup-host.js shell).
    // TODO-893 — RESPONSIBILITY SPLIT to kill the double-border (symptom 1):
    // the iframe inside the shell already paints the THEME card background AND
    // the single visible card border (popup.css `html.global-lookup body`
    // border + radius + padding). The shell therefore owns ONLY the rounded
    // clip — it must NOT draw a second `border` (that produced two concentric
    // grey rings with a white gap between them). `border-radius` stays so the
    // overflow clip follows the same rounded silhouette as the body border;
    // `background:transparent` keeps the shell from painting a second fill.
    //
    // BUG-709 — NO `box-shadow`. The overlay HWND is a NON-layered, OPAQUE
    // WebView2 window (global_lookup_window.cpp: "No WS_EX_LAYERED"). On such a
    // window the WebView2 composition surface has no per-pixel alpha against the
    // desktop, so a CSS `box-shadow` does NOT read as a soft translucent shadow
    // over whatever is behind the card — the shadow's blur (0 3px 12px) paints
    // onto the window's own transparent (=hard dark) surface as an ~11px DARK
    // HALO ringing the card's corners/edges, which the native rounded window
    // region (SetWindowRgn) cannot clip away. That halo is exactly the "black
    // border outside the rounded corners" the user reported. A real drop-shadow
    // is physically impossible on a non-layered WebView2 window (the design
    // already conceded this), so the shell casts none: the rounded silhouette
    // comes from SetWindowRgn + the body's 1px card border, with nothing painted
    // outside the card. All rules scoped to .global-lookup-frame-shell -> the
    // in-app popup (no host.js) is never touched.
    // D1 reveal gate: a shell paints only when BOTH data-* flags are 'true'.
    style.textContent =
        // D1 reveal gate FIRST (kept as its own rule so the gate contract stays
        // a single declarative source: a shell defaults hidden until BOTH flags
        // flip). The F2 chrome below is a SEPARATE .global-lookup-frame-shell
        // rule (CSS cascades the two), so the gate substring is unchanged.
        '.global-lookup-frame-shell{visibility:hidden;opacity:0;}' +
        '.global-lookup-frame-shell{' +
        'box-sizing:border-box;overflow:hidden;background:transparent;' +
        'border-radius:10px;' +
        // TODO-890 — slide-out close: the shell tweens transform+opacity so a
        // dismiss slides the card off-screen instead of vanishing instantly
        // (app-out parity with the in-app _BodySwipeDismissDetector). 200ms
        // ease-out matches the Flutter side. Scoped to the shell selector so
        // it never leaks into the in-app popup (which never loads host.js).
        'transition:transform 200ms ease-out, opacity 200ms ease-out;}' +
        // TODO-890 — the dismissing class drives the slide-out: translate the
        // card fully off its own width + margin and fade to 0; visibility stays
        // visible during the transition (the reveal gate already passed) so the
        // transitionend fires before the host posts dismissPopupAt to Dart.
        '.global-lookup-frame-shell.global-lookup-dismissing{' +
        'transform:translateX(120%);opacity:0;}' +
        '.global-lookup-frame-shell[' + ATTR_CONTENT_READY + '="true"]' +
        '[' + ATTR_REVEAL_READY + '="true"]{visibility:visible;opacity:1;}' +
        // TODO-1067 (子1) — per-shell close-X. Absolutely placed in the shell's
        // top-right corner, above the iframe (z-index) with its own pointer
        // events so it is always clickable even over the card content. Monochrome
        // Segoe glyph to match the overlay icon-font override; dark variant keyed
        // off the shell data-theme (same as the shadow variant above).
        '.global-lookup-frame-shell .global-lookup-close{' +
        'position:absolute;top:2px;right:6px;z-index:5;' +
        'width:22px;height:22px;line-height:22px;text-align:center;' +
        'font-family:"Segoe UI Symbol","Segoe UI",sans-serif;' +
        'font-size:17px;cursor:pointer;pointer-events:auto;' +
        'color:rgba(60,60,67,0.6);border-radius:11px;' +
        'transition:background-color 120ms ease-out, color 120ms ease-out;}' +
        '.global-lookup-frame-shell .global-lookup-close:hover{' +
        'background:rgba(120,120,128,0.16);color:rgba(60,60,67,0.9);}' +
        '.global-lookup-frame-shell[data-theme="dark"] .global-lookup-close{' +
        'color:rgba(235,235,245,0.6);}' +
        '.global-lookup-frame-shell[data-theme="dark"] ' +
        '.global-lookup-close:hover{' +
        'background:rgba(235,235,245,0.16);color:rgba(235,235,245,0.92);}' +
        // 剪贴板复制历史按钮（🕘）——瞬态覆盖窗 ROOT 卡左上角（与 close-X 右上角对称）。
        // 必须挂 SHELL 内（z-index 高于 iframe、pointer-events:auto），否则被 native 按
        // shell 卡矩形裁掉（同 close-X / resize-grip 的 BUG-749 约束）。面板模式另有面板
        // 栏🕘，此按钮只在 cascade 的 root 卡出现。
        '.global-lookup-frame-shell .global-lookup-history{' +
        'position:absolute;top:2px;left:6px;z-index:5;' +
        'width:22px;height:22px;line-height:22px;text-align:center;' +
        'font-size:14px;cursor:pointer;pointer-events:auto;' +
        'border-radius:11px;' +
        'transition:background-color 120ms ease-out;}' +
        '.global-lookup-frame-shell .global-lookup-history:hover{' +
        'background:rgba(120,120,128,0.16);}' +
        '.global-lookup-frame-shell[data-theme="dark"] ' +
        '.global-lookup-history:hover{background:rgba(235,235,245,0.16);}' +
        // Phase C（弹窗尺寸精细化 2026-07-13）— 瞬态覆盖窗（cascade 模式）ROOT 卡的
        // 右下角 resize grip：拖它进 native 模态 size 循环（beginWindowResize，与面板
        // grip 同一通路）。必须挂在 SHELL 内（z-index 高于 iframe、pointer-events:auto），
        // 因为瞬态窗被 native 按 shell 卡矩形做区域裁剪（BUG-749 gap click-through）——
        // 挂在窗口层的角落 grip 会被裁掉不可见/不可点，只有 root 卡区域在裁剪区内。
        // 透明无背景（cursor 提示可拖），与面板 grip 一致，避免遮挡卡片文字。
        '.global-lookup-frame-shell .global-lookup-resize-grip{' +
        'position:absolute;right:0;bottom:0;width:16px;height:16px;' +
        'z-index:6;cursor:nwse-resize;pointer-events:auto;}' +
        // spec 2026-07-10 — panel top bar (grip + pin + close). Fixed to the
        // window top, above the root shell (which starts at PANEL_BAR_HEIGHT).
        // pointer-events:auto so the grip mousedown reaches the drag handler
        // even though the layer beneath is pointer-events:none. Only created in
        // panel mode (ensurePanelBar), so the transient overlay never carries
        // this DOM/CSS.
        // 浅色模式对比修复：bar 底 + grip 文字 + 按钮字形都是浅色主题下的默认样式，
        // 原来 bar 底仅 10% 灰、字形 0.75 半透深灰，压在亮游戏上的半透明浅窗被冲淡
        // 「看不清」。加深到接近全实心深灰，并给 bar 一条底边界定轮廓（dark 变体在下面
        // 覆盖，深色窗不受影响）。
        '#global-lookup-panel-bar{' +
        'position:fixed;left:0;top:0;right:0;height:28px;' +
        'display:flex;align-items:center;z-index:2147483001;' +
        'pointer-events:auto;user-select:none;-webkit-user-select:none;' +
        'background:rgba(120,120,128,0.18);' +
        'border-bottom:1px solid rgba(120,120,128,0.20);' +
        'border-radius:10px 10px 0 0;}' +
        '#global-lookup-panel-bar .panel-grip{' +
        'flex:1;height:100%;cursor:move;display:flex;align-items:center;' +
        'padding-left:10px;font-family:"Segoe UI",sans-serif;font-size:11px;' +
        'color:rgba(70,70,78,0.92);letter-spacing:2px;}' +
        // BUG-768 — persistent chip background so the pin/close read as tappable
        // affordances on ANY window surface (light or dark); glyph color is made
        // theme-aware below so it stays legible against that chip.
        '#global-lookup-panel-bar .panel-btn{' +
        'width:24px;height:24px;line-height:24px;text-align:center;' +
        'margin-right:4px;font-family:"Segoe UI Symbol","Segoe UI",sans-serif;' +
        'font-size:14px;cursor:pointer;border-radius:12px;' +
        'background:rgba(120,120,128,0.24);color:rgba(30,30,35,0.95);}' +
        '#global-lookup-panel-bar .panel-btn:hover{' +
        'background:rgba(120,120,128,0.36);color:rgba(20,20,24,1);}' +
        // BUG-768 — dark-window variant (stamped via data-theme in renderStack):
        // light glyph + light chip so the buttons don't vanish on a dark surface.
        '#global-lookup-panel-bar[data-theme="dark"] .panel-btn{' +
        'background:rgba(235,235,245,0.14);color:rgba(235,235,245,0.72);}' +
        '#global-lookup-panel-bar[data-theme="dark"] .panel-btn:hover{' +
        'background:rgba(235,235,245,0.24);color:rgba(235,235,245,0.95);}' +
        // 深色窗:grip 提示文字改回浅色(默认的深灰在深色窗上会消失)。
        '#global-lookup-panel-bar[data-theme="dark"] .panel-grip{' +
        'color:rgba(235,235,245,0.66);}' +
        '#global-lookup-panel-bar .panel-btn.panel-pin-off{opacity:0.62;}' +
        // 防截屏按钮关闭态（允许截图）时同样调暗，与 pin-off 一致。
        '#global-lookup-panel-bar .panel-btn.panel-block-off{opacity:0.62;}' +
        // Bottom-right resize grip (posts beginWindowResize).
        '#global-lookup-panel-resize{' +
        'position:fixed;right:0;bottom:0;width:16px;height:16px;' +
        'cursor:nwse-resize;z-index:2147483001;pointer-events:auto;}' +
        // 真机反馈：面板 root 卡不画 per-shell 关闭 ×（与面板栏 × 重复；
        // 嵌套子卡的 × 保留）。
        '.global-lookup-frame-shell[data-panel-root="true"] ' +
        '.global-lookup-close{display:none;}' +
        // 剪贴板复制历史覆盖层（面板栏🕘 / 瞬态 root 卡🕘 触发）。渲染进 ROOT 卡
        // shell 内（绝对铺满、盖住 iframe），避免瞬态窗被 native 按 shell 矩形裁剪
        // 时历史面板落到透明裁剪区外看不见（与 BUG-749 gap click-through 同源）。
        '.clipboard-history-overlay{' +
        'position:absolute;left:0;top:0;width:100%;height:100%;' +
        'box-sizing:border-box;z-index:5;display:flex;flex-direction:column;' +
        'background:#ffffff;color:#1c1c1e;' +
        'font:13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}' +
        '.global-lookup-frame-shell[data-theme="dark"] .clipboard-history-overlay{' +
        'background:#1c1c1e;color:rgba(235,235,245,0.92);}' +
        '.clipboard-history-overlay .clipboard-history-head{' +
        'display:flex;align-items:center;gap:8px;padding:8px 10px;' +
        'border-bottom:1px solid rgba(120,120,128,0.24);flex:0 0 auto;}' +
        '.clipboard-history-overlay .clipboard-history-title{' +
        'flex:1 1 auto;font-weight:600;overflow:hidden;text-overflow:ellipsis;' +
        'white-space:nowrap;}' +
        '.clipboard-history-overlay .clipboard-history-btn{' +
        'flex:0 0 auto;cursor:pointer;padding:2px 8px;border-radius:6px;' +
        'user-select:none;color:inherit;opacity:0.8;}' +
        '.clipboard-history-overlay .clipboard-history-btn:hover{' +
        'background:rgba(120,120,128,0.16);opacity:1;}' +
        '.clipboard-history-overlay .clipboard-history-list{' +
        'flex:1 1 auto;overflow-y:auto;overflow-x:hidden;}' +
        '.clipboard-history-overlay .clipboard-history-row{' +
        'padding:8px 10px;border-bottom:1px solid rgba(120,120,128,0.16);' +
        'cursor:pointer;user-select:none;}' +
        '.clipboard-history-overlay .clipboard-history-row:hover{' +
        'background:rgba(120,120,128,0.12);}' +
        '.clipboard-history-overlay .clipboard-history-text{' +
        'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;' +
        'overflow:hidden;word-break:break-word;}' +
        '.clipboard-history-overlay .clipboard-history-time{' +
        'margin-top:2px;font-size:11px;opacity:0.5;}' +
        '.clipboard-history-overlay .clipboard-history-empty{' +
        'flex:1 1 auto;display:flex;align-items:center;justify-content:center;' +
        'opacity:0.5;padding:24px;text-align:center;}';
    var head = document.head ||
        (document.getElementsByTagName &&
            document.getElementsByTagName('head')[0]);
    (head || document.documentElement || document.body).appendChild(style);
  }

  // spec 2026-07-10 — the panel top bar: drag grip + pin toggle + close. Host
  // chrome (postToHost, no bridge id): beginWindowDrag/beginWindowResize are
  // intercepted natively (HTCAPTION modal loop); panelPin/panelClose reach the
  // Dart panel controller. Idempotent; only called from panel-mode renderStack.
  function ensurePanelBar() {
    if (!document || typeof document.createElement !== 'function') {
      return null;
    }
    var existing = document.getElementById('global-lookup-panel-bar');
    if (existing) {
      return existing;
    }
    ensureStyle();
    var bar = document.createElement('div');
    bar.id = 'global-lookup-panel-bar';

    var grip = document.createElement('div');
    grip.className = 'panel-grip';
    grip.textContent = '⋯';
    grip.addEventListener('mousedown', function (event) {
      if (event) {
        if (typeof event.preventDefault === 'function') event.preventDefault();
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
      }
      postToHost('beginWindowDrag', []);
    }, true);
    bar.appendChild(grip);

    // 剪贴板复制历史按钮（🕘）：postToHost('clipboardHistory') → Dart 从 DB 重载
    // 历史并注入 showClipboardHistory 渲染覆盖层。与 pin/close 同一 host-chrome 范式
    // （pointerdown 捕获 + stopPropagation，避免触发面板点外收子层）。
    var historyBtn = document.createElement('div');
    historyBtn.className = 'panel-btn panel-history';
    historyBtn.setAttribute('role', 'button');
    historyBtn.setAttribute('aria-label', 'Clipboard history');
    historyBtn.textContent = '🕘';
    historyBtn.addEventListener('pointerdown', function (event) {
      if (event) {
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (typeof event.preventDefault === 'function') event.preventDefault();
      }
      postToHost('clipboardHistory', []);
    }, true);
    bar.appendChild(historyBtn);

    var pinBtn = document.createElement('div');
    pinBtn.className =
        'panel-btn panel-pin' + (panelPinnedVisual ? '' : ' panel-pin-off');
    pinBtn.setAttribute('role', 'button');
    pinBtn.setAttribute('aria-label', 'Pin');
    pinBtn.textContent = '📌';
    var onPin = function (event) {
      if (event) {
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (typeof event.preventDefault === 'function') event.preventDefault();
      }
      setPanelPinnedVisual(!panelPinnedVisual);
      postToHost('panelPin', [panelPinnedVisual]);
    };
    pinBtn.addEventListener('pointerdown', onPin, true);
    bar.appendChild(pinBtn);

    // 防截屏按钮（🛡）：切换 SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)。
    // 默认开（盾牌亮）= 面板不进截图/录屏；关（盾牌变暗）= 允许被截。视觉态由
    // Dart 经 setPanelBlockCaptureVisual 同步（与 pin 同一范式）。
    var blockBtn = document.createElement('div');
    blockBtn.className =
        'panel-btn panel-block' + (panelBlockCaptureVisual ? '' : ' panel-block-off');
    blockBtn.setAttribute('role', 'button');
    blockBtn.setAttribute('aria-label', 'Block screen capture');
    blockBtn.textContent = '🛡';
    var onBlock = function (event) {
      if (event) {
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (typeof event.preventDefault === 'function') event.preventDefault();
      }
      setPanelBlockCaptureVisual(!panelBlockCaptureVisual);
      postToHost('panelBlockCapture', [panelBlockCaptureVisual]);
    };
    blockBtn.addEventListener('pointerdown', onBlock, true);
    bar.appendChild(blockBtn);

    var closeBtn = document.createElement('div');
    closeBtn.className = 'panel-btn panel-close';
    closeBtn.setAttribute('role', 'button');
    closeBtn.setAttribute('aria-label', 'Close');
    closeBtn.textContent = '×';
    var onClose = function (event) {
      if (event) {
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (typeof event.preventDefault === 'function') event.preventDefault();
      }
      postToHost('panelClose', []);
    };
    closeBtn.addEventListener('pointerdown', onClose, true);
    bar.appendChild(closeBtn);

    (document.body || document.documentElement).appendChild(bar);

    var resize = document.createElement('div');
    resize.id = 'global-lookup-panel-resize';
    resize.addEventListener('mousedown', function (event) {
      if (event) {
        if (typeof event.preventDefault === 'function') event.preventDefault();
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
      }
      postToHost('beginWindowResize', []);
    }, true);
    (document.body || document.documentElement).appendChild(resize);
    return bar;
  }

  // spec 2026-07-10 — syncs the pin button's VISUAL state to the Dart pref
  // (the truth source; native SetTopmost applies the actual z-order).
  function setPanelPinnedVisual(pinned) {
    panelPinnedVisual = !!pinned;
    var bar = document.getElementById &&
        document.getElementById('global-lookup-panel-bar');
    if (!bar) {
      return;
    }
    // children walk (not querySelector) so the node harness's minimal fake DOM
    // exercises the same code path a real browser does.
    var kids = bar.children || [];
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i];
      if (kid && String(kid.className).indexOf('panel-pin') >= 0) {
        kid.className =
            'panel-btn panel-pin' + (panelPinnedVisual ? '' : ' panel-pin-off');
        return;
      }
    }
  }

  // 防截屏 — 把 🛡 按钮视觉态同步到 Dart pref（真相源；native
  // SetWindowDisplayAffinity 应用真正的捕获排除）。与 setPanelPinnedVisual 同构。
  function setPanelBlockCaptureVisual(block) {
    panelBlockCaptureVisual = !!block;
    var bar = document.getElementById &&
        document.getElementById('global-lookup-panel-bar');
    if (!bar) {
      return;
    }
    var kids = bar.children || [];
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i];
      if (kid && String(kid.className).indexOf('panel-block') >= 0) {
        kid.className = 'panel-btn panel-block' +
            (panelBlockCaptureVisual ? '' : ' panel-block-off');
        return;
      }
    }
  }

  function ensureLayer() {
    ensureStyle();
    var existing = document.getElementById(LAYER_ID);
    if (existing) {
      return existing;
    }
    var layer = document.createElement('div');
    layer.id = LAYER_ID;
    layer.style.position = 'fixed';
    layer.style.left = '0';
    layer.style.top = '0';
    layer.style.width = '100%';
    layer.style.height = '100%';
    layer.style.pointerEvents = 'none';
    layer.style.zIndex = '2147483000';
    (document.body || document.documentElement).appendChild(layer);
    return layer;
  }

  function applyShellStyle(shell, descriptor) {
    var f = (descriptor && descriptor.frame) || {};
    // F2 — stamp the resolved brightness so the dark shell border/shadow variant
    // applies (the host document has no data-theme of its own; the render payload
    // carries it per layer).
    var theme = descriptor && descriptor.theme;
    if (theme === 'dark' || theme === 'light') {
      shell.setAttribute('data-theme', theme);
    }
    // spec 2026-07-10 panel — the ROOT shell ignores descriptor.frame and fills
    // the fixed window viewport below the panel bar; the sentence + entries
    // scroll INSIDE the iframe (fixed window = no reveal-resize loop, so a new
    // clipboard sentence re-renders in place without any window motion).
    // Nested children keep their Dart-computed cascade frames (bounded to the
    // panel rect by the render side).
    if (layoutMode === 'panel' && descriptor &&
        typeof descriptor.parentIndex === 'number' &&
        descriptor.parentIndex < 0) {
      shell.style.position = 'absolute';
      shell.style.left = '0px';
      shell.style.top = PANEL_BAR_HEIGHT + 'px';
      shell.style.width = '100%';
      shell.style.height = 'calc(100% - ' + PANEL_BAR_HEIGHT + 'px)';
      shell.style.zIndex = '0';
      shell.style.pointerEvents = 'auto';
      // 真机反馈：面板 root 卡的 per-shell 关闭 × 与面板栏的 × 重复——标记
      // panel-root，CSS 隐藏 root 卡的 ×（嵌套子卡保留各自的 ×，关子层有用）。
      shell.setAttribute('data-panel-root', 'true');
      return;
    }
    shell.style.position = 'absolute';
    // TODO-1189 — establish a per-shell STACKING CONTEXT ordered by insertion
    // depth (0 = root) so each shell — and the z-index:5 close-X inside it — is
    // CONFINED to its own context. Without a shell z-index the shells sit at
    // z-index:auto and every close-X (a POSITIVE z-index) escapes to the shared
    // parent (#global-lookup-host-layer) stacking level, painting ABOVE all
    // sibling shells' iframes regardless of DOM order: a parent card's X floated
    // over the child card stacked on top of it (the "X 穿透图层" bug). Giving each
    // shell a z-index equal to its depth makes a deeper child shell fully cover
    // its parent (including the parent's X); only the topmost card's X stays
    // exposed. The frames Map is insertion-ordered (root first), so layerIndexOf
    // is the depth. -1 (record not yet tracked) leaves z-index auto.
    var stackDepth = descriptor && descriptor.id != null
        ? layerIndexOf(descriptor.id)
        : -1;
    if (stackDepth >= 0) {
      shell.style.zIndex = String(stackDepth);
    }
    shell.style.left = (typeof f.left === 'number' ? f.left : 0) + 'px';
    shell.style.top = (typeof f.top === 'number' ? f.top : 0) + 'px';
    if (typeof f.width === 'number') {
      shell.style.width = f.width + 'px';
    }
    if (typeof f.height === 'number') {
      shell.style.height = f.height + 'px';
    }
    shell.style.pointerEvents = 'auto';
  }

  // C1 — wrap THIS iframe chrome.webview.postMessage so messages from popup.js
  // (via the adapter, which posts { handler, args, __bridgeId }) pass through the
  // host first: re-anchor onLinkClick LOCAL rect (args[1]) to full-screen CSS px,
  // and stamp __frameId on every message for layer attribution. The adapter reads
  // window.chrome.webview.postMessage FRESH each call, so wrapping after load is
  // observed by the next callHandler.
  function wrapFrameBridge(record) {
    var win = null;
    try {
      win = record.iframe.contentWindow;
    } catch (e) {
      win = null;
    }
    if (!win || !win.chrome || !win.chrome.webview) {
      return;
    }
    if (wrappedWindows.has(win)) {
      return;
    }
    var native = win.chrome.webview.postMessage;
    if (typeof native !== 'function') {
      return;
    }
    var topPost;
    try {
      // Route through the TOP-LEVEL bridge so the single C++ WebMessageReceived
      // receiver sees the re-anchored message.
      topPost = window.chrome.webview.postMessage.bind(window.chrome.webview);
    } catch (e) {
      topPost = native.bind(win.chrome.webview);
    }
    win.chrome.webview.postMessage = function (message) {
      // TODO-1067 (子3) — DRIVE THE REVEAL GATE OFF popup.js's authoritative
      // render signal instead of the body-height heuristic. popup.js calls
      // flutter_inappwebview.callHandler('popupRendered', scrollHeight) EXACTLY
      // when a render finishes (incl. the no-results card); it reaches the host
      // through THIS wrapped bridge. Marking content-ready here means the shell
      // only paints after popup.js truly rendered its themed card — no "empty
      // frame paints white, then the glossary fills in" flash, and no missed
      // no-results card (the old hasContent body>0 heuristic could reveal before
      // the theme CSS painted). The MutationObserver / safety timer stay as
      // belt-and-braces (a render that never signals still reveals via safety).
      // BUG-1139 ③ 陷阱提示：只吃 handler 名，**故意丢掉 args[0]**。那个数字是
      // popup.js 的 __hibikiScrollHeight()，在 CSS `zoom` 下是未乘 z 的 layout px，
      // 与 shell 几何（host CSS px）不同单位。谁将来拿它去定尺寸，必须先过
      // frameContentZoom 换算 —— 尺寸的唯一真值是 measureAndReport 的 overlaySize。
      try {
        if (message && typeof message === 'object' &&
            message.handler === 'popupRendered') {
          markContentReady(record);
        }
      } catch (e) {
        // Never let the reveal hook break the message forwarding below.
      }
      var out = message;
      try {
        out = transformFrameMessage(record, message);
      } catch (e) {
        out = message;
      }
      topPost(out);
    };
    wrappedWindows.add(win);
  }

  // Re-anchor + frame-stamp a message posted from record iframe. Pure given the
  // record current shell geometry; returns a NEW object. Non-onLinkClick messages
  // are passed through with only __frameId stamped.
  function transformFrameMessage(record, message) {
    if (!message || typeof message !== 'object') {
      return message;
    }
    var handler = message.handler;
    var out = {
      handler: handler,
      args: message.args,
      __frameId: record.id,
    };
    // TODO-1188 — rewrite the frame-LOCAL bridge id to a host-GLOBAL id and
    // remember the route (globalId -> {frameId, localId}) so the native reply
    // (which reaches only the top-level document) is forwarded back to the SOURCE
    // iframe's adapter with its own local id. The global id stays a plain integer
    // so the C++ digit scan of "__bridgeId": still extracts it verbatim.
    if (typeof message.__bridgeId !== 'undefined') {
      var globalBridgeId = ++bridgeSeq;
      bridgeRoutes.set(globalBridgeId, {
        frameId: record.id,
        localId: message.__bridgeId,
      });
      out.__bridgeId = globalBridgeId;
    }
    // TODO-893 v2 (symptom 1) — textSelected (tapping plain glossary text) carries
    // the SAME arg shape as onLinkClick (args[1] = the clicked word's iframe-LOCAL
    // rect), so it needs the identical iframe-local -> window-local re-anchor;
    // otherwise the child card anchors at iframe-internal coords (wrong cascade).
    if (
      (handler === 'onLinkClick' || handler === 'textSelected') &&
      Array.isArray(message.args)
    ) {
      var anchor = anchorRectToScreen(record, message.args[1]);
      var newArgs = message.args.slice();
      if (anchor) {
        newArgs[1] = anchor;
      }
      out.args = newArgs;
    }
    return out;
  }

  // Convert a child iframe LOCAL rect {x,y,width,height} (CSS px relative to the
  // iframe viewport) into a full-screen CSS px anchor by adding the frame shell
  // top-left + FRAME_CONTENT_TOP. Returns null when no usable rect. CSS px
  // throughout (the dpr boundary is C++ window geometry, never here).
  function anchorRectToScreen(record, localRect) {
    if (!localRect || typeof localRect !== 'object') {
      return null;
    }
    var shellLeft = parseFloat(record.shell.style.left) || 0;
    var shellTop = parseFloat(record.shell.style.top) || 0;
    var lx = typeof localRect.x === 'number' ? localRect.x : 0;
    var ly = typeof localRect.y === 'number' ? localRect.y : 0;
    var lw = typeof localRect.width === 'number' ? localRect.width : 0;
    var lh = typeof localRect.height === 'number' ? localRect.height : 0;
    return {
      x: shellLeft + lx,
      y: shellTop + FRAME_CONTENT_TOP + ly,
      width: lw,
      height: lh,
    };
  }

  // TODO-1067 (子1) — build the per-shell close-X. Positioned absolutely in the
  // shell's top-right; clicking it posts dismissPopupAt[layerIndex] so ONLY this
  // layer + its children close (the controller collapses the whole stack only
  // when the ROOT is dismissed, index 0). stopPropagation keeps the click from
  // also triggering onHostPointerDown's per-layer tapOutside. Returns null when
  // the DOM lacks createElement (node harness without full DOM) so createRecord
  // stays robust.
  function createCloseButton(frameId) {
    if (!document || typeof document.createElement !== 'function') {
      return null;
    }
    var btn = document.createElement('div');
    btn.className = 'global-lookup-close';
    btn.setAttribute('data-close-frame-id', frameId);
    btn.setAttribute('role', 'button');
    btn.setAttribute('aria-label', 'Close');
    // The glyph is set via CSS content (ensureStyle) so theming/font is uniform;
    // keep a textContent fallback for environments that do not honour ::before.
    if (typeof btn.textContent !== 'undefined') {
      btn.textContent = '×'; // multiplication sign ×
    }
    var onClose = function (event) {
      if (event && typeof event.stopPropagation === 'function') {
        event.stopPropagation();
      }
      if (event && typeof event.preventDefault === 'function') {
        event.preventDefault();
      }
      var index = layerIndexOf(frameId);
      if (index >= 0) {
        postToHost('dismissPopupAt', [index]);
      }
    };
    if (typeof btn.addEventListener === 'function') {
      // pointerdown (capture) so it wins over the host document pointerdown that
      // also fires for this host-chrome click; click kept as a fallback.
      btn.addEventListener('pointerdown', onClose, true);
      btn.addEventListener('click', onClose, true);
    }
    return btn;
  }

  // Phase C（弹窗尺寸精细化 2026-07-13）— 瞬态覆盖窗 ROOT 卡的右下角 resize grip。
  // mousedown 直接 postToHost('beginWindowResize')（host 顶层 DOM，无需 iframe 桥，
  // 与面板 grip 一致）：native 收到后 PostMessage(WM_NCLBUTTONDOWN, HTBOTTOMRIGHT)
  // 进模态 size 循环，松手经 WM_EXITSIZEMOVE 回报窗口 rect 给 Dart 落 overlay 尺寸键。
  // preventDefault + stopPropagation(capture)：不让这次 mousedown 触发 host 的
  // 点外关闭 / 拖出选区。返回 null 时（node harness 无 DOM）createRecord 照常健壮。
  function createResizeGrip() {
    if (!document || typeof document.createElement !== 'function') {
      return null;
    }
    var grip = document.createElement('div');
    grip.className = 'global-lookup-resize-grip';
    grip.setAttribute('role', 'button');
    grip.setAttribute('aria-label', 'Resize');
    var onDown = function (event) {
      if (event) {
        if (typeof event.preventDefault === 'function') event.preventDefault();
        if (typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
      }
      postToHost('beginWindowResize', []);
    };
    if (typeof grip.addEventListener === 'function') {
      grip.addEventListener('mousedown', onDown, true);
    }
    return grip;
  }

  // 剪贴板复制历史按钮（🕘）——瞬态覆盖窗 root 卡左上角。与面板栏🕘同一 host-chrome
  // 范式：pointerdown 捕获 + stopPropagation（不触发 root 卡的点外收层），postToHost
  // 让 Dart 从 DB 重载历史并回注 showClipboardHistory。
  function createHistoryButton() {
    if (!document || typeof document.createElement !== 'function') {
      return null;
    }
    var btn = document.createElement('div');
    btn.className = 'global-lookup-history';
    btn.setAttribute('role', 'button');
    btn.setAttribute('aria-label', 'Clipboard history');
    if (typeof btn.textContent !== 'undefined') {
      btn.textContent = '🕘';
    }
    var onOpen = function (event) {
      if (event && typeof event.stopPropagation === 'function') {
        event.stopPropagation();
      }
      if (event && typeof event.preventDefault === 'function') {
        event.preventDefault();
      }
      postToHost('clipboardHistory', []);
    };
    if (typeof btn.addEventListener === 'function') {
      btn.addEventListener('pointerdown', onOpen, true);
      btn.addEventListener('click', onOpen, true);
    }
    return btn;
  }

  // 历史覆盖层渲染进 ROOT 卡 shell（parentIndex < 0；面板模式该卡带 data-panel-root，
  // 瞬态模式即级联根卡）。挂进 shell 内而非窗口层：瞬态窗被 native 按 shell 卡矩形裁剪，
  // 挂窗口层的覆盖层会落到透明裁剪区外不可见（BUG-749 同源）。返回 root shell 或 null。
  function rootShellForHistory() {
    var found = null;
    if (frames && typeof frames.forEach === 'function') {
      frames.forEach(function (record) {
        if (found) return;
        if (record && record.shell &&
            typeof record.parentIndex === 'number' &&
            record.parentIndex < 0) {
          found = record.shell;
        }
      });
    }
    return found;
  }

  // 移除所有历史覆盖层（× 关闭 / 选中一条查词 / 重新打开前清旧层）。优先
  // querySelectorAll，node harness 的极简 DOM 无此 API 时回退遍历各 shell 子节点。
  function hideClipboardHistory() {
    if (!document) return false;
    var removed = false;
    var existing = (typeof document.querySelectorAll === 'function')
        ? document.querySelectorAll('.clipboard-history-overlay')
        : null;
    if (existing && existing.length) {
      for (var i = existing.length - 1; i >= 0; i--) {
        var node = existing[i];
        if (node && node.parentNode &&
            typeof node.parentNode.removeChild === 'function') {
          node.parentNode.removeChild(node);
          removed = true;
        }
      }
      return removed;
    }
    if (frames && typeof frames.forEach === 'function') {
      frames.forEach(function (record) {
        if (!record || !record.shell) return;
        var kids = record.shell.children || [];
        for (var j = kids.length - 1; j >= 0; j--) {
          var kid = kids[j];
          if (kid &&
              String(kid.className).indexOf('clipboard-history-overlay') >= 0 &&
              typeof record.shell.removeChild === 'function') {
            record.shell.removeChild(kid);
            removed = true;
          }
        }
      });
    }
    return removed;
  }

  // 由 Dart 注入渲染剪贴板复制历史覆盖层。payload（JSON 串或对象）：
  //   { entries:[{text, time}], title, clearLabel, emptyLabel }
  // entries 顺序=最新在前（Dart 已 reverse）。每行点选 → lookupClipboardHistoryEntry
  // 让 Dart 重查该文本；清空 → clearClipboardHistory；× / 选中一条后自动关层。
  function showClipboardHistory(payload) {
    var data = payload;
    if (typeof payload === 'string') {
      try {
        data = JSON.parse(payload);
      } catch (e) {
        data = null;
      }
    }
    if (!data || typeof data !== 'object') data = {};
    var entries = (data.entries && data.entries.length) ? data.entries : [];
    var title = data.title || 'Clipboard history';
    var clearLabel = data.clearLabel || 'Clear';
    var emptyLabel = data.emptyLabel || '';
    var host = rootShellForHistory();
    if (!host || typeof document.createElement !== 'function' ||
        typeof host.appendChild !== 'function') {
      return false;
    }
    hideClipboardHistory();

    var overlay = document.createElement('div');
    overlay.className = 'clipboard-history-overlay';

    var head = document.createElement('div');
    head.className = 'clipboard-history-head';
    var titleEl = document.createElement('div');
    titleEl.className = 'clipboard-history-title';
    titleEl.textContent = title;
    head.appendChild(titleEl);

    var clearBtn = document.createElement('div');
    clearBtn.className = 'clipboard-history-btn';
    clearBtn.setAttribute('role', 'button');
    clearBtn.textContent = clearLabel;
    if (typeof clearBtn.addEventListener === 'function') {
      clearBtn.addEventListener('pointerdown', function (event) {
        if (event && typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (event && typeof event.preventDefault === 'function') {
          event.preventDefault();
        }
        postToHost('clearClipboardHistory', []);
      }, true);
    }
    head.appendChild(clearBtn);

    var closeBtn = document.createElement('div');
    closeBtn.className = 'clipboard-history-btn';
    closeBtn.setAttribute('role', 'button');
    closeBtn.textContent = '×';
    if (typeof closeBtn.addEventListener === 'function') {
      closeBtn.addEventListener('pointerdown', function (event) {
        if (event && typeof event.stopPropagation === 'function') {
          event.stopPropagation();
        }
        if (event && typeof event.preventDefault === 'function') {
          event.preventDefault();
        }
        hideClipboardHistory();
      }, true);
    }
    head.appendChild(closeBtn);
    overlay.appendChild(head);

    if (!entries.length) {
      var empty = document.createElement('div');
      empty.className = 'clipboard-history-empty';
      empty.textContent = emptyLabel;
      overlay.appendChild(empty);
    } else {
      var list = document.createElement('div');
      list.className = 'clipboard-history-list';
      for (var k = 0; k < entries.length; k++) {
        (function (entry) {
          var row = document.createElement('div');
          row.className = 'clipboard-history-row';
          row.setAttribute('role', 'button');
          var textEl = document.createElement('div');
          textEl.className = 'clipboard-history-text';
          textEl.textContent =
              String(entry && entry.text != null ? entry.text : '');
          row.appendChild(textEl);
          if (entry && entry.time) {
            var timeEl = document.createElement('div');
            timeEl.className = 'clipboard-history-time';
            timeEl.textContent = String(entry.time);
            row.appendChild(timeEl);
          }
          var onPick = function (event) {
            if (event && typeof event.stopPropagation === 'function') {
              event.stopPropagation();
            }
            if (event && typeof event.preventDefault === 'function') {
              event.preventDefault();
            }
            var text = entry && entry.text != null ? String(entry.text) : '';
            if (!text) return;
            hideClipboardHistory();
            postToHost('lookupClipboardHistoryEntry', [text]);
          };
          if (typeof row.addEventListener === 'function') {
            row.addEventListener('pointerdown', onPick, true);
            row.addEventListener('click', onPick, true);
          }
          list.appendChild(row);
        })(entries[k]);
      }
      overlay.appendChild(list);
    }

    host.appendChild(overlay);
    return true;
  }

  function createRecord(layer, descriptor) {
    var shell = document.createElement('div');
    shell.className = 'global-lookup-frame-shell';
    shell.setAttribute('data-frame-id', descriptor.id);
    // D1 — start gated-hidden. The two flags flip independently:
    // content-ready (iframe DOM arrived) + reveal-ready (geometry placed).
    shell.setAttribute(ATTR_CONTENT_READY, 'false');
    shell.setAttribute(ATTR_REVEAL_READY, 'false');

    var iframe = document.createElement('iframe');
    // Deliberately NO sandbox attribute (same-origin contentWindow injection).
    iframe.setAttribute('src', POPUP_SRC);
    iframe.setAttribute('frameborder', '0');
    iframe.style.width = '100%';
    iframe.style.height = '100%';
    iframe.style.border = '0';
    iframe.style.background = 'transparent';

    shell.appendChild(iframe);
    // TODO-1067 (子1) — the app-external overlay is a bare iframe host: the
    // in-app Flutter chrome (its close affordance) never wraps these shells, so
    // there was NO way to dismiss a card with the mouse other than a lucky
    // click-outside (which子5 shows also over-collapsed the whole stack). Draw a
    // per-shell close-X in the top-right corner (host DOM, NOT inside the iframe)
    // that dismisses EXACTLY this layer + its children via dismissPopupAt[index].
    // The X lives on the shell, so `closest('.global-lookup-frame-shell')` in
    // onHostPointerDown still classifies a stray click as a shell hit; the X's
    // own handler stops propagation + posts the layer-scoped dismiss so it never
    // falls through to the per-layer tapOutside / root dismiss.
    var closeBtn = createCloseButton(descriptor.id);
    if (closeBtn) {
      shell.appendChild(closeBtn);
    }
    // Phase C — 只给瞬态覆盖窗（cascade）的 ROOT 卡（parentIndex < 0）挂 resize grip：
    // 调整的是 overlay「最大卡尺寸」真值，子级级联卡由它派生，故不各自加把手；面板
    // 模式另有窗口级 #global-lookup-panel-resize，不在此重复。
    if (layoutMode !== 'panel' && descriptor &&
        typeof descriptor.parentIndex === 'number' &&
        descriptor.parentIndex < 0) {
      var grip = createResizeGrip();
      if (grip) {
        shell.appendChild(grip);
      }
      // 剪贴板复制历史按钮（🕘）——瞬态窗无面板栏，挂 root 卡左上角（躲 native
      // shell 裁剪）。postToHost('clipboardHistory') → Dart 重载并注入覆盖层。
      var histBtn = createHistoryButton();
      if (histBtn) {
        shell.appendChild(histBtn);
      }
    }
    layer.appendChild(shell);

    var record = {
      id: descriptor.id,
      parentIndex: descriptor.parentIndex,
      iframe: iframe,
      shell: shell,
      descriptor: descriptor,
      loaded: false,
      contentReady: false,
      revealReady: false,
      observer: null,
      contentSafetyTimer: null,
      revealSafetyTimer: null,
    };
    frameSources.set(iframe, descriptor.id);

    iframe.addEventListener('load', function () {
      record.loaded = true;
      wrapFrameBridge(record);
      injectContent(record);
      // TODO-1231 P1 — seed the has-child flag on cold load (mirrors the in-app
      // cold-load _setHasChildPopupJs); renderPayload keeps it in sync after.
      applyHasChildPopup(record);
      observeContent(record);
      scheduleMeasure();
    });
    return record;
  }

  // D1 — flip a gate flag and, if both are now set, the shell paints (the CSS
  // attribute selector does the actual reveal). Idempotent.
  function setGateFlag(record, attr, key) {
    if (record[key]) {
      return;
    }
    record[key] = true;
    if (record.shell && typeof record.shell.setAttribute === 'function') {
      record.shell.setAttribute(attr, 'true');
    }
  }

  // TODO-1231 v3 (BUG-583) — a shell is "origin-covered" when the committed layer
  // origin (layerOffsetLeft/Top — the window origin the C++ RevealStack actually
  // moved to, set by commitLayerShift) is at or outside the shell's own top-left,
  // i.e. the shell falls INSIDE the current window viewport. An up/left-cascading
  // child placed at window-local coords LEFT/ABOVE the current origin is NOT covered
  // until commitLayerShift moves the origin out to include it; revealing it before
  // then paints it CLIPPED at the window edge for the whole Dart round-trip (the
  // residual "子弹窗闪" — the child appears cut, then jumps into place). Down-right /
  // already-ratcheted shells are covered immediately (unchanged). COVER_EPS absorbs
  // sub-pixel rounding across the device-pixel-ratio boundary.
  function shellCoveredByOrigin(record) {
    if (!record || !record.shell) {
      return false;
    }
    var left = parseFloat(record.shell.style.left) || 0;
    var top = parseFloat(record.shell.style.top) || 0;
    return left >= layerOffsetLeft - COVER_EPS &&
        top >= layerOffsetTop - COVER_EPS;
  }

  // TODO-1231 v3 (BUG-583) — flip reveal-ready ONLY once the shell's geometry is
  // placed AND the committed window origin covers it, so a shell never paints
  // outside the window (clipped). A root / down-right child is covered from the
  // start and flips immediately (byte-identical to the old unconditional flip). An
  // up/left child is HELD until commitLayerShift extends the origin to reach it
  // (re-checked there), so it first appears already in-position — no clipped-then-
  // jump. A one-shot safety flips it regardless after REVEAL_READY_SAFETY_MS so a
  // never-arriving commitLayerShift can never leave a card stuck hidden.
  function maybeFlipRevealReady(record) {
    if (!record) {
      return;
    }
    if (record.revealReady) {
      if (record.revealSafetyTimer != null) {
        clearTimerSafe(record.revealSafetyTimer);
        record.revealSafetyTimer = null;
      }
      return;
    }
    if (shellCoveredByOrigin(record)) {
      if (record.revealSafetyTimer != null) {
        clearTimerSafe(record.revealSafetyTimer);
        record.revealSafetyTimer = null;
      }
      setGateFlag(record, ATTR_REVEAL_READY, 'revealReady');
      return;
    }
    if (record.revealSafetyTimer == null) {
      record.revealSafetyTimer = setTimerSafe(function () {
        record.revealSafetyTimer = null;
        setGateFlag(record, ATTR_REVEAL_READY, 'revealReady');
      }, REVEAL_READY_SAFETY_MS);
    }
  }

  function markContentReady(record) {
    if (record.contentSafetyTimer != null) {
      clearTimerSafe(record.contentSafetyTimer);
      record.contentSafetyTimer = null;
    }
    if (record.observer && typeof record.observer.disconnect === 'function') {
      try {
        record.observer.disconnect();
      } catch (e) {
        // no-op
      }
      record.observer = null;
    }
    setGateFlag(record, ATTR_CONTENT_READY, 'contentReady');
    // Content height just changed -> the union bbox may grow. Re-measure
    // (coalesced) so Dart resizes the window to fit the filled card.
    scheduleMeasure();
  }

  // D1 — observe the SAME-ORIGIN iframe contentDocument.body for real content:
  // popup.js renders a `.glossary-content` (or the no-results card gives body a
  // non-zero height). No popup.js change needed (host reads the same-origin DOM
  // directly). Degrades gracefully where MutationObserver is unavailable (node
  // harness): fall back to the safety timer / an immediate content check.
  function observeContent(record) {
    if (record.contentReady) {
      return;
    }
    if (hasContent(record)) {
      markContentReady(record);
      return;
    }
    var body = null;
    try {
      var doc = record.iframe.contentDocument;
      body = doc && doc.body;
    } catch (e) {
      body = null;
    }
    if (body && typeof window.MutationObserver === 'function') {
      try {
        record.observer = new window.MutationObserver(function () {
          if (hasContent(record)) {
            markContentReady(record);
          }
        });
        record.observer.observe(body, {
          childList: true,
          subtree: true,
          attributes: false,
        });
      } catch (e) {
        record.observer = null;
      }
    }
    // Safety: force content-ready after a budget so a render failure never
    // leaves the card invisible (mirrors the Dart reveal safety).
    record.contentSafetyTimer = setTimerSafe(function () {
      record.contentSafetyTimer = null;
      markContentReady(record);
    }, CONTENT_READY_SAFETY_MS);
  }

  // TODO-1067 (子3) — True once popup.js has PAINTED a real card: a rendered
  // glossary node (.glossary-content) OR the no-results card (.no-results). The
  // old fallback accepted ANY body with a non-zero rendered height, which let the
  // gate reveal an empty/pre-theme body (white flash) before popup.js finished.
  // The authoritative reveal is now popupRendered (wrapFrameBridge); this
  // structural check only backs the synchronous first-look + MutationObserver, so
  // tightening it to a real card node removes the height-heuristic false-positive
  // without losing the no-results path.
  function hasContent(record) {
    try {
      var doc = record.iframe.contentDocument;
      if (!doc || !doc.body || typeof doc.querySelector !== 'function') {
        return false;
      }
      return !!(doc.querySelector('.glossary-content') ||
                doc.querySelector('.no-results'));
    } catch (e) {
      return false;
    }
  }

  function injectContent(record) {
    var win = null;
    try {
      win = record.iframe.contentWindow;
    } catch (e) {
      win = null;
    }
    if (!win) {
      return false;
    }
    var d = record.descriptor || {};
    try {
      if (typeof d.settingsJs === 'string' && d.settingsJs.length) {
        win.eval(d.settingsJs);
      }
      // TODO-1231 P1 — remember the body last eval'd into this frame so
      // renderPayload can SKIP re-evaling an UNCHANGED body (a full renderPopup()
      // card teardown+rebuild = the "父弹窗闪烁") on a nested open/close. Recorded
      // even for an empty body so the equality check stays stable.
      record.injectedSettingsJs =
          (typeof d.settingsJs === 'string') ? d.settingsJs : '';
      return true;
    } catch (e) {
      return false;
    }
  }

  // TODO-1231 P1 — apply THIS frame's has-child-popup boolean on its own cheap
  // channel: a single `window.__hasChildPopup` assignment inside the frame realm,
  // mirroring the in-app _setHasChildPopupJs. Kept OFF settingsJs so a nested
  // open/close never re-evals the whole card body. popup.js reads
  // window.__hasChildPopup LIVE at click time (parent-card tap -> close the
  // child), so setting the variable alone — no renderPopup() — is sufficient
  // (BUG-434 behaviour preserved). Guarded on the last-applied value so an
  // unchanged re-render posts nothing.
  function applyHasChildPopup(record) {
    var desired = !!(record.descriptor && record.descriptor.hasChildPopup);
    if (record.hasChildPopup === desired) {
      return;
    }
    var win = null;
    try {
      win = record.iframe.contentWindow;
    } catch (e) {
      win = null;
    }
    if (!win || typeof win.eval !== 'function') {
      return;
    }
    try {
      win.eval('window.__hasChildPopup = ' + (desired ? 'true' : 'false') + ';');
      record.hasChildPopup = desired;
    } catch (e) {
      // No realm yet (node harness / not loaded) -> the next render/load applies.
    }
  }

  function renderPayload(layer, descriptor) {
    var record = frames.get(descriptor.id);
    if (!record) {
      record = createRecord(layer, descriptor);
      frames.set(descriptor.id, record);
    } else {
      record.parentIndex = descriptor.parentIndex;
      record.descriptor = descriptor;
    }
    applyShellStyle(record.shell, descriptor);
    // D1 / TODO-1231 v3 — geometry is placed for this layer, so reveal-ready is
    // eligible. The shell still stays hidden until content-ready also flips (the
    // CSS gate needs BOTH). reveal-ready flips NOW only if the committed window
    // origin already covers the shell (root / down-right child); an up/left child
    // whose window has not yet moved to reach it is HELD so it never paints clipped
    // — commitLayerShift flips it once the origin catches up.
    maybeFlipRevealReady(record);
    if (record.loaded) {
      wrapFrameBridge(record);
      // TODO-1231 P1 — only re-run the FULL body (which ends in renderPopup() = a
      // card DOM teardown+rebuild) when it ACTUALLY changed. A nested open/close
      // leaves the parent's body byte-identical (has-child now rides its own
      // channel below), so re-evaling it needlessly rebuilt the card, dropped its
      // scroll, and re-fired favorite/duplicate/audio probes — the "父弹窗闪烁".
      // Skip it; the one thing that changed rides applyHasChildPopup.
      if (record.injectedSettingsJs !== descriptor.settingsJs) {
        injectContent(record);
        observeContent(record);
      } else if (hasContent(record)) {
        // TODO-1231 (BUG-583) — the body did not change (same-word re-lookup, or
        // a nested render re-sending the parent's identical body) AND the frame
        // already holds a rendered card. That card IS this render's correct
        // content, so satisfy the (possibly beginLookup-re-gated) content gate
        // now. Without this, a same-word re-lookup — where renderPayload skips the
        // re-eval and beginLookup no longer re-observes the stale card — would
        // wait for a popupRendered that never comes and reveal blank via the Dart
        // ready-safety only. Gated on hasContent so a freshly-created empty frame
        // (whose body genuinely has not rendered yet) still follows the
        // observeContent gate. markContentReady is a no-op when already satisfied
        // (nested open of a live parent).
        markContentReady(record);
      }
      applyHasChildPopup(record);
    }
    return record;
  }

  function removeMissing(keepIds) {
    var keep = new Set(keepIds);
    var toRemove = [];
    frames.forEach(function (record, id) {
      if (!keep.has(id)) {
        toRemove.push(id);
      }
    });
    for (var i = 0; i < toRemove.length; i++) {
      var id = toRemove[i];
      var record = frames.get(id);
      if (record) {
        // D1 — tear down the content observer + safety timer so a removed layer
        // leaves no dangling MutationObserver / timeout.
        if (record.observer &&
            typeof record.observer.disconnect === 'function') {
          try {
            record.observer.disconnect();
          } catch (e) {
            // no-op
          }
          record.observer = null;
        }
        if (record.contentSafetyTimer != null) {
          clearTimerSafe(record.contentSafetyTimer);
          record.contentSafetyTimer = null;
        }
        if (record.revealSafetyTimer != null) {
          clearTimerSafe(record.revealSafetyTimer);
          record.revealSafetyTimer = null;
        }
        if (record.shell && record.shell.parentNode) {
          record.shell.parentNode.removeChild(record.shell);
        }
      }
      frames.delete(id);
      // TODO-1188 — drop any pending bridge routes for the removed frame so the
      // route map never leaks entries for a torn-down iframe (whose adapter can
      // no longer resolve anything anyway).
      bridgeRoutes.forEach(function (route, globalId) {
        if (route.frameId === id) {
          bridgeRoutes.delete(globalId);
        }
      });
    }
  }

  // TODO-1095 — a NEW hotkey lookup is starting. Dart calls this (via the render
  // channel) BEFORE the fresh renderStack. Because the root frame id is now
  // STABLE (the root iframe is reused, not rebuilt), two per-lookup resets that
  // used to piggy-back on a changing root id must be done explicitly here:
  //   1. Clear lastBBoxKey so the new card's reveal-driving overlaySize is never
  //      de-duped away when its union bbox equals the previous lookup's.
  //   2. RE-GATE the reused root shell: reset data-content-ready to false and
  //      re-arm the content observer + safety timer, so the reveal WAITS for THIS
  //      lookup's popupRendered instead of inheriting the previous card's already
  //      satisfied content-ready (the "audio plays but no popup" mislevel: the
  //      window revealed before the fresh iframe card had actually rendered).
  // reveal-ready is left intact (geometry is re-placed by the following
  // renderStack); only the CONTENT half of the two-flag gate is re-armed.
  function beginLookup(rootId) {
    lastBBoxKey = '';
    // BUG-749 — native cleared its shell rects on Hide(); force a re-post even
    // when the fresh card's rects CSV equals the previous lookup's.
    lastShellRectsKey = '';
    // TODO-1231 v3 (BUG-583) — a NEW hotkey lookup re-reveals the window from a
    // fresh origin; drop the committed layer origin so a stale NEGATIVE origin left
    // by a PREVIOUS lookup's up/left cascade cannot falsely mark THIS lookup's
    // up/left child as already-covered (which would reveal it clipped). Mirrors the
    // Dart ratchet reset (_ratchetLeft/_ratchetTop = infinity) one layer up. The
    // real layer transform is re-applied by this lookup's first commitLayerShift.
    layerOffsetLeft = 0;
    layerOffsetTop = 0;
    // BUG-859 — reset the layer's DOM transform IN LOCK-STEP with the shadow
    // offsets above. Resetting only the variables left the previous lookup's
    // translate (layer.style.left/top) applied while shellCoveredByOrigin /
    // frameIdAtPoint reasoned against the zeroed offsets: the reveal gate was
    // defeated (a stale-shifted card counted as covered) and any reveal that
    // bypasses commitLayerShift (legacy Reveal / ready-safety fallback) showed
    // the fresh root displaced by the stale shift. The normal revealStack path
    // re-applies the correct transform via commitLayerShift, so this is a no-op
    // there (style already 0 for a fresh down-right cascade).
    var layerEl = document.getElementById(LAYER_ID);
    if (layerEl) {
      layerEl.style.left = '0px';
      layerEl.style.top = '0px';
    }
    // TODO-1345 (BUG-583 深层根因续) — drop the previous lookup's reserved cascade
    // floor so it can never leak into a fresh lookup (a new lookup re-computes its
    // own floor from the new cursor position and pushes it via the next renderStack).
    originFloorLeft = 0;
    originFloorTop = 0;
    if (typeof rootId !== 'string' || !rootId) {
      return;
    }
    var record = frames.get(rootId);
    if (!record) {
      return; // First-ever lookup for this id: createRecord gates it fresh.
    }
    // Re-arm the content half of the reveal gate for the reused shell.
    record.contentReady = false;
    if (record.shell && typeof record.shell.setAttribute === 'function') {
      record.shell.setAttribute(ATTR_CONTENT_READY, 'false');
    }
    // BUG-745 — strip the TODO-890 slide-out class off the REUSED root shell.
    // dismissRootWithSlide adds .global-lookup-dismissing (translateX(120%) +
    // opacity 0) and NOTHING ever removed it, while the root shell survives
    // across lookups (stable root id, TODO-1095). After the first slide
    // dismissal every later card therefore rendered ALREADY slid off-window and
    // fully transparent: native revealed the window, popupRendered/overlaySize
    // all fired, but the user saw NOTHING ("第一次正常，之后的弹窗根本不出
    // 现"). The TODO-1345 floor window made every click-outside take the JS
    // slide path (clicks always land inside the near-fullscreen window), so a
    // session was poisoned on its very first dismissal.
    if (record.shell && record.shell.classList &&
        typeof record.shell.classList.remove === 'function') {
      record.shell.classList.remove('global-lookup-dismissing');
    }
    // A slide interrupted by this new lookup must not leave the latch stuck.
    dismissingRoot = false;
    // TODO-1231 (BUG-583) -- tear down the PREVIOUS lookup's content observer +
    // safety timer, but DO NOT re-arm an observer off the stale card here. The
    // reused iframe still holds the previous lookup's `.glossary-content`, so
    // calling observeContent now would synchronously re-satisfy content-ready
    // from that STALE card and fire a premature overlaySize -- which revealed the
    // OLD card at the cursor for a frame (the "第一个弹窗出现时闪") before showAt
    // parked the window off-screen again for the fresh render. The content gate
    // is instead re-armed by the FOLLOWING renderStack: a changed body runs
    // injectContent + observeContent on the NEW card; an unchanged body (same
    // word) markContentReady's the already-correct content in renderPayload. So
    // the reveal-driving overlaySize now originates only from the fresh render,
    // never from the stale card.
    if (record.observer && typeof record.observer.disconnect === 'function') {
      try {
        record.observer.disconnect();
      } catch (e) {
        // no-op
      }
      record.observer = null;
    }
    if (record.contentSafetyTimer != null) {
      clearTimerSafe(record.contentSafetyTimer);
      record.contentSafetyTimer = null;
    }
  }

  // TODO-1345 (BUG-583 深层根因续) — set the reserved cascade origin floor from the
  // render payload (Dart's screen-edge-aware headroom). Called from renderStack so
  // the floor is in place before the following measureAndReport reports the origin.
  // Guarded: an absent / malformed value leaves the floor at its current (reset) 0
  // (no reservation). The floor only ever reserves OUTWARD (<= 0); a positive value
  // would pull the origin INWARD and clip the root, so it is clamped out to 0.
  function applyOriginFloor(floor) {
    if (!floor || typeof floor !== 'object') {
      return;
    }
    var l = (typeof floor.left === 'number' && isFinite(floor.left))
        ? floor.left
        : 0;
    var t = (typeof floor.top === 'number' && isFinite(floor.top))
        ? floor.top
        : 0;
    originFloorLeft = l < 0 ? l : 0;
    originFloorTop = t < 0 ? t : 0;
  }

  function renderStack(payload) {
    var popups = (payload && payload.popups) || [];
    // TODO-1345 — pick up this lookup's reserved origin floor BEFORE the diff +
    // measure so the very first reveal already commits the headroom-covered origin.
    applyOriginFloor(payload && payload.originFloor);
    // spec 2026-07-10 — panel mode rides the payload (absent = cascade, so the
    // transient overlay's payload/behaviour is byte-identical to pre-panel).
    layoutMode = (payload && payload.layoutMode) === 'panel' ? 'panel' : 'cascade';
    if (layoutMode === 'panel') {
      var panelBar = ensurePanelBar();
      // BUG-768 — the panel bar lives in document.body (fixed, OUTSIDE any shell),
      // so it never inherits the per-shell data-theme. Without it the pin/close
      // glyphs kept the light-theme dark-gray color (rgba(60,60,67,.6)) and
      // vanished on a dark window. Stamp the root descriptor's resolved brightness
      // onto the bar so the dark-theme .panel-btn variant applies (mirrors the
      // per-shell .global-lookup-close dark variant).
      var rootTheme = popups.length ? (popups[0] && popups[0].theme) : null;
      if (panelBar && (rootTheme === 'dark' || rootTheme === 'light')) {
        panelBar.setAttribute('data-theme', rootTheme);
      }
    }
    if (!popups.length) {
      removeMissing([]);
      lastBBoxKey = '';
      lastShellRectsKey = '';
      lastRootId = null;
      return;
    }
    var layer = ensureLayer();
    var ids = [];
    for (var i = 0; i < popups.length; i++) {
      var descriptor = popups[i];
      if (!descriptor || typeof descriptor.id !== 'string') {
        continue;
      }
      ids.push(descriptor.id);
      renderPayload(layer, descriptor);
    }
    // TODO-1079 (C) — a changed ROOT frame id means a fresh lookup: clear the
    // bbox de-dup so the new card's first overlaySize is never suppressed by a
    // stale identical-bbox key from the previous lookup.
    var rootId = ids.length ? ids[0] : null;
    if (rootId !== lastRootId) {
      lastRootId = rootId;
      lastBBoxKey = '';
      lastShellRectsKey = '';
    }
    removeMissing(ids);
    scheduleMeasure();
  }

  // D2 — measure every live frame same-origin content height and report the UNION
  // bounding box of all shells (CSS px) so C++ enlarges the window to fit the
  // whole stack. Height refined to the iframe content (capped to planned shell
  // height). devicePixelRatio sent so C++ converts CSS-px box to physical-px
  // window geometry. De-duped on the box key.
  function measureAndReport() {
    if (!frames.size) {
      return;
    }
    // spec 2026-07-10 panel — the window rect is FIXED (user-remembered): no
    // overlaySize report, no reveal-resize loop. The root shell fills the
    // viewport (applyShellStyle) and content scrolls inside the iframe, so a
    // new clipboard sentence re-renders with zero window motion. Shells still
    // need their reveal gate flipped (normally done by the overlaySize path),
    // so flip it here directly.
    if (layoutMode === 'panel') {
      frames.forEach(function (record) {
        setGateFlag(record, ATTR_REVEAL_READY, 'revealReady');
      });
      return;
    }
    // TODO-1231 v2 (BUG-583) — the union bbox has two independently-sourced
    // corners because they drive DIFFERENT things:
    //   * MIN-corner (origin): drives the window POSITION (SetWindowPos) AND the
    //     compensating commitLayerShift(-min) that pins the ROOT card at the
    //     cursor. A shell's on-screen position is (windowOrigin + layerShift +
    //     shellLocal) = cursor + shellLocal, so moving the origin does NOT move a
    //     card — EXCEPT for the ~1 frame where SetWindowPos has landed on the DWM
    //     window but the commitLayerShift ExecuteScript has NOT yet re-composited
    //     the WebView2 layer: during that gap the pinned parent card lurches by
    //     the origin delta, then snaps back (the residual “父弹窗出现子弹窗时闪
    //     一下”). So the origin must follow ONLY shells the user can already see
    //     (content-ready): a freshly-opened, still-gated-hidden child that
    //     cascades UP/LEFT must NOT drag the origin outward — and lurch the parent
    //     — before it has even rendered. When that child becomes content-ready
    //     (about to paint) it joins the origin set, so the single origin move
    //     coincides with the child's own appearance frame (masked).
    //   * MAX-corner (far edges): drives the window SIZE only. Growing it keeps
    //     the origin (and thus the layer shift) fixed, so it never moves the
    //     parent. It therefore includes EVERY placed shell — the window pre-grows
    //     down/right to cover a not-yet-ready child so that child is not clipped
    //     when it paints. A DOWN-RIGHT cascade only ever grows the max-corner, so
    //     the parent is now PERFECTLY still throughout a nested open.
    // Bootstrap: before ANY shell is content-ready (the very first root reveal,
    // where there is no visible parent to lurch), the origin falls back to all
    // placed shells — byte-identical to the pre-fix behaviour, so the first
    // reveal is unchanged and the existing harness (#11/#15) still passes.
    var minLeft = Infinity;
    var minTop = Infinity;
    var minLeftAll = Infinity;
    var minTopAll = Infinity;
    var maxRight = -Infinity;
    var maxBottom = -Infinity;
    var shellRects = [];
    frames.forEach(function (record) {
      var left = parseFloat(record.shell.style.left) || 0;
      var top = parseFloat(record.shell.style.top) || 0;
      var width = parseFloat(record.shell.style.width) || 0;
      var height = parseFloat(record.shell.style.height) || 0;
      var measured = measureContentHeight(record);
      if (measured > 0 && (height <= 0 || measured < height)) {
        height = measured;
      }
      // BUG-749 — collect every placed shell (same left/top/height the bbox
      // uses) for the native hit/paint region below.
      shellRects.push([left, top, width, height]);
      // MAX-corner (window size) + the bootstrap origin fallback see EVERY placed
      // shell, so the window pre-grows to cover a not-yet-ready child (no clip).
      if (left < minLeftAll) minLeftAll = left;
      if (top < minTopAll) minTopAll = top;
      if (left + width > maxRight) maxRight = left + width;
      if (top + height > maxBottom) maxBottom = top + height;
      // MIN-corner (window origin / pin) follows ONLY shells the user can already
      // see, so a hidden child never moves the pinned parent before it paints.
      if (record.contentReady) {
        if (left < minLeft) minLeft = left;
        if (top < minTop) minTop = top;
      }
    });
    // No content-ready shell yet (bootstrap first reveal): follow all placed
    // shells so the reveal geometry is identical to the pre-fix behaviour.
    if (!isFinite(minLeft) || !isFinite(minTop)) {
      minLeft = minLeftAll;
      minTop = minTopAll;
    }
    // TODO-1345 (BUG-583 深层根因续) — pull the origin OUT to at least the reserved
    // cascade floor. Applied AFTER the content-ready / bootstrap min so the floor is
    // a lower bound on how far IN the origin can sit (it only ever moves the origin
    // outward), never a cap. This is the root fix for the residual parent lurch: an
    // up/left child that lands WITHIN the floor no longer pulls the origin when it
    // becomes content-ready (min(shellLeft, floor) == floor while shellLeft >= floor)
    // — the window origin is frozen from the first reveal, so the pinned parent card
    // has ZERO displacement. 0 (default / down-right / cursor at an edge) leaves the
    // origin byte-identical (min(x, 0) never pulls a non-positive x outward).
    if (originFloorLeft < minLeft) {
      minLeft = originFloorLeft;
    }
    if (originFloorTop < minTop) {
      minTop = originFloorTop;
    }
    if (!isFinite(minLeft) || !isFinite(minTop) ||
        !isFinite(maxRight) || !isFinite(maxBottom)) {
      return;
    }
    // TODO-1231 P2 — do NOT shift the host layer (nor set layerOffset*) HERE. The
    // layer translation (-minLeft,-minTop) that pins the ROOT card at the cursor
    // while the window covers the whole cascade bbox must be applied ONLY AFTER
    // C++ SetWindowPos has moved the window to the new bbox origin. When the host
    // shifted the layer synchronously (WebView2 compositor, immediate) but the
    // window only moved a full Dart round-trip later, the two compensating moves
    // landed on DIFFERENT vsync frames and the parent card visibly lurched then
    // snapped back (the "几何跳动" half of TODO-1231). C++ RevealStack now calls
    // commitLayerShift(box.left, box.top) right AFTER SetWindowPos so the window
    // move and the content shift are causally ordered (window first, content ~1
    // frame later) instead of racing. Mitigation, not a true atomic commit: the
    // DWM window and the WebView2 surface cannot move in the SAME frame across the
    // JS/window boundary, so a ~1 frame residual remains (vs the old multi-frame
    // desync) — and only for a left/up cascade (dx/dy != 0; down-right stays 0).
    // BUG-749 — report the per-shell rects (window-relative CSS px: the window
    // is positioned at the bbox MIN-corner, so window-relative = shell − min)
    // BEFORE overlaySize. Native clips the opaque overlay window's region to
    // the UNION of these card rects (global_lookup_window.cpp
    // ApplyRoundedRegion), so a click in the reserved-floor GAP passes through
    // to the app below (clipboard panel next-word tap works in ONE click)
    // instead of being swallowed by a near-fullscreen invisible sheet — the
    // TODO-1345 floor regression. Posting before overlaySize means the region
    // is already correct when Dart reveals the window (no clipped first frame).
    // The window rect/origin itself never changes → BUG-583 zero-motion holds.
    var rectsCsv = shellRects.map(function (r) {
      return [r[0] - minLeft, r[1] - minTop, r[2], r[3]].map(function (v) {
        return Math.round(v * 100) / 100;
      }).join(',');
    }).join(';');
    if (rectsCsv !== lastShellRectsKey) {
      lastShellRectsKey = rectsCsv;
      postToHost('shellRects', [rectsCsv]);
    }
    var dpr = (typeof window.devicePixelRatio === 'number' &&
               window.devicePixelRatio > 0) ? window.devicePixelRatio : 1;
    var box = {
      left: minLeft,
      top: minTop,
      width: maxRight - minLeft,
      height: maxBottom - minTop,
      dpr: dpr,
    };
    var key = box.left + ',' + box.top + ',' + box.width + ',' + box.height +
        ',' + dpr;
    if (key === lastBBoxKey) {
      return;
    }
    lastBBoxKey = key;
    // overlaySize args: [dpr, box]. Dart reveal/resize the window to this CSS-px
    // box (times dpr at the C++ window boundary).
    postToHost('overlaySize', [dpr, box]);
  }

  // BUG-1139 ③ — 卡片 iframe 的 documentElement 上挂着 CSS `zoom`
  // （popup_settings_injection 的 head 注入 `= appUiScale × dictionaryFontSize/16`）。
  // 标准化 CSS zoom 下 scrollHeight/offsetHeight 返回的是**未乘 z 的 layout px**，
  // 而卡片实际画出 layout × z —— popup.js 的 popupCurrentZoom + `visualStep / z`
  // 正是同一语义的另一半。z 取不到（未注入 / 非法 / 跨域抛错）一律回落 1。
  function frameContentZoom(record) {
    try {
      var doc = record.iframe.contentDocument;
      var docEl = doc && doc.documentElement;
      var z = (docEl && docEl.style) ? parseFloat(docEl.style.zoom) : NaN;
      return (isFinite(z) && z > 0) ? z : 1;
    } catch (e) {
      return 1;
    }
  }

  // BUG-1139 ③ — 返回值必须与 shell 几何同单位：**未缩放的 host CSS px**
  // （host 文档自身从不设 zoom，shell.style.left/top/width/height 都是这个单位）。
  // 所以 iframe 里量到的 layout px 要先乘回 z，否则 z>1 时 measureAndReport 会把
  // shell 高度收到只有内容视觉高度的 1/z，union bbox 的 maxBottom 与 shellRects
  // （→ window region / ApplyRoundedRegion）跟着矮一截，卡片底部被窗口边缘裁掉、
  // 裁口外直接露出底下的应用 —— 正是本 bug 的原始症状。
  // Math.ceil 只防子像素短一格；z=1（默认 16px 字号 + 100% 界面大小）时
  // scrollHeight/offsetHeight 本就是整数，换算是恒等变换，行为逐字节不变。
  function measureContentHeight(record) {
    try {
      var doc = record.iframe.contentDocument;
      if (!doc || !doc.body) {
        return 0;
      }
      var body = doc.body;
      var docEl = doc.documentElement;
      var layoutPx = Math.max(
        body.scrollHeight || 0,
        body.offsetHeight || 0,
        docEl ? (docEl.scrollHeight || 0) : 0);
      if (layoutPx <= 0) {
        return 0;
      }
      return Math.ceil(layoutPx * frameContentZoom(record));
    } catch (e) {
      return 0;
    }
  }

  // TODO-1231 P2 — apply the layer translation that pins the ROOT card at the
  // cursor while the window covers the whole cascade bounding box. Called by C++
  // RevealStack AFTER SetWindowPos (see measureAndReport), so the window has
  // already moved to the bbox origin before the content compensates. [bboxLeft]/
  // [bboxTop] are the union bbox origin (window-local CSS px — the SAME values
  // Dart sized/positioned the window from), so the layer is translated by their
  // negation and layerOffset* is kept in lock-step for the hit-test (TODO-1189).
  // CSS px only (no dpr; the dpr boundary is the C++ window). Bad args default to
  // 0 (no shift), matching a single popup / down-right cascade.
  function commitLayerShift(bboxLeft, bboxTop) {
    var l = (typeof bboxLeft === 'number' && isFinite(bboxLeft)) ? bboxLeft : 0;
    var t = (typeof bboxTop === 'number' && isFinite(bboxTop)) ? bboxTop : 0;
    var layerEl = document.getElementById(LAYER_ID);
    if (layerEl) {
      layerEl.style.left = (-l) + 'px';
      layerEl.style.top = (-t) + 'px';
    }
    layerOffsetLeft = l;
    layerOffsetTop = t;
    // TODO-1231 v3 (BUG-583) — the window just settled at this origin, so any shell
    // held hidden because it fell OUTSIDE the previous (narrower) window is now
    // covered; flip its reveal-ready so it paints IN PLACE, coincident with the
    // window/layer settling — no clipped-then-jump. Idempotent (covered shells that
    // already revealed are a no-op); content-ready is gated separately, so a child
    // still waits for its own popupRendered before actually painting.
    frames.forEach(function (record) {
      maybeFlipRevealReady(record);
    });
  }

  // TODO-890 — slide the ROOT card off-screen, THEN post dismiss. Adds the
  // .global-lookup-dismissing class (CSS transitions transform+opacity), waits
  // for transitionend on the root shell, and only then posts dismissPopupAt([0])
  // so the Dart hide() lands AFTER the slide-out finishes (no instant vanish).
  // A safety timer mirrors the CSS duration so a missing transitionend (node
  // harness / reduced-motion) still posts. Idempotent per root shell.
  var SLIDE_OUT_MS = 200;
  var dismissingRoot = false;
  function dismissRootWithSlide() {
    if (dismissingRoot) {
      return;
    }
    var rootId = null;
    frames.forEach(function (record, id) {
      if (rootId === null) {
        rootId = id;
      }
    });
    var record = rootId !== null ? frames.get(rootId) : null;
    var shell = record && record.shell;
    if (!shell || typeof shell.setAttribute !== 'function' ||
        !shell.classList || typeof shell.classList.add !== 'function') {
      // No animatable shell (node harness fake DOM without classList): post now.
      postToHost('dismissPopupAt', [0]);
      return;
    }
    dismissingRoot = true;
    var posted = false;
    var post = function () {
      if (posted) {
        return;
      }
      posted = true;
      dismissingRoot = false;
      postToHost('dismissPopupAt', [0]);
    };
    if (typeof shell.addEventListener === 'function') {
      shell.addEventListener('transitionend', function onEnd(e) {
        if (e && e.propertyName && e.propertyName !== 'transform' &&
            e.propertyName !== 'opacity') {
          return;
        }
        if (typeof shell.removeEventListener === 'function') {
          shell.removeEventListener('transitionend', onEnd);
        }
        post();
      });
    }
    shell.classList.add('global-lookup-dismissing');
    // Safety: fire even if transitionend never arrives.
    setTimerSafe(post, SLIDE_OUT_MS + 50);
  }

  // TODO-1067 (子5) — insertion-order id of the DEEPEST shell containing (x,y),
  // or null when the point is outside every shell. "Deepest" (last matching in
  // insertion order) so an overlapping cascade attributes the click to the child
  // card on top, not the root beneath it. Used by the host click handlers to
  // decide per-layer close vs root dismiss.
  function frameIdAtPoint(x, y) {
    var deepest = null;
    frames.forEach(function (record, id) {
      // TODO-1189 — record.shell.style.left/top are coordinates INSIDE the layer,
      // which measureAndReport shifted by (-layerOffsetLeft, -layerOffsetTop) to
      // pin the union bbox to the window origin. The incoming (x, y) is in WINDOW
      // coordinates (C++ WH_MOUSE_LL forwards window-relative CSS px), so map each
      // shell back to window space by subtracting the layer offset. Without this
      // a nested sub-popup pushed off the cursor (minLeft/minTop < 0) is hit-
      // tested against stale un-shifted coords and a click ON its card is misread
      // as an empty gap, wrongly dismissing the whole stack. Offsets are 0 for a
      // single popup / down-right cascade, so this is a no-op there.
      var left = (parseFloat(record.shell.style.left) || 0) - layerOffsetLeft;
      var top = (parseFloat(record.shell.style.top) || 0) - layerOffsetTop;
      var width = parseFloat(record.shell.style.width) || 0;
      var height = parseFloat(record.shell.style.height) || 0;
      if (x >= left && x <= left + width && y >= top && y <= top + height) {
        deepest = id;
      }
    });
    return deepest;
  }

  // C3 / TODO-1067 (子5) — capture-phase pointerdown on the HOST document. A
  // click that lands on a shell is a CARD interaction: DEFER to popup.js running
  // inside that iframe, which owns the PER-LAYER close decision (tap parent card
  // body -> close child, via the __hasChildPopup guard wired by the render body).
  // The host must NOT also post a dismiss here or it double-fires with popup.js
  // and races the stack. Only a click that hits NO shell at all (true empty space
  // in the bbox window / a cascade gap) dismisses the root. This is exactly why
  // "click the first popup, everything closes" happened: the host used to nuke
  // the root whenever its coarse hit-test missed the visual card; deferring card
  // clicks to popup.js's per-layer path fixes it (SUB5) while the close-X (SUB1)
  // gives the mouse an explicit per-layer affordance.
  function onHostPointerDown(event) {
    // spec 2026-07-10 panel — persistent semantics: a blank click inside the
    // fixed panel window (panel bar gaps etc.) never dismisses. The panel bar's
    // own buttons stopPropagation before this handler anyway.
    if (layoutMode === 'panel') {
      return;
    }
    var t = event && event.target;
    if (t && typeof t.closest === 'function' &&
        t.closest('.global-lookup-frame-shell')) {
      // On a shell: let popup.js (inside the iframe) decide per-layer. The
      // close-X has its own stopPropagation handler, so it never reaches here.
      return;
    }
    dismissRootWithSlide();
  }

  // E2 / TODO-1067 (子5) — C++ WH_MOUSE_LL forwards a global click already
  // converted to host CSS px relative to the window so the host can hit-test
  // shells (geometry truth lives here). A click INSIDE a shell is a card
  // interaction -> DEFER to popup.js's own document handler (per-layer close via
  // __hasChildPopup); the host must not post a competing dismiss (double-fire /
  // stack race). Only a click OUTSIDE every shell (true gap) dismisses the root.
  // Returns whether the click hit any shell (C++ uses it for logging).
  function handleGlobalClick(x, y) {
    // BUG-859 — persistent panel semantics: a blank click never dismisses the
    // clipboard panel (mirrors the onHostPointerDown panel guard). Without this
    // a forwarded gap-click would post dismissPopupAt(0) against the panel —
    // and the panel root's percentage/calc() shell size parses to a 100×0 box
    // in frameIdAtPoint, so EVERY panel click would mis-read as a gap.
    if (layoutMode === 'panel') {
      return true;
    }
    var frameId = frameIdAtPoint(x, y);
    if (frameId != null) {
      return true; // Card hit: popup.js owns the per-layer decision.
    }
    // BUG-749 — post the root dismiss IMMEDIATELY (no TODO-890 slide-out).
    // With the shell-union window region the SAME physical gap click also
    // lands in the app below (region hole) and may start a NEW lookup there
    // (clipboard panel word tap → lookupText). A dismiss delayed 200ms by the
    // slide would post AFTER the fresh card seeded and kill it (stale-dismiss
    // race); posted now it always precedes the new lookup's stack reset
    // (searchDictionary alone takes longer than the bridge round-trip).
    postToHost('dismissPopupAt', [0]);
    return false;
  }

  // BUG-1166 — C++ 把「落在卡片上、且按着 Ctrl/Alt」的滚轮交到这里。
  //
  // 为什么这条路必须存在：那格滚轮已被 WH_MOUSE_LL 钩子吞掉（否则会穿到底下的
  // galgame），而窗口线程若用 PostMessage 合成一条 WM_MOUSEWHEEL 补回去，修饰键
  // 会在边界上丢失 —— Chromium 取 ctrlKey/altKey 读的是 GetKeyState，而合成消息不
  // 更新线程键状态表，覆盖窗又是 WS_EX_NOACTIVATE、不在前台输入队列里。于是修饰键
  // 只能作为**数据**送到这一层，由 JS 合成一条带显式 flag 的 WheelEvent。
  //
  // 判定语义仍然全部留在既有 JS 里，host 不做策略（绑定真值 __hoshiEntryWheelBindings
  // 在 popup.js，用户可改键位；缩放档距在 Dart）：
  //   ctrlKey → _globalLookupZoomWheelJs 的 window wheel 监听 → callHandler
  //             ('popupZoomFontStep') → jsMessage → Dart maybeHandleOverlayZoomFontStep
  //   altKey  → popup.js __hibikiPopupWheelListener 的 popupEntryWheelAction → 换词条
  //
  // (x, y) 与 handleGlobalClick 同一坐标系（窗口内 CSS px）；deltaY 已由 C++ 转成
  // **DOM 约定**（向上滚为负），所以 JS 侧收到的与真滚轮完全同构。
  // 返回是否真的派发了（false = 落在卡片外/无 realm，调用方不必处理）。
  function handleGlobalWheel(x, y, deltaY, ctrlKey, altKey, shiftKey) {
    var frameId = frameIdAtPoint(x, y);
    if (frameId == null) return false;
    var record = frames.get(frameId);
    if (!record || !record.iframe) return false;
    var win = null;
    try {
      win = record.iframe.contentWindow;
    } catch (e) {
      win = null;
    }
    if (!win) return false;
    var doc = win.document || record.iframe.contentDocument;
    if (!doc || typeof doc.dispatchEvent !== 'function') return false;
    var init = {
      bubbles: true,
      cancelable: true,
      composed: true,
      deltaX: 0,
      deltaY: deltaY,
      deltaZ: 0,
      deltaMode: 0,
      ctrlKey: !!ctrlKey,
      altKey: !!altKey,
      shiftKey: !!shiftKey,
      metaKey: false,
    };
    var evt = null;
    // 真实 WebView2 走这条：构造真 WheelEvent，composedPath()/preventDefault() 等
    // 一应俱全，下游监听分辨不出它是合成的。
    if (typeof win.WheelEvent === 'function') {
      try {
        evt = new win.WheelEvent('wheel', init);
      } catch (e) {
        evt = null;
      }
    }
    if (!evt) {
      // 无 WheelEvent 构造器（node harness / 极老 realm）：退化成同形字面量，
      // 保证契约仍可被断言，且真实浏览器永远走不到这里。
      evt = { type: 'wheel' };
      for (var k in init) {
        if (Object.prototype.hasOwnProperty.call(init, k)) evt[k] = init[k];
      }
      evt.preventDefault = function () {};
      evt.composedPath = function () { return []; };
    }
    try {
      doc.dispatchEvent(evt);
    } catch (e) {
      return false;
    }
    return true;
  }

  function topPopupId() {
    var last = null;
    frames.forEach(function (record, id) {
      last = id;
    });
    return last;
  }

  function frameIdForIframe(iframe) {
    return frameSources.has(iframe) ? frameSources.get(iframe) : null;
  }

  // 剪贴板面板：把 ROOT 帧的滚动位置复位到顶部。面板的 root iframe 是**复用**的
  // （renderStack 只换 #entries-container innerHTML，iframe / 其滚动容器不重建），
  // 故上一句被滚动过的 scrollTop 会跨渲染保留——一条更长的新剪贴板内容渲染进来时
  // 停在旧偏移而非从头看。Dart 面板控制器在「剪贴板内容更新」路径（update /
  // _showTextOnly，均 seed 新 root）渲染后调本函数，让新句总是从顶部开始。点句中字
  // 重查（_lookupFromBanner）/ 关子卡（_rerender）不调，保留其滚动位置。
  // 面板 iframe 直接加载 popup.html（无 content.js shadow，__hibikiRoot 为 null），
  // 滚动落在 document 上；#entries-container 兜底（万一改用容器滚动）。no-op 当无
  // root 帧 / 跨源守卫 / node harness。
  function scrollRootToTop() {
    var rootId = null;
    frames.forEach(function (record, id) {
      if (rootId === null) {
        rootId = id;
      }
    });
    var record = rootId !== null ? frames.get(rootId) : null;
    if (!record) {
      return;
    }
    var win = null;
    var doc = null;
    try {
      win = record.iframe.contentWindow;
      doc = record.iframe.contentDocument;
    } catch (e) {
      win = null;
      doc = null;
    }
    try {
      if (doc) {
        if (doc.scrollingElement) {
          doc.scrollingElement.scrollTop = 0;
        }
        if (doc.documentElement) {
          doc.documentElement.scrollTop = 0;
        }
        if (doc.body) {
          doc.body.scrollTop = 0;
        }
        var container = (typeof doc.getElementById === 'function')
            ? doc.getElementById('entries-container')
            : null;
        if (container) {
          container.scrollTop = 0;
        }
      }
      if (win && typeof win.scrollTo === 'function') {
        win.scrollTo(0, 0);
      }
    } catch (e) {
      // no-op（跨源 / 未加载）。
    }
  }

  // TODO-1188 — the contentWindow of a frame record, or null when unavailable
  // (cross-origin guard / torn-down iframe / node harness).
  function frameWindowOf(record) {
    if (!record) {
      return null;
    }
    try {
      return record.iframe.contentWindow;
    } catch (e) {
      return null;
    }
  }

  // TODO-1188 — install the top-level bridge-reply router. Native
  // (global_lookup_window.cpp: ResolveBridge for the deferred audio/favorite
  // handlers, and the immediate null-resolve for the read-only ones) calls
  // window.__hibikiBridgeResolve(globalId, jsonValue) on THIS top-level document.
  // The global id was minted in transformFrameMessage and maps back to the source
  // iframe + its frame-local id; forward the reply to exactly that iframe's
  // adapter so the awaited callHandler Promise there resolves. No route -> defer
  // to the top-level adapter (the host itself issues no bridge calls, so this is
  // normally a no-op); a spurious/duplicate reply with no route is dropped rather
  // than broadcast, so two frames sharing a local id can never mis-resolve.
  function installBridgeRouter() {
    var priorResolve = (typeof window.__hibikiBridgeResolve === 'function')
        ? window.__hibikiBridgeResolve
        : null;
    window.__hibikiBridgeResolve = function (globalId, jsonValue) {
      var route = bridgeRoutes.get(globalId);
      if (route) {
        bridgeRoutes.delete(globalId);
        var win = frameWindowOf(frames.get(route.frameId));
        if (win && typeof win.__hibikiBridgeResolve === 'function') {
          try {
            win.__hibikiBridgeResolve(route.localId, jsonValue);
          } catch (e) {
            // Never let one frame's resolve throw break the router.
          }
        }
        return;
      }
      if (priorResolve) {
        try {
          priorResolve(globalId, jsonValue);
        } catch (e) {
          // no-op
        }
      }
    };
  }
  installBridgeRouter();

  if (document && typeof document.addEventListener === 'function') {
    document.addEventListener('pointerdown', onHostPointerDown, true);
  }

  // D1 — read the {contentReady, revealReady, visible} gate state of a frame.
  // visible mirrors the CSS gate (both flags true). For diagnostics + the host
  // test harness; never used to drive rendering (the CSS attribute selector is
  // the single visibility source).
  function frameGateState(frameId) {
    var record = frames.get(frameId);
    if (!record) {
      return null;
    }
    return {
      contentReady: !!record.contentReady,
      revealReady: !!record.revealReady,
      visible: !!record.contentReady && !!record.revealReady,
    };
  }

  // TODO-1190 — highlight the searched word inside a PARENT frame's popup.js
  // realm. When a nested lookup opens off a clicked word, the in-app popup marks
  // that word with a CSS Custom Highlight in the PARENT card
  // (dictionary_popup_webview.highlightSelection); the app-external overlay never
  // did, so the source word in the parent card was left unmarked. The controller
  // resolves the parent's insertion-order frame index + the matched char count
  // and calls this; we find that frame and eval popup.js's own
  // window.hoshiSelection.highlightSelection(count) inside its iframe realm (the
  // popup.js selection already spans the just-clicked word). No-op on a bad index
  // / count / missing frame so a failed highlight never breaks the lookup.
  function highlightFrame(frameIndex, count) {
    if (typeof frameIndex !== 'number' || frameIndex < 0) {
      return false;
    }
    if (typeof count !== 'number' || !(count > 0)) {
      return false;
    }
    var i = 0;
    var target = null;
    frames.forEach(function (record) {
      if (i === frameIndex) {
        target = record;
      }
      i++;
    });
    if (!target) {
      return false;
    }
    var win = null;
    try {
      win = target.iframe.contentWindow;
    } catch (e) {
      win = null;
    }
    if (!win || typeof win.eval !== 'function') {
      return false;
    }
    try {
      win.eval(
          'window.hoshiSelection && ' +
          'window.hoshiSelection.highlightSelection && ' +
          'window.hoshiSelection.highlightSelection(' + count + ');');
      return true;
    } catch (e) {
      return false;
    }
  }

  // BUG-1127 — drive the overlay AUTO-READ through popup.js's own HTML5
  // <audio> (the unified fast path, same playWordAudio the manual ♪ button
  // uses) instead of the Dart/libmpv round-trip. [frameId] is the target frame
  // (the controller passes the STABLE root id — always loaded after prewarm;
  // audio is realm-agnostic so the entry's own frame does not matter). The
  // iframe realm reports the REAL audio.play() outcome as a
  // { handler: 'wordAudioPlayed', args: [token, ok] } message through its
  // WRAPPED chrome.webview.postMessage (host-stamped, routed to Dart's
  // _onJsMessage like every popup.js message). A missing/unloaded frame or an
  // eval failure reports false from the HOST realm via postToHost so the Dart
  // completer resolves immediately instead of waiting out its 5s timeout —
  // Dart then falls back to its own player (never a silent drop, BUG-1093
  // contract).
  function playWordAudioInFrame(frameId, url, token) {
    const record = frames.get(frameId);
    let win = null;
    if (record?.loaded) {
      try {
        win = record.iframe.contentWindow;
      } catch (e) {
        win = null;
      }
    }
    if (!win || typeof win.eval !== 'function') {
      postToHost('wordAudioPlayed', [token, false, 'FrameNotLoaded']);
      return false;
    }
    try {
      // BUG-1204：回报第三个参数 = 失败原因（popup.js 的 playWordAudio 存在
      // window.__hibikiWordAudioLastError 上）。Dart 端按位置读且早已 `length >= 2`
      // 守卫，多带一个参数对旧端完全无害。`play` 缺失是另一类失败（realm 里没装
      // popup.js），给它自己的原因串，不与 play() 的 DOMException 混为一谈。
      win.eval(
          '(function () {' +
          'var reason = function () {' +
          'try { return String(window.__hibikiWordAudioLastError || ""); }' +
          ' catch (_) { return ""; }' +
          '};' +
          'var report = function (ok, why) {' +
          'try { window.chrome.webview.postMessage(' +
          '{ handler: "wordAudioPlayed", args: [' + token + ', ok === true,' +
          ' String(why == null ? reason() : why)] }' +
          '); } catch (_) { /* bridge gone: Dart times out and falls back */ }' +
          '};' +
          'try {' +
          'var play = window.__hibikiPlayWordAudioUrl;' +
          'if (!play) { report(false, "PlayFunctionMissing"); return; }' +
          'Promise.resolve(play(' + JSON.stringify(url) + '))' +
          '.then(function (r) { report(r === true); },' +
          ' function (e) { report(false, (e && e.name) || "PlayThrew"); });' +
          '} catch (e) { report(false, (e && e.name) || "EvalThrew"); }' +
          '})();');
      return true;
    } catch (error) {
      window.console?.debug?.(
          '[global-lookup] word audio frame eval failed', error);
      postToHost('wordAudioPlayed',
          [token, false, (error && error.name) || 'FrameEvalFailed']);
      return false;
    }
  }

  window.__globalLookupHost = {
    __installed: true,
    renderStack: renderStack,
    beginLookup: beginLookup,
    topPopupId: topPopupId,
    frameIdForIframe: frameIdForIframe,
    layerIndexOf: layerIndexOf,
    highlightFrame: highlightFrame,
    playWordAudioInFrame: playWordAudioInFrame,
    frameIdAtPoint: frameIdAtPoint,
    handleGlobalClick: handleGlobalClick,
    handleGlobalWheel: handleGlobalWheel,
    measureAndReport: measureAndReport,
    commitLayerShift: commitLayerShift,
    frameGateState: frameGateState,
    dismissRootWithSlide: dismissRootWithSlide,
    // spec 2026-07-10 — panel-mode hooks (no-ops in cascade mode).
    setPanelPinnedVisual: setPanelPinnedVisual,
    setPanelBlockCaptureVisual: setPanelBlockCaptureVisual,
    scrollRootToTop: scrollRootToTop,
    // 剪贴板复制历史覆盖层（Dart 注入渲染 / 关闭）。
    showClipboardHistory: showClipboardHistory,
    hideClipboardHistory: hideClipboardHistory,
    _frames: frames,
    // TODO-1188 — exposed for the node bridge-routing harness only (never used to
    // drive behaviour): the live globalId -> {frameId, localId} route map.
    _bridgeRoutes: bridgeRoutes,
  };
})();
