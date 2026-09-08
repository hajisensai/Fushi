// side-panel.html 嵌入态的信任链守卫（行为测试，非正则）。
//
// 背景：手机抽屉把 side-panel.html 当 iframe 嵌进宿主网页，它因此必须是
// web_accessible_resource——于是**任何站点**都能凭同一个 URL 把这份持完整扩展
// 权限的文档嵌进自己的页面，而且可以一个参数都不带。回归形状有两个：
//   ① 把身份（tabId / hostOrigin）写在 URL 参数里——那是嵌入方自证，等于没校验；
//   ② 按参数（?fushiEmbed=1）分流——不带参数那条反而跑成完整侧板，站点只要
//      不写参数就能驱动它轮询 chrome.tabs。
// 真侧板永远是顶层文档，所以判据只能是「我被嵌了吗」+ SW 现发的一次性票据。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const POPUP_SIZE = fs.readFileSync(path.join(__dirname, 'popup-size.js'), 'utf8');
const DICT_MEDIA = fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

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
    id: '', textContent: '', innerHTML: '', hidden: false, disabled: false, value: '',
    dataset: {}, style: { setProperty() {}, removeProperty() {} }, children: [], handlers: {},
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { this.children.push(child); return child; },
    removeChild(child) { this.children = this.children.filter((c) => c !== child); return child; },
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
    attachShadow() { return makeEl(); },
    scrollIntoView() {}, focus() {},
    getBoundingClientRect() { return { top: 0, left: 0, width: 100, height: 20 }; },
  };
}

// 嵌入态面板（window.top !== window.self），验票结果由 authReply 决定。
function loadEmbeddedPanel(options) {
  options = options || {};
  const els = new Map();
  const runtimeMessages = [];
  const tabQueries = [];
  const tabMessages = [];
  const intervals = [];
  const winHandlers = Object.create(null);
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return {
          id: 'test-ext-id',
          lastError: undefined,
          getURL(p) { return 'chrome-extension://test/' + p; },
          onMessage: { addListener() {} },
          sendMessage(message, callback) {
            runtimeMessages.push(message);
            if (message && message.type === 'drawerFrameAuth') {
              if (callback) callback(options.authReply);
              return;
            }
            if (callback) callback(undefined);
          },
          openOptionsPage() {},
        };
      }
      if (key === 'storage') {
        return {
          local: { get(_k, cb) { if (cb) cb({}); return Promise.resolve({}); }, set() { return Promise.resolve(); } },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'tabs') {
        return {
          query(q, cb) { tabQueries.push(q); cb([{ id: 99, title: '攻击者的页' }]); },
          get(_id, cb) { cb({ id: 7, title: '宿主页' }); },
          sendMessage(tabId, message, cb) { tabMessages.push({ tabId, message }); if (cb) cb(undefined); },
          onActivated: { addListener() {} },
          onUpdated: { addListener() {} },
        };
      }
      return permissive();
    },
  });
  const windowObj = {
    innerWidth: 360, innerHeight: 640,
    addEventListener(type, fn) { (winHandlers[type] = winHandlers[type] || []).push(fn); },
    removeEventListener() {},
    getSelection: () => ({ isCollapsed: true }),
    matchMedia: () => ({ matches: false, addListener() {}, addEventListener() {} }),
  };
  windowObj.window = windowObj;
  windowObj.self = windowObj;
  windowObj.top = { /* 宿主页的顶层窗口（跨源，只可比较引用） */ };
  const sandbox = {
    document: {
      documentElement: makeEl(),
      getElementById(id) { if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); } return els.get(id); },
      createElement() { return makeEl(); },
      createDocumentFragment() { return makeEl(); },
      elementFromPoint() { return null; },
      addEventListener() {},
      querySelector() { return null; },
      querySelectorAll() { return []; },
      createRange() { return { setStart() {}, setEnd() {}, getBoundingClientRect() { return null; } }; },
      body: makeEl(),
    },
    window: windowObj,
    chrome: chromeMock,
    location: { search: options.search === undefined ? '?fushiTicket=tkt-1' : options.search },
    localStorage: { getItem() { return null; }, setItem() {} },
    setTimeout() { return 0; },
    clearTimeout() {},
    setInterval(fn) { intervals.push(fn); return intervals.length; },
    clearInterval() {},
    requestAnimationFrame: () => 0,
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    console: { log() {}, warn() {}, error() {} },
    navigator: { language: 'zh-CN' },
    URL,
  };
  sandbox.self = windowObj;
  vm.createContext(sandbox);
  vm.runInContext(POPUP_SIZE, sandbox, { filename: 'popup-size.js' });
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(SIDE_PANEL, sandbox, { filename: 'side-panel.js' });
  return {
    els, runtimeMessages, tabQueries, tabMessages, intervals, winHandlers,
    tick() { intervals.forEach((fn) => fn()); }, // 300ms 轮询
    post(origin, data) { (winHandlers.message || []).forEach((fn) => fn({ origin, data })); },
  };
}

