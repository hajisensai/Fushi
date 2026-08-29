// 「侧边栏的查词弹窗跨不出侧边栏」行为守卫。
//
// 用户报：在 Side Panel 的字幕列表里点词，弹窗被那 ~400px 宽的面板夹住，只能挤成一条。
// 根因不是落点逻辑：Chrome 的 side panel 是浏览器自己的一份 web contents，面板内的 DOM
// 不管怎么定位都画不出面板边界——没有 CSS/JS 能突破。唯一的真路径是把词交回宿主页，用
// 页面弹窗（Shadow host）渲染，于是查词请求、暂停/恢复、嵌套查词、发音、查重、制卡全部
// 沿用页面既有链路。本文件守住这条链路的两端：
//   [content.js]  fushiShowLookupFromSidePanel：发查词 + 弹窗落在视口右上（紧邻侧栏、不压
//                 底部字幕）；不拿宿主页上一轮的选区当锚点、不把上一处词重新点亮；关窗时
//                 定向回 fushiSidePanelLookupGone（页面自己的 Shift 查词关窗不发）。
//   [side-panel.js] 默认把词交给宿主页且**不**在面板内渲染；宿主页不可达时回落面板内渲染
//                 （绝不能变成查不了词）；设置关掉时仍走面板内；Esc 关掉页面上那份。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
// BUG-1718：真实运行时里 vendor/dict-media.js 恒在 content.js / side-panel.js 之前加载。
const DICT_MEDIA = fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8');

const flush = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    _rect: null,
    className: '',
    innerHTML: '',
    textContent: '',
    isConnected: true,
    hidden: false,
    value: '',
    dataset: {},
    children: [],
    parentNode: null,
    handlers: Object.create(null),
    style: { cssText: '', setProperty() {}, removeProperty() {}, getPropertyValue: () => '' },
    classList: { add() {}, remove() {}, toggle() {} },
    setAttribute(k, v) { if (k === 'id') el._id = v; if (k === 'class') el.className = v; },
    getAttribute() { return null; },
    removeAttribute() {},
    addEventListener(type, fn) { (el.handlers[type] = el.handlers[type] || []).push(fn); },
    removeEventListener() {},
    attachShadow() {
      const shadow = makeEl('shadow-root');
      el.shadowRoot = shadow;
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
    scrollIntoView() {}, focus() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getBoundingClientRect() {
      return el._rect || { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findByClassName(el, cls) {
  if (!el) return null;
  if ((el.className || '').split(/\s+/).includes(cls)) return el;
  for (const c of el.children) {
    const hit = findByClassName(c, cls);
    if (hit) return hit;
  }
  return null;
}

function findById(el, id) {
  if (el._id === id) return el;
  for (const c of el.children) {
    const hit = findById(c, id);
    if (hit) return hit;
  }
  return null;
}

// ───────────────────────── content.js（宿主页一侧） ─────────────────────────

function loadContent() {
  const docListeners = Object.create(null);
  const sent = [];
  const rafs = [];
  const body = makeEl('body');
  const html = makeEl('html');
  // 宿主页上一轮 Shift 查词留下的选区：侧栏路径必须先清掉它，否则会拿旧词的 rects 当锚点、
  // 并把页面上那处词重新点亮（用户点的是侧栏里的另一个词）。
  const staleTextNode = { textContent: '前回の言葉', nodeType: 3 };
  const selection = {
    selection: { ranges: [{ node: staleTextNode, start: 0, end: 2 }], text: '前回' },
    cleared: 0,
    getCharacterAtPoint: () => ({ node: staleTextNode, offset: 0 }),
    selectFromPosition: () => '前回',
    getSelectionRect: () => ({ x: 100, y: 120, width: 40, height: 18 }),
    highlightSelection() { return { x: 100, y: 120, width: 40, height: 18 }; },
    clearSelection() { selection.cleared += 1; selection.selection.ranges = []; },
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: (fn) => { rafs.push(fn); return rafs.length; },
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
      getURL: (rel) => 'chrome-extension://test-ext-id/' + rel,
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb) cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
      },
    },
    storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {} } },
  };
  sandbox.window = {
    addEventListener() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: selection,
    flutter_inappwebview: { callHandler() {} },
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(CONTENT, sandbox, { filename: 'content.js' });
  return {
    sandbox, docListeners, sent, body, selection, rafs,
    // 量出真实尺寸后跑落点（rAF 里的 place）。
    runPlacement(width, height) {
      const host = findById(body, 'hibiki-popup-host');
      assert.ok(host, '未建出页面弹窗宿主 #hibiki-popup-host');
      host._rect = {
        x: 0, y: 0, left: 0, top: 0, right: width, bottom: height, width, height,
      };
      for (const fn of rafs.splice(0)) fn();
      return host;
    },
  };
}

