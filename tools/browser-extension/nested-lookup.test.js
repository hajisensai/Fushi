const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-1279 回归守卫：浏览器扩展里的「嵌套查词」（在查词弹窗内点释义里的词 / 词典交叉引用
// a[href] → popup.js handleGlossaryAnchorClick → callHandler('onLinkClick') → bridge-shim →
// content.js __fushiOnLinkClick → 重发 lookup → 原地重渲染同一个弹窗）。
//
// 根因（修复前）：__fushiOnLinkClick 调 fushiRender(json, termLen, theme) 时**不传 anchorRect**，
// 而 fushiRender 是「首次查词」的完整渲染路径——它每次都会
//   ① 用**新词长度** termLen 去截**宿主页原文的旧选区**（fushiSelectionRects），把原文高亮
//      覆盖层重画成一段与原文词无关的错误范围；
//   ② 拿这段错误几何当锚点重新 place 弹窗，把弹窗从用户眼下的位置搬回原文旁边；
//   ③ 把 host.opacity 压 0 再淡入。
// 三者叠加 = 用户报的「嵌套查词把旧弹窗关掉了」+「弹窗跳位置」+「原文高亮乱变」。
//
// 正确语义（与 yomitan 单弹窗内导航、与本实现「咱们没有前进后退·咱们是嵌套查词」的既定设计
// 一致）：嵌套查词只换弹窗**内容**，弹窗位置、尺寸夹取、入场淡入、原文高亮一律**原样保持**——
// 原文里被查的词根本没变，没有任何理由重算它的几何。
//
// 本测试在受控 vm 里按 manifest 顺序真加载 vendor/popup.js + content.js，用带 shadow /
// composedPath / closest 语义的 DOM shim 驱动真实的 fushiSendLookup / __fushiOnLinkClick /
// popup.js document click 派发，断言上述契约。

const POPUP = path.join(__dirname, 'vendor', 'popup.js');
const CONTENT = path.join(__dirname, 'content.js');
const SHIM = path.join(__dirname, 'bridge-shim.js');

// BUG-1718：真实运行时（manifest content_scripts / side-panel.html）里 vendor/dict-media.js
// 恒在 content.js / side-panel.js 之前加载，后者依赖它导出的 applyFushiPopupCss 与
// installDictMediaPlaceholderResolver。测试沙箱必须照同样顺序装，否则跑的是一个真实
// 世界里不存在的、缺半个脚本集的环境。
const FUSHI_DICT_MEDIA = require('node:path').join(__dirname, 'vendor', 'dict-media.js');
function loadFushiDictMedia(ctx) {
  require('node:vm').runInContext(
    require('node:fs').readFileSync(FUSHI_DICT_MEDIA, 'utf8'), ctx,
    { filename: 'vendor/dict-media.js' });
}


// ---------------------------------------------------------------------------
// 最小 DOM shim：只实现本测试判据需要的语义，但这几项必须是**真语义**，否则守卫会假绿——
// closest 必须在 shadow 边界处停下（Element.closest 不跨 shadow），composedPath 必须给出
// 跨边界的完整路径，document 上的监听必须看到被 retarget 成 host 的 e.target。
// ---------------------------------------------------------------------------
// 当前世界的样式写入日志（loadWorld 每次重置；测试串行，无交叉污染）。
let styleWrites = [];

