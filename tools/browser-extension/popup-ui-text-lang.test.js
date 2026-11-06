'use strict';
// 反馈 9GSrEkVLai：弹窗里的界面文案（「音调 · N」药丸等 i18n 串）挂界面语言的 lang。
// 弹窗根节点不设 lang，兜底字体链按默认内容语言（日语）建，中文界面串里的简体字
// 「调」在日文字体里缺字，掉到别的字体，同一枚药丸两种字形。标了 lang 后 :lang(zh)
// 规则接管。浏览器扩展没有注入 __fushiUiLanguage，不标（维持原样）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function makeEl() {
  return {
    id: '', className: '', textContent: '', innerHTML: '', style: { setProperty() {}, removeProperty() {} },
    dataset: {}, children: [], classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; }, removeChild() {}, remove() {},
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    append(...c) { this.children.push(...c); },
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
    __fushiUiLanguage: o.uiLanguage,
    i18nPitchSourceCount: '音调 · {count}',
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(POPUP, sandbox, { filename: 'vendor/popup.js' });
  return sandbox;
}

function countPill(group) {
  return group.children.find((c) => c.className === 'pitch-dict-label pitch-dict-count');
}

test('注入了界面语言：音调来源计数药丸挂界面语言 lang', () => {
  const s = loadPopup({ uiLanguage: 'zh-CN' });
  const group = s.createPitchGroup(
    { dictionaries: ['NHK', '大辞林'], pitchPositions: [] }, 'かすれる');
  const pill = countPill(group);
  assert.ok(pill, '两本来源时应有计数药丸');
  assert.strictEqual(pill.attrs.lang, 'zh-CN');
});

test('来源药丸（词典名，属内容）不挂界面语言', () => {
  const s = loadPopup({ uiLanguage: 'zh-CN' });
  const group = s.createPitchGroup(
    { dictionaries: ['NHK', '大辞林'], pitchPositions: [] }, 'かすれる');
  const names = group.children.filter((c) => c.className === 'pitch-dict-label');
  assert.strictEqual(names.length, 2);
  names.forEach((n) => assert.strictEqual(n.attrs.lang, undefined));
});

test('没注入界面语言（浏览器扩展）：不标 lang', () => {
  const s = loadPopup({});
  const pill = countPill(s.createPitchGroup(
    { dictionaries: ['NHK', '大辞林'], pitchPositions: [] }, 'かすれる'));
  assert.strictEqual(pill.attrs.lang, undefined);
});
