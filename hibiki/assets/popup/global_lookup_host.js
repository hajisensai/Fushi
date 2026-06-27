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

  function ensureLayer() {
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
    if (handler === 'onLinkClick' && Array.isArray(message.args)) {
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
    };
    frameSources.set(iframe, descriptor.id);

    iframe.addEventListener('load', function () {
      record.loaded = true;
      wrapFrameBridge(record);
      injectContent(record);
      measureAndReport();
    });
    return record;
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
    if (record.loaded) {
      wrapFrameBridge(record);
      injectContent(record);
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
      if (record && record.shell && record.shell.parentNode) {
        record.shell.parentNode.removeChild(record.shell);
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
    measureAndReport();
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

  // C3 — capture-phase pointerdown on the host document. A click inside ANY shell
  // is a card interaction -> do nothing. A click OUTSIDE all shells dismisses the
  // ROOT (index 0) -> whole stack collapses -> empty -> C++ hides.
  function onHostPointerDown(event) {
    var t = event && event.target;
    if (t && typeof t.closest === 'function' &&
        t.closest('.global-lookup-frame-shell')) {
      return;
    }
    postToHost('dismissPopupAt', [0]);
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
      postToHost('dismissPopupAt', [0]);
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

  window.__globalLookupHost = {
    __installed: true,
    renderStack: renderStack,
    topPopupId: topPopupId,
    frameIdForIframe: frameIdForIframe,
    layerIndexOf: layerIndexOf,
    handleGlobalClick: handleGlobalClick,
    measureAndReport: measureAndReport,
    _frames: frames,
  };
})();
