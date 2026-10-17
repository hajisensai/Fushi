// Each nested dictionary has its own JS realm: popup.js selection, async render,
// draft and scroll state must never overwrite the parent dictionary's state.
(function () {
  'use strict';
  function tr(key, params) {
    return (typeof window.fushiT === 'function') ? window.fushiT(key, params) : key;
  }

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
      // popupRendered 双发（首词条 / 终高）：把「尾批仍在途」一并告诉宿主，宿主据此按最终
      // 可能的高度选边、显示即锁边，不再先落词下方再翻上去（nested-popup-host.js place）。
      if (name === 'popupRendered') {
        args = [args[0], args[1], args[2], window._renderInProgress === true];
      }
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
  // 本层不放可见的关闭钮：Esc（下方 keydown）、点本层外（tapOutside）与鼠标离开即逐层关闭。

  function render(data) {
    if (!data || typeof data.popupJson !== 'string') return;
    let entries;
    try { entries = JSON.parse(data.popupJson); }
    catch (_) {
      container.textContent = tr('lookup_parse_failed');
      return;
    }
    if (!Array.isArray(entries)) return;
    window.lookupEntries = entries;
    queuedExpressions = new Set(Array.isArray(data.queuedExpressions)
      ? data.queuedExpressions.filter(value => typeof value === 'string') : []);
    window.audioSources = Array.isArray(data.audioSources) ? data.audioSources : [];
    window.needsAudio = true;
    window.embedMedia = true;
    window._noResultsMessage = tr('lookup_no_results');
    window.sentenceContextPreviewEnabled = data.sentenceContextPreviewEnabled === true;
    if (data.i18nCtx && typeof data.i18nCtx === 'object') window.i18nCtx = data.i18nCtx;
    window.__hasChildPopup = false;
    if (typeof window.resetSentenceContextMirror === 'function') window.resetSentenceContextMirror();
    const theme = data.theme && typeof data.theme === 'object' ? data.theme : {};
    const zoom = Number(data.popupZoom) > 0 ? Number(data.popupZoom) : 1;
    host.style.zoom = String(zoom);
    // 百分比尺寸按包含块解析、不乘 zoom（Chrome 标准化 CSS zoom 后实测：zoom 1.25 + 80%
    // 渲染为父盒 80%）。写 100/zoom % 会让内容只占外框的 1/zoom，底部右侧留大块空白。
    host.style.width = '100%';
    host.style.height = '100%';
    for (const [key, value] of Object.entries(theme)) {
      if (key.startsWith('--') && typeof value === 'string') {
        container.style.setProperty(key, value);
        document.documentElement.style.setProperty(key, value);
      }
    }
    // 扩展主题显式 light/dark 压过 app 的值（theme.js；查词请求已带同一个 colorScheme 提示）。
    let scheme = theme['--fushi-color-scheme'];
    if (window.fushiTheme && typeof window.fushiTheme.resolve === 'function') {
      scheme = window.fushiTheme.resolve(scheme);
    }
    if (scheme === 'light' || scheme === 'dark') {
      container.setAttribute('data-theme', scheme);
      // 本层文档的滚动条跟弹窗同一明暗；color-scheme 与 iframe 元素上那份
      // （nested-popup-host.js fushiNestedLayerSkin）一致，Chrome 才不给 iframe 垫不透明画布底。
      document.documentElement.setAttribute('data-theme', scheme);
      if (document.documentElement.style) document.documentElement.style.colorScheme = scheme;
    }
    // 与第一层同一套玻璃（content.js fushiApplyGlass）：弹窗根挂 .fushi-glass = 半透明填充；
    // 模糊 / 圆角 / 描边在宿主页的外框上（nested-popup-host.js，iframe 里的 backdrop-filter
    // 采样不到网页）。半透明填充**只在宿主明确告知外框正在模糊（glassBackdrop === true）时**
    // 才挂：本文件是 web_accessible_resource，每次从磁盘现读；宿主脚本却可能是扩展加载时缓存
    // 的旧版（磁盘被覆盖更新、扩展未重载），旧宿主不给模糊——此时若照样半透明，背后的网页和
    // 父层文字会清清楚楚透出来（2026-10-04 录屏）。没收到握手一律不透明。
    const glass = data.glassBackdrop === true && theme['--fushi-glass'] !== '0';
    if (container.classList) container.classList.toggle('fushi-glass', glass);
    // 预设 / 自定义调色板下弹窗颜色项按扩展主题覆盖（见 content.js fushiApplyTheme）。
    if (window.fushiTheme && typeof window.fushiTheme.applyPopupPalette === 'function') {
      window.fushiTheme.applyPopupPalette(container, scheme);
      window.fushiTheme.applyPopupPalette(document.documentElement, scheme);
    }
    if (window.fushiTheme && typeof window.fushiTheme.applyPopupStyle === 'function') {
      window.fushiTheme.applyPopupStyle(container, theme['--fushi-glass'] === '0');
    }
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
    // 子层里的音频源菜单 / 制卡面板开着：Esc 归它们先关最内层，不能连整层一起关。
    if ((window.__fushiPopupModalDepth || 0) > 0) return;
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
        if (typeof fushiRetryDictionaryFont === 'function') fushiRetryDictionaryFont();
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
