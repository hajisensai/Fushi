const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-1078 回归守卫：扩展 content script 曾在**所有网页**常驻一个非 passive 的
// document wheel 监听（popup.js 顶层 addEventListener('wheel', …, {passive:false})）。
// 非 passive wheel 监听一旦存在，浏览器就放弃合成器快速滚动路径，宿主页每次滚轮都要
// 同步等主线程跑完监听（含祖先 getComputedStyle/scrollHeight 布局读取）——用户感知为
// 装了扩展后网页滚动变卡。根因修复：
//   - popup.js 在扩展上下文（chrome.runtime.id 存在）不再挂 document，改为把监听暴露成
//     window.__hibikiPopupWheelListener；
//   - content.js 在弹窗 shadow host 创建时（fushiEnsureContainer）把它挂到 host 上
//     （非 passive 只影响弹窗内滚轮），fushiRemoveContainer 销毁时卸载；
//   - 弹窗不在场 ⇒ 宿主页上没有任何 wheel 监听，原生滚动零开销。
// 本测试在受控 vm 里按 manifest 顺序真加载 vendor/popup.js + content.js，驱动真实的
// fushiEnsureContainer / fushiRemoveContainer，断言上述生命周期与弹窗内滚动行为。

const POPUP = path.join(__dirname, 'vendor', 'popup.js');
const CONTENT = path.join(__dirname, 'content.js');

function fakeEl(tag) {
  const listeners = Object.create(null);
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    nodeType: 1,
    style: {},
    dataset: {},
    children: [],
    parentNode: null,
    parentElement: null,
    classList: { add() {}, remove() {}, contains() { return false; } },
    listeners,
    scrollByCalls: [],
    addEventListener(type, fn, options) {
      (listeners[type] = listeners[type] || []).push({ fn, options });
    },
    removeEventListener(type, fn) {
      const l = listeners[type];
      if (!l) return;
      const i = l.findIndex((r) => r.fn === fn);
      if (i >= 0) l.splice(i, 1);
    },
    appendChild(c) { c.parentNode = el; el.children.push(c); return c; },
    setAttribute() {},
    getAttribute() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    remove() { el.parentNode = null; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 100 }; },
    scrollBy(arg) { el.scrollByCalls.push(arg); },
    attachShadow() {
      const shadow = fakeEl('#shadow-root');
      shadow.host = el;
      el.shadowRoot = shadow;
      shadow.getSelection =
          () => ({ toString() { return ''; }, removeAllRanges() {} });
      return shadow;
    },
  };
  return el;
}

// 加载真 popup.js + 真 content.js（manifest 里 popup.js 先于 content.js），返回可
// 驱动的世界：document wheel 注册记录、window 桩、content.js 的容器函数等。
function loadWorld() {
  const docWheelRegs = [];
  const body = fakeEl('body');
  const documentObj = {
    documentElement: { style: {}, dataset: {}, setAttribute() {} },
    body,
    fullscreenElement: null,
    addEventListener(type, handler, options) {
      if (type === 'wheel') docWheelRegs.push({ handler, options });
    },
    createElement(tag) { return fakeEl(tag); },
    createTextNode(t) { return { nodeType: 3, textContent: String(t) }; },
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
  };
  const windowScrollBy = [];
  const windowObj = {
    innerWidth: 1200,
    innerHeight: 800,
    addEventListener() {},
    scrollBy(arg) { windowScrollBy.push(arg); },
    getSelection() { return { toString() { return ''; }, removeAllRanges() {} }; },
    getComputedStyle() { return { overflowY: 'visible', fontSize: '15px' }; },
  };
  windowObj.window = windowObj;

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: {
      hostname: 'example.com',
      href: 'https://example.com/page',
      pathname: '/page',
    },
    performance: { now() { return 1000; } },
    setTimeout() { return 0; },
    clearTimeout() {},
    requestAnimationFrame() { return 0; },
    DOMParser: class {
      parseFromString() { return { body: {}, querySelectorAll() { return []; } }; }
    },
    Image: class { addEventListener() {} set src(_v) {} },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return { overflowY: 'visible', fontSize: '15px' }; },
    chrome: {
      runtime: {
        id: 'test-ext-id',
        lastError: null,
        getURL: (p) => 'chrome-extension://test-ext-id/' + p,
        onMessage: { addListener() {} },
        sendMessage(_msg, cb) { if (cb) cb({}); },
      },
      storage: {
        local: { get: async () => ({}), set: async () => {} },
        onChanged: { addListener() {} },
      },
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(POPUP, 'utf8'), sandbox,
      { filename: 'popup.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox,
      { filename: 'content.js' });
  return { sandbox, documentObj, windowObj, docWheelRegs, windowScrollBy };
}

