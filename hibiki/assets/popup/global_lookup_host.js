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
  var lastBBoxKey = '';
  // TODO-1079 (C) / TODO-1095 — the root frame id of the currently-rendered
  // stack. TODO-1095 makes the root frame id STABLE across hotkey lookups (the
  // root iframe is REUSED, not rebuilt per lookup — see beginLookup), so the
  // authoritative "new lookup" bbox-dedup reset + content-gate re-arm now arrive
  // via beginLookup(). This changed-root-id path stays as belt-and-braces for any
  // caller that still rotates the root id (nested-only rebuilds, tests).
  var lastRootId = null;

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
    // clip + the drop-shadow that the iframe element itself cannot cast — it
    // must NOT draw a second `border` (that produced two concentric grey rings
    // with a white gap between them). `border-radius` stays so the shadow +
    // overflow clip follow the same rounded silhouette as the body border;
    // `background:transparent` keeps the shell from painting a second fill.
    // Unlike the P2 single-frame chrome (which lived on the iframe body and got
    // clipped at the window edge), the shell shadow has room to render inside
    // the enlarged bounding-box window (E1). Dark variant keyed off data-theme
    // stamped by the render payload. All rules scoped to
    // .global-lookup-frame-shell -> the in-app popup (no host.js) is never
    // touched.
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
        'box-shadow:0 3px 12px rgba(0,0,0,0.22);' +
        // TODO-890 — slide-out close: the shell tweens transform+opacity so a
        // dismiss slides the card off-screen instead of vanishing instantly
        // (app-out parity with the in-app _BodySwipeDismissDetector). 200ms
        // ease-out matches the Flutter side. Scoped to the shell selector so
        // it never leaks into the in-app popup (which never loads host.js).
        'transition:transform 200ms ease-out, opacity 200ms ease-out;}' +
        '.global-lookup-frame-shell[data-theme="dark"]{' +
        'box-shadow:0 3px 12px rgba(0,0,0,0.44);}' +
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
        'background:rgba(235,235,245,0.16);color:rgba(235,235,245,0.92);}';
    var head = document.head ||
        (document.getElementsByTagName &&
            document.getElementsByTagName('head')[0]);
    (head || document.documentElement || document.body).appendChild(style);
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
    shell.style.position = 'absolute';
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
    if (typeof message.__bridgeId !== 'undefined') {
      out.__bridgeId = message.__bridgeId;
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
    };
    frameSources.set(iframe, descriptor.id);

    iframe.addEventListener('load', function () {
      record.loaded = true;
      wrapFrameBridge(record);
      injectContent(record);
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
      return true;
    } catch (e) {
      return false;
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
    // D1 — geometry is placed for this layer -> reveal-ready. The shell still
    // stays hidden until content-ready also flips (the CSS gate needs BOTH), so
    // a placed-but-empty frame never flashes.
    setGateFlag(record, ATTR_REVEAL_READY, 'revealReady');
    if (record.loaded) {
      wrapFrameBridge(record);
      injectContent(record);
      observeContent(record);
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
        if (record.shell && record.shell.parentNode) {
          record.shell.parentNode.removeChild(record.shell);
        }
      }
      frames.delete(id);
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
    // Re-arm the content observer + safety timer so the fresh card re-signals
    // content-ready (observeContent no-ops if contentReady were still true).
    observeContent(record);
  }

  function renderStack(payload) {
    var popups = (payload && payload.popups) || [];
    if (!popups.length) {
      removeMissing([]);
      lastBBoxKey = '';
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
    var minLeft = Infinity;
    var minTop = Infinity;
    var maxRight = -Infinity;
    var maxBottom = -Infinity;
    frames.forEach(function (record) {
      var left = parseFloat(record.shell.style.left) || 0;
      var top = parseFloat(record.shell.style.top) || 0;
      var width = parseFloat(record.shell.style.width) || 0;
      var height = parseFloat(record.shell.style.height) || 0;
      var measured = measureContentHeight(record);
      if (measured > 0 && (height <= 0 || measured < height)) {
        height = measured;
      }
      if (left < minLeft) minLeft = left;
      if (top < minTop) minTop = top;
      if (left + width > maxRight) maxRight = left + width;
      if (top + height > maxBottom) maxBottom = top + height;
    });
    if (!isFinite(minLeft) || !isFinite(minTop) ||
        !isFinite(maxRight) || !isFinite(maxBottom)) {
      return;
    }
    // Shift the layer so the bbox top-left maps to the window origin: the C++
    // window moves to (cursor + minLeft, cursor + minTop) and grows to the bbox
    // size (E1), so shifting the layer by (-minLeft, -minTop) keeps the ROOT
    // card pinned at the cursor while the whole cascade fits inside the window.
    var layerEl = document.getElementById(LAYER_ID);
    if (layerEl) {
      layerEl.style.left = (-minLeft) + 'px';
      layerEl.style.top = (-minTop) + 'px';
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

  function measureContentHeight(record) {
    try {
      var doc = record.iframe.contentDocument;
      if (!doc || !doc.body) {
        return 0;
      }
      var body = doc.body;
      var docEl = doc.documentElement;
      return Math.max(
        body.scrollHeight || 0,
        body.offsetHeight || 0,
        docEl ? (docEl.scrollHeight || 0) : 0);
    } catch (e) {
      return 0;
    }
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
      var left = parseFloat(record.shell.style.left) || 0;
      var top = parseFloat(record.shell.style.top) || 0;
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
    var frameId = frameIdAtPoint(x, y);
    if (frameId != null) {
      return true; // Card hit: popup.js owns the per-layer decision.
    }
    dismissRootWithSlide();
    return false;
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

  window.__globalLookupHost = {
    __installed: true,
    renderStack: renderStack,
    beginLookup: beginLookup,
    topPopupId: topPopupId,
    frameIdForIframe: frameIdForIframe,
    layerIndexOf: layerIndexOf,
    frameIdAtPoint: frameIdAtPoint,
    handleGlobalClick: handleGlobalClick,
    measureAndReport: measureAndReport,
    frameGateState: frameGateState,
    dismissRootWithSlide: dismissRootWithSlide,
    _frames: frames,
  };
})();
