// Each child has its own popup realm, like the App's per-layer WebView. Parents
// are never re-rendered, and callbacks are owned by the exact layer that sent them.
(function () {
  'use strict';
  const layers = [];
  const requests = new Map();
  let sequence = 0;
  const frameUrl = chrome.runtime.getURL('nested-popup.html');
  const frameOrigin = 'chrome-extension://' + chrome.runtime.id;
  function send(layer, message) {
    if (layer.port && layers.includes(layer)) layer.port.postMessage({ __fushiPopupFrame: true, ...message });
  }
  function updateParents() {
    window.__hasChildPopup = layers.length > 0;
    layers.forEach((layer, index) => send(layer, { type: 'hasChild', value: index < layers.length - 1 }));
  }
  function dismissAfter(parent) {
    const keep = parent ? layers.indexOf(parent) + 1 : 0;
    if (parent && !keep) return;
    for (const layer of layers.splice(keep)) {
      requests.delete(layer);
      if (layer.port) {
        layer.port.onmessage = null;
        layer.port.close();
      }
      layer.frame.remove();
    }
    requests.delete(parent);
    updateParents();
  }
  function withContext(layer, callback) {
    const cue = fushiPendingCueWindow, draft = fushiSentenceCtx;
    fushiPendingCueWindow = layer.cue;
    fushiSentenceCtx = layer.draft;
    try { return callback(); }
    finally {
      layer.draft = fushiSentenceCtx;
      fushiPendingCueWindow = cue;
      fushiSentenceCtx = draft;
    }
  }
  function place(layer, reportedHeight) {
    const box = fushiResolvePopupBox(layer.data.theme || {}, { width: window.innerWidth, height: window.innerHeight });
    layer.data.popupZoom = box.zoom;
    const width = Math.min(box.width * box.zoom, Math.max(64, window.innerWidth - 16));
    const height = Math.min(Number(reportedHeight) || box.maxHeight, box.maxHeight * box.zoom, window.innerHeight * 0.8);
    const pos = fushiComputePlacement(layer.anchor, { width, height }, { width: window.innerWidth, height: window.innerHeight });
    Object.assign(layer.frame.style, {
      left: pos.left + 'px', top: pos.top + 'px', width: width + 'px',
      height: Math.min(height, pos.maxHeight || height) + 'px',
    });
  }
  function open(query, anchor, parent, highlight) {
    const term = typeof query === 'string' ? query.trim() : '';
    if (!term || !fushiHost || (parent && !layers.includes(parent))) return;
    dismissAfter(parent);
    const owner = fushiHost;
    const request = ++sequence;
    requests.set(parent, request);
    const cue = parent ? parent.cue : fushiPendingCueWindow;
    chrome.runtime.sendMessage({ type: 'lookup', term }, function (response) {
      if (requests.get(parent) !== request || fushiHost !== owner || (parent && !layers.includes(parent))) return;
      if (chrome.runtime.lastError || !response || !response.ok || !response.data || typeof response.data.popupJson !== 'string') {
        fushiShowConnectionFailure(response);
        return;
      }
      const frame = document.createElement('iframe');
      const matchLength = response.data.result && response.data.result.bestLength;
      if (highlight && Number.isInteger(matchLength) && matchLength > 0) {
        if (parent) send(parent, { type: 'highlight', length: matchLength });
        else if (window.fushiSelection && typeof window.fushiSelection.highlightSelection === 'function') {
          window.fushiSelection.highlightSelection(matchLength);
        }
      }
      frame.title = '嵌套查词：' + term;
      frame.setAttribute('allow', 'autoplay');
      frame.style.cssText = 'position:fixed;z-index:2147483647;border:0;visibility:hidden;background:transparent;border-radius:10px;box-shadow:0 5px 24px #0005;';
      const fallback = (parent ? parent.frame : owner).getBoundingClientRect();
      let rect = anchor && Number.isFinite(anchor.x) && Number.isFinite(anchor.y)
        ? { x: anchor.x, y: anchor.y, height: Number(anchor.height) || 18 }
        : { x: fallback.left + 24, y: fallback.top + 24, height: 18 };
      if (parent && anchor) rect = { x: fallback.left + rect.x, y: fallback.top + rect.y, height: rect.height };
      const layer = { frame, data: { ...response.data }, anchor: rect, cue, draft: { prev: 0, next: 0 } };
      layer.data.i18nCtx = window.i18nCtx || FUSHI_CTX_I18N;
      layer.data.sentenceContextPreviewEnabled = withContext(layer, () => !!fushiCurrentCueLocation());
      let entries = [];
      try { entries = JSON.parse(layer.data.popupJson); } catch (_) { return; }
      layer.data.queuedExpressions = entries.filter(entry => withContext(layer, () => window.fushiIsEntryQueued(entry))).map(entry => entry.expression);
      layers.push(layer);
      frame.src = frameUrl;
      (document.fullscreenElement || document.body).appendChild(frame);
      place(layer);
      updateParents();
    });
  }
  const allowed = new Set(['mineEntry', 'duplicateCheck', 'resolveWordAudio', 'openLink',
    'setSentenceContext', 'clearSentenceDraft', 'sentenceContextPreview']);
  function receive(layer, message) {
    if (!layers.includes(layer) || !message || message.__fushiPopupFrame !== true) return;
    if (message.type === 'close') {
      const index = layers.indexOf(layer);
      dismissAfter(index > 0 ? layers[index - 1] : null);
      (layers.length ? layers[layers.length - 1].frame : fushiHost)?.focus();
      return;
    }
    if (message.type !== 'call') return;
    const args = Array.isArray(message.args) ? message.args : [];
    let result = null;
    if (message.name === 'onLinkClick' || message.name === 'textSelected') open(args[0], args[1], layer, message.name === 'textSelected');
    else if (message.name === 'tapOutside') dismissAfter(layer);
    else if (message.name === 'popupRendered') {
      place(layer, args[0]);
      layer.frame.style.visibility = 'visible';
    } else if (message.name === 'openSentenceContextModal') {
      const oldCue = fushiPendingCueWindow, oldDraft = fushiSentenceCtx;
      fushiPendingCueWindow = layer.cue;
      fushiSentenceCtx = layer.draft;
      window.fushiOpenSentenceContextModal({ ...(args[0] || {}),
        onClose: function () {
          layer.draft = fushiSentenceCtx;
          fushiPendingCueWindow = oldCue;
          fushiSentenceCtx = oldDraft;
        },
        onConfirm: function (entryIndex) { if (layers.includes(layer)) send(layer, { type: 'mine', entryIndex }); },
      });
    } else if (allowed.has(message.name)) {
      result = withContext(layer, () => window.flutter_inappwebview.callHandler(message.name, ...args));
    }
    Promise.resolve(result).then(value => {
      if (layers.includes(layer)) send(layer, { type: 'reply', id: message.id, result: value });
    }, error => {
      if (layers.includes(layer)) send(layer, { type: 'reply', id: message.id, error: String(error) });
    });
  }
  // The public window channel only bootstraps a capability. All commands and
  // replies use the private port, so the website cannot forge popup actions.
  window.addEventListener('message', function (event) {
    const message = event.data;
    if (!message || message.__fushiPopupFrame !== true || message.type !== 'ready' || event.origin !== frameOrigin) return;
    const layer = layers.find(item => item.frame.contentWindow === event.source);
    if (!layer || layer.port) return;
    const channel = new MessageChannel();
    layer.port = channel.port1;
    layer.port.onmessage = event => receive(layer, event.data);
    layer.port.start();
    layer.frame.contentWindow.postMessage(
      { __fushiPopupFrame: true, type: 'connect' }, frameOrigin, [channel.port2]);
    send(layer, { type: 'render', data: layer.data });
    send(layer, { type: 'hasChild', value: layers.indexOf(layer) < layers.length - 1 });
  });
  window.fushiNestedPopups = {
    open: (query, anchor, highlight) => open(query, anchor, null, highlight),
    dismissChildren: () => dismissAfter(null),
    clear: () => { requests.clear(); dismissAfter(null); },
    pop: () => {
      if (!layers.length) return false;
      dismissAfter(layers.length > 1 ? layers[layers.length - 2] : null);
      (layers.length ? layers[layers.length - 1].frame : fushiHost)?.focus();
      return true;
    },
  };
})();
