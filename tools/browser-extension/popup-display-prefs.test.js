'use strict';
// BUG-4935：浏览器扩展查词弹窗不跟随 App 的「自动展开行数」「词频聚合」等显示偏好。
//
// 扩展弹窗与 app 内弹窗跑同一份 popup.js，它读一批 window.* 开关决定怎么画：
//   autoExpandRows / collapseDictionaries / collapsedDictionaryNames / expandedDictionaryNames
//   （词典展开折叠）、harmonicFrequency（词频聚合）、deduplicatePitchAccents、showExpressionTags、
//   compactGlossaries。app 内由 popup_settings_injection 注入；扩展侧只接了音调去重一项，
//   其余恒 undefined——collapseDictionaries 缺 → `!undefined` 为真，所有词典全展开，
//   自动展开行数形同虚设；harmonicFrequency 缺 → 词频永远不聚合。
//
// 修法：app 把这批偏好编进查词响应 theme（popup_theme_css.dart buildPopupDisplayPrefsThemeVars），
// 扩展 vendor/dict-media.js 的 applyFushiPopupDisplayPrefs 解回同名全局，三个渲染面共用。
// 本文件：① 解码器真执行；② 解码结果喂给**真的 popup.js**，钉住展开 / 折叠与词频聚合的
// 实际渲染分支；③ 三个渲染面都调用解码器的接线。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const DICT_MEDIA = fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8');
const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function makeEl(tag) {
  return {
    tagName: String(tag || 'div').toUpperCase(),
    id: '', className: '', textContent: '', innerHTML: '', open: false,
    style: { setProperty() {}, removeProperty() {} },
    dataset: {}, children: [], classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; }, append(...cs) { this.children.push(...cs); },
    removeChild() {}, remove() {}, prepend() {}, insertBefore(c) { this.children.push(c); return c; },
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {}, hasAttribute() { return false; },
    attachShadow() { const s = makeEl(); this.shadowRoot = s; return s; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    closest() { return null; },
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

// popup.js 与 dict-media.js 装进同一个 realm（与扩展页面弹窗 / 侧边栏 / 嵌套层的加载方式一致）。
function loadRealm() {
  const docEl = makeEl('html');
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    navigator: { language: 'zh-CN', userAgent: 'test' },
    URL, Math, JSON, Date, Promise, isFinite, parseInt, parseFloat, RegExp, Object, Array, String, Number,
    Boolean, Error, TypeError, Map, Set, WeakMap, Symbol, encodeURIComponent, decodeURIComponent,
    document: {
      documentElement: docEl, body: makeEl('body'),
      getElementById: () => null, createElement: (tag) => makeEl(tag),
      createTextNode: (text) => ({ textContent: text }),
      addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
      createRange: () => ({ setStart() {}, setEnd() {}, getBoundingClientRect: () => null }),
      createTreeWalker: () => ({ nextNode: () => null }),
      createDocumentFragment: () => makeEl(),
    },
    getComputedStyle: () => ({ getPropertyValue: (k) => (k === '--dict-columns' ? '1' : '') }),
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    ResizeObserver: class { observe() {} disconnect() {} unobserve() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    chrome: permissive(),
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  };
  sandbox.window = {
    addEventListener() {}, removeEventListener() {},
    innerWidth: 1200, innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    __fushiPopupViewportWidth: 1200,
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(POPUP, sandbox, { filename: 'vendor/popup.js' });
  return sandbox;
}

// 与 app 侧 buildPopupDisplayPrefsThemeVars 的编码一致（Dart 测试钉住那一侧的键名与格式）。
function appTheme(overrides) {
  return Object.assign({
    '--fushi-dedup-pitch': '1',
    '--fushi-harmonic-frequency': '1',
    '--fushi-expression-tags': '0',
    '--fushi-collapse-dicts': '1',
    '--fushi-compact-glossaries': '0',
    '--fushi-auto-expand-rows': '1',
    '--fushi-collapsed-dicts': '[]',
    '--fushi-expanded-dicts': '[]',
  }, overrides || {});
}

function openStates(realm, totalDicts) {
  const names = [];
  for (let i = 0; i < totalDicts; i++) names.push('D' + i);
  return names.map((name, i) => realm.createGlossarySection(name, [], i, 0, totalDicts).open === true);
}

test('解码器把 app 下发的显示偏好落到 popup.js 读的同名全局上', () => {
  const realm = loadRealm();
  realm.applyFushiPopupDisplayPrefs(appTheme({
    '--fushi-expression-tags': '1',
    '--fushi-compact-glossaries': '1',
    '--fushi-auto-expand-rows': '3',
    '--fushi-collapsed-dicts': '["明鏡","大辞林 \\"第四版\\""]',
    '--fushi-expanded-dicts': '["JMdict"]',
  }));
  const w = realm.window;
  assert.strictEqual(w.deduplicatePitchAccents, true);
  assert.strictEqual(w.harmonicFrequency, true);
  assert.strictEqual(w.showExpressionTags, true);
  assert.strictEqual(w.collapseDictionaries, true);
  assert.strictEqual(w.compactGlossaries, true);
  assert.strictEqual(w.autoExpandRows, 3);
  assert.deepStrictEqual([...w.collapsedDictionaryNames], ['明鏡', '大辞林 "第四版"']);
  assert.deepStrictEqual([...w.expandedDictionaryNames], ['JMdict']);
});

test('旧 app（缺键）与坏数据：按关 / 未设处理，名单归空，绝不抛', () => {
  const realm = loadRealm();
  realm.applyFushiPopupDisplayPrefs({ '--fushi-collapsed-dicts': '{not json', '--fushi-expanded-dicts': '{"a":1}' });
  const w = realm.window;
  assert.strictEqual(w.harmonicFrequency, false);
  assert.strictEqual(w.collapseDictionaries, false);
  assert.strictEqual(w.autoExpandRows, undefined);
  assert.strictEqual(w.collapsedDictionaryNames.length, 0);
  assert.strictEqual(w.expandedDictionaryNames.length, 0);
  realm.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-auto-expand-rows': 'abc' }));
  assert.strictEqual(w.autoExpandRows, undefined);
  realm.applyFushiPopupDisplayPrefs(null);
  assert.strictEqual(w.harmonicFrequency, true, 'null theme 不清掉上次的值');
});

test('修复前的扩展（全局恒 undefined）：所有词典全展开——即用户报的症状', () => {
  const realm = loadRealm();
  assert.deepStrictEqual(openStates(realm, 4), [true, true, true, true]);
});

test('自动展开 1 行 + 折叠开：真 popup.js 只展开第一本，其余折叠（与 app 内一致）', () => {
  const realm = loadRealm();
  realm.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-auto-expand-rows': '1' }));
  assert.deepStrictEqual(openStates(realm, 4), [true, false, false, false]);
  realm.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-auto-expand-rows': '2' }));
  assert.deepStrictEqual(openStates(realm, 4), [true, true, false, false]);
  realm.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-auto-expand-rows': '0' }));
  assert.deepStrictEqual(openStates(realm, 4), [false, false, false, false]);
});

test('逐本折叠 / 展开名单压过自动展开窗口与全局开关（BUG-1264 / BUG-2158 三态在扩展里同样成立）', () => {
  const realm = loadRealm();
  realm.applyFushiPopupDisplayPrefs(appTheme({
    '--fushi-auto-expand-rows': '1',
    '--fushi-collapsed-dicts': '["D0"]',
    '--fushi-expanded-dicts': '["D3"]',
  }));
  assert.deepStrictEqual(openStates(realm, 4), [false, false, false, true]);
});

test('全局折叠关：除逐本折叠的外全部展开', () => {
  const realm = loadRealm();
  realm.applyFushiPopupDisplayPrefs(appTheme({
    '--fushi-collapse-dicts': '0',
    '--fushi-collapsed-dicts': '["D2"]',
  }));
  assert.deepStrictEqual(openStates(realm, 4), [true, true, false, true]);
});

test('词频聚合开：真 popup.js 渲染聚合行并把逐本词频行藏起来；关：只有逐本词频行', () => {
  const freqs = [
    { dictionary: 'JPDB', frequencies: [{ value: 1200, displayValue: '1200' }] },
    { dictionary: 'BCCWJ', frequencies: [{ value: 3400, displayValue: '3400' }] },
  ];
  const on = loadRealm();
  on.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-harmonic-frequency': '1' }));
  const onBody = on.createFrequencySection(freqs).children.find((c) => /category-body/.test(c.className));
  const onRows = onBody.children.filter((c) => /tag-row/.test(c.className));
  assert.strictEqual(onRows.length, 2, '聚合开：逐本行 + 聚合行');
  // 第一行是聚合行（可见），第二行是逐本行（el() 把 style 串直接赋上：display:none）。
  assert.strictEqual(typeof onRows[0].style, 'object', '聚合行可见');
  assert.strictEqual(onRows[1].style, 'display:none', '逐本行默认藏起');

  const off = loadRealm();
  off.applyFushiPopupDisplayPrefs(appTheme({ '--fushi-harmonic-frequency': '0' }));
  const offBody = off.createFrequencySection(freqs).children.find((c) => /category-body/.test(c.className));
  const offRows = offBody.children.filter((c) => /tag-row/.test(c.className));
  assert.strictEqual(offRows.length, 1, '聚合关：只有逐本行');
});

test('三个渲染面（页面弹窗 / 侧边栏 / 嵌套层）都经同一个解码器落显示偏好', () => {
  for (const file of ['content.js', 'side-panel.js', 'nested-popup.js']) {
    const src = fs.readFileSync(path.join(__dirname, file), 'utf8');
    assert.ok(/applyFushiPopupDisplayPrefs\(theme\)/.test(src), file + ' 必须调用 applyFushiPopupDisplayPrefs(theme)');
    assert.ok(!/window\.(autoExpandRows|harmonicFrequency|collapseDictionaries|deduplicatePitchAccents)\s*=/.test(src),
      file + ' 不得另写一份解码（单一解码点在 vendor/dict-media.js）');
  }
});