function makeEl(tag, doc) {
  const listeners = Object.create(null);
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    nodeType: 1,
    ownerDocument: doc,
    id: '',
    textContent: '',
    // CSSStyleDeclaration 的真语义子集：setProperty 写的自定义属性要能被 getPropertyValue
    // 读回（fushiDrawHighlightOverlay 就靠 getComputedStyle(...).getPropertyValue 取高亮色）。
    // 外面再包一层 Proxy 记录**每一次**样式写入——判据是「有没有被重写」，比「值等不等」强：
    // 重新 place 出同一个坐标值也是重新定位，不能算没动过。
    style: new Proxy({
      props: Object.create(null),
      setProperty(k, v) { this.props[k] = String(v); },
      getPropertyValue(k) { return k in this.props ? this.props[k] : ''; },
      removeProperty(k) { delete this.props[k]; },
    }, {
      set(t, k, v) { styleWrites.push({ el, k: String(k), v: String(v) }); t[k] = v; return true; },
    }),
    dataset: {},
    attrs: Object.create(null),
    classes: new Set(),
    children: [],
    parentNode: null,
    parentElement: null,
    shadowRoot: null,
    listeners,
    rect: { left: 0, top: 0, right: 0, bottom: 0, width: 100, height: 20 },
    scrollByCalls: [],
    get className() { return Array.from(el.classes).join(' '); },
    set className(v) {
      el.classes = new Set(String(v || '').split(/\s+/).filter(Boolean));
    },
    classList: {
      add(...c) { c.forEach((x) => el.classes.add(x)); },
      remove(...c) { c.forEach((x) => el.classes.delete(x)); },
      contains(c) { return el.classes.has(c); },
      toggle(c, on) { if (on) el.classes.add(c); else el.classes.delete(c); },
    },
    addEventListener(type, fn, options) {
      (listeners[type] = listeners[type] || []).push({ fn, options });
    },
    removeEventListener(type, fn) {
      const l = listeners[type];
      if (!l) return;
      const i = l.findIndex((r) => r.fn === fn);
      if (i >= 0) l.splice(i, 1);
    },
    appendChild(c) {
      c.parentNode = el;
      // ShadowRoot 不是 Element：其子节点的 parentElement 链在此处**断开**（closest 就此停）。
      c.parentElement = el.nodeType === 11 ? null : el;
      el.children.push(c);
      return c;
    },
    setAttribute(k, v) {
      el.attrs[k] = String(v);
      if (k === 'class') el.className = v;
      if (k === 'id') el.id = String(v);
    },
    getAttribute(k) { return k in el.attrs ? el.attrs[k] : null; },
    removeAttribute(k) { delete el.attrs[k]; },
    matches(sel) {
      return String(sel).split(',').map((s) => s.trim()).some((s) => {
        if (s.startsWith('.')) return el.classes.has(s.slice(1));
        if (s.startsWith('#')) return el.id === s.slice(1);
        const m = /^([a-z]+)\[([a-z-]+)\]$/i.exec(s);
        if (m) return el.tagName === m[1].toUpperCase() && el.attrs[m[2]] != null;
        return el.tagName === s.toUpperCase();
      });
    },
    closest(sel) {
      let n = el;
      while (n && n.nodeType === 1) {
        if (n.matches(sel)) return n;
        n = n.parentElement;
      }
      return null;
    },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getBoundingClientRect() { return el.rect; },
    remove() {
      if (el.parentNode) {
        const i = el.parentNode.children.indexOf(el);
        if (i >= 0) el.parentNode.children.splice(i, 1);
      }
      el.parentNode = null;
      el.parentElement = null;
      el.removed = true;
    },
    scrollBy(a) { el.scrollByCalls.push(a); },
    attachShadow() {
      const shadow = makeEl('#shadow-root', doc);
      shadow.nodeType = 11;
      shadow.host = el;
      shadow.getSelection = () => ({ toString() { return ''; }, removeAllRanges() {} });
      el.shadowRoot = shadow;
      return shadow;
    },
  };
  return el;
}

// 从 shadow 内节点向外走出完整 composedPath（含 shadow root 与 host），并给出「document 上的
// 监听器该看到的 target」= 跨越 shadow 边界后的宿主元素（浏览器的 retarget 语义）。
function composedPathOf(node, documentObj) {
  const p = [];
  let n = node;
  while (n) {
    p.push(n);
    if (n.nodeType === 11 && n.host) n = n.host;
    else n = n.parentNode;
  }
  p.push(documentObj);
  return p;
}
function retargetFor(node, documentObj) {
  const p = composedPathOf(node, documentObj);
  for (const n of p) {
    // 第一个「不在任何 shadow 内」的祖先即 document 视角的 target。
    let anc = n, inShadow = false;
    while (anc) {
      if (anc.nodeType === 11) { inShadow = true; break; }
      anc = anc.parentNode;
    }
    if (!inShadow) return n;
  }
  return documentObj;
}

