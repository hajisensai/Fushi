const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// content.js 的宿主适配口（Fushi app 内浏览器）。扩展里 `__fushiHostAdapter` 不存在：查词照旧
// 发 runtime 消息、画页内弹窗（行为逐字不变）；app 宿主把同名局部变量放进整栈闭包：查词交给宿主
// 弹窗，暂停 / 续播 / 手动播放关窗 / 命中高亮时序仍由 content.js 管。两种模式在同一个受控 vm 里
// 真加载 content.js 对照。

const CONTENT = path.join(__dirname, 'content.js');

function makeElement(tag) {
  return {
    tagName: String(tag || 'div').toUpperCase(),
    style: {},
    dataset: {},
    isConnected: true,
    parentNode: null,
    children: [],
    addEventListener() {},
    removeEventListener() {},
    appendChild(child) { if (child && typeof child === 'object') child.parentNode = this; this.children.push(child); return child; },
    insertBefore(child) { return this.appendChild(child); },
    setAttribute() {},
    getAttribute() { return null; },
    removeAttribute() {},
    remove() { this.isConnected = false; },
    contains(node) { return node === this; },
    closest() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getBoundingClientRect() { return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
    focus() {},
    classList: { add() {}, remove() {}, contains() { return false; } },
    attachShadow() { const s = makeElement('#shadow'); s.host = this; this.shadowRoot = s; return s; },
  };
}

function load(adapter) {
  const docListeners = Object.create(null);
  const sent = [];
  const video = {
    paused: false, isConnected: true, pauseCount: 0, playCount: 0, handlers: {},
    addEventListener(type, fn, opts) { (this.handlers[type] = this.handlers[type] || []).push({ fn, once: !!(opts && opts.once) }); },
    removeEventListener() {},
    emit(type) { const hs = this.handlers[type] || []; this.handlers[type] = hs.filter((h) => !h.once); for (const h of hs) h.fn(); },
    pause() { this.paused = true; this.pauseCount++; },
    play() { this.paused = false; this.playCount++; this.emit('play'); return { catch() {} }; },
  };
  const overlay = makeElement('div');
  overlay.id = 'fushi-subtitle-overlay';
  const overlayText = makeElement('span');
  overlayText.closest = (sel) => (String(sel).indexOf('#fushi-subtitle-overlay') >= 0 ? overlay : null);
  const body = makeElement('body');
  const hitNode = { textContent: '世界の天気', nodeType: 3, parentElement: overlayText, parentNode: overlayText };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 1,
    clearTimeout() {},
    requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    NodeFilter: { SHOW_TEXT: 4 },
    performance: { now() { return 1000; }, timeOrigin: 1700000000000 },
    location: { hostname: 'www.youtube.com', href: 'https://www.youtube.com/watch?v=x', pathname: '/watch' },
  };
  sandbox.document = {
    documentElement: makeElement('html'),
    body,
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    removeEventListener() {},
    getElementById: () => null,
    querySelector: (s) => (s === 'video' ? video : null),
    querySelectorAll: (s) => (s === 'video' ? [video] : []),
    createElement: (tag) => makeElement(tag),
    createRange: () => ({ setStart() {}, setEnd() {}, getClientRects: () => [] }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      getURL: (p) => 'chrome-extension://test/' + p,
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb && msg && msg.type === 'lookup') {
          cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
        }
      },
    },
    storage: {
      local: { get: (_k, cb) => { if (cb) cb({}); return Promise.resolve({}); }, set: async () => {} },
      onChanged: { addListener() {} },
    },
  };
  sandbox.window = {
    addEventListener() {},
    removeEventListener() {},
    innerWidth: 1200,
    innerHeight: 800,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    fushiSelection: {
      selection: null,
      getCharacterAtPoint: () => ({ node: hitNode, offset: 0 }),
      selectFromPosition(node, offset) { this.selection = { startNode: node, startOffset: offset, ranges: [], text: '世界' }; return '世界'; },
      getSelectionRect: () => ({ x: 300, y: 400, width: 20, height: 16 }),
      highlightSelection: () => ({ x: 300, y: 400, width: 20, height: 16 }),
      clearSelection() {},
    },
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  if (adapter) sandbox.__fushiHostAdapter = adapter;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  const fire = (type, ev) => { for (const fn of docListeners[type] || []) fn(ev); };
  return { sandbox, sent, video, fire, overlayText, body };
}

