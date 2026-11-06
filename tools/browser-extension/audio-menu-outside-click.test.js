const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// fWIaHFV1qD：右键 ♪ 打开「选择音频源」菜单，点其中一项 → 整个查词窗被关、也不播放。
// 菜单宿主 #fushi-audio-menu-host 由 popup.js 的 __fushiAudioMenuMount 建在 documentElement 下，
// 与弹窗宿主 fushiHost 平级；content.js 的 document capture mousedown 旧判据只认 fushiHost /
// 缩放把手 / 上下文模态，菜单宿主被当成外部点击。修复后归属只认 data-fushi-session-host。
// 本测试加载真实 content.js 与 popup.js 的真实 __fushiAudioMenuMount，经完整的
// capture → target → bubble 事件链（含 shadow retarget 与 composedPath）点菜单项。
class Element {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.children = [];
    this.listeners = [];
    this.attrs = new Map();
    this.style = { setProperty() {} };
    this.dataset = {};
    this.classList = { add() {}, remove() {}, contains() { return false; } };
    this.parentNode = null;
  }
  addEventListener(type, fn, options = false) {
    this.listeners.push({ type, fn, capture: options === true || !!options.capture, once: !!options.once });
  }
  removeEventListener(type, fn, options = false) {
    const capture = options === true || !!options.capture;
    this.listeners = this.listeners.filter((l) => l.type !== type || l.fn !== fn || l.capture !== capture);
  }
  appendChild(child) {
    if (child.parentNode) child.remove();
    child.parentNode = this;
    this.children.push(child);
    return child;
  }
  remove() {
    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  closest() { return null; }
  setAttribute(name, value) { this.attrs.set(name, String(value)); }
  getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null; }
  hasAttribute(name) { return this.attrs.has(name); }
  removeAttribute(name) { this.attrs.delete(name); }
  getBoundingClientRect() { return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
  focus() {}
  attachShadow() { this.shadowRoot = new Element('#shadow-root'); this.shadowRoot.host = this; return this.shadowRoot; }
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
  const kids = node.children.slice();
  if (node.shadowRoot) kids.push(node.shadowRoot);
  return kids.flatMap((child) => [child, ...descendants(child)]);
}

function sliceFunction(src, header) {
  const start = src.indexOf(header);
  assert.ok(start >= 0, `切片锚失效：找不到 ${header}`);
  const end = src.indexOf('\n}\n', start);
  assert.ok(end > start, `切片锚失效：${header} 没有收尾`);
  return src.slice(start, end + 3);
}

function load() {
  const document = new Element('#document');
  document.documentElement = document.appendChild(new Element('html'));
  document.head = document.documentElement.appendChild(new Element('head'));
  document.body = document.documentElement.appendChild(new Element('body'));
  document.createElement = (tag) => new Element(tag);
  document.createTextNode = (text) => { const node = new Element('#text'); node.nodeType = 3; node.text = text; return node; };
  document.getElementById = (id) => descendants(document).find((node) => node.id === id) || null;
  document.querySelectorAll = () => [];
  document.querySelector = () => null;
  const window = {
    addEventListener() {}, postMessage() {}, innerWidth: 1200, innerHeight: 800,
    matchMedia: () => ({ matches: false }), getSelection: () => null,
  };
  const ctx = vm.createContext({
    document, window, URL,
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    performance: { now: () => 0 }, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'example.com', href: 'https://example.com/', pathname: '/' },
    chrome: {
      runtime: { id: 'test', lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
      storage: { local: { get() {}, set() {} }, onChanged: { addListener() {} } },
    },
  });
  for (const file of ['subtitle-adapters.js', 'vendor/dict-media.js', 'popup-size.js', 'subtitle-providers.js', 'content.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, file), 'utf8'), ctx, { filename: file });
  }
  // 弹窗宿主走真实的建宿主路径（fushiMarkSessionHost 打标记），shadow root 作为 popup.js 的 __fushiRoot。
  vm.runInContext(
    "fushiHost = fushiMarkSessionHost(document.createElement('div')); fushiHost.id = 'fushi-popup-host';" +
    "document.body.appendChild(fushiHost); window.__fushiRoot = fushiHost.attachShadow({ mode: 'open' });",
    ctx);
  const popupSrc = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
  vm.runInContext(sliceFunction(popupSrc, 'function __fushiAudioMenuMount('), ctx);
  // 与 popup.js 一样把菜单挂进 __fushiAudioMenuMount 返回的 shadow root，菜单项监听 click。
  const menuRoot = vm.runInContext('__fushiAudioMenuMount()', ctx);
  const menu = menuRoot.appendChild(new Element('div'));
  const item = menu.appendChild(new Element('div'));
  const played = [];
  item.addEventListener('click', () => played.push('jpod101'));
  const host = () => vm.runInContext('fushiHost', ctx);
  return { ctx, document, menuRoot, item, played, host };
}

test('音频源菜单宿主带会话归属标记', () => {
  const h = load();
  const menuHost = h.document.getElementById('fushi-audio-menu-host');
  assert.ok(menuHost, '菜单宿主应已建立');
  assert.equal(menuHost.hasAttribute('data-fushi-session-host'), true);
  assert.notEqual(menuHost.parentNode, h.host(), '菜单宿主与弹窗宿主平级（本测试的前提）');
});

test('点音频源菜单项：查词窗不关、点击送达菜单项', () => {
  const h = load();
  dispatch(h.item, 'mousedown');
  assert.ok(h.host(), '点菜单项不能被当成外部点击关掉查词窗');
  dispatch(h.item, 'mouseup');
  dispatch(h.item, 'click');
  assert.deepEqual(h.played, ['jpod101'], 'click 必须到达菜单项（没有被吞）');
});

test('点真正的页面元素仍会关窗并吞掉随后的 click', () => {
  const h = load();
  const page = h.document.body.appendChild(new Element('p'));
  const clicks = [];
  page.addEventListener('click', () => clicks.push('page'));
  dispatch(page, 'mousedown');
  assert.equal(h.host(), null, '点页面应关窗');
  dispatch(page, 'click');
  assert.deepEqual(clicks, [], '关窗的那一击不能落到站点上');
});

test('没有 composedPath 的事件沿父链 / shadow host 上溯判定归属', () => {
  const h = load();
  const isSession = vm.runInContext('fushiIsLookupSessionTarget', h.ctx);
  assert.equal(isSession({ target: h.item }), true);
  assert.equal(isSession({ target: h.document.body }), false);
});
