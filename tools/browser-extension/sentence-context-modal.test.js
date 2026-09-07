const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 加载真实 content.js；小型 DOM 仅模拟本回归依赖的 capture → target → bubble、
// Shadow DOM retarget 和 once 监听。按钮必须经真实事件链触发，不能直接调用 onclick，
// 否则 document capture 误关底层并吞掉 click 的原始问题会被绕过。
class Element {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.listeners = [];
    this.style = { setProperty() {} };
    this.dataset = {};
    this.classList = { add() {} };
    this.parentNode = null;
  }
  addEventListener(type, fn, options = false) {
    this.listeners.push({ type, fn, capture: options === true || !!options.capture, once: !!options.once });
  }
  removeEventListener(type, fn, options = false) {
    const capture = options === true || !!options.capture;
    this.listeners = this.listeners.filter((l) => l.type !== type || l.fn !== fn || l.capture !== capture);
  }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  remove() {
    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  closest() { return null; }
  setAttribute() {}
  getAttribute() { return null; }
  focus() {}
  attachShadow() { this.shadowRoot = new Element('shadow-root'); this.shadowRoot.host = this; return this.shadowRoot; }
  set textContent(value) {
    this.text = value;
    for (const child of this.children) child.parentNode = null;
    this.children = [];
  }
  get textContent() { return (this.text || '') + this.children.map((child) => child.textContent).join(''); }
}

function dispatch(target, type, extra = {}) {
  const route = [];
  let retargeted = target;
  for (let node = target; node; node = node.parentNode || node.host) {
    route.push({ node, target: retargeted });
    if (node.host) retargeted = node.host;
  }
  const event = {
    type, target, defaultPrevented: false, stopped: false, immediate: false,
    composedPath: () => route.map((step) => step.node),
    stopPropagation() { this.stopped = true; },
    stopImmediatePropagation() { this.stopped = true; this.immediate = true; },
    preventDefault() { this.defaultPrevented = true; },
    ...extra,
  };
  const invoke = (step, capture) => {
    event.target = step.target;
    event.currentTarget = step.node;
    for (const listener of [...step.node.listeners]) {
      if (listener.type !== type || listener.capture !== capture) continue;
      if (listener.once) step.node.removeEventListener(type, listener.fn, capture);
      listener.fn(event);
      if (event.immediate) break;
    }
    if (!capture && !event.immediate && typeof step.node['on' + type] === 'function') {
      step.node['on' + type](event);
    }
  };
  for (const step of [...route].reverse()) {
    invoke(step, true);
    if (event.stopped) return event;
  }
  for (const step of route) {
    invoke(step, false);
    if (event.stopped) break;
  }
  return event;
}

function descendants(node) {
  return node.children.flatMap((child) => [child, ...descendants(child)]);
}

