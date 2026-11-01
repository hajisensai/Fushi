// 带脚本词典词条在扩展里的两层沙箱（BUG-3762 扩展版，docs/specs/2026-10-23-dictionary-script-sandbox.md）：
//   ① manifest 声明 sandbox 页与两份 CSP（外层扩展页 frame-src 'self'、内层 connect-src 'none'）；
//   ② 外层 dict-frame.js 只认父窗口交来的那一个 port、只把白名单类型转出去；
//   ③ popup.js 在扩展上下文挂外层 frame、经 port 投递文档，不再走 _fushiLockBridge。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// vm 里建的对象原型属于另一个 realm，比结构前先转成本 realm 的普通值。
const eq = (actual, expected, message) =>
  assert.deepEqual(actual === undefined ? undefined : JSON.parse(JSON.stringify(actual)), expected, message);

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));

function directives(policy) {
  const map = new Map();
  for (const part of `${policy}`.split(';')) {
    const tokens = part.trim().split(/\s+/).filter(Boolean);
    if (tokens.length) map.set(tokens[0], tokens.slice(1));
  }
  return map;
}

// ---------------------------------------------------------------- manifest

test('manifest：dict-sandbox.html 声明为 sandbox 页，沙箱 CSP 收紧', () => {
  eq(manifest.sandbox && manifest.sandbox.pages, ['dict-sandbox.html']);
  const csp = directives(manifest.content_security_policy.sandbox);
  eq(csp.get('sandbox'), ['allow-scripts'], '只给 allow-scripts，绝不 allow-same-origin');
  eq(csp.get('default-src'), ["'none'"]);
  eq(csp.get('connect-src'), ["'none'"]);
  eq(csp.get('frame-src'), ["'none'"]);
  eq(csp.get('form-action'), ["'none'"]);
  eq(csp.get('base-uri'), ["'none'"]);
  eq(csp.get('script-src'), ["'unsafe-inline'", "'unsafe-eval'"]);
  // 媒体只认父侧内联好的 data:（和沙箱脚本自建的 blob:），不留任何网络来源。
  for (const name of ['img-src', 'font-src', 'media-src', 'style-src']) {
    for (const source of csp.get(name) || []) {
      assert.ok(["'unsafe-inline'", 'data:', 'blob:'].includes(source), `${name} 不得放行 ${source}`);
    }
  }
});

test('manifest：扩展页 CSP 显式写出 MV3 默认 + frame-src self；外层可被网页嵌入', () => {
  const csp = directives(manifest.content_security_policy.extension_pages);
  eq(csp.get('script-src'), ["'self'"]);
  eq(csp.get('object-src'), ["'self'"]);
  eq(csp.get('frame-src'), ["'self'"]);
  const war = manifest.web_accessible_resources.flatMap((entry) => entry.resources);
  assert.ok(war.includes('dict-frame.html'));
  // Chrome 对网页里的嵌套扩展 frame 也查 WAR（headless Chromium 实测不列就 Denying load）。
  assert.ok(war.includes('dict-sandbox.html'));
  const html = fs.readFileSync(path.join(__dirname, 'dict-frame.html'), 'utf8');
  assert.match(html, /<script src="dict-frame\.js"><\/script>/);
  assert.doesNotMatch(html, /<script>(?!<\/script>)/, '扩展页 CSP 不许内联脚本');
});

test('dict-sandbox.html：只收扩展源 parent 的一次 render，document.write 渲染', () => {
  const html = fs.readFileSync(path.join(__dirname, 'dict-sandbox.html'), 'utf8');
  assert.match(html, /event\.source !== window\.parent \|\| event\.origin !== relayOrigin/);
  assert.match(html, /removeEventListener\('message', onMessage\)/);
  assert.match(html, /document\.open\(\);\s*document\.write\(data\.html\);\s*document\.close\(\);/);
});

// ---------------------------------------------------------------- dict-frame.js

