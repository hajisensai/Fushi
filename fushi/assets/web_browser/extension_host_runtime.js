// app 内浏览器的「扩展宿主运行时」：让浏览器扩展（tools/browser-extension，app 内镜像
// assets/browser_extension/）的内容脚本栈在标签页 WebView 的页面主世界里原样运行。
//
// 拼装见 lib/src/web_browser/features/extension_host/web_browser_extension_bundle.dart：整栈
// （本文件 + 扩展 manifest content_scripts 的脚本）拼进**一个闭包**，本文件排在最前。闭包外
// 先声明好两个局部量：
//   __fushiExtSecret  Dart 生成的会话密钥（写在脚本源码里，页面读不到闭包与脚本源码）
//   __fushiExtBoot    {contentCss, iconDataUrl, extensionId, forceStart}
// 页面主世界里没有扩展的隔离世界，所以这里把扩展依赖的东西都收成**闭包局部变量**：
//   chrome            chrome.runtime / chrome.storage 垫片，全部转给 Dart（fushiExt 处理器）
//   fetch             只拦 chrome.runtime.getURL 给出的 fushi-ext://asset/ 地址，其余原样交给页面 fetch
//   __fushiExtNs      打包时把扩展源码里的 window.fushiSelection / window.flutter_inappwebview
//                     改写到这里：扩展的取词状态与 bridge-shim 的桥垫片都不碰页面全局，
//                     app 自己的取词脚本（window.fushiSelection）与 JS 桥（window.flutter_inappwebview）不受影响
//   __fushiHostAdapter content.js 的宿主适配口（查词交给 app 的查词弹窗）
// 页面能拿到的只有 window.__fushiExtHost（Dart 反调入口，每个方法都先核对密钥）。
/* eslint-disable no-unused-vars */
var __fushiExtNs = {};
var __fushiExtAssetPrefix = 'fushi-ext://asset/';
var __fushiExtCall = null;

// app 的 JS 桥：document-start 就收进闭包（页面脚本此时还没跑，换不掉它）。个别平台桥
// 晚于用户脚本就绪 → 等 flutterInAppWebViewPlatformReady 再取。
function __fushiExtCapture() {
  if (__fushiExtCall) return __fushiExtCall;
  try {
    var b = window.flutter_inappwebview;
    if (b && typeof b.callHandler === 'function') {
      var fn = b.callHandler;
      __fushiExtCall = function () { return fn.apply(b, arguments); };
    }
  } catch (_) { /* 桥还没注入 */ }
  return __fushiExtCall;
}
__fushiExtCapture();
var __fushiExtReady = __fushiExtCall ? Promise.resolve() : new Promise(function (resolve) {
  try {
    window.addEventListener('flutterInAppWebViewPlatformReady', function () {
      __fushiExtCapture();
      resolve();
    }, { once: true });
  } catch (_) { resolve(); }
});

// 发给 Dart 的唯一出口：{secret, op, ...}。Dart 核对密钥，不对就丢。
function __fushiExtSend(op, payload) {
  return __fushiExtReady.then(function () {
    var call = __fushiExtCapture();
    if (!call) return null;
    var body = {};
    var src = payload || {};
    for (var k in src) {
      if (Object.prototype.hasOwnProperty.call(src, k)) body[k] = src[k];
    }
    body.secret = __fushiExtSecret;
    body.op = op;
    return call('fushiExt', body);
  });
}

