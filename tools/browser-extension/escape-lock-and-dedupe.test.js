// 用户 2026-09-18 两条：
//  ① 「按 Esc 关查词框会连全屏一起退掉」——Fullscreen API 全屏下浏览器进程先于渲染器用 Esc 退
//     全屏，页面 stopPropagation 拦不住；正规出口是 Keyboard Lock：进全屏（且页面有 <video>）
//     就 navigator.keyboard.lock(['Escape'])，Esc 交给页面：有弹窗关弹窗，没弹窗我们代为
//     exitFullscreen（单按退全屏体感不变）；退全屏即 unlock；无 <video> 的页面不碰。
//  ② 「会重复查词」——弹窗已开着、显示的就是这个词，再点它一次（Shift 悬停后顺手点、悬浮字幕
//     自动查词后点、面板行连点）不得重发请求；同词在途也不发第二笔；关窗或换词照常。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT();
const CONTENT = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
const DICT_MEDIA = fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8');
const AUTO_READ = fs.readFileSync(path.join(__dirname, 'auto-read.js'), 'utf8');
const POPUP_SIZE = fs.readFileSync(path.join(__dirname, 'popup-size.js'), 'utf8');
const NESTED_HOST = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');

function makeEl(tag) {
  const handlers = Object.create(null);
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    id: '', className: '', textContent: '', innerHTML: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {}, children: [], parentNode: null, handlers,
    setAttribute(k, v) { if (k === 'id') el.id = v; el['_' + k] = String(v); },
    getAttribute(k) { return el['_' + k] == null ? null : el['_' + k]; },
    removeAttribute(k) { delete el['_' + k]; },
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener(t, fn) { (handlers[t] = handlers[t] || []).push(fn); },
    removeEventListener() {},
    appendChild(c) { c.parentNode = el; el.children.push(c); return c; },
    removeChild(c) { const i = el.children.indexOf(c); if (i >= 0) el.children.splice(i, 1); c.parentNode = null; return c; },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    closest: () => null,
    querySelector: () => null, querySelectorAll: () => [],
    getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 400, bottom: 300, width: 400, height: 300 }; },
    attachShadow() { el.shadowRoot = makeEl('shadow'); el.shadowRoot.host = el; return el.shadowRoot; },
    focus() {},
  };
  return el;
}
function findById(root, id) {
  if (root.id === id) return root;
  for (const c of root.children || []) { const hit = findById(c, id); if (hit) return hit; }
  return null;
}

function loadContent(opts) {
  opts = opts || {};
  const docListeners = Object.create(null);
  const sent = [];
  const locks = [];
  let unlocks = 0;
  let exits = 0;
  const body = makeEl('body');
  const html = makeEl('html');
  html.appendChild(body);
  const textNode = { textContent: '世界です', nodeType: 3 };
  let nextTerm = '世界';
  const selection = {
    selection: { ranges: [{ node: textNode, start: 0, end: 2 }], text: '世界' },
    getCharacterAtPoint: () => ({ node: textNode, offset: 0 }),
    selectFromPosition: () => nextTerm,
    getSelectionRect: () => ({ x: 100, y: 120, width: 40, height: 18 }),
    highlightSelection() { return { x: 100, y: 120, width: 40, height: 18 }; },
    clearSelection() { selection.selection.ranges = []; },
  };
  const video = opts.video === false ? null : { paused: false, ended: false, pause() {} };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {},
    requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now() { return 1000; }, timeOrigin: 1700000000000 },
    location: { hostname: 'example.com', href: 'https://example.com/page', pathname: '/page' },
    navigator: opts.keyboard === false ? {} : {
      keyboard: {
        lock(keys) { locks.push(keys); return Promise.resolve(); },
        unlock() { unlocks += 1; },
      },
    },
  };
  sandbox.document = {
    documentElement: html, body,
    fullscreenElement: null,
    exitFullscreen() { exits += 1; sandbox.document.fullscreenElement = null; return Promise.resolve(); },
    addEventListener: (t, fn, o) => {
      (docListeners[t] = docListeners[t] || []).push(fn);
      if (o === true || (o && o.capture)) (docListeners['capture:' + t] = docListeners['capture:' + t] || []).push(fn);
    },
    removeEventListener() {},
    getElementById: () => null,
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: (sel) => (sel === 'video' && video ? [video] : []),
    createElement: (tag) => makeEl(tag),
    createRange: () => ({
      setStart() {}, setEnd() {},
      getClientRects: () => [{ left: 100, top: 120, right: 140, bottom: 138, width: 40, height: 18 }],
      getBoundingClientRect: () => ({ x: 100, y: 120, left: 100, top: 120, right: 140, bottom: 138, width: 40, height: 18 }),
      extractContents: () => makeEl('span'), insertNode() {},
    }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id', getURL: (rel) => 'chrome-extension://test-ext-id/' + rel, lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (!cb) return;
        if (msg.type === 'lookup' && opts.holdLookups) { pendingCallbacks.push(() => cb(okResponse())); return; }
        cb(okResponse());
      },
    },
    storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {} } },
  };
  const pendingCallbacks = [];
  const okResponse = () => ({ ok: true, data: {
    popupJson: '[{"expression":"世界","reading":"せかい"}]', result: { bestLength: 2 }, audioSources: [],
  } });
  sandbox.window = {
    fushiT: FUSHI_T,
    addEventListener() {}, innerWidth: 1200, innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: selection,
    flutter_inappwebview: { callHandler() { return Promise.resolve(null); } },
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(AUTO_READ, sandbox, { filename: 'auto-read.js' });
  vm.runInContext(POPUP_SIZE, sandbox, { filename: 'popup-size.js' });
  vm.runInContext(NESTED_HOST, sandbox, { filename: 'nested-popup-host.js' });
  vm.runInContext(CONTENT, sandbox, { filename: 'content.js' });
  return {
    sandbox, sent, body, docListeners, video, locks,
    get unlocks() { return unlocks; },
    get exits() { return exits; },
    setTerm(t) { nextTerm = t; },
    lookups: () => sent.filter((m) => m && m.type === 'lookup'),
    popupOpen: () => !!findById(body, 'hibiki-popup-host'),
    flushLookups() { for (const fn of pendingCallbacks.splice(0)) fn(); },
    enterFullscreen() {
      // 全屏元素挂在 body 下：弹窗宿主会挂到 fullscreenElement 上，findById 要能找到。
      sandbox.document.fullscreenElement = body.appendChild(makeEl('div'));
      for (const fn of docListeners.fullscreenchange || []) fn({});
    },
    exitFullscreen() {
      sandbox.document.fullscreenElement = null;
      for (const fn of docListeners.fullscreenchange || []) fn({});
    },
    pressEscape() {
      const e = {
        key: 'Escape', defaultPrevented: false, prevented: false, stopped: false,
        preventDefault() { this.prevented = true; },
        stopPropagation() { this.stopped = true; }, stopImmediatePropagation() { this.stopped = true; },
      };
      for (const fn of docListeners['capture:keydown'] || []) fn(e);
      return e;
    },
  };
}