function relayWorld() {
  const windowListeners = {};
  const parent = { name: 'parent' };
  const created = [];
  const body = { children: [], appendChild(child) { this.children.push(child); } };
  const document = {
    body,
    createElement(tag) {
      const element = {
        tag, attrs: {}, style: {}, listeners: {}, removed: false,
        contentWindow: { posted: [], postMessage(data, origin) { this.posted.push({ data, origin }); } },
        setAttribute(k, v) { this.attrs[k] = v; },
        addEventListener(name, handler) { this.listeners[name] = handler; },
        remove() { this.removed = true; },
      };
      created.push(element);
      return element;
    },
  };
  const window = { parent, addEventListener(name, handler) { windowListeners[name] = handler; } };
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'dict-frame.js'), 'utf8'),
    vm.createContext({ window, document, isFinite, Number, String, Math }));
  const sent = [];
  const port = { postMessage(data) { sent.push(data); } };
  const message = (data, source, origin = 'chrome-extension://abc', ports = []) =>
    windowListeners.message({ data, source, origin, ports });
  return { parent, port, sent, created, message, get inner() { return created[0]; } };
}

function connectedRelay() {
  const w = relayWorld();
  w.message({ __fushiDictFrame: 1, type: 'connect' }, w.parent, 'http://host.example', [w.port]);
  w.port.onmessage({ data: { type: 'render', html: '<p>doc</p>' } });
  const inner = w.inner;
  w.message({ __fushiDictSandbox: 1, type: 'ready' }, inner.contentWindow, 'null');
  return { ...w, inner };
}

test('dict-frame：只认来自 parent 的第一份 connect；之后父窗口的 window message 一律不理', () => {
  const w = relayWorld();
  const rogue = { postMessage() { throw new Error('rogue port must not be used'); } };
  w.message({ __fushiDictFrame: 1, type: 'connect' }, { name: 'not-parent' }, 'http://x', [rogue]);
  assert.equal(rogue.onmessage, undefined, '非 parent 来源的 connect 不收');
  w.message({ __fushiDictFrame: 1, type: 'connect' }, w.parent, 'http://host.example', [w.port]);
  assert.equal(typeof w.port.onmessage, 'function');
  w.message({ __fushiDictFrame: 1, type: 'connect' }, w.parent, 'http://host.example', [rogue]);
  assert.equal(rogue.onmessage, undefined, '已连上后不换 port');
  // 父窗口（宿主网页脚本也能发）冒充内层消息：source 不是内层 → 丢。
  w.message({ __fushiDictSandbox: 1, type: 'select', text: 'x' }, w.parent, 'null');
  eq(w.sent, []);
});

test('dict-frame：render 建 sandbox 内层，ready 后只投递一次文档', () => {
  const w = relayWorld();
  w.message({ __fushiDictFrame: 1, type: 'connect' }, w.parent, 'http://host.example', [w.port]);
  w.port.onmessage({ data: { type: 'render', html: '<p>doc</p>' } });
  w.port.onmessage({ data: { type: 'render', html: '<p>second</p>' } });
  assert.equal(w.created.length, 1, '一个中继只建一个内层');
  const inner = w.inner;
  assert.equal(inner.tag, 'iframe');
  assert.equal(inner.src, 'dict-sandbox.html');
  assert.equal(inner.attrs.sandbox, 'allow-scripts');
  w.message({ __fushiDictSandbox: 1, type: 'ready' }, inner.contentWindow, 'null');
  w.message({ __fushiDictSandbox: 1, type: 'ready' }, inner.contentWindow, 'null');
  assert.equal(inner.contentWindow.posted.length, 1, '词典脚本再发 ready 也不会重投');
  eq(inner.contentWindow.posted[0].data, { __fushiDictSandboxRender: 1, html: '<p>doc</p>' });
});

