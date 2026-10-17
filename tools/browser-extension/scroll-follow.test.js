const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-3336 行为守卫：查词后滚动页面（或页面里的内部可滚动容器），被查词高亮与查词弹窗都是
// position:fixed 的视口坐标，旧实现没有任何滚动处理 → 两者停在原位、与词错开。修复后：
//   1) document 上以 capture + passive 监听 scroll（内部容器的 scroll 不冒泡，只有 capture 收得到）；
//   2) 词仍在视口内：高亮重画到词的新位置，弹窗按词的位移整体平移；
//   3) 词整个滚出视口：关窗，高亮随之撤掉；
//   4) 没开弹窗时滚动不做任何事（不排 rAF）。
// 本测试在受控 vm 里真加载 content.js（同 highlight-overlay.test.js 的沙箱），用可变的
// Range.getClientRects 模拟「滚动后词的视口位置变了」。

const CONTENT = path.join(__dirname, 'content.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    style: { cssText: '', setProperty() {}, removeProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    setAttribute(k, v) { if (k === 'id') el._id = v; if (k === 'class') el.className = v; },
    getAttribute() { return null; },
    classList: { add(c) { el.className += ' ' + c; }, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {},
    removeEventListener() {},
    attachShadow() {
      const shadow = makeEl('shadow-root');
      shadow.getElementById = (id) => findById(shadow, id);
      return shadow;
    },
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
    const hit = findById(c, id);
    if (hit) return hit;
  }
  return null;
}

// 被查词「世界」当前的视口矩形；滚动 = 改它。
function wordRect(top) {
  return { left: 100, top, right: 140, bottom: top + 18, width: 40, height: 18 };
}

function setup() {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const rafQueue = [];
  const body = makeEl('body');
  const html = makeEl('html');
  const state = { rect: wordRect(120) };

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: (fn) => { rafQueue.push(fn); return rafQueue.length; },
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now() { return 1000; }, timeOrigin: 1700000000000 },
    location: { hostname: 'example.com', href: 'https://example.com/page', pathname: '/page' },
  };
  sandbox.document = {
    documentElement: html,
    body,
    fullscreenElement: null,
    addEventListener: (t, fn, opts) => { (docListeners[t] = docListeners[t] || []).push({ fn, opts }); },
    removeEventListener() {},
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createRange: () => ({
      setStart() {}, setEnd() {},
      getClientRects: () => [state.rect],
      getBoundingClientRect: () => ({ x: state.rect.left, y: state.rect.top, ...state.rect }),
      extractContents: () => makeEl('span'),
      insertNode() {},
    }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      getURL: (rel) => `chrome-extension://test-ext-id/${rel}`,
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
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
    fushiSelection: {
      selection: { ranges: [{ node: hostTextNode, start: 0, end: 2 }], text: '世界' },
      getCharacterAtPoint: () => ({ node: hostTextNode, offset: 0 }),
      selectFromPosition: () => '世界',
      getSelectionRect: () => ({ x: 100, y: 120, width: 40, height: 18 }),
      highlightSelection() { return { x: 0, y: 0, width: 0, height: 0 }; },
      clearSelection() {},
    },
    flutter_inappwebview: { callHandler() {} },
  };
  sandbox.window.window = sandbox.window;

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(src, sandbox, { filename: 'content.js' });

  const scrollListeners = docListeners.scroll || [];
  const scroll = (target) => {
    for (const { fn } of scrollListeners) fn({ type: 'scroll', target: target || sandbox.document });
    // 每帧最多复算一次：把这一帧排下的回调跑掉。
    const pending = rafQueue.splice(0);
    for (const fn of pending) fn(0);
  };
  const lookup = () => {
    for (const { fn } of (docListeners.mousemove || [])) fn({ shiftKey: true, clientX: 300, clientY: 400 });
    // 丢掉 place()（落点牵扯真实布局，这里只测滚动跟随）：host 停在 render 写下的 (0,0)。
    rafQueue.splice(0);
  };
  const host = () => findById(body, 'fushi-popup-host');
  const overlay = () => findById(body, 'fushi-highlight-overlay');
  return { sandbox, state, scroll, lookup, host, overlay, scrollListeners, rafQueue };
}

test('scroll 监听挂在 document 的 capture 阶段且是 passive（内部容器滚动也收得到、不拖慢滚动）', () => {
  const { scrollListeners } = setup();
  assert.ok(scrollListeners.length >= 1, 'content.js 没有监听 scroll');
  const hit = scrollListeners.find(({ opts }) => opts && opts.capture === true);
  assert.ok(hit, 'scroll 监听不是 capture：内部可滚动容器的 scroll 不冒泡，document 收不到');
  assert.strictEqual(hit.opts.passive, true, 'scroll 监听必须 passive');
});

test('词仍在视口内：高亮重画到词的新位置，弹窗按词的位移平移', () => {
  const { state, scroll, lookup, host, overlay } = setup();
  lookup();
  assert.ok(host(), '前置：弹窗已开');
  assert.ok(overlay(), '前置：高亮已画');
  assert.strictEqual(host().style.top, '0px');

  state.rect = wordRect(20); // 页面往下滚了 100px，词上移
  scroll(makeEl('div')); // 内部可滚动容器滚动（capture 收到）

  const box = overlay().children[0];
  assert.match(box.style.cssText, /top:20px/, '高亮没有跟到词的新位置');
  assert.strictEqual(host().style.top, '-100px', '弹窗没有按词的位移平移');
  assert.strictEqual(host().style.left, '0px', '只有纵向位移，横向不该变');
});

test('词整个滚出视口：关窗并撤掉高亮', () => {
  const { state, scroll, lookup, host, overlay } = setup();
  lookup();
  assert.ok(host() && overlay(), '前置：弹窗与高亮都在');

  state.rect = wordRect(-60); // 词滚到视口顶之外
  scroll();

  assert.strictEqual(host(), null, '词已不可见，弹窗仍残留在页面上');
  assert.strictEqual(overlay(), null, '词已不可见，高亮仍残留在页面上');
});

test('没开弹窗时滚动什么都不做（不排 rAF）', () => {
  const { scrollListeners, rafQueue, sandbox } = setup();
  for (const { fn } of scrollListeners) fn({ type: 'scroll', target: sandbox.document });
  assert.strictEqual(rafQueue.length, 0, '无弹窗时滚动仍在每帧排复算');
});