function loadWorld(opts) {
  const options = opts || {};
  const docListeners = Object.create(null);
  const rafQueue = [];
  styleWrites = [];
  const body = makeEl('body', null);
  const documentObj = {
    nodeType: 9,
    documentElement: { style: { setProperty() {} }, dataset: {}, setAttribute() {} },
    body,
    fullscreenElement: null,
    addEventListener(type, handler, options2) {
      (docListeners[type] = docListeners[type] || []).push({ handler, options: options2 });
    },
    removeEventListener() {},
    createElement(tag) { return makeEl(tag, documentObj); },
    createTextNode(t) { return { nodeType: 3, textContent: String(t) }; },
    createRange() {
      let node = null, start = 0, end = 0;
      return {
        setStart(n, o) { node = n; start = o; },
        setEnd(n, o) { node = n; end = o; },
        // 每个字符一个 8px 宽的 rect，从选区所在节点的基准坐标起算——字符数不同 → 几何不同，
        // 这正是「用新词长度截旧选区」会被观测到的地方。
        getClientRects() {
          const base = (node && node.__rectBase) || { left: 0, top: 0 };
          const out = [];
          for (let i = start; i < end; i++) {
            out.push({
              left: base.left + i * 8, top: base.top,
              right: base.left + (i + 1) * 8, bottom: base.top + 20,
              width: 8, height: 20,
            });
          }
          return out;
        },
      };
    },
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
  };
  body.ownerDocument = documentObj;

  const sent = [];
  const windowObj = {
    innerWidth: 1200,
    innerHeight: 800,
    addEventListener() {},
    removeEventListener() {},
    scrollBy() {},
    getSelection() {
      return { toString() { return ''; }, removeAllRanges() {}, rangeCount: 0, isCollapsed: true };
    },
    getComputedStyle() {
      return { overflowY: 'visible', fontSize: '15px', getPropertyValue() { return ''; } };
    },
    open() {},
  };
  windowObj.window = windowObj;

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'example.com', href: 'https://example.com/p', pathname: '/p' },
    performance: { now() { return 1000; } },
    setTimeout() { return 0; },
    clearTimeout() {},
    requestAnimationFrame(fn) { rafQueue.push(fn); return rafQueue.length; },
    DOMParser: class { parseFromString() { return { body: {}, querySelectorAll() { return []; } }; } },
    Image: class { addEventListener() {} set src(_v) {} },
    Audio: class { play() { return Promise.resolve(); } },
    document: documentObj,
    window: windowObj,
    getComputedStyle: windowObj.getComputedStyle,
    chrome: {
      runtime: {
        id: 'test-ext-id',
        lastError: null,
        getURL: (p) => 'chrome-extension://test-ext-id/' + p,
        onMessage: { addListener() {} },
        sendMessage(msg, cb) {
          sent.push(msg);
          const resp = options.respond ? options.respond(msg) : null;
          if (cb) cb(resp);
          return Promise.resolve(resp);
        },
      },
      storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {} } },
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(POPUP, 'utf8'), sandbox, { filename: 'popup.js' });
  vm.runInContext(fs.readFileSync(SHIM, 'utf8'), sandbox, { filename: 'bridge-shim.js' });
  loadFushiDictMedia(sandbox);
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });

  const flushRaf = () => { while (rafQueue.length) rafQueue.shift()(); };
  // 只看某个元素上某几个样式属性的写入记录（cssText 初始化那一次不计）。
  const writesOn = (el, keys) => styleWrites.filter(
      (w) => w.el === el && keys.includes(w.k));
  const resetWrites = () => { styleWrites.length = 0; };
  return {
    sandbox, documentObj, windowObj, docListeners, sent, flushRaf, body,
    writesOn, resetWrites,
  };
}

// 宿主页原文里被查的那个词所在的文本节点（选区源）。__rectBase 决定它的视口几何。
function makeSourceTextNode(text, base) {
  return { nodeType: 3, textContent: text, __rectBase: base };
}

// 装一个 fushiSelection 桩：selection.ranges 指向宿主页原文节点（与真实 selectFromPosition 的
// 产物同形），供 fushiSelectionRects 只读取几何。
function installSelection(windowObj, node, start, end) {
  windowObj.fushiSelection = {
    __node: node,
    selection: { ranges: [{ node, start, end }] },
    getSelectionRect() {
      return { x: node.__rectBase.left, y: node.__rectBase.top, width: 32, height: 20 };
    },
    highlightSelection() { return null; },
    clearSelection() { windowObj.fushiSelection.selection = null; },
    selectText() {},
    getCharacterAtPoint() { return null; },
    selectFromPosition() { return ''; },
  };
}

const THEME = {
  '--fushi-popup-max-width': '400px',
  '--fushi-popup-max-height': '360px',
  '--fushi-popup-zoom': '1',
};

function lookupResponder(entriesByTerm) {
  return (msg) => {
    if (msg.type !== 'lookup') return { ok: true, data: {} };
    const e = entriesByTerm[msg.term];
    return {
      ok: true,
      data: {
        popupJson: JSON.stringify(e ? e.entries : []),
        result: { bestLength: e ? e.bestLength : msg.term.length },
        theme: THEME,
        audioSources: [],
      },
    };
  };
}