test('侧栏查词交给宿主页：发出查词请求并建出页面弹窗（不是面板内那份窄弹窗）', () => {
  const h = loadContent();
  const ok = h.sandbox.window.fushiShowLookupFromSidePanel('世界', { startMs: 1000, endMs: 2000, text: '世界です' });
  assert.strictEqual(ok, true, '侧栏入口必须回 true，否则侧栏会以为宿主页不可达而回落面板内');
  const lookups = h.sent.filter((m) => m && m.type === 'lookup');
  assert.strictEqual(lookups.length, 1, '必须真的发出 lookup 请求');
  assert.strictEqual(lookups[0].term, '世界', '发出的词必须是侧栏点的那个');
  assert.ok(findById(h.body, 'hibiki-popup-host'), '必须在宿主页上建出页面弹窗');
});

test('侧栏查词的弹窗落在视口右上（紧邻侧栏、不压底部字幕）', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null);
  const host = h.runPlacement(400, 300);
  // 锚点是视口右上角的零宽矩形：左缘溢出后夹回 vw - pw - 8 = 1200 - 400 - 8。
  assert.strictEqual(host.style.left, '792px', '弹窗未贴视口右缘（应紧邻侧栏那侧）');
  assert.strictEqual(host.style.top, '12px', '弹窗未落在视口顶部（落到底部会压住字幕）');
});

test('侧栏查词不拿宿主页上一轮选区当锚点，也不把上一处词重新点亮', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null);
  assert.ok(h.selection.cleared >= 1, '未清掉宿主页残留选区（会拿旧词 rects 当锚点）');
  assert.strictEqual(findById(h.body, 'fushi-highlight-overlay'), null,
    '把宿主页上一处词重新点亮了——用户点的是侧栏里的词，宿主页上没有对应位置');
  const host = h.runPlacement(400, 300);
  assert.strictEqual(host.style.left, '792px', '落点被旧选区的 rects 带偏（应用侧栏专用锚点）');
});

test('页面弹窗关闭时回 fushiSidePanelLookupGone；页面自身 Shift 查词关窗不发这条', () => {
  const h = loadContent();
  h.sandbox.window.fushiShowLookupFromSidePanel('世界', null);
  h.sent.length = 0;
  assert.strictEqual(h.sandbox.window.fushiCloseLookupFromSidePanel(), true, '侧栏 Esc 必须能关掉页面弹窗');
  assert.ok(h.sent.some((m) => m && m.type === 'fushiSidePanelLookupGone'),
    '关窗未回执 → 侧栏的扫词去重键不复位，鼠标停在同一个字上永远重查不了');

  // 定向性：页面自己的 Shift 悬停查词关窗，不该给侧栏发这条（侧栏那份弹窗与它无关）。
  const p = loadContent();
  for (const fn of (p.docListeners.mousemove || [])) fn({ shiftKey: true, clientX: 300, clientY: 400 });
  assert.ok(findById(p.body, 'hibiki-popup-host'), '前置：Shift 悬停应建出页面弹窗');
  p.sent.length = 0;
  const outside = makeEl('div');
  for (const fn of (p.docListeners.mousedown || [])) fn({ target: outside });
  assert.ok(!p.sent.some((m) => m && m.type === 'fushiSidePanelLookupGone'),
    '页面自身查词关窗也发了侧栏回执（会误清侧栏状态）');
});

// ───────────────────────── side-panel.js（侧边栏一侧） ─────────────────────────

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