// ── chrome.* 垫片 ──────────────────────────────────────────────────────────
var chrome = (function () {
  var lastError;
  var messageListeners = [];
  var storageListeners = [];

  function listenerApi(list) {
    return {
      addListener: function (fn) { if (typeof fn === 'function' && list.indexOf(fn) < 0) list.push(fn); },
      removeListener: function (fn) { var i = list.indexOf(fn); if (i >= 0) list.splice(i, 1); },
      hasListener: function (fn) { return list.indexOf(fn) >= 0; },
    };
  }

  // MV3 双形态：给回调就回调、不给就回 Promise。失败时回调里 lastError 有值（与扩展同语义）。
  function settle(promise, cb) {
    if (typeof cb !== 'function') return promise;
    promise.then(function (value) {
      try { cb(value); } catch (e) { setTimeout(function () { throw e; }); }
    }, function (err) {
      lastError = { message: String((err && err.message) || err || 'error') };
      try { cb(undefined); } catch (e) { setTimeout(function () { throw e; }); }
      lastError = undefined;
    });
    return undefined;
  }

  function normalizeKeys(keys) {
    if (keys === null || keys === undefined) return { list: null, defaults: null };
    if (typeof keys === 'string') return { list: [keys], defaults: null };
    if (Array.isArray(keys)) return { list: keys.map(String), defaults: null };
    if (typeof keys === 'object') return { list: Object.keys(keys), defaults: keys };
    return { list: [], defaults: null };
  }

  var runtime = {
    id: __fushiExtBoot.extensionId,
    get lastError() { return lastError; },
    getURL: function (path) {
      var p = String(path || '').replace(/^\/+/, '');
      if (p === 'icon-32.png' && __fushiExtBoot.iconDataUrl) return __fushiExtBoot.iconDataUrl;
      return __fushiExtAssetPrefix + p;
    },
    sendMessage: function (message, cb) {
      // 扩展签名还允许 (extensionId, message, options, cb)；内容脚本只用 (message[, cb])。
      var p = __fushiExtSend('message', { message: message }).then(function (r) {
        return r === null ? undefined : r;
      });
      return settle(p, cb);
    },
    openOptionsPage: function () {
      __fushiExtSend('message', { message: { type: 'openOptions' } });
    },
    onMessage: listenerApi(messageListeners),
  };

  var local = {
    get: function (keys, cb) {
      var k = normalizeKeys(keys);
      var p = __fushiExtSend('storageGet', { keys: k.list }).then(function (r) {
        var out = {};
        if (k.defaults) {
          for (var d in k.defaults) {
            if (Object.prototype.hasOwnProperty.call(k.defaults, d)) out[d] = k.defaults[d];
          }
        }
        if (r && typeof r === 'object') {
          for (var key in r) {
            if (Object.prototype.hasOwnProperty.call(r, key)) out[key] = r[key];
          }
        }
        return out;
      });
      return settle(p, cb);
    },
    set: function (items, cb) {
      var p = __fushiExtSend('storageSet', { items: items || {} }).then(function () { return undefined; });
      return settle(p, cb);
    },
    remove: function (keys, cb) {
      var k = normalizeKeys(keys);
      var p = __fushiExtSend('storageRemove', { keys: k.list || [] }).then(function () { return undefined; });
      return settle(p, cb);
    },
  };

  return {
    runtime: runtime,
    storage: { local: local, onChanged: listenerApi(storageListeners) },
    __messageListeners: messageListeners,
    __storageListeners: storageListeners,
  };
})();

// ── fetch：只服务 getURL 给出的扩展资源 ─────────────────────────────────────
var fetch = function (input, init) {
  var url = typeof input === 'string' ? input : (input && input.url) || '';
  if (typeof url === 'string' && url.indexOf(__fushiExtAssetPrefix) === 0) {
    var path = url.slice(__fushiExtAssetPrefix.length);
    if (path === 'vendor/content.css') {
      return Promise.resolve(new Response(__fushiExtBoot.contentCss || '', {
        status: 200, headers: { 'Content-Type': 'text/css' },
      }));
    }
    return __fushiExtSend('asset', { path: path }).then(function (text) {
      return typeof text === 'string'
        ? new Response(text, { status: 200 })
        : new Response('', { status: 404 });
    });
  }
  return window.fetch.apply(window, arguments);
};

// ── content.js 的宿主适配口 ─────────────────────────────────────────────────
var __fushiExtLookupMatched = {};
var __fushiHostAdapter = {
  // req: {term, sentence, rect:{x,y,width,height}|null, fromHover, fromSidePanel,
  //       ruby:[{s,e,r}]|null（term 上的原文振假名）}
  lookup: function (req, onMatched) {
    var id = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
    __fushiExtLookupMatched = {};
    if (typeof onMatched === 'function') __fushiExtLookupMatched[id] = onMatched;
    __fushiExtSend('lookup', {
      id: id,
      term: String(req && req.term || ''),
      sentence: String(req && req.sentence || ''),
      rect: req && req.rect ? req.rect : null,
      fromHover: !!(req && req.fromHover),
      ruby: req && Array.isArray(req.ruby) && req.ruby.length ? req.ruby : null,
    });
    return id;
  },
  dismiss: function () { __fushiExtSend('lookupDismiss', {}); },
  onClosed: null,
};