// ───────── ① Esc 与全屏 ─────────

test('有 <video> 的页面进全屏即锁住 Esc（navigator.keyboard.lock），退全屏即解锁', () => {
  const h = loadContent();
  h.enterFullscreen();
  assert.strictEqual(JSON.stringify(h.locks), '[["Escape"]]', '进全屏必须只锁 Esc 一个键');
  h.exitFullscreen();
  assert.strictEqual(h.unlocks, 1, '退全屏必须解锁，别把锁留给站点');
});

test('没有 <video> 的页面全屏不锁 Esc（只有视频页有查词框压在全屏上的场景）', () => {
  const h = loadContent({ video: false });
  h.enterFullscreen();
  assert.strictEqual(h.locks.length, 0);
});

test('全屏 + 弹窗开着：Esc 只关弹窗，不退全屏；按键被截住不漏给站点', () => {
  const h = loadContent();
  h.enterFullscreen();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null, 0.2);
  assert.ok(h.popupOpen());
  const e = h.pressEscape();
  assert.strictEqual(h.popupOpen(), false, 'Esc 没关掉弹窗');
  assert.strictEqual(h.exits, 0, '弹窗开着时 Esc 不得退全屏（用户报的就是这个）');
  assert.ok(e.stopped && e.prevented, '这次 Esc 要截住');
});

test('全屏 + 没弹窗：单按 Esc 由我们代为退全屏（锁着时浏览器不会自己退）', () => {
  const h = loadContent();
  h.enterFullscreen();
  h.pressEscape();
  assert.strictEqual(h.exits, 1);
});

test('非全屏没弹窗：Esc 什么都不做（不调 exitFullscreen）', () => {
  const h = loadContent();
  h.pressEscape();
  assert.strictEqual(h.exits, 0);
});

test('popup.js 的模态（制卡操作单）开着：Esc 归它，不关整个查词窗', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null, 0.2);
  h.sandbox.window.__fushiPopupModalDepth = 1;
  const e = h.pressEscape();
  assert.ok(h.popupOpen(), '模态开着时 Esc 不得关整个弹窗');
  assert.ok(!e.stopped, '要留给模态自己的监听');
});

test('没有 Keyboard Lock API 的浏览器：不抛、弹窗照关', () => {
  const h = loadContent({ keyboard: false });
  h.enterFullscreen();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null, 0.2);
  h.pressEscape();
  assert.strictEqual(h.popupOpen(), false);
});

// ───────── ② 重复查词 ─────────

test('弹窗已显示这个词：再点同一个词不重发查词请求；换词照常', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null, 0.2);
  assert.strictEqual(h.lookups().length, 1);
  h.setTerm('世界');
  h.sandbox.window.fushiLookupAtPoint(10, 10, null);
  assert.strictEqual(h.lookups().length, 1, '同词且弹窗在场：不得再发一笔（用户报「重复查词」）');
  h.setTerm('計画');
  h.sandbox.window.fushiLookupAtPoint(10, 10, null);
  assert.strictEqual(h.lookups().length, 2, '换了词必须查');
});

test('关窗后再点同一个词照常查（去重只针对「在场」的弹窗）', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null, 0.2);
  h.pressEscape();
  h.setTerm('世界');
  h.sandbox.window.fushiLookupAtPoint(10, 10, null);
  assert.strictEqual(h.lookups().length, 2);
});

test('同词还在途：第二次点击不再发第二笔；响应回来后弹窗照常', () => {
  const h = loadContent({ holdLookups: true });
  h.setTerm('世界');
  h.sandbox.window.fushiLookupAtPoint(10, 10, null);
  h.sandbox.window.fushiLookupAtPoint(12, 10, null);
  assert.strictEqual(h.lookups().length, 1, '在途同词不得重发');
  h.flushLookups();
  assert.ok(h.popupOpen());
});
