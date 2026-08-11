// PR #804 审查缺陷 1 守卫：chrome.sidePanel.open() 的用户手势链。
//
// open() 要求「瞬态用户激活」——激活在当前 task 结束时就没了。回归形状有三处：
//  ① action popup 把 open() 放进 chrome.tabs.query 回调、且前面还 await 了 setOptions
//     → 真正调用时激活早已过期，唯一能开侧边栏的入口 100% 失败；
//  ② background 同样先 await setOptions 再 open()；
//  ③ 内容脚本发出的 openSubtitleSidePanel 无回调，失败被丢弃，而 shortcutTogglePanel 无条件
//     return true → video-shortcuts 据此 preventDefault，用户按 Shift+S 后按键被吃、
//     站点原生快捷键也没了、屏幕上什么都没发生。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r)); };

// 任意属性访问都返回可调用壳的宽松 mock，用来吃掉与本用例无关的 chrome API。
function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
}

function makeEl() {
  return {
    id: '', textContent: '', hidden: false, disabled: false, value: '',
    dataset: {}, style: { setProperty() {}, removeProperty() {} }, children: [],
    handlers: {},
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { this.children.push(child); return child; },
    removeChild() {},
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
    scrollIntoView() {}, focus() {},
  };
}

// ── ① action popup：click 同步栈里必须已经调掉 open() ──

function loadPopup(options) {
  options = options || {};
  const els = new Map();
  const calls = [];
  let closed = 0;
  let openSettle = null;
  const sidePanel = {
    open(opts) {
      calls.push({ fn: 'open', opts });
      return new Promise((resolve, reject) => { openSettle = { resolve, reject }; });
    },
    setOptions(opts) { calls.push({ fn: 'setOptions', opts }); return Promise.resolve(); },
  };
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'sidePanel') return sidePanel;
      if (key === 'storage') {
        return {
          local: {
            get(_keys, cb) { if (cb) cb({}); return Promise.resolve({}); },
            set(obj, cb) { calls.push({ fn: 'storage.set', obj }); if (cb) cb(); return Promise.resolve(); },
          },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'tabs') {
        return {
          query(_q, cb) {
            cb(options.tabs === undefined
              ? [{ id: 7, url: 'https://www.youtube.com/watch?v=x', windowId: 3 }]
              : options.tabs);
          },
          update() {}, create() {},
        };
      }
      if (key === 'runtime') {
        return {
          sendMessage(msg, cb) { calls.push({ fn: 'sendMessage', msg }); if (cb) cb(undefined); },
          openOptionsPage() {}, lastError: undefined,
          getManifest() { return { version: '0.1.0' }; },
        };
      }
      return permissive();
    },
  });
  const sandbox = {
    document: {
      getElementById(id) {
        if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); }
        return els.get(id);
      },
      createElement: makeEl,
      addEventListener() {},
      querySelector() { return null; },
      querySelectorAll() { return []; },
    },
    chrome: chromeMock,
    window: { close() { closed += 1; }, addEventListener() {} },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    console, URL, Number, Promise, Date,
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.js'), 'utf8'),
      sandbox, { filename: 'action-popup.js' });
  return {
    calls,
    settleOpen() { return openSettle; },
    closedCount() { return closed; },
    clickPanelButton() {
      calls.length = 0; // 丢掉 popup init 的连接探测等噪声，只留 click 这一刻发生的事
      const btn = els.get('hp-nf-sublist');
      assert.ok(btn && btn.handlers.click && btn.handlers.click.length,
          'popup 必须给「打开字幕侧边栏」按钮挂 click');
      for (const fn of btn.handlers.click) fn({});
    },
  };
}

test('popup 打开字幕侧边栏：open() 必须在 click 的同步栈里，且先于任何 await/回调', () => {
  const h = loadPopup();
  h.clickPanelButton();
  // 处理器返回时（还没跑任何微任务）open 就必须已经调过——这正是瞬态激活唯一有效的窗口。
  assert.ok(h.calls.length > 0, 'click 同步栈里什么都没做 = 激活被浪费');
  assert.strictEqual(h.calls[0].fn, 'open',
      '第一件事必须是 open()，不能是 setOptions/storage.set/tabs.query');
  assert.strictEqual(h.calls[0].opts.tabId, 7);
});

test('popup：open() 落地后才补 setOptions 并关闭 popup（过早 close 会带走请求）', async () => {
  const h = loadPopup();
  h.clickPanelButton();
  assert.strictEqual(h.closedCount(), 0, 'open 未落地前不得关闭 popup');
  h.settleOpen().resolve();
  await flush();
  assert.ok(h.calls.some((c) => c.fn === 'setOptions'), 'open 之后要补 setOptions');
  assert.strictEqual(h.closedCount(), 1);
});

test('popup：拿不到 tabId 才回落给 service worker（且不空跑 open）', () => {
  const h = loadPopup({ tabs: [] });
  h.clickPanelButton();
  assert.ok(!h.calls.some((c) => c.fn === 'open'));
  const fallback = h.calls.find((c) => c.fn === 'sendMessage' && c.msg &&
      c.msg.type === 'openSubtitleSidePanel');
  assert.ok(fallback, '无 tabId 时必须至少把请求转给 SW');
});