// storedSettings：chrome.storage.local 的初值；tabReply：宿主页对 side panel 消息的回复
// （null = 页面不可达，如 chrome:// 或没有内容脚本的页面）。
function loadSidePanel(storedSettings, tabReply) {
  const els = new Map();
  const created = [];
  const runtimeMessages = [];
  const tabMessages = [];
  const docListeners = Object.create(null);
  const runtimeListeners = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return {
          id: 'test-ext-id',
          lastError: undefined,
          getURL() { return 'chrome-extension://test/x'; },
          onMessage: { addListener(fn) { runtimeListeners.push(fn); } },
          sendMessage(message, callback) {
            runtimeMessages.push(message);
            if (message && message.type === 'lookup') return; // 留在途，本文件不断言查词结果
            if (callback) callback(undefined);
          },
          openOptionsPage() {},
        };
      }
      if (key === 'storage') {
        return {
          local: {
            get(_keys, cb) { if (cb) cb(storedSettings || {}); return Promise.resolve(storedSettings || {}); },
            set() { return Promise.resolve(); },
          },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'tabs') {
        return {
          query(_q, cb) { cb([{ id: 7, title: '测试页' }]); },
          get(_id, cb) { cb({ id: 7, title: '测试页' }); },
          sendMessage(_tabId, message, cb) {
            tabMessages.push(message);
            if (cb) cb(tabReply ? tabReply(message) : undefined);
          },
          onActivated: { addListener() {} },
          onUpdated: { addListener() {} },
        };
      }
      return permissive();
    },
  });
  // 字幕行里被“点”的那个文字元素（elementFromPoint 的命中目标）。
  let hitEl = null;
  const cueTextNode = { textContent: '世界です', nodeType: 3 };
  const windowObj = {
    addEventListener() {},
    innerWidth: 400,
    innerHeight: 800,
    getSelection: () => ({ isCollapsed: true }),
    // 侧栏里的取词（与宿主页同一套 selection.js）：命中一个字、扩成词。
    fushiSelection: {
      getCharacterAtPoint: () => ({ node: cueTextNode, offset: 0 }),
      selectFromPosition: () => '世界',
    },
  };
  const sandbox = {
    document: {
      getElementById(id) {
        if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); }
        return els.get(id);
      },
      createElement() { const el = makeEl(); created.push(el); return el; },
      createDocumentFragment() { return makeEl('fragment'); },
      elementFromPoint() { return hitEl; },
      addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
      querySelector() { return null; },
      querySelectorAll() { return []; },
      createRange() { return { setStart() {}, setEnd() {}, getBoundingClientRect() { return null; } }; },
      body: makeEl(),
    },
    window: windowObj,
    chrome: chromeMock,
    setTimeout(fn) { return 0; },
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
  vm.createContext(sandbox);
  vm.runInContext(DICT_MEDIA, sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(SIDE_PANEL, sandbox, { filename: 'side-panel.js' });
  const container = created.find((el) => el.id === 'entries-container');
  assert.ok(container, 'side-panel.js 必须建出 #entries-container 查词容器');
  return {
    windowObj, container, runtimeMessages, tabMessages, docListeners, runtimeListeners,
    pane: els.get('lookup-pane'),
    lookup(term) { windowObj.flutter_inappwebview.callHandler('onLinkClick', term); },
    // 用户在字幕行里点词（asbplayer 同款单击查词）——截图里那个操作的真实路径。
    clickCueWord() {
      const text = findByClassName(els.get('list'), 'subtitle-text');
      assert.ok(text, '字幕列表里没有渲染出可点的字幕文字');
      hitEl = text;
      for (const fn of (text.handlers.click || [])) fn({ clientX: 40, clientY: 60, stopPropagation() {} });
    },
    pressEscape() {
      for (const fn of (docListeners.keydown || [])) fn({ key: 'Escape' });
    },
    deliver(message) { for (const fn of runtimeListeners) fn(message); },
  };
}

// 宿主页一切正常：状态查询回一条带字幕的状态，其余命令回 {ok:true}。
const OK_REPLY = (message) => {
  if (!message || !message.type) return undefined;
  if (message.type === 'fushiSubtitleSidePanelState') {
    return {
      ok: true,
      videoKey: 'v1',
      hasVideo: true,
      activeLang: 'ja',
      currentTimeMs: 0,
      offsetMs: 0,
      tracks: [{ lang: 'ja', label: 'ja', length: 1, signature: 's1' }],
      cues: [{ startMs: 1000, endMs: 2000, text: '世界です' }],
    };
  }
  return { ok: true };
};