function loadContent() {
  const document = new Element('document');
  document.documentElement = document.appendChild(new Element('html'));
  document.head = document.documentElement.appendChild(new Element('head'));
  document.body = document.documentElement.appendChild(new Element('body'));
  document.createElement = (tag) => new Element(tag);
  document.createTextNode = (text) => { const node = new Element('text'); node.textContent = text; return node; };
  document.getElementById = (id) => descendants(document).find((node) => node.id === id) || null;
  document.querySelectorAll = () => [];
  const video = {
    paused: true, currentTime: 4.2, textTracks: [], playCalls: 0,
    addEventListener() {}, removeEventListener() {},
    play() { this.playCalls++; this.paused = false; return Promise.resolve(); },
  };
  document.querySelector = (selector) => selector === 'video' ? video : null;
  const window = {
    addEventListener() {}, postMessage() {}, innerWidth: 1200, innerHeight: 800,
    matchMedia: () => ({ matches: false }), getSelection: () => null,
  };
  const ctx = vm.createContext({
    document, window, video, URL,
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    performance: { now: () => 0 }, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'example.com', href: 'https://example.com/watch', pathname: '/watch' },
    chrome: {
      runtime: { id: 'test', lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
      storage: { local: { get() {}, set() {} }, onChanged: { addListener() {} } },
    },
  });
  for (const file of ['subtitle-adapters.js', 'vendor/dict-media.js', 'popup-size.js', 'subtitle-providers.js', 'content.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, file), 'utf8'), ctx, { filename: file });
  }
  window.fushiActiveFullTrack = () => ({ lang: 'ja', cues: [
    { startMs: 1000, endMs: 2000, text: '第一句' },
    { startMs: 2500, endMs: 3500, text: '第二句' },
    { startMs: 4000, endMs: 5000, text: '当前句' },
    { startMs: 5500, endMs: 6500, text: '第四句' },
    { startMs: 7000, endMs: 8000, text: '第五句' },
  ] });
  // 仅布置已打开的词典宿主；上下文 UI、暂停所有权和关闭逻辑仍使用真实实现。
  vm.runInContext("fushiHost = document.createElement('div'); fushiHost.id = 'fushi-host'; document.body.appendChild(fushiHost); fushiMarkPausedForLookup(video);", ctx);
  const base = document.getElementById('fushi-host');
  const modal = () => document.getElementById('fushi-ctx-modal-host');
  const buttons = () => descendants(modal().shadowRoot).filter((node) => node.tagName === 'BUTTON');
  const clickButton = (index) => {
    const button = buttons()[index];
    assert.equal(button.disabled, false);
    dispatch(button, 'mousedown');
    dispatch(button, 'mouseup');
    return dispatch(button, 'click');
  };
  const preview = () => window.fushiSentenceContextPreview({ matched: '当前' });
  return { ctx, window, document, video, base, modal, buttons, clickButton, preview };
}

test('上下文四个 ± 经 document capture 点击仍调整句子，保留底层查词和暂停', () => {
  const h = loadContent();
  h.window.fushiOpenSentenceContextModal({ matched: '当前' });
  for (const [index, prev, next] of [[0, 1, 0], [2, 1, 1], [1, 0, 1], [3, 0, 0]]) {
    h.clickButton(index);
    assert.ok(h.document.body.contains(h.base), '上下文按钮不能被当作词典外部点击');
    assert.ok(h.modal(), '调整句数不能导致模态消失');
    assert.equal(h.video.playCalls, 0, '调整句数不能恢复播放');
    assert.equal(h.video.paused, true);
    assert.equal(h.preview().prev.length, prev, 'click 必须到达按钮');
    assert.equal(h.preview().next.length, next, 'click 必须到达按钮');
  }
});

test('连续加减复用全部按钮和预览骨架，不移除焦点所在节点', () => {
  const h = loadContent();
  h.window.fushiOpenSentenceContextModal({ matched: '当前' });
  const buttons = h.buttons();
  const card = buttons[0].parentNode.parentNode;
  const skeleton = [...card.children];
  for (const index of [0, 2, 0, 2, 1, 3, 1, 3]) {
    h.clickButton(index);
    assert.deepEqual(h.buttons(), buttons, '重建按钮会让键盘焦点落回页面');
    assert.deepEqual(card.children, skeleton, '预览更新不得清空整张弹层');
    assert.equal(h.video.playCalls, 0);
  }
});

test('Escape 只取消顶层上下文并还原快照；第二次 Escape 才关闭词典恢复视频', () => {
  const h = loadContent();
  h.window.fushiSetSentenceContext(1, 0);
  h.window.fushiOpenSentenceContextModal({});
  h.window.fushiSetSentenceContext(1, 1);
  dispatch(h.buttons()[0], 'keydown', { key: 'Escape' });
  assert.equal(h.modal(), null);
  assert.ok(h.document.body.contains(h.base));
  assert.equal(h.video.playCalls, 0);
  assert.equal(h.preview().prev.length, 1);
  assert.equal(h.preview().next.length, 0);
  dispatch(h.base, 'keydown', { key: 'Escape' });
  assert.equal(h.document.body.contains(h.base), false);
  assert.equal(h.video.playCalls, 1);
});

test('真正关闭底层词典时同时撤掉模态，且视频只恢复一次', () => {
  const h = loadContent();
  h.window.fushiOpenSentenceContextModal({});
  h.ctx.fushiRemoveContainer();
  assert.equal(h.modal(), null);
  assert.equal(h.document.body.contains(h.base), false);
  assert.equal(h.video.playCalls, 1);
  h.ctx.fushiRemoveContainer();
  assert.equal(h.video.playCalls, 1);
});

test('模态指针和鼠标事件不冒泡给站点播放器，同时不阻止按钮默认行为', () => {
  const h = loadContent();
  h.window.fushiOpenSentenceContextModal({});
  const leaked = [];
  for (const type of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'touchstart', 'touchend']) {
    h.document.addEventListener(type, () => leaked.push(type));
    const event = dispatch(h.buttons()[0], type);
    assert.equal(event.defaultPrevented, false, type + ' 应保留聚焦和按钮默认行为');
  }
  assert.deepEqual(leaked, []);
  assert.equal(h.video.playCalls, 0);
});
