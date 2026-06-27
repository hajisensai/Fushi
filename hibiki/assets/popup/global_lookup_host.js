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
        '[' + ATTR_REVEAL_READY + '="true"]{visibility:visible;opacity:1;}';
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

  // True once the iframe document has real content: a rendered glossary node OR
  // a body with a non-zero rendered height (the no-results card path).
  function hasContent(record) {
    try {
      var doc = record.iframe.contentDocument;
      if (!doc || !doc.body) {
        return false;
      }
      if (typeof doc.querySelector === 'function' &&
          doc.querySelector('.glossary-content')) {
        return true;
      }
      var body = doc.body;
      var h = Math.max(body.scrollHeight || 0, body.offsetHeight || 0);
      return h > 0;
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

  function renderStack(payload) {
    var popups = (payload && payload.popups) || [];
    if (!popups.length) {
      removeMissing([]);
      lastBBoxKey = '';
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

  // C3 — capture-phase pointerdown on the host document. A click inside ANY shell
  // is a card interaction -> do nothing. A click OUTSIDE all shells dismisses the
  // ROOT (index 0) -> whole stack collapses -> empty -> C++ hides.
  function onHostPointerDown(event) {
    var t = event && event.target;
    if (t && typeof t.closest === 'function' &&
        t.closest('.global-lookup-frame-shell')) {
      return;
    }
    dismissRootWithSlide();
  }

  // E2 — C++ WH_MOUSE_LL forwards a global click already converted to host CSS px
  // relative to the window so the host can hit-test shells (geometry truth lives
  // here). Inside any shell -> keep; otherwise -> dismiss the root.
  function handleGlobalClick(x, y) {
    var hit = false;
    frames.forEach(function (record) {
      if (hit) {
        return;
      }
      var left = parseFloat(record.shell.style.left) || 0;
      var top = parseFloat(record.shell.style.top) || 0;
      var width = parseFloat(record.shell.style.width) || 0;
      var height = parseFloat(record.shell.style.height) || 0;
      if (x >= left && x <= left + width && y >= top && y <= top + height) {
        hit = true;
      }
    });
    if (!hit) {
      dismissRootWithSlide();
    }
    return hit;
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
    topPopupId: topPopupId,
    frameIdForIframe: frameIdForIframe,
    layerIndexOf: layerIndexOf,
    handleGlobalClick: handleGlobalClick,
    measureAndReport: measureAndReport,
    frameGateState: frameGateState,
    dismissRootWithSlide: dismissRootWithSlide,
    _frames: frames,
  };
})();
