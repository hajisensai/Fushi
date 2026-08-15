const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1279 行为守卫：扩展 Shift 悬停查词时，浏览器会在 Shift 按住+指针移动时把「原生文本选区」
// 从既有 caret 扩到指针 → 与我们自绘的覆盖层高亮（#fushi-highlight-overlay）叠出一条多余的蓝色
// 原生选区（用户报「一个我们的选区、一个浏览器自带的蓝色选区」）。修复：纯悬停（e.buttons===0）
// 扫描时调 window.getSelection().removeAllRanges() 清掉原生选区，只留覆盖层；用户手动按住键拖拽
// 划选复制（e.buttons!==0）不清，保住复制能力。这里在受控 vm 里真加载 content.js、捕获它注册的
// document mousemove 监听器、用带 shiftKey 的事件触发，断言原生选区被/未被清除，且覆盖层路径仍在。

const CONTENT = path.join(__dirname, 'content.js');

// 返回带可追踪 getSelection 的 sandbox 加载结果。collapsed 控制原生选区是否可见；
// anchorNode 可注入选区锚点（模拟选区落在 contenteditable 等可编辑区）。
function loadContent({ collapsed = false, anchorNode = null } = {}) {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const winListeners = Object.create(null);
  const sent = [];
  const dataset = {};
  let removeAllRangesCalls = 0;

  const nativeSelection = {
    rangeCount: 1,
    isCollapsed: collapsed,
    anchorNode,
    removeAllRanges() {
      removeAllRangesCalls += 1;
      this.rangeCount = 0;
      this.isCollapsed = true;
    },
  };

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: () => 0,
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    // content.js 的查词耗时埋点用 performance.now() / performance.timeOrigin；真实内容脚本
    // 里这个全局一定存在，手写的 sandbox 得补上。给固定值即可——这些用例断言的是行为，
    // 不是真实耗时，不该依赖真实时钟。
    performance: { now() { return 1000; }, timeOrigin: 1700000000000 },
    location: { hostname: 'example.com', href: 'https://example.com/page', pathname: '/page' },
  };
  sandbox.document = {
    documentElement: { dataset, setAttribute() {} },
    body: { appendChild() {}, contains: () => false },
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    createRange: () => ({
      setStart() {}, setEnd() {},
      getClientRects: () => [{ left: 100, top: 120, right: 140, bottom: 138, width: 40, height: 18 }],
    }),
    createElement: () => ({
      style: { cssText: '', setProperty() {} },
      addEventListener() {}, appendChild() {}, setAttribute() {}, remove() {},
      classList: { add() {} },
    }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id', lastError: null, onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb) cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
      },
    },
    storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {} } },
  };
  sandbox.window = {
    addEventListener: (t, fn) => { (winListeners[t] = winListeners[t] || []).push(fn); },
    innerWidth: 1200, innerHeight: 800,
    getSelection: () => nativeSelection,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    // 覆盖层从 fushiSelection.selection.ranges 只读取几何；给一个含 ranges 的最小取词状态。
    fushiSelection: {
      selection: { ranges: [{ node: { textContent: '世界です' }, start: 0, end: 2 }], text: '世界' },
      getCharacterAtPoint: () => ({ node: { textContent: '世界です', nodeType: 3 }, offset: 0 }),
      selectFromPosition() { return '世界'; },
      getSelectionRect: () => ({ x: 100, y: 120, width: 40, height: 18 }),
      highlightSelection: () => ({ x: 100, y: 120, width: 40, height: 18 }),
      clearSelection() {},
    },
  };
  sandbox.window.window = sandbox.window;

  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  return { docListeners, sent, dataset, getRemoveCalls: () => removeAllRangesCalls, nativeSelection };
}

test('纯悬停（buttons=0）Shift 查词：清掉浏览器原生蓝色选区，且仍发出 lookup（覆盖层路径未断）', () => {
  const { docListeners, sent, getRemoveCalls } = loadContent({ collapsed: false });
  assert.ok(docListeners.mousemove && docListeners.mousemove.length >= 1, '未注册 mousemove 监听器');
  const ev = { shiftKey: true, buttons: 0, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.ok(getRemoveCalls() >= 1, '纯悬停查词未清掉浏览器原生选区（会与覆盖层叠出多余蓝色选区）');
  const lookups = sent.filter((m) => m && m.type === 'lookup');
  assert.strictEqual(lookups.length, 1, '清原生选区不应影响查词主路径：仍应发出恰好一次 lookup');
  assert.strictEqual(lookups[0].term, '世界', 'lookup 携带的词不对');
});

test('手动拖拽划选（buttons!=0）Shift 移动：不清原生选区，保住复制能力', () => {
  const { docListeners, getRemoveCalls } = loadContent({ collapsed: false });
  const ev = { shiftKey: true, buttons: 1, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.strictEqual(getRemoveCalls(), 0, '拖拽划选时清了原生选区 → 破坏用户手动选文本复制');
});

test('塌缩选区（仅 caret，无可见蓝色）：不做无谓 removeAllRanges', () => {
  const { docListeners, getRemoveCalls } = loadContent({ collapsed: true });
  const ev = { shiftKey: true, buttons: 0, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.strictEqual(getRemoveCalls(), 0, '塌缩选区无可见蓝色，不应调用 removeAllRanges');
});

test('选区落在 contenteditable 里：绝不清（用户报「开着插件有时无法粘贴」的主根因）', () => {
  // Ctrl+Shift+V（粘贴为纯文本）按下期间 Shift 在按住态，任何一次 mousemove 都会走清理路径；
  // 富文本编辑器（Lexical/ProseMirror 等）的选区被 removeAllRanges 抹掉后粘贴静默丢弃。
  const editor = {
    nodeType: 1,
    tagName: 'DIV',
    getAttribute: (name) => (name === 'contenteditable' ? 'true' : null),
    parentElement: null,
  };
  const textNode = { nodeType: 3, parentElement: editor };
  const { docListeners, getRemoveCalls } = loadContent({ collapsed: false, anchorNode: textNode });
  const ev = { shiftKey: true, buttons: 0, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.strictEqual(getRemoveCalls(), 0, '可编辑区内的选区是用户为输入/粘贴准备的，绝不能清');
});

test('普通页面选区（非可编辑区锚点）仍照常清理，TODO-1279 行为不回退', () => {
  const plain = { nodeType: 1, tagName: 'P', getAttribute: () => null, parentElement: null };
  const textNode = { nodeType: 3, parentElement: plain };
  const { docListeners, getRemoveCalls } = loadContent({ collapsed: false, anchorNode: textNode });
  const ev = { shiftKey: true, buttons: 0, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.ok(getRemoveCalls() >= 1, '非可编辑区选区仍应清掉（多余蓝色选区问题不回退）');
});
