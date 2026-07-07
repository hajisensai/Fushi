const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1272 行为守卫：浏览器扩展「Shift 悬停查词」时被查词的高亮**非常容易消失**。
// 根因：旧实现走 selection.js 的 DOM 包裹路径（把宿主页文本节点裹进 <span class="hoshi-dict-highlight">），
// 动态站点（React/Vue/视频字幕逐帧重渲染）的框架 diff / MutationObserver 会在下一帧把这个凭空多出的
// span revert 掉，高亮闪一下就没。修复：content.js 改画「扩展自有的顶层 fixed 覆盖层」（不改宿主页 DOM），
// 保持到弹窗关闭。本测试在受控 vm 里真加载 content.js，断言：
//   1) Shift 悬停查词后，宿主页 body 上出现扩展的覆盖层高亮（#hibiki-highlight-overlay），且**不**把
//      宿主页文本节点裹进 hoshi-dict-highlight 包裹 span（宿主页 DOM 未被改动）。
//   2) 宿主页事件（无 Shift 的 mousemove）不会撤掉高亮——高亮保持到弹窗关闭。
//   3) 关闭弹窗（点弹窗外 mousedown）时覆盖层高亮被撤掉（跟随弹窗生命周期）。

const CONTENT = path.join(__dirname, 'content.js');

// 极简 DOM 元素桩：记录 id / 子节点 / 挂载关系，支持 remove/contains/appendChild。
function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    setAttribute(k, v) { if (k === 'id') el._id = v; if (k === 'class') el.className = v; },
    getAttribute() { return null; },
    classList: { add(c) { el.className += ' ' + c; } },
    addEventListener() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    insertBefore(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) {
      if (x === el) return true;
      return el.children.some((c) => c.contains && c.contains(x));
    },
    normalize() {},
    getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findById(el, id) {
  if (el._id === id) return el;
  for (const c of el.children) {
    const hit = c.findById ? c.findById(id) : findById(c, id);
    if (hit) return hit;
  }
  return null;
}
function findByClass(el, cls) {
  if ((el.className || '').split(/\s+/).includes(cls)) return el;
  for (const c of el.children) {
    const hit = findByClass(c, cls);
    if (hit) return hit;
  }
  return null;
}

function loadAndLookup() {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const sent = [];
  const body = makeEl('body');
  const html = makeEl('html');
  html.dataset = {};

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: () => 0, // 不执行 place()，避免牵扯弹窗定位
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'example.com', href: 'https://example.com/page', pathname: '/page' },
  };
  sandbox.document = {
    documentElement: html,
    body,
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createRange: () => ({
      setStart() {}, setEnd() {},
      getClientRects: () => [{ left: 100, top: 120, right: 140, bottom: 138, width: 40, height: 18 }],
      getBoundingClientRect: () => ({ x: 100, y: 120, left: 100, top: 120, right: 140, bottom: 138, width: 40, height: 18 }),
      extractContents: () => makeEl('span'),
      insertNode() {},
    }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb) cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
      },
    },
    storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {} } },
  };
  const hostTextNode = { textContent: '世界です', nodeType: 3 };
  sandbox.window = {
    addEventListener() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    // 与 app 同款 selection.js 的最小行为桩：命中一个字、扩成词、并暴露 selection.ranges 供覆盖层取 rects。
    hoshiSelection: {
      selection: { ranges: [{ node: hostTextNode, start: 0, end: 2 }], text: '世界' },
      getCharacterAtPoint: () => ({ node: hostTextNode, offset: 0 }),
      selectFromPosition: () => '世界',
      getSelectionRect: () => ({ x: 100, y: 120, width: 40, height: 18 }),
      // 若被调用即视为走了 DOM 包裹兜底路径——本用例期望**不**触发它。
      highlightSelection() { sandbox.__wrapperUsed = true; return { x: 0, y: 0, width: 0, height: 0 }; },
      clearSelection() {},
    },
    flutter_inappwebview: { callHandler() {} },
  };
  sandbox.window.window = sandbox.window;
  sandbox.__wrapperUsed = false;

  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'content.js' });

  // 触发 Shift 悬停查词（→ 同步走完 lookup 回调 → hibikiRender → 画覆盖层高亮）。
  const ev = { shiftKey: true, clientX: 300, clientY: 400 };
  for (const fn of (docListeners.mousemove || [])) fn(ev);

  return { sandbox, docListeners, sent, body };
}

test('Shift 悬停查词后画出扩展覆盖层高亮，且不改宿主页 DOM（无包裹 span）', () => {
  const { sandbox, body } = loadAndLookup();
  const overlay = findById(body, 'hibiki-highlight-overlay');
  assert.ok(overlay, '未画出扩展覆盖层高亮 #hibiki-highlight-overlay');
  assert.ok(overlay.children.length >= 1, '覆盖层里没有高亮色块');
  assert.match(overlay.style.cssText, /pointer-events:none/, '覆盖层未穿透点击');
  assert.strictEqual(sandbox.__wrapperUsed, false,
    '仍走了 selection.js 的 DOM 包裹高亮路径（会被宿主页重绘冲掉）');
  assert.strictEqual(findByClass(body, 'hoshi-dict-highlight'), null,
    '宿主页文本被裹进 hoshi-dict-highlight span（动态站点会 revert 掉 → 高亮易消失）');
});

test('宿主页事件（无 Shift 的 mousemove）不撤高亮——高亮保持到弹窗关闭', () => {
  const { docListeners, body } = loadAndLookup();
  assert.ok(findById(body, 'hibiki-highlight-overlay'), '前置：高亮应已画出');
  // 模拟用户移向弹窗：一串不带 Shift 的 mousemove。
  for (const fn of (docListeners.mousemove || [])) {
    fn({ shiftKey: false, clientX: 500, clientY: 500 });
    fn({ shiftKey: false, clientX: 520, clientY: 520 });
  }
  assert.ok(findById(body, 'hibiki-highlight-overlay'),
    '无 Shift 的 mousemove 把高亮撤掉了（应保持到关弹窗）');
});

test('关闭弹窗（点弹窗外）时覆盖层高亮被撤掉（跟随弹窗生命周期）', () => {
  const { docListeners, body } = loadAndLookup();
  assert.ok(findById(body, 'hibiki-highlight-overlay'), '前置：高亮应已画出');
  const outside = makeEl('div'); // 弹窗容器之外的宿主页元素
  for (const fn of (docListeners.mousedown || [])) fn({ target: outside });
  assert.strictEqual(findById(body, 'hibiki-highlight-overlay'), null,
    '关弹窗后覆盖层高亮未被撤掉（会残留在页面上）');
});
