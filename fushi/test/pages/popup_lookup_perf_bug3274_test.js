// BUG-3274：视频页换词时查词弹窗先闪「未找到」、结果多时滑动掉帧。
//
// 用 Node 真执行 popup.js（vm + 极简假 DOM，见 _popup_dom_host.js），守三件事：
//   1. 宿主推的空闲占位（lookupIdle=true，热槽 seed / 换词复位）只画空占位盒，绝不画
//      「未找到」——换词时隐藏层先收到它，结果一慢、宿主兜底强制翻可见就露出假空态。
//      查询真结束且为空（lookupIdle=false、pending=false）仍画「未找到」。
//   2. 浏览器跳过渲染的屏外词条（content-visibility 的 skipped 态）masonry 一律不碰：
//      读它的几何会把整棵子树强制排版，按需渲染就白做了。滚进视口的事件到来时就地铺好。
//   3. 列数从 documentElement 的内联 --dict-columns 读，不调 getComputedStyle（整页
//      样式重算；masonry 每帧都要问一次列数）。
//   4. 长释义切块：块级子元素直接标记、li 永不标记、词典 CSS 含 counter 的整张卡不切；
//      「文字 + <br>」平铺正文只在 <br> 后断开包段、拆回后与原始逐节点相同；空闲预热只
//      处理浏览器正在跳过渲染的段（屏上的段不动，避免闪变）。
//
// Run: node fushi/test/pages/popup_lookup_perf_bug3274_test.js
// (also driven from popup_lookup_perf_bug3274_test.dart inside `flutter test`).

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('./_popup_dom_host.js');

function withContainer(sandbox) {
  const container = sandbox.document.createElement('div');
  container.id = 'entries-container';
  sandbox.document.getElementById = (id) => (id === 'entries-container' ? container : null);
  return container;
}

function renderEmpty({ pending, idle }) {
  const sandbox = loadPopup();
  const container = withContainer(sandbox);
  sandbox.window.lookupEntries = [];
  sandbox.window.kanjiResults = [];
  sandbox.window.lookupPending = pending;
  sandbox.window.lookupIdle = idle;
  vm.runInContext('window.renderPopup()', sandbox);
  return container.innerHTML;
}

// 1. 空闲占位不是「没有结果」。
{
  const idleHtml = renderEmpty({ pending: false, idle: true });
  assert.ok(!idleHtml.includes('no-results'),
    '空闲占位（换词复位）画成了「未找到」：兜底强制翻可见时就是用户看到的假空态');
  assert.ok(idleHtml.includes('popup-loading'), '空闲占位应留空占位盒');

  const pendingHtml = renderEmpty({ pending: true, idle: false });
  assert.ok(!pendingHtml.includes('no-results'), '查询中不得画「未找到」');

  const emptyHtml = renderEmpty({ pending: false, idle: false });
  assert.ok(emptyHtml.includes('no-results'), '查询真结束且为空仍应画「未找到」');
}

function makeMasonryBody(sandbox, skipped) {
  const doc = sandbox.document;
  const entry = doc.createElement('div');
  entry.className = 'entry';
  entry.__fushiRenderSkipped = skipped;
  entry.isConnected = true;
  const body = doc.createElement('div');
  let geometryReads = 0;
  Object.defineProperty(body, 'clientWidth', { get() { geometryReads++; return 600; } });
  body.closest = (sel) => (sel === '.entry' ? entry : null);
  const items = [0, 1, 2].map((i) => {
    const item = doc.createElement('details');
    item.classList.add('glossary-group');
    item.open = true;
    Object.defineProperty(item, 'offsetHeight', { get() { geometryReads++; return 100 + i * 10; } });
    body.appendChild(item);
    return item;
  });
  entry.querySelectorAll = (sel) => (sel === '.glossary-section > .category-body' ? [body] : []);
  return { entry, body, items, reads: () => geometryReads };
}

// 2. 跳过渲染的词条不铺；滚进视口（skipped=false）时就地铺好。
{
  const sandbox = loadPopup();
  withContainer(sandbox);
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '2' : '');
  sandbox.window.innerWidth = 900;
  const skipped = makeMasonryBody(sandbox, true);
  sandbox.__body = skipped.body;
  vm.runInContext('layoutMasonry([__body])', sandbox);
  assert.strictEqual(skipped.reads(), 0, '被跳过渲染的词条被读了几何：会强制排版整棵屏外子树');
  assert.strictEqual(skipped.body.style.position, undefined, '被跳过渲染的词条不应被 masonry 改写');

  sandbox.__entry = skipped.entry;
  vm.runInContext(
    '__fushiOnLazyEntryVisibility({ currentTarget: __entry, skipped: false })', sandbox);
  assert.strictEqual(skipped.entry.__fushiRenderSkipped, false);
  assert.ok(skipped.reads() > 0, '滚进视口后应当就地铺 masonry');
  assert.strictEqual(skipped.body.style.position, 'relative');
  assert.ok(skipped.items.every((it) => it.style.position === 'absolute' && it.style.transform),
    '滚进视口的词条每张卡都应被摆位');
}

