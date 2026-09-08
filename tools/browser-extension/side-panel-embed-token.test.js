'use strict';
// 审计报告 #1295 的嵌入协议守卫：side-panel.js EMBED 模式下，宿主 pause/resume 的
// 信任根必须是 **SW 核销过的 token**，不再是 URL 参数自证的 origin。
// 行为信号：embedPaused 生效与否直接反映为 300ms 轮询 tick 是否再向 tabs 发消息。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const DICT_MEDIA = fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8');

const flush = async () => { for (let i = 0; i < 12; i++) await new Promise((r) => setImmediate(r)); };

function makeEl() {
  return {
    id: '', textContent: '', innerHTML: '', hidden: false, disabled: false, value: '',
    dataset: {}, style: { setProperty() {}, removeProperty() {} }, children: [],
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; },
    removeChild() {}, remove() {},
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
    attachShadow() { const s = makeEl(); this.shadowRoot = s; return s; },
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

async function loadEmbedPanel(opts) {
  const o = opts || {};
  const tabSends = [];
  const runtimeSends = [];
  const intervals = [];
  const winHandlers = {};
  const els = new Map();
  const created = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return {
          id: 'test-ext-id',
          lastError: undefined,
          getURL() { return 'chrome-extension://test/x'; },
          onMessage: { addListener() {} },
          sendMessage(message, callback) {
            runtimeSends.push(message);
            if (message && message.type === 'drawerEmbedVerify' && callback) {
              // 真 SW 的应答形状：origin 只有 token 核销通过才有值；tabId 取自
              // sender.tab.id，与 token 成败无关（默认给 42，用例可覆盖成 null）。
              var base = o.verifyResp || { origin: '' };
              var resp = { origin: base.origin || '' };
              resp.tabId = Object.prototype.hasOwnProperty.call(base, 'tabId') ? base.tabId : 42;
              // 真 chrome.runtime.sendMessage 的回调**永远是异步的**：核销到货之前
              // 面板已经跑过一轮 refresh。同步 mock 会把这段窗口抹掉，让「URL 自证的
              // tabId 被首轮用掉」这类真漏洞在测试里看不见（实测：同步 mock 下该用例
              // 对着有漏洞的实现照样绿）。这里必须跨一个宏任务。
              setImmediate(function () { callback(resp); });
              return;
            }
            if (callback) callback({});
          },
        };
      }
      if (key === 'tabs') {
        return {
          get(_id, cb) { if (cb) cb({ id: 42 }); return Promise.resolve({ id: 42 }); },
          query(_q, cb) { if (cb) cb([{ id: 42 }]); return Promise.resolve([{ id: 42 }]); },
          onActivated: { addListener() {} },
          onUpdated: { addListener() {} },
          sendMessage(tabId, msg, cb) {
            tabSends.push({ tabId: tabId, msg: msg });
            if (cb) cb({ ok: true, data: {} });
            return Promise.resolve({ ok: true });
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
    addEventListener(type, fn) { (winHandlers[type] = winHandlers[type] || []).push(fn); },
    removeEventListener(type, fn) {
      if (winHandlers[type]) winHandlers[type] = winHandlers[type].filter((f) => f !== fn);
    },
    innerWidth: 400, innerHeight: 800,
    matchMedia: () => ({ matches: false }),
  };
  const sandbox = {
    document: {
      getElementById(id) {
        if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); }
        return els.get(id);
      },
      createElement() { const el = makeEl(); created.push(el); return el; },
      addEventListener() {},
      querySelector() { return null; }, querySelectorAll() { return []; },
      createRange() { return { setStart() {}, setEnd() {}, getBoundingClientRect() { return null; } }; },
      documentElement: makeEl(),
      body: makeEl(),
    },
    location: { search: o.search || '', href: 'chrome-extension://test/side-panel.html' + (o.search || '') },
    window: windowObj,
    chrome: chromeMock,
    setTimeout(fn) { fn(); return 1; },
    clearTimeout() {},
    setInterval(fn) { intervals.push(fn); return intervals.length; },
    clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    console: { log() {}, warn() {}, error() {} },
    navigator: { language: 'zh-CN' },
    URL,
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(SIDE_PANEL, sandbox, { filename: 'side-panel.js' });
  await flush();
  const dispatch = (origin, data) => {
    for (const fn of (winHandlers.message || []).slice()) fn({ origin, data, source: {} });
  };
  const tick = async () => { for (const fn of intervals.slice()) fn(); await flush(); };
  return { tabSends, runtimeSends, dispatch, tick };
}

test('带 token 的嵌入面板开局向 SW 核销，且只带 token 不带自证 origin', async () => {
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=42&fushiEmbedToken=TK1',
    verifyResp: { origin: 'https://m.test' },
  });
  const verify = p.runtimeSends.filter((m) => m && m.type === 'drawerEmbedVerify');
  assert.strictEqual(verify.length, 1);
  assert.strictEqual(verify[0].token, 'TK1');
});