test('dict-frame：内层消息按白名单逐字段重建后转给 port', () => {
  const w = connectedRelay();
  const src = w.inner.contentWindow;
  w.message({ __fushiDictSandbox: 1, type: 'height', value: 99999 }, src, 'null');
  w.message({ __fushiDictSandbox: 1, type: 'select', text: '検索'.repeat(100), rect: { x: 1, y: 'bad' }, extra: 'leak' }, src, 'null');
  w.message({ __fushiDictSandbox: 1, type: 'link', href: 'sound://a.mp3', text: 'a', rect: null }, src, 'null');
  w.message({ __fushiDictSandbox: 1, type: 'callHandler', name: 'updateEntry' }, src, 'null');
  w.message({ __fushiDictSandbox: 1, type: 'select', text: 'origin' }, src, 'chrome-extension://abc');
  w.message({ type: 'select', text: 'no marker' }, src, 'null');
  assert.equal(w.sent.length, 3);
  eq(w.sent[0], { __fushiDictSandbox: 1, type: 'height', value: 20000 });
  assert.equal(w.inner.style.height, '20000px');
  eq(Object.keys(w.sent[1]).sort(), ['__fushiDictSandbox', 'rect', 'text', 'type']);
  assert.equal(w.sent[1].text.length, 64);
  eq(w.sent[1].rect, { x: 1, y: 0, width: 0, height: 0 });
  eq(w.sent[2], { __fushiDictSandbox: 1, type: 'link', href: 'sound://a.mp3', text: 'a',
    rect: { x: 0, y: 0, width: 0, height: 0 } });
});

test('dict-frame：渲染后超过两次 load（被导航走）就拆掉内层', () => {
  const w = connectedRelay();
  w.inner.listeners.load(); // dict-sandbox.html
  w.inner.listeners.load(); // document.close 完成
  assert.equal(w.inner.removed, false);
  w.inner.listeners.load(); // 导航（被 frame-src 拦下的错误页也算）
  assert.equal(w.inner.removed, true);
  assert.equal(w.sent.at(-1).type, 'error');
});

// ---------------------------------------------------------------- popup.js

const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
const SLICE_START = "const FUSHI_BRIDGE_LOCKED = 'fushi-bridge-locked-v1';";
const SLICE_END = '// 把文本节点里的裸 URL 换成 <a>';

