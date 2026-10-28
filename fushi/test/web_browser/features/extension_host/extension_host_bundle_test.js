// 由 web_browser_extension_bundle_test.dart 调起：node <bundle.js> <secret>。
//
// 在受控 vm 里真跑 app 内浏览器注入的整栈脚本（宿主运行时 + 扩展内容脚本），DOM 用
// 「什么都接得住」的宽松桩：这里验的不是扩展 UI 的行为（那由 tools/browser-extension 的测试
// 管），而是**拼装与宿主边界**——
//   ① 整段能编译、主栈在 DOM 就绪时跑完不抛错（拼进同一作用域没有撞名 / 顺序问题）；
//   ② 子框架、非 http(s) 文档什么都不做；
//   ③ 页面全局不被污染：window.flutter_inappwebview 还是 app 的桥、没有 window.fushiSelection、
//      页面拿不到 chrome；
//   ④ 页内调用都带会话密钥走 fushiExt 处理器；window.__fushiExtHost 不认错的密钥；
//   ⑤ chrome.storage.local.get 经 Dart 往返；runtime.onMessage 派发并把 sendResponse 回给 Dart。
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert');

const bundle = fs.readFileSync(process.argv[2], 'utf8');
const secret = process.argv[3];
// 标签页 initialUserScripts 里排在整栈前面的 adblock cosmetic 引导脚本（可选第三个参数）。
const adblock = process.argv[4] ? fs.readFileSync(process.argv[4], 'utf8') : '';

function stub(name) {
  const target = function () {};
  const own = Object.create(null);
  return new Proxy(target, {
    get(_t, k) {
      if (k === Symbol.toPrimitive) return () => 0;
      if (k === Symbol.iterator) return function* () {};
      if (k === 'then') return undefined;
      if (k === 'length') return 0;
      if (k === 'toString' || k === 'valueOf') return () => '';
      if (k in own) return own[k];
      const v = stub(name + '.' + String(k));
      own[k] = v;
      return v;
    },
    set(_t, k, v) { own[k] = v; return true; },
    has(_t, k) { return k in own; },
    apply() { return stub(name + '()'); },
    construct() { return stub('new ' + name); },
  });
}