test('核销成功：验证过的宿主 origin 的 pause 生效（轮询熄火）、resume 复活', async () => {
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=42&fushiEmbedToken=TK1',
    verifyResp: { origin: 'https://m.test' },
  });
  p.dispatch('https://m.test', { source: 'fushi-drawer', type: 'pause' });
  const before = p.tabSends.length;
  await p.tick();
  assert.strictEqual(p.tabSends.length, before, 'pause 被采纳后 tick 不许再向 tabs 发消息');
  await p.tick();
  assert.strictEqual(p.tabSends.length, before, '熄火要持续，不是一次性');
  p.dispatch('https://m.test', { source: 'fushi-drawer', type: 'resume' });
  await flush();
  assert.ok(p.tabSends.length > before, 'resume 必须立刻补一次全量刷新');
});

test('核销成功后，别的 origin 冒充宿主一律丢弃', async () => {
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=42&fushiEmbedToken=TK1',
    verifyResp: { origin: 'https://m.test' },
  });
  p.dispatch('https://evil.test', { source: 'fushi-drawer', type: 'pause' });
  const before = p.tabSends.length;
  await p.tick();
  assert.ok(p.tabSends.length > before, 'evil origin 的 pause 被采纳了——双向校验漏了方向');
});

test('核销失败（伪造 token 兑不出 origin）：宿主消息全数丢弃 = fail-closed', async () => {
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=42&fushiEmbedToken=FORGED',
    verifyResp: { origin: '' },
  });
  p.dispatch('https://evil.test', { source: 'fushi-drawer', type: 'pause' });
  const before = p.tabSends.length;
  await p.tick();
  assert.ok(p.tabSends.length > before, 'token 未核销通过时面板绝不可进入暂停态');
});

test('URL 无 token：照样核销（要拿 tabId），但宿主消息通道保持关死', async () => {
  // token 与 tabId 是两个信任根：前者决定「收不收宿主 pause/resume」，后者决定
  // 「驱动哪一页」。签不出 token 的页面（file:// 之类取不到 origin）仍必须能驱动本页，
  // 所以核销请求无条件发；能拿回的只有 tabId，origin 为空 → 哨兵不换 → 通道仍关。
  const p = await loadEmbedPanel({ search: '?fushiEmbed=1' });
  const verify = p.runtimeSends.filter((m) => m && m.type === 'drawerEmbedVerify');
  assert.strictEqual(verify.length, 1);
  assert.strictEqual(verify[0].token, '', '没 token 就送空串，别把请求整个吞掉');
  p.dispatch('https://m.test', { source: 'fushi-drawer', type: 'pause' });
  const before = p.tabSends.length;
  await p.tick();
  assert.ok(p.tabSends.length > before, '无 token 的宿主通道必须整条关死');
});

test('URL 里的 fushiTabId 不作数：只驱动 SW 背书的那一页', async () => {
  // 攻击形状：任意网站嵌 side-panel.html?fushiEmbed=1&fushiTabId=<受害者标签号>。
  // 面板跨源读不到内容，但点击劫持能借用户的手点选轨/跳转——所以目标页也不能自证。
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=999&fushiEmbedToken=TK1',
    verifyResp: { origin: 'https://m.test', tabId: 42 },
  });
  await p.tick();
  assert.ok(p.tabSends.length > 0, '背书到货后应当正常驱动');
  for (const s of p.tabSends) {
    assert.strictEqual(s.tabId, 42, 'URL 自证的 999 被采信了——tabId 必须只认 SW 背书');
  }
});

test('SW 背书不出 tabId：一条消息都不许发（fail-closed）', async () => {
  const p = await loadEmbedPanel({
    search: '?fushiEmbed=1&fushiTabId=999&fushiEmbedToken=TK1',
    verifyResp: { origin: 'https://m.test', tabId: null },
  });
  await p.tick();
  await p.tick();
  assert.strictEqual(p.tabSends.length, 0, '拿不到背书就不许回落去猜标签页');
});
