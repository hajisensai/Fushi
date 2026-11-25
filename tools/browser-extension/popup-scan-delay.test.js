'use strict';
// 反馈 r4tpeIzVuD：「扫描延迟」（storage.scanDelay，反馈 L4Vhk0hOjM）原先只接进网页侧
// （content.js 的 document mousemove），查词弹窗内部的悬停扫词（vendor/popup.js 的
// __fushiPopupMouseMove）在「不按键」模式下指针每动 8px 就立刻 selectText，同一个设置在弹窗里
// 不起作用。修法：各扩展 realm 注入 __fushiScanDelayMs 钩子，popup.js 延迟 > 0 时改成「停稳后扫」。
// 这里真加载 vendor/popup.js（= fushi/assets/popup/popup.js 字节镜像）驱动 mousemove，
// 再真加载 nested-popup.js / content.js 验钩子接线。
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

// 不带 chrome、不设 __fushiRoot = app WebView 形态：__fushiEventInsidePopup 恒真。
// hooks 给了就模拟扩展 realm 注入的两个钩子。
function loadPopup(hooks) {
  const timers = [];
  const selects = [];
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: (fn, ms) => { timers.push({ fn, ms, cleared: false }); return timers.length; },
    clearTimeout: (id) => { if (timers[id - 1]) timers[id - 1].cleared = true; },
    setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    navigator: { language: 'zh-CN', userAgent: 'test' },
    URL, Math, JSON, Date, Promise, isFinite, parseInt, parseFloat, RegExp, Object, Array, String, Number, Boolean, Error, TypeError, Map, Set, WeakMap, WeakSet, Symbol, encodeURIComponent, decodeURIComponent,
    document: {
      documentElement: makeEl(), body: makeEl(),
      getElementById: () => null, createElement: () => makeEl(),
      addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
      createRange: () => ({ setStart() {}, setEnd() {}, getBoundingClientRect: () => null }),
      createTreeWalker: () => ({ nextNode: () => null }),
      createDocumentFragment: () => makeEl(),
    },
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    ResizeObserver: class { observe() {} disconnect() {} unobserve() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  };
  sandbox.window = {
    addEventListener() {}, removeEventListener() {},
    innerWidth: 800, innerHeight: 800,
    matchMedia: () => ({ matches: false }),
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(POPUP, sandbox, { filename: 'vendor/popup.js' });
  sandbox.window.fushiSelection = { selectText(x, y) { selects.push([x, y]); } };
  if (hooks) {
    sandbox.window.__fushiScanModifierHeld = hooks.held;
    sandbox.window.__fushiScanDelayMs = hooks.delay;
  }
  const move = (x, y, extra) => sandbox.__fushiPopupMouseMove(Object.assign({ clientX: x, clientY: y }, extra || {}));
  const pending = () => timers.filter((t) => !t.cleared);
  return { sandbox, timers, selects, move, pending };
}

const noneMode = (delayMs) => ({ held: () => true, delay: () => delayMs });

test('不按键 + 延迟 300：弹窗内连续划过不扫，停稳到点只按最后坐标扫一次', () => {
  const p = loadPopup(noneMode(300));
  p.move(10, 10);
  p.move(40, 10);
  p.move(80, 10);
  assert.strictEqual(p.selects.length, 0, '设了延迟不得一划过就扫');
  const pending = p.pending();
  assert.strictEqual(pending.length, 1, '每次 mousemove 必须作废旧计时、只留一个');
  assert.strictEqual(pending[0].ms, 300);
  pending[0].fn();
  assert.deepStrictEqual(p.selects, [[80, 10]], '停稳到点按最后坐标扫一次');
  // 停在原地的抖动（< 8px）到点后不重复扫同一处。
  p.move(83, 12);
  p.pending()[0].fn();
  assert.strictEqual(p.selects.length, 1);
});

test('延迟 0（含按键模式钩子回 0）：立即扫，旧行为不变', () => {
  const p = loadPopup(noneMode(0));
  p.move(10, 10);
  p.move(40, 10);
  assert.deepStrictEqual(p.selects, [[10, 10], [40, 10]]);
  assert.strictEqual(p.pending().length, 0);
});

test('app 内无钩子：仍是 Shift 立即扫，不排计时', () => {
  const p = loadPopup(null);
  p.move(10, 10, { shiftKey: false });
  assert.strictEqual(p.selects.length, 0);
  p.move(10, 10, { shiftKey: true });
  assert.deepStrictEqual(p.selects, [[10, 10]]);
  assert.strictEqual(p.timers.length, 0);
});

test('松开触发键 / 指针离开弹窗：作废排着的扫描；弹窗内换元素不作废', () => {
  let held = true;
  const p = loadPopup({ held: () => held, delay: () => 300 });
  p.move(10, 10);
  held = false;
  p.move(30, 10);
  assert.strictEqual(p.pending().length, 0, '松开触发键必须撤掉待扫');

  held = true;
  const inner = {};
  const root = { contains: (n) => n === inner };
  p.move(50, 10);
  p.sandbox.__fushiPopupMouseOut(root, { relatedTarget: inner });
  assert.strictEqual(p.pending().length, 1, '弹窗内换元素不撤');
  p.sandbox.__fushiPopupMouseOut(root, { relatedTarget: {} });
  assert.strictEqual(p.pending().length, 0, '移到网页上必须撤');
  p.move(70, 10);
  p.sandbox.__fushiPopupMouseOut(root, { relatedTarget: null });
  assert.strictEqual(p.pending().length, 0, '移出窗口必须撤');
  assert.strictEqual(p.selects.length, 0);
});

test('HBK-AUDIT-231：排着的扫描绑定弹窗与设置代次——关窗 / 换词 / 换弹窗 / 热切换设置后到点不扫', () => {
  // ① Esc 关窗：宿主（content.js fushiHidePopup / side-panel.js hideLookupPane）推进
  // _renderGeneration、清 __fushiRoot，不派 mouseout。
  {
    const p = loadPopup(noneMode(300));
    p.move(10, 10);
    p.sandbox.window._renderGeneration += 1;
    p.pending()[0].fn();
    assert.strictEqual(p.selects.length, 0, '关窗后到点不得 selectText');
  }
  // ② 关窗后又开了新弹窗（新 ShadowRoot）。
  {
    const p = loadPopup(noneMode(300));
    p.sandbox.window.__fushiRoot = null;
    p.move(10, 10);
    p.sandbox.window.__fushiRoot = { host: {} };
    p.pending()[0].fn();
    assert.strictEqual(p.selects.length, 0, '新开的弹窗不得吃旧计时');
  }
  // ③ 热切换触发键（none → shift：有效延迟变 0）或改延迟值。
  {
    let delay = 300;
    const p = loadPopup({ held: () => true, delay: () => delay });
    p.move(10, 10);
    delay = 0;
    p.pending()[0].fn();
    assert.strictEqual(p.selects.length, 0, '切走 none 模式后旧计时不得扫');
    delay = 300;
    p.move(40, 10);
    delay = 500;
    p.pending()[0].fn();
    assert.strictEqual(p.selects.length, 0, '改了延迟值后按旧值排的计时不得扫');
  }
  // 对照：弹窗与设置都没变，到点照常扫。
  {
    const p = loadPopup(noneMode(300));
    p.move(10, 10);
    p.pending()[0].fn();
    assert.deepStrictEqual(p.selects, [[10, 10]]);
  }
});

test('嵌套弹窗（独立 realm）自己按 storage 装两个钩子，并随 onChanged 热更新', () => {
  const storageListeners = [];
  const host = { attachShadow: () => makeEl() };
  const window = { parent: {}, addEventListener() {} };
  const context = vm.createContext({
    window, console,
    document: { getElementById: () => host, createElement: makeEl, addEventListener() {} },
    chrome: {
      runtime: { lastError: undefined, sendMessage() {} },
      storage: {
        local: { get(_keys, cb) { cb({ scanModifier: 'none', scanDelay: 250 }); } },
        onChanged: { addListener(fn) { storageListeners.push(fn); } },
      },
    },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'nested-popup.js'), 'utf8'), context);
  assert.strictEqual(window.__fushiScanModifierHeld({}), true, 'none 模式不按键也算按着');
  assert.strictEqual(window.__fushiScanDelayMs(), 250);
  for (const fn of storageListeners) fn({ scanModifier: { newValue: 'alt' } }, 'local');
  assert.strictEqual(window.__fushiScanModifierHeld({ shiftKey: true }), false);
  assert.strictEqual(window.__fushiScanModifierHeld({ altKey: true }), true);
  assert.strictEqual(window.__fushiScanDelayMs(), 0, '按键模式不加延迟');
});

test('侧栏（与 popup.js 同 realm）注入两个钩子，判据与自身字幕悬停同一份', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  assert.match(src, /window\.__fushiScanModifierHeld = function \(e\) \{ return fushiScanModifierHeld\(e, scanModifier\); \};/);
  assert.match(src, /window\.__fushiScanDelayMs = function \(\) \{ return fushiEffectiveScanDelay\(scanModifier, scanDelayMs\); \};/);
});
