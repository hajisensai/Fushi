// TODO-867 P3b — app-OUTSIDE global lookup nested-stack HOST (Windows only).
//
// Ported from hoshi reader-popup-host.js frames model. Injected ONLY into the
// top-level WebView2 document of the bare global-lookup window
// (global_lookup_window.cpp AddScriptToExecuteOnDocumentCreated). NEVER loaded
// in-app, so in-app popup rendering is byte-for-byte unchanged.
//
// Why iframes: popup.js is a page-level SINGLETON (one #entries-container, one
// window.lookupEntries / renderPopup / __hasChildPopup, one set of document
// listeners). To stack N lookup cards we host N iframes, each loading popup.html
// unchanged, so each frame keeps the single-frame assumptions inside its own
// document. The host only owns the OUTER shell layout + frame diff.
//
// NO sandbox on the iframes. Frames load the SAME origin
// (https://hibiki.popup/popup.html) and the host injects per-frame settings +
// entries DIRECTLY via iframe.contentWindow (same-origin). A sandbox attribute
// without allow-same-origin forces an opaque origin -> contentWindow becomes
// cross-origin -> contentWindow.lookupEntries assignment throws SecurityError
// and document-created adapter/bridge injection is blocked. Same-origin iframes
// are already trusted here, so no sandbox.
//
// renderStack(payload) is the single Dart entry point. payload =
//   { popups: [ { id, parentIndex, frame:{left,top,width,height}, settingsJs },
//               ... ] }
// built by global_lookup_render.buildStackRenderScript. The host diffs the
// payload against its live frames Map: new ids -> createRecord (new iframe);
// gone ids -> removeMissing (detach iframe); surviving ids -> re-apply shell
// geometry + (re)inject content. Top popup id is the last entry.
//
// P3b scope: frame diff + per-frame content injection + shell geometry. Does
// NOT move the top-level WebView2 to a dedicated host.html (cpp still navigates
// to popup.html). Window enlargement, mouse hooks, real cascade coordinates,
// per-frame offscreen measurement = P3c (real device).

(function () {
  'use strict';

  if (window.__globalLookupHost && window.__globalLookupHost.__installed) {
    return;
  }

  var POPUP_SRC = 'https://hibiki.popup/popup.html';
  var LAYER_ID = 'global-lookup-host-layer';

  // id -> record. Map insertion order IS the stack order (index 0 root, last =
  // top).
  var frames = new Map();
  // iframe element -> frame id (parent attribution for bubbled messages).
  var frameSources = new WeakMap();

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

  // Per-frame outer-shell geometry. Coordinates are computed in Dart
  // (deterministic placeholder offsets in P3b; real cascade in P3c). The shell
  // carries the .global-lookup card chrome from popup.css; the iframe fills it.
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

  // New frame record: a shell div + an iframe loading popup.html (same-origin,
  // NO sandbox). Content is injected once the iframe loads (and re-injected on
  // every renderStack that targets this id).
  function createRecord(layer, descriptor) {
    var shell = document.createElement('div');
    shell.className = 'global-lookup-frame-shell';
    shell.setAttribute('data-frame-id', descriptor.id);

    var iframe = document.createElement('iframe');
    // Deliberately NO sandbox attribute (see file header). Same-origin
    // contentWindow injection requires a non-opaque origin.
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
      injectContent(record);
    });
    return record;
  }

  // Same-origin content injection: run the per-frame settings JS (built in Dart)
  // INSIDE the iframe realm so it targets that frame document and calls its own
  // popup.js renderPopup(). Defensive try/catch so a not-yet-navigated frame does
  // not abort the whole stack render (it re-injects on its load event).
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
      injectContent(record);
    }
    return record;
  }

  // Detach every live frame whose id is NOT in keepIds (diff delete: closing
  // children / truncation drops the tail frames).
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

  // Single Dart entry point. payload.popups is the ordered stack (index 0 root
  // ... last = top). Empty/absent popups clears the whole stack.
  function renderStack(payload) {
    var popups = (payload && payload.popups) || [];
    if (!popups.length) {
      removeMissing([]);
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
  }

  // Id of the deepest (top) frame, or null when empty. Map insertion order IS the
  // stack order.
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

  window.__globalLookupHost = {
    __installed: true,
    renderStack: renderStack,
    topPopupId: topPopupId,
    frameIdForIframe: frameIdForIframe,
    _frames: frames,
  };
})();