function popupWorld({ chrome } = {}) {
  const start = POPUP.indexOf(SLICE_START);
  const end = POPUP.indexOf(SLICE_END);
  assert.ok(start >= 0 && end > start, 'popup.js 沙箱段落找不到');
  const calls = [];
  const posted = [];
  const channels = [];
  function element(tag) {
    return {
      tag, attrs: {}, style: {}, listeners: {}, isConnected: true, className: '',
      contentWindow: { postMessage(data, origin, transfer) { posted.push({ data, origin, transfer }); } },
      setAttribute(k, v) { this.attrs[k] = v; },
      getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
      addEventListener(name, handler) { this.listeners[name] = handler; },
      remove() { this.isConnected = false; },
      getBoundingClientRect() { return { left: 10, top: 20 }; },
    };
  }
  class MessageChannel {
    constructor() {
      this.port1 = { sent: [], closed: false, postMessage(d) { this.sent.push(d); }, close() { this.closed = true; } };
      this.port2 = { name: 'port2' };
      channels.push(this);
    }
  }
  const windowObj = {
    flutter_inappwebview: { callHandler(name, ...args) { calls.push([name, ...args]); return Promise.resolve(null); } },
    addEventListener() {},
    dictionaryStyles: {},
  };
  const ctx = {
    window: windowObj,
    document: { createElement: element, activeElement: null },
    navigator: { userActivation: { isActive: true } },
    chrome,
    URL,
    MessageChannel,
    getComputedStyle: () => ({ color: 'red', fontSize: '16px', fontFamily: 'serif' }),
    dictHtmlFragment: () => ({ static: true }),
    dictSandboxHtml: (html) => `${html}`,
    fetchDictAsset: async () => null,
    normalizeDictMediaPath: (p) => p,
    reportDictScriptError: () => {},
    stripDictCssRemoteRefs: (css) => css,
    rewriteDictionaryMediaPath: () => null,
    playWordAudio: () => {},
    isDangerousDictUrl: () => false,
  };
  vm.createContext(ctx);
  vm.runInContext(POPUP.slice(start, end), ctx);
  const wrapper = {
    isConnected: true, children: [],
    replaceChildren(...nodes) { this.children = nodes; },
  };
  return { ctx, calls, posted, channels, wrapper,
    mount(html) { vm.runInContext('mountDictScriptSandbox', ctx)(wrapper, html, 'NLT'); } };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

test('popup.js（扩展上下文）：挂外层 dict-frame.html，经 port 投递文档，不锁桥', async () => {
  const w = popupWorld({ chrome: { runtime: { id: 'abc', getURL: (p) => `chrome-extension://abc/${p}` } } });
  w.mount('<p>語</p><script>draw()</script>');
  await flush();
  const frame = w.wrapper.children[0];
  assert.equal(frame.tag, 'iframe');
  assert.equal(frame.src, 'chrome-extension://abc/dict-frame.html');
  assert.equal(frame.attrs.sandbox, undefined, '外层必须是扩展源，不能加 sandbox');
  assert.ok(!w.calls.some((c) => c[0] === '_fushiLockBridge'), '扩展里不走 fushiLockBridge');

  frame.listeners.load();
  assert.equal(w.posted.length, 1);
  eq(w.posted[0].data, { __fushiDictFrame: 1, type: 'connect' });
  assert.equal(w.posted[0].origin, 'chrome-extension://abc');
  assert.equal(w.posted[0].transfer[0], w.channels[0].port2);
  const port = w.channels[0].port1;
  assert.equal(port.sent.length, 1);
  assert.equal(port.sent[0].type, 'render');
  assert.match(port.sent[0].html, /<script>draw\(\)<\/script>/);
  assert.match(port.sent[0].html, /__fushiDictSandbox = 1/, '文档里带 helper');
  assert.match(port.sent[0].html, /connect-src 'none'/, '文档里照旧带沙箱 meta CSP');

  // 回来的消息走同一套处理：高度、点词查词（加上 frame 偏移）、外链丢弃。
  port.onmessage({ data: { __fushiDictSandbox: 1, type: 'height', value: 321 } });
  assert.equal(frame.style.height, '321px');
  port.onmessage({ data: { __fushiDictSandbox: 1, type: 'select', text: '語', rect: { x: 1, y: 2 } } });
  eq(w.calls.at(-1), ['textSelected', '語', { x: 11, y: 22, width: 0, height: 0 }]);
  const before = w.calls.length;
  port.onmessage({ data: { __fushiDictSandbox: 1, type: 'link', href: 'https://evil/?w=x', text: 'x' } });
  assert.equal(w.calls.length, before, '沙箱来的外链一律丢');

  // 外层被换地址（宿主页能改 src）→ 再 load 即拆掉。
  frame.listeners.load();
  assert.equal(frame.isConnected, false);
  assert.equal(port.closed, true);
});

test('popup.js（扩展上下文）：没有用户激活时点词消息不放行', async () => {
  const w = popupWorld({ chrome: { runtime: { id: 'abc', getURL: (p) => `chrome-extension://abc/${p}` } } });
  w.ctx.navigator.userActivation.isActive = false;
  w.mount('<script>x()</script>');
  await flush();
  w.wrapper.children[0].listeners.load();
  w.channels[0].port1.onmessage({ data: { __fushiDictSandbox: 1, type: 'select', text: '語' } });
  assert.ok(!w.calls.some((c) => c[0] === 'textSelected'));
});

test('popup.js（非扩展 / 非 chrome-extension 地址）：仍走原生桥锁定路径', async () => {
  for (const chrome of [undefined, { runtime: { id: 'x', getURL: (p) => `fushi-ext://asset/${p}` } }]) {
    const w = popupWorld({ chrome });
    w.mount('<script>x()</script>');
    await flush();
    assert.ok(w.calls.some((c) => c[0] === '_fushiLockBridge'));
    eq(w.wrapper.children, [{ static: true }], '未锁定 → 只留静态内容');
  }
});