// 在原文上 Shift 悬停查词。走**真实的** document mousemove 路径（而不是直接调
// fushiSendLookup），否则同词去重状态 fushiLastTerm 根本不会被写，相关守卫会假绿。
function shiftHover(world, term, node, x, y) {
  const { windowObj, docListeners } = world;
  windowObj.fushiSelection.getCharacterAtPoint = () => ({ node, offset: 0 });
  windowObj.fushiSelection.selectFromPosition = () => term;
  const move = { shiftKey: true, buttons: 0, clientX: x, clientY: y };
  for (const r of (docListeners.mousemove || [])) r.handler(move);
}

// 首查词 → 拿到「弹窗已就位」的世界。返回落点快照与高亮覆盖层快照。
function openPopup(world, term, node) {
  const { windowObj, flushRaf, body } = world;
  installSelection(windowObj, node, 0, node.textContent.length);
  shiftHover(world, term, node, 320, 410);
  flushRaf();
  const host = windowObj.__fushiRoot && windowObj.__fushiRoot.host;
  assert.ok(host, '首查词必须建出弹窗 shadow host');
  return {
    host,
    left: host.style.left,
    top: host.style.top,
    overlay: body.children.find((c) => c.id === 'fushi-highlight-overlay'),
  };
}

const ENTRIES = {
  '日本語': { entries: [{ expression: '日本語' }], bestLength: 3 },
  '言語': { entries: [{ expression: '言語' }], bestLength: 2 },
};

test('嵌套查词不得关掉弹窗：__fushiOnLinkClick 后 host 仍在文档里', () => {
  const world = loadWorld({ respond: lookupResponder(ENTRIES) });
  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  const before = openPopup(world, '日本語', src);

  world.resetWrites();
  world.windowObj.__fushiOnLinkClick('言語');
  world.flushRaf();

  assert.strictEqual(before.host.removed, undefined,
      '嵌套查词绝不能移除弹窗 host（用户报「把旧弹窗关掉」）');
  assert.strictEqual(world.windowObj.__fushiRoot, before.host.shadowRoot,
      '嵌套查词必须复用同一个 shadow root（原地重渲染，不重建弹窗）');
  // 「旧弹窗被关掉」的直接视觉来源：重新走一遍入场淡入（opacity 压 0 再翻 1）。内容原地
  // 替换绝不该让弹窗先消失一次。
  const opacity = world.writesOn(before.host, ['opacity']).map((w) => w.v);
  assert.ok(!opacity.includes('0'),
      '嵌套查词不得把弹窗压成透明重新淡入（用户看到的就是「旧弹窗被关掉了」），实际写入：'
      + JSON.stringify(opacity));
  // 内容重渲染期间把容器藏起来量尺寸，也是同一个「消失一次」的来源。
  const vis = world.writesOn(world.windowObj.__fushiRoot.children.find(
      (c) => c.id === 'entries-container'), ['visibility']).map((w) => w.v);
  assert.ok(!vis.includes('hidden'),
      '嵌套查词不得把弹窗内容藏起来重新量尺寸，实际写入：' + JSON.stringify(vis));
});

test('嵌套查词必须原地：弹窗落点不得被重算搬回原文旁边', () => {
  const world = loadWorld({ respond: lookupResponder(ENTRIES) });
  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  const before = openPopup(world, '日本語', src);

  // 用户把弹窗读到一半，点了释义里的「言語」。原文里被查的词一个字都没变。
  world.resetWrites();
  world.windowObj.__fushiOnLinkClick('言語');
  world.flushRaf();

  // 判据是「有没有被重新定位」而不是「坐标值等不等」：重新 place 恰好算回同一个值也是
  // 重新定位（换个原文位置/换个内容高度就会真的跳走），假绿必须堵死。
  const moved = world.writesOn(before.host, ['left', 'top', 'maxHeight']);
  assert.deepStrictEqual(moved, [],
      '嵌套查词不得重新定位弹窗（应原地换内容），实际写入：'
      + JSON.stringify(moved.map((w) => w.k + '=' + w.v)));
  assert.strictEqual(before.host.style.left, before.left, '弹窗横向落点必须原样保持');
  assert.strictEqual(before.host.style.top, before.top, '弹窗纵向落点必须原样保持');
});

test('嵌套查词不得重画原文高亮：原文词没变，高亮范围就不能变', () => {
  const world = loadWorld({ respond: lookupResponder(ENTRIES) });
  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  const before = openPopup(world, '日本語', src);
  assert.ok(before.overlay, '首查词必须画出原文高亮覆盖层');
  const beforeBoxes = before.overlay.children.length;

  world.windowObj.__fushiOnLinkClick('言語'); // 子词 2 字，父词 3 字
  world.flushRaf();

  const after = world.body.children.find((c) => c.id === 'fushi-highlight-overlay');
  assert.strictEqual(after, before.overlay,
      '嵌套查词不得撤掉/重建原文高亮覆盖层');
  assert.strictEqual(after.children.length, beforeBoxes,
      '嵌套查词不得把原文高亮按子词长度重截（3 字词被截成 2 字）');
});