test('默认把词交给宿主页渲染：不在面板内查词、不显示面板内弹窗', async () => {
  const h = loadSidePanel({}, OK_REPLY);
  await flush();
  h.lookup('世界');
  await flush();
  const shown = h.tabMessages.filter((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup');
  assert.strictEqual(shown.length, 1, '必须把词交给宿主页（否则弹窗永远只有侧边栏那么宽）');
  assert.strictEqual(shown[0].term, '世界', '交出去的词不对');
  assert.strictEqual(h.runtimeMessages.filter((m) => m && m.type === 'lookup').length, 0,
    '词已交给宿主页，侧栏不该再自己发一份查词请求');
  assert.strictEqual(h.pane.hidden, true, '面板内那份窄弹窗不该出现');
  assert.doesNotMatch(h.container.innerHTML, /正在查词/, '面板内不该显示查词内容');
});

test('宿主页不可达（无内容脚本）：回落面板内渲染，绝不能变成查不了词', async () => {
  const h = loadSidePanel({}, () => undefined); // sendMessage 回 undefined = 页面没有内容脚本
  await flush();
  h.lookup('世界');
  await flush();
  assert.ok(h.tabMessages.some((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup'),
    '仍应先尝试交给宿主页');
  assert.strictEqual(h.runtimeMessages.filter((m) => m && m.type === 'lookup').length, 1,
    '宿主页不可达时必须回落到面板内自己查词');
  assert.strictEqual(h.pane.hidden, false, '回落后面板内弹窗必须显示');
  assert.match(h.container.innerHTML, /正在查词/, '回落后应进入面板内 loading');
});

test('设置关掉「查词结果显示在网页上」：仍走面板内渲染', async () => {
  const h = loadSidePanel({ subtitleLookupOnPage: false }, OK_REPLY);
  await flush();
  h.lookup('世界');
  await flush();
  assert.ok(!h.tabMessages.some((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup'),
    '设置已关，不该把词交给宿主页');
  assert.strictEqual(h.runtimeMessages.filter((m) => m && m.type === 'lookup').length, 1,
    '设置关掉后必须在面板内查词');
  assert.strictEqual(h.pane.hidden, false, '设置关掉后面板内弹窗必须显示');
});

test('侧栏按 Esc 关掉页面上那份弹窗（否则页面弹窗只能回页面上关）', async () => {
  const h = loadSidePanel({}, OK_REPLY);
  await flush();
  h.lookup('世界');
  await flush();
  h.tabMessages.length = 0;
  h.pressEscape();
  await flush();
  assert.ok(h.tabMessages.some((m) => m && m.type === 'fushiSubtitleSidePanelCloseLookup'),
    'Esc 没有关掉页面上那份弹窗');
});

test('点字幕行里的词：交给宿主页；弹窗还开着时同一个词不重复发请求', async () => {
  const h = loadSidePanel({}, OK_REPLY);
  await flush();
  h.clickCueWord();
  await flush();
  const first = h.tabMessages.filter((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup');
  assert.strictEqual(first.length, 1, '点字幕行里的词必须把词交给宿主页');
  assert.strictEqual(first[0].term, '世界', '交出去的词不对');
  assert.deepStrictEqual(first[0].cue, { startMs: 1000, endMs: 2000, text: '世界です' },
    '必须带上该行的精确时间窗（制卡要用它取媒体）');

  h.clickCueWord();
  await flush();
  assert.strictEqual(
    h.tabMessages.filter((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup').length, 1,
    '页面弹窗还开着，同一个词不该重复发请求（去重判据得认页面上那份弹窗）');
});

test('页面弹窗关窗回执到达后，同一个词能重新查（去重键已复位）', async () => {
  const h = loadSidePanel({}, OK_REPLY);
  await flush();
  h.clickCueWord();
  await flush();
  h.deliver({ type: 'fushiSidePanelLookupGone' }); // 用户在页面上把弹窗关了
  h.clickCueWord();
  await flush();
  assert.strictEqual(
    h.tabMessages.filter((m) => m && m.type === 'fushiSubtitleSidePanelShowLookup').length, 2,
    '页面弹窗已关，同词必须能重新查（否则用户得先移到别的词上再回来）');
});