function makeWorld(opts) {
  const errors = [];
  const calls = [];
  const listeners = Object.create(null);
  const docListeners = Object.create(null);
  const timers = [];
  const bridge = {
    callHandler(name, body) {
      calls.push({ name, body });
      if (opts && typeof opts.onCall === 'function') return Promise.resolve(opts.onCall(name, body));
      return Promise.resolve(null);
    },
  };
  const documentElement = stub('html');
  const document = new Proxy(stub('document'), {
    get(t, k) {
      if (k === 'readyState') return 'loading';
      if (k === 'documentElement') return documentElement;
      if (k === 'fullscreenElement') return null;
      if (k === 'addEventListener') return (type, fn) => { (docListeners[type] = docListeners[type] || []).push(fn); };
      if (k === 'getElementsByTagName') return () => [];
      if (k === 'querySelector') return () => null;
      if (k === 'querySelectorAll') return () => [];
      if (k === 'getElementById') return () => null;
      return t[k];
    },
  });
  const win = {
    flutter_inappwebview: bridge,
    location: Object.assign({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=abc', href: 'https://www.youtube.com/watch?v=abc', protocol: 'https:' }, opts && opts.location),
    navigator: { language: 'ja', userAgent: 'test', keyboard: null },
    document,
    console: { log() {}, warn() {}, error() {}, info() {}, debug() {} },
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    dispatchEvent() { return true; },
    postMessage() {},
    getComputedStyle: () => stub('style'),
    matchMedia: () => ({ matches: false, addEventListener() {}, addListener() {} }),
    MutationObserver: function () { return { observe() {}, disconnect() {} }; },
    ResizeObserver: function () { return { observe() {}, disconnect() {}, unobserve() {} }; },
    IntersectionObserver: function () { return { observe() {}, disconnect() {}, unobserve() {} }; },
    fetch: () => Promise.resolve({ ok: false, text: () => Promise.resolve(''), json: () => Promise.resolve(null) }),
    Response: class { constructor(body, init) { this.body = body; this.status = (init && init.status) || 200; this.ok = this.status < 300; } text() { return Promise.resolve(String(this.body)); } json() { return Promise.resolve(JSON.parse(String(this.body))); } },
    XMLHttpRequest: function () { return stub('xhr'); },
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    NodeFilter: { SHOW_TEXT: 4, SHOW_ELEMENT: 1 },
    HTMLVideoElement: function () {},
    HTMLElement: function () {},
    Element: function () {},
    CSS: { supports: () => false, highlights: null },
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    crypto: { getRandomValues: (a) => a, randomUUID: () => 'uuid' },
    innerWidth: 1280,
    innerHeight: 720,
    devicePixelRatio: 1,
    screen: { width: 1280, height: 720 },
    history: { pushState() {}, replaceState() {} },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    Promise, JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error, TypeError,
    Map, Set, WeakMap, WeakSet, Symbol, Proxy, Reflect, URL, URLSearchParams, TextEncoder, TextDecoder,
    parseInt, parseFloat, isFinite, isNaN, encodeURIComponent, decodeURIComponent, Intl, queueMicrotask,
    AbortController, Event: function (t) { this.type = t; }, CustomEvent: function (t, i) { this.type = t; this.detail = i && i.detail; },
  };
  win.window = win;
  win.self = win;
  win.top = (opts && opts.top) || win;
  win.globalThis = win;
  const ctx = vm.createContext(win);
  return { win, ctx, calls, listeners, docListeners, errors, timers };
}

async function flush() {
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
}

(async () => {
  // ① 编译
  new vm.Script(bundle, { filename: 'bundle.js' });

  // ② 子框架 / 非 http(s)：什么都不做
  {
    const parent = {};
    const w = makeWorld({ top: parent });
    vm.runInContext(bundle, w.ctx);
    assert.strictEqual(w.win.__fushiExtHost, undefined, '子框架不装宿主入口');
    assert.strictEqual(w.calls.length, 0, '子框架不调 Dart');
  }
  {
    const w = makeWorld({ location: { protocol: 'file:', href: 'file:///x' } });
    vm.runInContext(bundle, w.ctx);
    assert.strictEqual(w.win.__fushiExtHost, undefined, 'file: 文档不装');
  }

  // ①③④⑤ 顶层 YouTube 文档
  const storage = { subtitleOverlayEnabled: true };
  const w = makeWorld({
    onCall(name, body) {
      if (body && body.op === 'storageGet') {
        const out = {};
        for (const k of body.keys || Object.keys(storage)) if (k in storage) out[k] = storage[k];
        return out;
      }
      return null;
    },
  });
  const realBridge = w.win.flutter_inappwebview;
  const realFetch = w.win.fetch;
  if (adblock) {
    // 与标签页同序：adblock 引导脚本先跑。它只做 cosmetic（藏元素），不得碰 fetch——
    // youtube-bridge 取整轨字幕走页面 fetch。
    vm.runInContext(adblock, w.ctx);
    assert.strictEqual(w.win.fetch, realFetch, 'adblock 引导脚本不得改写 fetch');
  }
  vm.runInContext(bundle, w.ctx);
  assert.strictEqual(w.win.__fushiYoutubeBridgeInstalled, true, 'YouTube 上 youtube-bridge 在 adblock 之后照常装上');
  assert.ok(w.win.__fushiExtHost, '顶层文档装上宿主入口');
  assert.strictEqual(w.win.flutter_inappwebview, realBridge, 'app 的 JS 桥不得被覆盖');
  // DOM 就绪：主栈开跑（YouTube 是视频站，不等 <video>）。
  for (const fn of w.docListeners.DOMContentLoaded || []) fn({});
  await flush();
  assert.strictEqual(w.win.flutter_inappwebview, realBridge, '主栈跑完 app 的 JS 桥仍是原物');
  assert.strictEqual(w.win.fushiSelection, undefined, '扩展取词状态不得落到页面全局');
  assert.strictEqual(w.win.chrome, undefined, '页面拿不到 chrome 垫片');
  assert.ok(w.calls.some((c) => c.name === 'fushiExt'), '主栈应经 fushiExt 调 Dart（读存储等）');
  for (const c of w.calls) {
    // adblock 引导脚本有自己的处理器；整栈的调用（带 op）只走 fushiExt。
    if (c.name !== 'fushiExt') {
      assert.ok(!(c.body && c.body.op), '整栈只走 fushiExt 一个处理器：' + c.name);
      continue;
    }
    assert.strictEqual(c.body.secret, secret, '每次调用都带会话密钥');
  }
  assert.ok(w.calls.some((c) => c.body && c.body.op === 'storageGet'), '扩展读设置经 Dart');
  assert.strictEqual(typeof w.win.fushiSubtitleTrackList, 'function', 'subtitle-panel.js 跑完（侧栏契约在）');
  assert.ok(w.win.FUSHI_PLAYER_CONTROLS, 'player-controls.js 跑完');

  // ④ 错密钥一律拒
  assert.strictEqual(w.win.__fushiExtHost.dispatch('wrong', 'x', { type: 'fushiSubtitleSidePanelState' }), false);
  assert.strictEqual(w.win.__fushiExtHost.lookupClosed('wrong'), false);
  assert.throws(() => { w.win.__fushiExtHost.dispatch = null; }, TypeError, '宿主入口冻结，页面换不掉');

  // ⑤ onMessage 派发：侧栏状态请求 → sendResponse 回给 Dart（op: reply）
  const before = w.calls.length;
  assert.strictEqual(w.win.__fushiExtHost.dispatch(secret, 'r1', { type: 'fushiSubtitleSidePanelState', includeCues: false }), true);
  await flush();
  const reply = w.calls.slice(before).find((c) => c.body && c.body.op === 'reply');
  assert.ok(reply, '应回一条 reply');
  assert.strictEqual(reply.body.id, 'r1');
  assert.strictEqual(reply.body.response && reply.body.response.ok, true, 'subtitle-panel.js 回了侧栏状态');

  console.log('all assertions passed');
})().catch((e) => {
  console.error(e && e.stack || e);
  process.exit(1);
});