test('嵌套查词后 hover 回父词仍能重查：去重状态跟着弹窗内容走', () => {
  const world = loadWorld({ respond: lookupResponder(ENTRIES) });
  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  openPopup(world, '日本語', src);

  world.windowObj.__fushiOnLinkClick('言語');
  world.flushRaf();

  // 走**真实的** Shift 悬停路径（document mousemove handler），同词去重判定就在那里；
  // 直接调 fushiSendLookup 会绕过去重、把这条守卫变成假绿（已变异实测确认）。
  // 换个坐标，避开 mousemove 自己的「几乎没动就跳过」位移阈值。
  world.sent.length = 0;
  shiftHover(world, '日本語', src, 420, 410);

  assert.ok(world.sent.some((m) => m.type === 'lookup' && m.term === '日本語'),
      '弹窗内容已是子词时，Shift 悬停回父词必须能重查（同词去重状态必须随嵌套更新）');
});

test('请求在途时用户关掉了弹窗：嵌套结果丢弃，不得凭空弹回一个没落点的弹窗', () => {
  // background 先不回，模拟「点了链接 → 用户随即点页面别处关窗 → 响应才回来」。
  let deliver = null;
  const world = loadWorld({ respond: () => null });
  const responder = lookupResponder(ENTRIES);
  world.sandbox.chrome.runtime.sendMessage = (msg, cb) => {
    world.sent.push(msg);
    if (msg.type === 'lookup' && msg.term === '言語') { deliver = () => cb(responder(msg)); return; }
    if (cb) cb(responder(msg));
  };

  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  const before = openPopup(world, '日本語', src);

  world.windowObj.__fushiOnLinkClick('言語');
  world.sandbox.fushiRemoveContainer();   // 用户关窗
  deliver();                                // 迟到的嵌套响应
  world.flushRaf();

  assert.strictEqual(world.windowObj.__fushiRoot, null,
      '弹窗已关闭时，迟到的嵌套查词结果不得重建弹窗');
  assert.strictEqual(before.host.style.left, before.left,
      '不得出现没有落点的弹窗（重建后不 place 会钉在屏幕左上角）');
});

test('点释义里的交叉引用 a[href]：popup.js 必须走 onLinkClick，不得落到 tapOutside 关窗', () => {
  const world = loadWorld({ respond: lookupResponder(ENTRIES) });
  const src = makeSourceTextNode('日本語を勉強する', { left: 300, top: 400 });
  const before = openPopup(world, '日本語', src);

  // 在 shadow 里搭出真实结构：#entries-container > .entry > .glossary-content > a[href="entry://言語"]
  const shadow = before.host.shadowRoot;
  const container = shadow.children.find((c) => c.id === 'entries-container') || shadow.children[0];
  const entry = makeEl('div', world.documentObj); entry.className = 'entry';
  const gloss = makeEl('div', world.documentObj); gloss.className = 'glossary-content';
  const anchor = makeEl('a', world.documentObj);
  anchor.setAttribute('href', 'entry://言語');
  anchor.textContent = '言語';
  gloss.appendChild(anchor); entry.appendChild(gloss); container.appendChild(entry);

  let tapOutside = false;
  const realHandler = world.windowObj.__fushiOnTapOutside;
  world.windowObj.__fushiOnTapOutside = () => { tapOutside = true; if (realHandler) realHandler(); };

  let defaultPrevented = false;
  const evt = {
    clientX: 320, clientY: 410,
    target: retargetFor(anchor, world.documentObj),
    composedPath: () => composedPathOf(anchor, world.documentObj),
    preventDefault() { defaultPrevented = true; },
  };
  for (const r of (world.docListeners.click || [])) r.handler(evt);

  assert.strictEqual(defaultPrevented, true,
      '交叉引用必须 preventDefault（否则结果框架被导航走）');
  assert.strictEqual(tapOutside, false,
      '点释义里的词绝不能落到 tapOutside 关窗路径');
  assert.strictEqual(before.host.removed, undefined, '点释义里的词后弹窗必须还在');
  assert.ok(world.sent.some((m) => m.type === 'lookup' && m.term === '言語'),
      '点交叉引用必须发出对该词的 lookup（嵌套查词真的查了）');
});