// 3. 列数读内联值，不触发 getComputedStyle。
{
  let computedCalls = 0;
  const sandbox = loadPopup((sb) => {
    sb.getComputedStyle = () => { computedCalls++; return { getPropertyValue() { return '1'; } }; };
  });
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '3' : '');
  sandbox.window.innerWidth = 1200;
  computedCalls = 0;
  const cols = vm.runInContext('effectiveDictColumns()', sandbox);
  assert.strictEqual(cols, 3);
  assert.strictEqual(computedCalls, 0, '内联值存在时不应调 getComputedStyle（整页样式重算）');
}

// ---------- 4. 长释义切块 ----------
// 带父子关系与节点移动的微型 DOM（_popup_dom_host 的假元素不支持 insertBefore / replaceWith）。
function miniNode(type, tag, text) {
  const node = {
    nodeType: type, tagName: tag, _text: text || '', parentNode: null, childNodes: [],
    style: {}, listeners: {},
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); },
    },
    get className() { return [...this.classList._s].join(' '); },
    set className(v) { this.classList._s = new Set(String(v).split(/\s+/).filter(Boolean)); },
    get children() { return this.childNodes.filter((n) => n.nodeType === 1); },
    get textContent() { return type === 3 ? this._text : this.childNodes.map((n) => n.textContent).join(''); },
    appendChild(c) { if (c.parentNode) c.parentNode._remove(c); c.parentNode = this; this.childNodes.push(c); return c; },
    insertBefore(c, ref) {
      if (c.parentNode) c.parentNode._remove(c);
      c.parentNode = this;
      this.childNodes.splice(this.childNodes.indexOf(ref), 0, c);
      return c;
    },
    _remove(c) { this.childNodes = this.childNodes.filter((n) => n !== c); c.parentNode = null; },
    replaceWith(...nodes) {
      const parent = this.parentNode;
      let at = parent.childNodes.indexOf(this);
      parent._remove(this);
      nodes.forEach((n) => { if (n.parentNode) n.parentNode._remove(n); n.parentNode = parent; parent.childNodes.splice(at++, 0, n); });
    },
    addEventListener(t, fn) { this.listeners[t] = fn; },
    removeEventListener(t) { delete this.listeners[t]; },
    querySelectorAll(sel) {
      const cls = sel.replace(/^\./, '');
      const out = [];
      const walk = (n) => n.children.forEach((c) => { if (c.classList.contains(cls)) out.push(c); walk(c); });
      walk(this);
      return out;
    },
  };
  return node;
}
const T = (s) => miniNode(3, undefined, s);
const E = (tag, ...kids) => { const n = miniNode(1, tag); kids.forEach((k) => n.appendChild(k)); return n; };
const txt = (n) => 'あ'.repeat(n);

function chunkSandbox(dictStyles) {
  const sandbox = loadPopup((sb) => {
    sb.window.oncontentvisibilityautostatechange = null;
    sb.CSS = { supports: () => true };
  });
  sandbox.document.createElement = (tag) => miniNode(1, String(tag).toUpperCase());
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '2' : '');
  sandbox.window.innerWidth = 900;
  sandbox.window.dictionaryStyles = dictStyles || {};
  assert.strictEqual(vm.runInContext('__fushiLazyEntriesSupported', sandbox), true);
  return sandbox;
}

// 4a. 块级子元素直接标记；li 不标；短卡不切。
{
  const sandbox = chunkSandbox();
  const blocks = [0, 1, 2, 3].map(() => E('DIV', T(txt(800))));
  const li = E('LI', T(txt(1300)));
  const li2 = E('LI', T(txt(1300)));
  const root = E('DIV', E('DIV', ...blocks, E('OL', li, li2)));
  sandbox.__root = root;
  vm.runInContext('__fushiChunkLongGlossary(__root, "明鏡")', sandbox);
  assert.ok(blocks.every((b) => b.classList.contains('fushi-lazy-chunk')), '块级子元素应被标记成段');
  assert.ok(blocks.every((b) => /^auto \d+px$/.test(b.style.containIntrinsicSize)), '每段要有预估高度');
  assert.ok(!li.classList.contains('fushi-lazy-chunk') && !li2.classList.contains('fushi-lazy-chunk'), 'li 不得成段：style containment 会把列表编号断成每项都是 1');

  const small = E('DIV', E('DIV', T(txt(200))));
  sandbox.__small = small;
  vm.runInContext('__fushiChunkLongGlossary(__small, "明鏡")', sandbox);
  assert.strictEqual(small.querySelectorAll('.fushi-lazy-chunk').length, 0, '短卡不切');
}