function fakeAdapter() {
  const a = {
    lookups: [],
    dismissed: 0,
    onClosed: null,
    lookup(req, onMatched) { a.lookups.push(req); a.onMatched = onMatched; return 'id'; },
    dismiss() { a.dismissed++; },
  };
  return a;
}

const CUE = { startMs: 1000, endMs: 3000, text: '世界の天気は晴れ。' };

test('扩展模式（无适配口）：查词照旧走 runtime 消息，行为不变', () => {
  const h = load(null);
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  const lookups = h.sent.filter((m) => m && m.type === 'lookup');
  assert.strictEqual(lookups.length, 1, '应发一条 lookup 消息');
  assert.strictEqual(lookups[0].term, '世界');
  assert.strictEqual(h.video.pauseCount, 1, '查词时暂停照旧');
});

test('宿主模式：查词交给适配口，不发 lookup 消息，带上例句与锚点', () => {
  const a = fakeAdapter();
  const h = load(a);
  assert.strictEqual(typeof a.onClosed, 'function', 'content.js 应登记宿主关窗回调');
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  assert.strictEqual(h.sent.filter((m) => m && m.type === 'lookup').length, 0, '宿主模式不得发 lookup 消息');
  assert.strictEqual(a.lookups.length, 1);
  assert.strictEqual(a.lookups[0].term, '世界');
  assert.strictEqual(a.lookups[0].sentence, CUE.text, '例句取查词所在字幕行');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(a.lookups[0].rect)), { x: 300, y: 400, width: 20, height: 16 });
  assert.strictEqual(a.lookups[0].fromHover, false);
  assert.strictEqual(h.video.pauseCount, 1, '查词时暂停仍由 content.js 执行');
  // 命中回报不抛错（覆盖层高亮走 fushiSelectionRects，空 ranges 时静默）。
  a.onMatched(2);
});

test('宿主模式：宿主关窗 → 续播被查词暂停的视频；同词弹窗在场时重复点击是 no-op', () => {
  const a = fakeAdapter();
  const h = load(a);
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  assert.strictEqual(a.lookups.length, 1, '同词且宿主弹窗在场：不重发');
  assert.strictEqual(h.video.paused, true);
  a.onClosed();
  assert.strictEqual(h.video.paused, false, '宿主关窗即续播');
  assert.strictEqual(h.video.playCount, 1);
  assert.strictEqual(a.dismissed, 0, '宿主发起的关窗不再回头叫宿主关');
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  assert.strictEqual(a.lookups.length, 2, '关窗后同词可再查');
});

test('宿主模式：用户手动按播放 → 叫宿主关弹窗，且不再被续播逻辑重复 play', () => {
  const a = fakeAdapter();
  const h = load(a);
  h.sandbox.window.fushiLookupAtPoint(300, 400, CUE);
  h.video.play(); // 用户自己点播放
  assert.strictEqual(a.dismissed, 1, '手动播放应关掉宿主弹窗');
  a.onClosed(); // 宿主随后回报关窗：恢复侧已解除，不得再 play 一次
  assert.strictEqual(h.video.playCount, 1);
});

test('宿主模式：正文 Shift 悬停交给宿主取词脚本，只认扩展字幕覆盖层', () => {
  const a = fakeAdapter();
  const h = load(a);
  h.fire('mousemove', { shiftKey: true, clientX: 300, clientY: 400, buttons: 0, target: h.body });
  assert.strictEqual(a.lookups.length, 0, '正文上的 Shift 悬停不归扩展管');
  h.fire('mousemove', { shiftKey: true, clientX: 310, clientY: 400, buttons: 0, target: h.overlayText });
  assert.strictEqual(a.lookups.length, 1, '覆盖层上的 Shift 悬停照常查词');
  assert.strictEqual(a.lookups[0].fromHover, true);
});

test('扩展模式：正文 Shift 悬停照旧查词', () => {
  const h = load(null);
  h.fire('mousemove', { shiftKey: true, clientX: 300, clientY: 400, buttons: 0, target: h.body });
  assert.strictEqual(h.sent.filter((m) => m && m.type === 'lookup').length, 1);
});