function wheelListenersOf(el) {
  return (el.listeners && el.listeners.wheel) || [];
}

test('扩展上下文加载后 document 上没有任何 wheel 监听，监听以全局暴露待懒装', () => {
  const { docWheelRegs, windowObj } = loadWorld();
  assert.strictEqual(docWheelRegs.length, 0,
      '扩展 content script 不得在 document 上常驻 wheel 监听（BUG-1078 根因）');
  assert.strictEqual(typeof windowObj.__hibikiPopupWheelListener, 'function',
      'popup.js 必须暴露 window.__hibikiPopupWheelListener 供 content.js 懒装');
});

test('fushiEnsureContainer 把非 passive wheel 监听挂到 shadow host，且复用不重复挂', () => {
  const { sandbox, windowObj } = loadWorld();
  sandbox.fushiEnsureContainer();
  const host = windowObj.__hibikiRoot && windowObj.__hibikiRoot.host;
  assert.ok(host, 'fushiEnsureContainer 必须建出 shadow host');
  const regs = wheelListenersOf(host);
  assert.strictEqual(regs.length, 1, 'host 上必须恰好挂一个 wheel 监听');
  assert.strictEqual(regs[0].fn, windowObj.__hibikiPopupWheelListener,
      '挂的必须是 popup.js 暴露的同一个监听');
  assert.ok(regs[0].options && regs[0].options.passive === false,
      '弹窗滚轮监听必须 {passive:false}（它要 preventDefault 接管弹窗滚动）');
  // 弹窗打开期间再次 ensure（host 复用路径）不得重复挂监听。
  sandbox.fushiEnsureContainer();
  assert.strictEqual(wheelListenersOf(host).length, 1,
      'host 复用路径不得重复挂 wheel 监听');
});

test('弹窗内滚轮行为不变：preventDefault + 滚 shadow host，不碰 window', () => {
  const { sandbox, windowObj, windowScrollBy } = loadWorld();
  sandbox.fushiEnsureContainer();
  const host = windowObj.__hibikiRoot.host;
  const inner = { nodeType: 1, parentElement: null };
  let prevented = false;
  const evt = {
    ctrlKey: false,
    deltaY: 100,
    deltaX: 0,
    deltaMode: 0,
    target: inner,
    composedPath() { return [inner, host]; },
    preventDefault() { prevented = true; },
  };
  for (const r of wheelListenersOf(host)) r.fn(evt);
  assert.strictEqual(prevented, true, '弹窗内滚轮必须 preventDefault（接管滚动）');
  assert.strictEqual(host.scrollByCalls.length, 1, '弹窗内滚轮必须滚 shadow host');
  const step = host.scrollByCalls[0].top;
  assert.ok(step > 0 && step <= 120,
      '滚动步长必须是缩放/钳制后的值，got ' + step);
  assert.strictEqual(windowScrollBy.length, 0, '弹窗内滚轮不得滚宿主页 window');
});

test('fushiRemoveContainer 随弹窗卸载 wheel 监听', () => {
  const { sandbox, windowObj } = loadWorld();
  sandbox.fushiEnsureContainer();
  const host = windowObj.__hibikiRoot.host;
  assert.strictEqual(wheelListenersOf(host).length, 1);
  sandbox.fushiRemoveContainer();
  assert.strictEqual(wheelListenersOf(host).length, 0,
      '关弹窗必须卸载 host 上的 wheel 监听（弹窗不在场 ⇒ 页面零 wheel 监听）');
  assert.strictEqual(windowObj.__hibikiRoot, null,
      '关弹窗必须清 __hibikiRoot');
});
