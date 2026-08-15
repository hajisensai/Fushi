// 「正在查词…」永久卡死回归守卫（BUG-1024 的 Side Panel 孪生）：
// MV3 service worker 在查词消息在途时被系统回收，chrome.runtime.sendMessage 的回调**永不触发**。
// 修复前的死锁闭环：
//   ① sendRuntime 的 Promise 永不 settle → lookupTerm 的 await 永久挂起 → 「正在查词…」永久停留；
//   ② fetchLookup 的同词在途复用（BUG-1525）把这个死 Promise 存进 lookupInFlight，
//      `.finally` 永不执行 → 同一个词此后每次查询都直接拿回死 Promise，永久锁死。
// 本守卫在受控 vm 里真加载 side-panel.js：stub sendMessage 永不回调，推进超时定时器，断言
//   a) loading 被替换成可重试的失败文案（不是无限转圈）；
//   b) 同一个词能再次真正发出 lookup 请求（在途表已去毒）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');

const flush = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };

function makeEl() {
  return {
    id: '', textContent: '', innerHTML: '', hidden: false, disabled: false, value: '',
    dataset: {}, style: { setProperty() {}, removeProperty() {} }, children: [],
    handlers: {},
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    removeEventListener() {},
    appendChild(child) { this.children.push(child); return child; },
    removeChild() {}, remove() {},
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
    attachShadow() { const shadow = makeEl(); this.shadowRoot = shadow; return shadow; },
    scrollIntoView() {}, focus() {}, contains() { return false; },
    querySelector() { return null; }, querySelectorAll() { return []; },
  };
}

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

function loadSidePanel() {
  const els = new Map();
  const created = [];
  const sentLookups = []; // {message, callback} —— callback 由测试决定何时/是否触发
  const timers = []; // {fn, ms}
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return {
          id: 'test-ext-id',
          lastError: undefined,
          getURL() { return 'chrome-extension://test/x'; },
          onMessage: { addListener() {} },
          sendMessage(message, callback) {
            if (message && message.type === 'lookup') {
              sentLookups.push({ message, callback });
              return; // SW 被回收：回调永不触发
            }
            if (callback) callback(undefined); // 打点等旁路消息直接回
          },
        };
      }
      if (key === 'storage') {
        return {
          local: {
            get(_keys, cb) { if (cb) cb({}); return Promise.resolve({}); },
            set() { return Promise.resolve(); },
          },
          onChanged: { addListener() {} },
        };
      }
      return permissive();
    },
  });
  const windowObj = {
    addEventListener() {},
    innerWidth: 400,
    innerHeight: 800,
  };
  const sandbox = {
    document: {
      getElementById(id) {
        if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); }
        return els.get(id);
      },
      createElement() { const el = makeEl(); created.push(el); return el; },
      addEventListener() {},
      querySelector() { return null; },
      querySelectorAll() { return []; },
      createRange() { return { setStart() {}, setEnd() {}, getBoundingClientRect() { return null; } }; },
      body: makeEl(),
    },
    window: windowObj,
    chrome: chromeMock,
    setTimeout(fn, ms) { timers.push({ fn, ms }); return timers.length; },
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    console: { log() {}, warn() {}, error() {} },
    navigator: { language: 'zh-CN' },
    URL,
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.runInNewContext(SIDE_PANEL, sandbox, { filename: 'side-panel.js' });
  const container = created.find((el) => el.id === 'entries-container');
  assert.ok(container, 'side-panel.js 必须建出 #entries-container 查词容器');
  return {
    windowObj,
    container,
    sentLookups,
    timers,
    lookup(term) {
      // popup.js 桥的嵌套查词入口 —— 外部可达且直通 lookupTerm。
      windowObj.flutter_inappwebview.callHandler('onLinkClick', term);
    },
    fireRuntimeTimeout() {
      // sendRuntime 的超时兜底定时器：不推进它 Promise 永不 settle（这正是本 bug）。
      const t = timers.splice(0).filter((x) => x.ms >= 1000);
      assert.ok(t.length >= 1, 'sendRuntime 必须挂超时兜底定时器（否则 SW 回收后永久 pending）');
      for (const timer of t) timer.fn();
    },
  };
}

test('SW 回调永不触发时：超时把「正在查词…」替换成失败文案，同词可重试（在途表去毒）', async () => {
  const h = loadSidePanel();

  h.lookup('世界');
  await flush();
  assert.strictEqual(h.sentLookups.length, 1, '首查必须真的发出 lookup 消息');
  assert.match(h.container.innerHTML, /正在查词/, '在途期间显示 loading');

  h.fireRuntimeTimeout();
  await flush();
  assert.doesNotMatch(h.container.innerHTML, /正在查词/, '超时后 loading 不得永久停留');
  assert.match(h.container.innerHTML, /查词失败/, '超时按失败处理，给出可重试文案');

  // 同一个词再查：修复前 lookupInFlight 里的死 Promise 会被直接还回 → 永远不再发请求。
  h.lookup('世界');
  await flush();
  assert.strictEqual(h.sentLookups.length, 2, '同词重试必须真正重新发出 lookup（在途表已去毒）');
  assert.match(h.container.innerHTML, /正在查词/, '重试重新进入 loading');
});
