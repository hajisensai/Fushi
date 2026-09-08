'use strict';
// 审计报告 #1295 第三项的守卫：coarse 指针不再「一律单列」。
// 真加载 vendor/popup.js，直接驱动 effectiveDictColumns()/dictColumns()：
//   · 手机竖屏（coarse + 窄视口）维持单列——原裁决不翻案；
//   · 平板横屏 / in-app 大窗（coarse + 宽视口）按视口解锁多列；
//   · fine（桌面）口径分毫不差；
//   · grid 与 masonry 两路同源不分叉。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function makeEl() {
  return {
    id: '', textContent: '', innerHTML: '', style: { setProperty() {}, removeProperty() {} },
    dataset: {}, children: [], classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; }, removeChild() {}, remove() {},
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
    attachShadow() { const s = makeEl(); this.shadowRoot = s; return s; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
  };
}
function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      return permissive();
    },
    apply() { return permissive(); },
  });
}

function loadPopup(opts) {
  const o = opts || {};
  const docEl = makeEl();
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    navigator: { language: 'zh-CN', userAgent: 'test' },
    URL, Math, JSON, Date, Promise, isFinite, parseInt, parseFloat, RegExp, Object, Array, String, Number, Boolean, Error, TypeError, Map, Set, WeakMap, Symbol, encodeURIComponent, decodeURIComponent,
    document: {
      documentElement: docEl, body: makeEl(),
      getElementById: () => null, createElement: () => makeEl(),
      addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
      createRange: () => ({ setStart() {}, setEnd() {}, getBoundingClientRect: () => null }),
      createTreeWalker: () => ({ nextNode: () => null }),
      createDocumentFragment: () => makeEl(),
    },
    getComputedStyle: () => ({
      getPropertyValue: (k) => (k === '--dict-columns' ? String(o.columns == null ? 1 : o.columns) : ''),
    }),
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    ResizeObserver: class { observe() {} disconnect() {} unobserve() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    chrome: permissive(),
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  };
  sandbox.window = {
    addEventListener() {}, removeEventListener() {},
    innerWidth: o.width || 0, innerHeight: 800,
    matchMedia: (q) => ({ matches: q.indexOf('coarse') >= 0 && o.coarse === true }),
    __fushiPopupViewportWidth: o.width || 0,
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(POPUP, sandbox, { filename: 'vendor/popup.js' });
  return sandbox;
}

test('coarse + 手机竖屏 400px：维持单列（原裁决不翻案）', () => {
  const s = loadPopup({ coarse: true, width: 400, columns: 3 });
  assert.strictEqual(s.effectiveDictColumns(), 1);
});

test('coarse + 平板横屏 700px：解锁到 2 列（老版此处被静默锁死 1）', () => {
  const s = loadPopup({ coarse: true, width: 700, columns: 3 });
  assert.strictEqual(s.effectiveDictColumns(), 2); // 700 / (170*2) = 2
});

test('coarse + in-app 大窗 1200px：按用户设置出 3 列', () => {
  const s = loadPopup({ coarse: true, width: 1200, columns: 3 });
  assert.strictEqual(s.effectiveDictColumns(), 3);
});

test('fine + 桌面 400px：口径不变（400/170 → 2 列）', () => {
  const s = loadPopup({ coarse: false, width: 400, columns: 3 });
  assert.strictEqual(s.effectiveDictColumns(), 2);
});

test('grid 与 masonry 单一真值：dictColumns() 与 effectiveDictColumns() 恒等', () => {
  for (const cfg of [
    { coarse: true, width: 400, columns: 3 },
    { coarse: true, width: 700, columns: 3 },
    { coarse: false, width: 1200, columns: 4 },
  ]) {
    const s = loadPopup(cfg);
    assert.strictEqual(s.dictColumns(), s.effectiveDictColumns(),
      '两路分叉 cfg=' + JSON.stringify(cfg));
  }
});