// ── Dart 反调入口（页面可见，但每个方法都先核对密钥）────────────────────────
(function () {
  function ok(secret) { return secret === __fushiExtSecret; }
  var host = {
    // runtime.onMessage 派发；有 id 时把 sendResponse 的结果回给 Dart（侧栏取状态等）。
    dispatch: function (secret, id, message) {
      if (!ok(secret)) return false;
      var listeners = chrome.__messageListeners.slice();
      var responded = false;
      var async = false;
      function reply(value) {
        if (responded) return;
        responded = true;
        if (id) __fushiExtSend('reply', { id: id, response: value === undefined ? null : value });
      }
      for (var i = 0; i < listeners.length; i++) {
        try {
          if (listeners[i](message, { id: chrome.runtime.id }, reply) === true) async = true;
        } catch (_) { /* 一个监听器抛错不影响其它 */ }
      }
      if (!async) reply(undefined);
      return true;
    },
    storageChanged: function (secret, changes) {
      if (!ok(secret) || !changes) return false;
      var listeners = chrome.__storageListeners.slice();
      for (var i = 0; i < listeners.length; i++) {
        try { listeners[i](changes, 'local'); } catch (_) {}
      }
      return true;
    },
    lookupMatched: function (secret, id, matched) {
      if (!ok(secret)) return false;
      var cb = __fushiExtLookupMatched[id];
      if (typeof cb === 'function') { try { cb(matched); } catch (_) {} }
      return true;
    },
    lookupClosed: function (secret) {
      if (!ok(secret)) return false;
      __fushiExtLookupMatched = {};
      var fn = __fushiHostAdapter.onClosed;
      if (typeof fn === 'function') { try { fn(); } catch (_) {} }
      return true;
    },
  };
  try {
    Object.defineProperty(window, '__fushiExtHost', {
      value: Object.freeze(host), writable: false, configurable: false, enumerable: false,
    });
  } catch (_) { /* 已存在（同文档重复注入）：保留先装的那份 */ }
})();

// ── 宿主取词脚本让位：点 / 悬停在扩展自绘的页内 UI 上时，宿主正文取词不接这一下 ──
// 宿主正文取词（srs_card_lookup.dart 的 kSrsCardLookupScript）在 document 冒泡阶段听
// pointer / touch / mousemove，并读门控 window.__fushiSrsLookup。字幕覆盖层自己就查词，
// 两边都接就弹两次。这里把门控换成访问器：事件目标在扩展 UI 上的那一次派发期间，
// 读到的门控是 open:true（= 宿主取词不动），派发结束立即复原。不改宿主脚本本身。
(function () {
  var EXT_UI = '#fushi-subtitle-overlay, #fushi-player-btn, #fushi-player-controls, ' +
    '#fushi-toast, #fushi-queue-chip, #fushi-ctx-modal-host, #fushi-subtitle-drop-hint';
  var gate;
  var suppressed = false;
  try {
    gate = window.__fushiSrsLookup;
    Object.defineProperty(window, '__fushiSrsLookup', {
      configurable: true,
      get: function () {
        if (!suppressed || !gate || typeof gate !== 'object') return gate;
        var copy = {};
        for (var k in gate) if (Object.prototype.hasOwnProperty.call(gate, k)) copy[k] = gate[k];
        copy.open = true;
        return copy;
      },
      set: function (v) { gate = v; },
    });
  } catch (_) { return; }
  function onExtUi(target) {
    try { return !!(target && target.closest && target.closest(EXT_UI)); } catch (_) { return false; }
  }
  function begin(e) {
    if (!onExtUi(e.target)) return;
    suppressed = true;
    setTimeout(end, 0);
  }
  function end() { suppressed = false; }
  var types = ['pointerdown', 'pointerup', 'pointermove', 'touchstart', 'touchend', 'touchmove', 'mousemove'];
  for (var i = 0; i < types.length; i++) {
    window.addEventListener(types[i], begin, { capture: true, passive: true });
    window.addEventListener(types[i], end, { capture: false, passive: true });
  }
})();

// ── 主栈启动时机 ─────────────────────────────────────────────────────────────
// 扩展的内容脚本是 document_idle 注入的（manifest 没写 run_at）；这里等 DOM 就绪。
// 已知视频站（forceStart）直接起；其它站等页面里真出现 <video> 再起——不看视频的网页
// 不必跑整栈（扩展对它们也只是挂着监听）。
function __fushiExtWhenReady(start) {
  var started = false;
  function go() {
    if (started) return;
    started = true;
    try {
      if (__fushiExtBoot.contentCss && document.documentElement) {
        var style = document.createElement('style');
        style.id = 'fushi-ext-content-css';
        style.textContent = __fushiExtBoot.contentCss;
        (document.head || document.documentElement).appendChild(style);
      }
    } catch (_) { /* 样式进不去（CSP）：功能照常，只是没有扩展样式 */ }
    start();
  }
  function hasVideo() {
    try { return document.getElementsByTagName('video').length > 0; } catch (_) { return false; }
  }
  function onReady() {
    if (__fushiExtBoot.forceStart || hasVideo()) { go(); return; }
    try {
      var mo = new MutationObserver(function () {
        if (hasVideo()) { mo.disconnect(); go(); }
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (_) { /* 没有 MutationObserver：只认就绪时已有的视频 */ }
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', onReady, { once: true });
  } else {
    onReady();
  }
}