test('站点自己嵌的面板（无票）一律停摆：不碰 chrome.tabs、不轮询、不收宿主消息', async () => {
  const panel = loadEmbeddedPanel({ authReply: { ok: false } });
  await flush();
  panel.tick();
  await flush();
  assert.deepEqual(panel.tabQueries, [], '无票嵌入竟然去查了当前标签页');
  assert.deepEqual(panel.tabMessages, [], '无票嵌入竟然向标签页发了消息');
  assert.equal(panel.els.get('video-status').textContent, '未授权的嵌入');
  // 嵌入方冒充任意 origin 发 resume 也拉不起来（根本没挂监听）。
  panel.post('https://evil.test', { source: 'fushi-drawer', type: 'resume' });
  panel.tick();
  await flush();
  assert.deepEqual(panel.tabMessages, [], 'resume 消息竟然把未授权面板叫醒了');
});

test('不带任何参数直接嵌（旧分流下会跑成完整侧板）同样停摆', async () => {
  const panel = loadEmbeddedPanel({ search: '', authReply: { ok: false } });
  await flush();
  panel.tick();
  await flush();
  assert.deepEqual(panel.tabQueries, [], '无参数嵌入被当成了真侧板，已经开始轮询它看不到的标签页');
  assert.deepEqual(panel.tabMessages, []);
});

test('验票通过：标签 id 与宿主 origin 只认 SW 回报值，冒充 origin 的宿主消息无效', async () => {
  const panel = loadEmbeddedPanel({
    search: '?fushiTicket=tkt-1',
    authReply: { ok: true, tabId: 7, hostOrigin: 'https://m.test' },
  });
  await flush();
  const auth = panel.runtimeMessages.find((m) => m && m.type === 'drawerFrameAuth');
  assert.ok(auth && auth.ticket === 'tkt-1', '面板没拿 URL 里的票去验');
  assert.ok(panel.tabMessages.length > 0, '验票通过后应该开始干活');
  assert.equal(panel.tabMessages[0].tabId, 7, '标签 id 必须是 SW 回报的那一页');
  assert.deepEqual(panel.tabQueries, [], '嵌入态绝不能回退到 tabs.query 拿任意活动标签');

  // 冒充 origin 的 pause 必须被丢掉：否则任何站点都能遥控面板的可见性状态。
  const before = panel.tabMessages.length;
  panel.post('https://evil.test', { source: 'fushi-drawer', type: 'pause' });
  panel.tick();
  await flush();
  assert.ok(panel.tabMessages.length > before, '冒充 origin 的 pause 竟然生效了');

  // 真宿主 origin 的 pause 生效。
  const mid = panel.tabMessages.length;
  panel.post('https://m.test', { source: 'fushi-drawer', type: 'pause' });
  panel.tick();
  await flush();
  assert.equal(panel.tabMessages.length, mid, '真宿主的 pause 没暂停轮询');
});

// SW 侧（发票/验票）没法在 vm 里单独跑（票据逻辑活在 background.js 的整体作用域里），
// 下面三条钉住它的关键不变式——回归时至少不会无声退化成「谁问都给票」。
const BACKGROUND = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');

test('SW 发票：票号必须来自真随机源，拿不到就不发票（绝不回退到可猜的值）', () => {
  assert.match(
    BACKGROUND,
    /function newDrawerTicketId\(\)[\s\S]*?crypto\.randomUUID[\s\S]*?crypto\.getRandomValues[\s\S]*?return null;/,
  );
  // 没标签身份 / 没真 origin / 没随机源 —— 任一缺失都不发票。
  assert.match(
    BACKGROUND,
    /if \(tabId == null \|\| !hostOrigin \|\| hostOrigin === 'null' \|\| !ticket\) return \{ ok: false \};/,
  );
});

test('SW 验票：一次性 + 校验（票有效 / 回问者是本扩展面板 / 同标签加固）', () => {
  assert.match(BACKGROUND, /if \(rec\) drawerTickets\.delete\(ticket\);/);
  assert.match(BACKGROUND, /if \(!rec \|\| !fromOwnPanel\) return \{ ok: false \};/);
  assert.match(BACKGROUND, /sender\.url\.indexOf\(panelUrl\) === 0/);
  assert.match(
    BACKGROUND,
    /if \(askerTabId != null && askerTabId !== rec\.tabId\) return \{ ok: false \};/,
  );
});

test('身份只经消息通道回报，绝不写进 iframe URL；manifest 只暴露入口 HTML', () => {
  const drawer = fs.readFileSync(path.join(__dirname, 'mobile-drawer.js'), 'utf8');
  assert.doesNotMatch(drawer, /fushiTabId|fushiHostOrigin/);
  assert.doesNotMatch(SIDE_PANEL, /fushiTabId|fushiHostOrigin/);
  // 子脚本是扩展页的同源子资源，不需要（也不该）对网页可见——参照 nested-popup.html。
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const war = manifest.web_accessible_resources.reduce((acc, e) => acc.concat(e.resources), []);
  assert.deepEqual(war.filter((r) => /side-panel|\.js$/.test(r)), ['side-panel.html']);
});
