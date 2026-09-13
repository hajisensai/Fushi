// Each nested dictionary has its own JS realm: popup.js selection, async render,
// draft and scroll state must never overwrite the parent dictionary's state.
(function () {
  'use strict';

  const host = document.getElementById('fushi-nested-root');
  const root = host.attachShadow({ mode: 'open' });
  window.__fushiRoot = root;
  const stylesheet = document.createElement('link');
  stylesheet.rel = 'stylesheet';
  stylesheet.href = 'vendor/content.css';
  root.appendChild(stylesheet);
  const layout = document.createElement('style');
  layout.textContent = '#entries-container{position:relative!important;width:100%!important;max-width:none!important;max-height:none!important;overflow:visible!important;zoom:1!important}';
  root.appendChild(layout);
  const container = document.createElement('div');
  container.id = 'entries-container';
  root.appendChild(container);

  let parentPort = null;
  let nextId = 0;
  const pending = new Map();
  let queuedExpressions = new Set();

  function send(message) {
    // Business messages never enter the website's window message channel.
    if (parentPort) parentPort.postMessage({ __fushiPopupFrame: true, ...message });
  }

  function expressionOf(fields) {
    return String(fields && (fields.expression || fields.word || fields.term) || '');
  }

  window.fushiIsEntryQueued = function (fields) {
    return queuedExpressions.has(expressionOf(fields));
  };
  window.flutter_inappwebview = {
    callHandler(name, ...args) {
      if (typeof name !== 'string') return Promise.reject(new TypeError('Invalid bridge handler'));
      if (!parentPort) return Promise.reject(new Error('Dictionary bridge is not connected'));
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject, name, args });
        try {
          send({ type: 'call', id, name, args });
        } catch (error) {
          pending.delete(id);
          reject(error);
        }
      });
    },
  };
  window.__fushiOnTapOutside = function () { send({ type: 'close' }); };
  const closeButton = document.getElementById('fushi-nested-close');
  if (closeButton) closeButton.addEventListener('click', function () { send({ type: 'close' }); });

  function render(data) {
    if (!data || typeof data.popupJson !== 'string') return;
    let entries;
    try { entries = JSON.parse(data.popupJson); }
    catch (_) {
      container.textContent = '词典结果解析失败，请重试。';
      return;
    }
    if (!Array.isArray(entries)) return;
    window.lookupEntries = entries;
    queuedExpressions = new Set(Array.isArray(data.queuedExpressions)
      ? data.queuedExpressions.filter(value => typeof value === 'string') : []);
    window.audioSources = Array.isArray(data.audioSources) ? data.audioSources : [];
    window.needsAudio = true;
    window.embedMedia = true;
    window._noResultsMessage = '没有查词结果';
    window.sentenceContextPreviewEnabled = data.sentenceContextPreviewEnabled === true;
    if (data.i18nCtx && typeof data.i18nCtx === 'object') window.i18nCtx = data.i18nCtx;
    window.__hasChildPopup = false;
    if (typeof window.resetSentenceContextMirror === 'function') window.resetSentenceContextMirror();
    const theme = data.theme && typeof data.theme === 'object' ? data.theme : {};
    const zoom = Number(data.popupZoom) > 0 ? Number(data.popupZoom) : 1;
    host.style.zoom = String(zoom);
    host.style.width = (100 / zoom) + '%';
    host.style.height = (100 / zoom) + '%';
    for (const [key, value] of Object.entries(theme)) {
      if (key.startsWith('--') && typeof value === 'string') {
        container.style.setProperty(key, value);
        document.documentElement.style.setProperty(key, value);
      }
    }
    const scheme = theme['--fushi-color-scheme'];
    if (scheme === 'light' || scheme === 'dark') container.setAttribute('data-theme', scheme);
    const wheelSpeed = Number.parseFloat(theme['--fushi-wheel-speed']);
    window.__fushiPopupWheelSpeed = Number.isFinite(wheelSpeed) && wheelSpeed > 0 ? wheelSpeed : 1;
    applyFushiPopupCss(data);
    installDictMediaPlaceholderResolver(root);
    window.renderPopup();
    if (typeof window.fushiAutoReadFirstEntry === 'function') {
      window.fushiAutoReadFirstEntry(entries, {
        enabled: data.autoReadOnLookup === true,
        audioSources: window.audioSources,
      });
    }
  }

  function receive(event) {
    const message = event.data;
    if (!message || message.__fushiPopupFrame !== true) return;
    if (!['render', 'reply', 'hasChild', 'mine', 'highlight'].includes(message.type)) return;
    if (message.type === 'render') {
      render(message.data);
    } else if (message.type === 'reply') {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.error) request.reject(new Error(String(message.error)));
      else {
        if (request.name === 'mineEntry' && message.result && message.result.queued === true) {
          queuedExpressions.add(expressionOf(request.args[0]));
        }
        request.resolve(message.result);
      }
    } else if (message.type === 'hasChild') {
      window.__hasChildPopup = message.value === true;
    } else if (message.type === 'highlight') {
      if (window.fushiSelection && Number.isInteger(message.length) && message.length > 0) {
        window.fushiSelection.highlightSelection(message.length);
      }
    } else if (Number.isInteger(message.entryIndex) && message.entryIndex >= 0 &&
        typeof window.fushiPopupMineEntryByIndex === 'function') {
      window.fushiPopupMineEntryByIndex(message.entryIndex);
    }
  }
  window.addEventListener('message', function (event) {
    if (parentPort || event.source !== window.parent || window.parent === window) return;
    const message = event.data;
    if (!message || message.__fushiPopupFrame !== true || message.type !== 'connect') return;
    const port = event.ports && event.ports[0];
    if (!port || typeof port.postMessage !== 'function') return;
    parentPort = port;
    parentPort.onmessage = receive;
    parentPort.start();
  });
  document.addEventListener('pointerdown', function () { send({ type: 'activate' }); }, true);
  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape' || event.defaultPrevented) return;
    event.preventDefault();
    event.stopPropagation();
    send({ type: 'close' });
  }, true);

  // Retrieve secrets directly in the extension realm, never across the page's
  // postMessage channel where the website can observe them.
  try {
    chrome.runtime.sendMessage({ type: 'dictMediaConfig' }, function (response) {
      if (response && response.ok && response.base && response.token) {
        window.__fushiDictMedia = { base: response.base, token: response.token };
      }
    });
  } catch (_) { /* The normal shared media fallback handles unavailable config. */ }
  document.addEventListener('DOMContentLoaded', function () {
    // Only this data-free handshake is visible to the embedding page. The
    // transferred channel is fixed once; later window messages cannot trigger
    // rendering or privileged bridge calls through the extension's channel.
    window.parent.postMessage({ __fushiPopupFrame: true, type: 'ready' }, '*');
  }, { once: true });
})();