// 4b. 词典 CSS 含 counter：整张卡不切。
{
  const sandbox = chunkSandbox({ 'wty-ja-zh': 'ol > li { counter-increment: gloss; }' });
  const root = E('DIV', E('DIV', ...[0, 1, 2, 3].map(() => E('DIV', T(txt(400))))));
  sandbox.__root = root;
  vm.runInContext('__fushiChunkLongGlossary(__root, "wty-ja-zh")', sandbox);
  assert.strictEqual(root.querySelectorAll('.fushi-lazy-chunk').length, 0, '计数器可能跨段累加，含 counter 的词典不切');
}

// 4c. 「文字 + <br>」平铺：只在 <br> 后断开，拆回后与原始逐节点相同。
{
  const sandbox = chunkSandbox();
  const flat = E('DIV');
  for (let i = 0; i < 40; i++) {
    flat.appendChild(T(txt(80)));
    flat.appendChild(E('BR'));
    if (i % 7 === 0) flat.appendChild(E('BR'));
  }
  const original = [...flat.childNodes];
  const root = E('DIV', flat);
  sandbox.__root = root;
  vm.runInContext('__fushiChunkLongGlossary(__root, "日本国語大辞典")', sandbox);
  const wrappers = flat.childNodes;
  assert.ok(wrappers.length > 1 && wrappers.every((w) => w.classList.contains('fushi-lazy-wrap')), '平铺正文应被包成多段');
  wrappers.slice(0, -1).forEach((w) => {
    const last = w.childNodes[w.childNodes.length - 1];
    assert.strictEqual(last.tagName, 'BR', '只能在 <br> 之后断开，否则会凭空多出换行');
  });
  assert.strictEqual(wrappers[0].style.textIndent, undefined, '首段继承容器的 text-indent（原文首行）');
  assert.ok(wrappers.slice(1).every((w) => w.style.textIndent === '0'), '后续段首行不是原文首行，text-indent 置 0');

  // 预热：屏上的段不动，只拆被跳过的段。
  wrappers[0].__fushiRenderSkipped = false;
  const container = E('DIV', root);
  container.querySelector = () => null; // 没有待预热的词条
  sandbox.document.getElementById = (id) => (id === 'entries-container' ? container : null);
  sandbox.window._renderGeneration = 7;
  let idle = null;
  sandbox.requestIdleCallback = (fn) => { idle = fn; return 1; };
  vm.runInContext('__fushiWarmLazyContent(7)', sandbox);
  for (let i = 0; i < 100 && idle; i++) { const fn = idle; idle = null; fn(); }
  assert.strictEqual(flat.childNodes[0], wrappers[0], '屏上的段不得被预热改动（会闪变）');
  wrappers[0].replaceWith(...wrappers[0].childNodes);
  assert.deepStrictEqual(flat.childNodes, original, '拆回后必须与切块前逐节点相同');
}

// 4d. 用户正在滚动时预热暂停，停下后继续。
{
  let clock = 1000;
  const listeners = {};
  const sandbox = loadPopup((sb) => {
    sb.window.oncontentvisibilityautostatechange = null;
    sb.CSS = { supports: () => true };
    sb.performance = { now: () => clock };
    sb.window.addEventListener = (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); };
  });
  sandbox.document.createElement = (tag) => miniNode(1, String(tag).toUpperCase());
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '2' : '');
  sandbox.window.innerWidth = 900;
  sandbox.window.dictionaryStyles = {};
  const blocks = [0, 1, 2, 3].map(() => E('DIV', T(txt(800))));
  const root = E('DIV', E('DIV', ...blocks));
  sandbox.__root = root;
  vm.runInContext('__fushiChunkLongGlossary(__root, "明鏡")', sandbox);
  const container = E('DIV', root);
  container.querySelector = () => null;
  sandbox.document.getElementById = (id) => (id === 'entries-container' ? container : null);
  sandbox.window._renderGeneration = 3;
  const idle = [];
  const timers = [];
  sandbox.requestIdleCallback = (fn) => { idle.push(fn); return 1; };
  sandbox.setTimeout = (fn) => { timers.push(fn); return 1; };
  (listeners.scroll || []).forEach((fn) => fn({}));   // clock=1000 时用户在滚
  clock = 1050;
  vm.runInContext('__fushiWarmLazyContent(3)', sandbox);
  idle.shift()();
  assert.strictEqual(container.querySelectorAll('.fushi-lazy-chunk').length, 4, '滚动停下不足 200ms 时预热不得动任何段');
  assert.strictEqual(timers.length, 1, '应排一个延时，等滚动停下再继续');
  clock = 1400;
  timers.shift()();
  idle.shift()();
  assert.ok(container.querySelectorAll('.fushi-lazy-chunk').length < 4, '滚动停下后预热应继续');
}

console.log('all assertions passed');
