'use strict';
// BUG-3666 / BUG-3667 守卫：扩展把查词弹窗画进网页的 shadow root（window.__fushiRoot）。
//   · 3666：词典列数按 window.innerWidth（整张网页宽）算「装得下几列」，370px 宽的弹窗里
//     照样挤三列。列数必须按 shadow 宿主的弹窗宽算。
//   · 3667：语法说明浮层挂在 shadow root 顶层、不在 #entries-container 之下，拿不到主题
//     变量 → 没有底色。显示前必须从弹窗容器把变量与明暗抄过来。
// 真加载 vendor/popup.js（与 app 内 assets/popup/popup.js 字节一致，sync-mirrors 守）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function makeEl() {
  const props = {};
  const attrs = {};
  return {
    id: '', textContent: '', innerHTML: '',
    style: {
      setProperty(k, v) { props[k] = v; }, removeProperty(k) { delete props[k]; },
      getPropertyValue(k) { return props[k] || ''; },
    },
    _props: props,
    dataset: {}, children: [], classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; }, removeChild() {}, remove() {},
    setAttribute(k, v) { attrs[k] = String(v); }, getAttribute(k) { return k in attrs ? attrs[k] : null; },
    removeAttribute(k) { delete attrs[k]; },
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

// o.shadow：{ width, zoom } = 扩展 shadow 宿主；缺省 = app 内整窗 WebView。
function loadPopup(o) {
  const docEl = makeEl();
  const container = makeEl();
  container.setAttribute('data-theme', 'dark');
  const containerVars = {
    '--surface-container-high': '#2b2930',
    '--outline-variant': '#49454f',
    '--text-color': '#e6e0e9',
    '--on-surface-variant': '#cac4d0',
  };
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
    getComputedStyle: (el) => ({
      fontFamily: el === container ? 'Noto Sans JP' : '',
      getPropertyValue: (k) => {
        if (k === '--dict-columns') return String(o.columns == null ? 1 : o.columns);
        return el === container ? (containerVars[k] || '') : '';
      },
    }),
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    ResizeObserver: class { observe() {} disconnect() {} unobserve() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    chrome: permissive(),
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  };
  sandbox.window = {
    addEventListener() {}, removeEventListener() {},
    innerWidth: o.pageWidth, innerHeight: 800,
    matchMedia: () => ({ matches: false }),
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(POPUP, sandbox, { filename: 'vendor/popup.js' });
  // shadow 宿主在弹窗首次打开时才由 content.js 建（加载 popup.js 时还没有），装载后再挂。
  if (o.shadow) {
    const host = makeEl();
    host.style.width = o.shadow.width + 'px';
    if (o.shadow.zoom) host.style.zoom = String(o.shadow.zoom);
    sandbox.window.__fushiRoot = {
      host,
      querySelector: (sel) => (sel === '#entries-container' ? container : null),
    };
  }
  return { sandbox, container };
}

test('3666: 扩展 shadow 弹窗 370px、网页 1389px、设 3 列 → 按弹窗宽只排 2 列', () => {
  const { sandbox } = loadPopup({ pageWidth: 1389, columns: 3, shadow: { width: 370 } });
  assert.strictEqual(sandbox.effectiveDictColumns(), 2);
});

test('3666: 扩展 shadow 弹窗 300px → 单列（上下堆叠）', () => {
  const { sandbox } = loadPopup({ pageWidth: 1389, columns: 3, shadow: { width: 300 } });
  assert.strictEqual(sandbox.effectiveDictColumns(), 1);
});

test('3666: 宿主带 zoom、视口比弹窗还窄时按 max-width 上限折算', () => {
  // max-width: calc(100vw - 16px) 在 zoom 2 的宿主上 = (500-16)/2 = 242 基准 px → 1 列。
  const { sandbox } = loadPopup({ pageWidth: 500, columns: 3, shadow: { width: 600, zoom: 2 } });
  assert.strictEqual(sandbox.effectiveDictColumns(), 1);
});

test('3666: 非 shadow 宿主（app 内整窗 WebView）口径不变：按视口宽', () => {
  const { sandbox } = loadPopup({ pageWidth: 1389, columns: 3 });
  assert.strictEqual(sandbox.effectiveDictColumns(), 3);
});

test('3667: shadow 宿主里语法说明浮层抄到容器的底色 / 描边 / 文字色与明暗', () => {
  const { sandbox } = loadPopup({ pageWidth: 1389, columns: 1, shadow: { width: 370 } });
  const tip = {
    style: { _p: {}, setProperty(k, v) { this._p[k] = v; } },
    _a: {}, setAttribute(k, v) { this._a[k] = v; },
  };
  sandbox.applyGrammarTooltipTheme(tip);
  assert.strictEqual(tip.style._p['--surface-container-high'], '#2b2930');
  assert.strictEqual(tip.style._p['--outline-variant'], '#49454f');
  assert.strictEqual(tip.style._p['--text-color'], '#e6e0e9');
  assert.strictEqual(tip._a['data-theme'], 'dark');
  assert.strictEqual(tip.style.fontFamily, 'Noto Sans JP');
});

test('3667: 非 shadow 宿主不动浮层（它挂在 body 下，本来就继承 <html> 的变量）', () => {
  const { sandbox } = loadPopup({ pageWidth: 400, columns: 1 });
  const tip = { style: { _p: {}, setProperty(k, v) { this._p[k] = v; } }, setAttribute() {} };
  sandbox.applyGrammarTooltipTheme(tip);
  assert.deepStrictEqual(tip.style._p, {});
});

test('3667: showGrammarTooltip 每次显示前都走 applyGrammarTooltipTheme', () => {
  const body = POPUP.slice(POPUP.indexOf('function showGrammarTooltip('));
  const head = body.slice(0, body.indexOf('\n}\n'));
  assert.ok(/ensureGrammarTooltip\(\);\s*applyGrammarTooltipTheme\(tooltip\);/.test(head),
    'showGrammarTooltip 必须在 ensureGrammarTooltip 之后立刻套主题');
});