// ── ② background：open() 先于 setOptions，失败必须回报 ──

function loadBackground() {
  const calls = [];
  let openSettle = null;
  const sidePanel = {
    open(opts) {
      calls.push({ fn: 'open', opts });
      return new Promise((resolve, reject) => { openSettle = { resolve, reject }; });
    },
    setOptions(opts) { calls.push({ fn: 'setOptions', opts }); return Promise.resolve(); },
  };
  const messageListeners = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'sidePanel') return sidePanel;
      if (key === 'runtime') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'onMessage') return { addListener(fn) { messageListeners.push(fn); } };
            return permissive();
          },
        });
      }
      return permissive();
    },
  });
  const sandbox = {
    chrome: chromeMock, console, fetch: () => Promise.resolve({ ok: false }),
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'),
      sandbox, { filename: 'background.js' });
  return {
    calls,
    settleOpen() { return openSettle; },
    send(msg) {
      const responses = [];
      for (const fn of messageListeners) fn(msg, {}, (value) => responses.push(value));
      return responses;
    },
  };
}

test('background openSubtitleSidePanel：open() 是第一句，setOptions 只在其后补', async () => {
  const h = loadBackground();
  const responses = h.send({ type: 'openSubtitleSidePanel', tabId: 11 });
  assert.strictEqual(h.calls.length, 1, 'setOptions 绝不能排在 open 之前——await 它会让瞬态激活过期');
  assert.strictEqual(h.calls[0].fn, 'open');
  assert.strictEqual(h.calls[0].opts.tabId, 11);
  assert.strictEqual(responses.length, 0, 'open 未落地不得抢答');
  h.settleOpen().resolve();
  await flush();
  assert.strictEqual(h.calls[1].fn, 'setOptions');
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].ok, true);
});

test('background openSubtitleSidePanel：open() 失败必须原样回报，不得静默吞掉', async () => {
  const h = loadBackground();
  const responses = h.send({ type: 'openSubtitleSidePanel', tabId: 11 });
  h.settleOpen().reject(new Error('sidePanel.open() may only be called in response to a user gesture'));
  await flush();
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].ok, false);
  assert.match(responses[0].error, /user gesture/);
});

// ── ③ 内容脚本：Shift+S 不吞按键 + 失败有可见提示 ──

function loadSubtitleController() {
  const sent = [];
  const toasts = [];
  const video = {
    currentTime: 0,
    getBoundingClientRect() { return { left: 0, top: 0, width: 1280, height: 720 }; },
  };
  const windowObject = {
    fushiEpisodeCues: { '81001|ja': [{ startMs: 1000, endMs: 2000, text: 'こんにちは' }] },
    addEventListener() {}, postMessage() {},
    fushiToast(text) { toasts.push(String(text)); },
  };
  const sandbox = {
    window: windowObject,
    document: {
      body: makeEl(), fullscreenElement: null, addEventListener() {},
      getElementById() { return null; },
      querySelector(sel) { return sel === 'video' ? video : null; },
      querySelectorAll() { return []; },
      createElement: makeEl, createDocumentFragment: makeEl,
    },
    location: { hostname: 'www.netflix.com', pathname: '/watch/81001', origin: 'https://www.netflix.com' },
    navigator: { clipboard: { writeText() { return Promise.resolve(); } } },
    setInterval: () => 1, clearInterval, setTimeout, clearTimeout, Date,
    chrome: {
      storage: {
        local: {
          get(_k, cb) {
            if (cb) { cb({ netflixSubtitlePanel: true }); return undefined; }
            return Promise.resolve({ netflixSubtitlePanel: true });
          },
          set() {},
        },
        onChanged: { addListener() {} },
      },
      runtime: {
        sendMessage(msg, cb) { sent.push({ msg, cb }); },
        onMessage: { addListener() {} },
        lastError: undefined,
      },
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8'),
      sandbox, { filename: 'subtitle-panel.js' });
  return { sent, toasts, shortcut: (action) => windowObject.fushiSubtitleShortcut(action) };
}

test('Shift+S 打不开侧边栏时不吞按键（返回 false，调用方就不会 preventDefault）', () => {
  const h = loadSubtitleController();
  assert.strictEqual(h.shortcut('toggle-panel'), false,
      '内容脚本永远开不了原生侧边栏；无条件 return true 会白吃用户按键');
  const req = h.sent.find((s) => s.msg && s.msg.type === 'openSubtitleSidePanel');
  assert.ok(req, '仍要把请求发给 SW（将来 Chrome 放宽即生效）');
  assert.strictEqual(typeof req.cb, 'function', '必须带回调收结果，否则失败被静默丢弃');
});

test('侧边栏打开失败给出可见提示（指向唯一可用入口），而不是什么都不发生', () => {
  const h = loadSubtitleController();
  h.shortcut('toggle-panel');
  const req = h.sent.find((s) => s.msg && s.msg.type === 'openSubtitleSidePanel');
  req.cb({ ok: false, error: 'may only be called in response to a user gesture' });
  assert.strictEqual(h.toasts.length, 1, '失败必须 toast，不能静默');
  assert.match(h.toasts[0], /图标/);
});
