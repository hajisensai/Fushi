// 查词弹窗「渲染尾巴」行为测试：masonry 三相批处理 + 脏 body 作用域 + 尾批时间预算分片
// + MessageChannel 调度原语。用 Node 真执行 popup.js（vm 沙箱 + 最小假 DOM），不是源码扫描。
//
// 守的回归（每条都做过变异实测，见同名 .dart 包装里的说明）：
//   ① layoutMasonry 内所有卡片的 width 写 **先于** 任何 offsetHeight 读——回到「每张卡片写完
//      立刻读高」就是每卡一次强制同步布局（O(卡片数) 次回流/帧）。
//   ② markMasonryDirty(body) + scheduleMasonry() 只重铺该 body；scheduleMasonryAll()/无标脏的
//      scheduleMasonry() 铺全部——回到全量重铺就是 O((词条×词典)²)。
//   ③ 渲染尾批一个宏任务里连续建多块（时间预算），而不是一块一任务——但仍然让出主线程
//      （宏任务数 ≥ 2）。
//   ④ scheduleRenderTail 有 MessageChannel 时走它（FIFO），没有时回落 setTimeout(fn, 0)。
//
// Run: node fushi/test/pages/popup_render_tail_batching_test.js
// (also driven from popup_render_tail_batching_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// ---------- 最小假 DOM（与 popup_empty_entry_card_test.js 同形，够 renderPopup 跑通） ----------

function makeClassList() {
  return {
    _set: new Set(),
    add(name) { this._set.add(name); },
    remove(name) { this._set.delete(name); },
    contains(name) { return this._set.has(name); },
    toggle(name, force) {
      const shouldHave = force === undefined ? !this._set.has(name) : !!force;
      if (shouldHave) { this._set.add(name); } else { this._set.delete(name); }
      return shouldHave;
    },
  };
}

function matchClass(el, cls) {
  if (!el) return false;
  if (el.classList && el.classList.contains(cls)) return true;
  const cn = typeof el.className === 'string' ? el.className : '';
  return cn.split(/\s+/).indexOf(cls) >= 0;
}

// `log` 记录几何读写顺序：{ op: 'write:width' | 'read:height', el }。
function makeElement(tag, log) {
  const styleStore = {};
  const node = {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    nodeType: 1,
    _innerHTML: '',
    dataset: {},
    children: [],
    childNodes: [],
    attributes: {},
    parentElement: null,
    isConnected: true,
    classList: makeClassList(),
    clientWidth: 600,
    _height: 40,
    style: new Proxy(styleStore, {
      set(target, prop, value) {
        if (prop === 'width' && log) log.push({ op: 'write:width', el: node });
        target[prop] = value;
        return true;
      },
      get(target, prop) {
        if (prop === 'setProperty') return (k, v) => { target[k] = v; };
        return prop in target ? target[prop] : '';
      },
    }),
    get offsetHeight() {
      if (log) log.push({ op: 'read:height', el: node });
      return node._height;
    },
    get innerHTML() { return this._innerHTML; },
    set innerHTML(v) {
      this._innerHTML = v;
      if (v === '') { this.children = []; this.childNodes = []; }
    },
    appendChild(child) {
      if (child && child.tagName === 'DOCUMENTFRAGMENT') {
        for (const c of child.children) { this.appendChild(c); }
        return child;
      }
      this.children.push(child);
      this.childNodes.push(child);
      if (child && typeof child === 'object') child.parentElement = this;
      return child;
    },
    append(...nodes) {
      for (const n of nodes) {
        if (typeof n === 'string') this.children.push({ nodeType: 3, textContent: n });
        else this.appendChild(n);
      }
    },
    remove() {
      const p = this.parentElement;
      if (!p) return;
      p.children = p.children.filter(c => c !== this);
      p.childNodes = p.childNodes.filter(c => c !== this);
    },
    setAttribute(k, v) { this.attributes[k] = String(v); },
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null;
    },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    removeAttribute(k) { delete this.attributes[k]; },
    addEventListener() {},
    closest(sel) {
      const cls = sel.replace(/^\./, '');
      let cur = this;
      while (cur) {
        if (matchClass(cur, cls)) return cur;
        cur = cur.parentElement;
      }
      return null;
    },
    getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; },
    querySelector(sel) {
      const all = this.querySelectorAll(sel);
      return all.length ? all[0] : null;
    },
    querySelectorAll(sel) {
      const out = [];
      if (sel === ':scope > .entry') {
        for (const c of this.children) if (matchClass(c, 'entry')) out.push(c);
        return out;
      }
      if (sel === '.glossary-section .category-body' ||
          sel === '.glossary-section > .category-body') {
        const find = (el, underGlossary) => {
          for (const c of (el.children || [])) {
            if (c && c.nodeType === 1) {
              const ug = underGlossary || matchClass(c, 'glossary-section');
              if (ug && matchClass(c, 'category-body')) out.push(c);
              find(c, ug);
            }
          }
        };
        find(this, false);
        return out;
      }
      if (sel === ':scope > .glossary-group > [data-dictionary]') {
        for (const g of this.children) {
          if (matchClass(g, 'glossary-group')) {
            for (const d of (g.children || [])) {
              if (d && d.getAttribute && d.getAttribute('data-dictionary') != null) out.push(d);
            }
          }
        }
        return out;
      }
      return out;
    },
  };
  return node;
}

function makeSandbox(opts) {
  const o = opts || {};
  const log = o.log || null;
  const fragmentFactory = () => {
    const f = makeElement('documentfragment', log);
    f.tagName = 'DOCUMENTFRAGMENT';
    return f;
  };
  const documentObj = {
    documentElement: { style: { setProperty() {} }, classList: makeClassList() },
    head: { appendChild() {} },
    body: makeElement('body', log),
    _byId: {},
    getElementById(id) { return this._byId[id] || null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) {
      if ((tag || '').toLowerCase() === 'fragment') return fragmentFactory();
      return makeElement(tag, log);
    },
    createDocumentFragment() { return fragmentFactory(); },
    createTextNode(text) { return { nodeType: 3, textContent: String(text) }; },
    addEventListener() {},
  };
  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    kanjiResults: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: [],
    innerWidth: 1200,
    innerHeight: 800,
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
    addEventListener() {},
    scrollTo() {},
  };
  documentObj.defaultView = windowObj;

  const timers = [];
  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, Number, String, console, Promise,
    performance: o.performance || { now() { return 0; } },
    setTimeout(cb) { timers.push(cb); return timers.length; },
    clearTimeout() {},
    __timers: timers,
    DOMParser: class {
      parseFromString() { return { body: makeElement('body', log), querySelectorAll() { return []; } }; }
    },
    document: documentObj,
    window: windowObj,
    getComputedStyle() {
      return {
        getPropertyValue(name) {
          return name === '--dict-columns' ? String(o.dictColumns === undefined ? 2 : o.dictColumns) : '';
        },
      };
    },
  };
  if (o.masonry !== false) {
    // masonrySupported() 要 requestAnimationFrame 与 ResizeObserver 都是 function。
    sandbox.__frames = [];
    sandbox.requestAnimationFrame = (cb) => { sandbox.__frames.push(cb); return sandbox.__frames.length; };
    sandbox.cancelAnimationFrame = () => {};
    sandbox.ResizeObserver = class { observe() {} disconnect() {} };
  }
  if (o.MessageChannel) sandbox.MessageChannel = o.MessageChannel;
  sandbox.globalThis = sandbox;
  return sandbox;
}

function loadPopup(opts) {
  const sandbox = makeSandbox(opts);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      layoutMasonry, markMasonryDirty, scheduleMasonry, scheduleMasonryAll,
      scheduleRenderTail,
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function el(sb, cls) {
  const node = sb.document.createElement('div');
  node.className = cls;
  cls.split(/\s+/).forEach(c => node.classList.add(c));
  return node;
}

// 一个词条的 .glossary-section > .category-body，内含 n 张 .glossary-group 卡片。
function makeBody(sb, container, n, heights) {
  const section = el(sb, 'category-section glossary-section');
  const body = el(sb, 'category-body');
  section.appendChild(body);
  for (let i = 0; i < n; i++) {
    const card = el(sb, 'glossary-group');
    card._height = heights ? heights[i] : 40 + i * 10;
    body.appendChild(card);
  }
  container.appendChild(section);
  return body;
}

function setupContainer(sb) {
  const container = sb.document.createElement('div');
  container.id = 'entries-container';
  sb.document._byId['entries-container'] = container;
  return container;
}

function drainFrames(sb) {
  let ran = 0;
  while (sb.__frames.length) {
    const cb = sb.__frames.shift();
    cb(0);
    ran++;
  }
  return ran;
}

// ---------- ① 写读分相：所有 width 写在任何 offsetHeight 读之前 ----------
{
  const log = [];
  const sb = loadPopup({ log, dictColumns: 3 });
  const container = setupContainer(sb);
  makeBody(sb, container, 5);
  makeBody(sb, container, 4);
  sb.window.__test.layoutMasonry();

  const writes = log.map((e, i) => (e.op === 'write:width' ? i : -1)).filter(i => i >= 0);
  const reads = log.map((e, i) => (e.op === 'read:height' ? i : -1)).filter(i => i >= 0);
  assert.strictEqual(writes.length, 9, 'every card gets its column width written once');
  assert.strictEqual(reads.length, 9, 'every card height is read exactly once');
  assert.ok(Math.max(...writes) < Math.min(...reads),
    'batched layout: the LAST width write must precede the FIRST offsetHeight read ' +
    '(interleaving write→read per card = one forced synchronous layout per card)');

  // 结果仍是最短列打包 + 粘着列：每张卡片都拿到列号与 translate。
  const bodies = container.querySelectorAll('.glossary-section > .category-body');
  bodies.forEach(body => {
    assert.strictEqual(body.dataset.masonryCols, '3');
    body.children.forEach(card => {
      assert.ok(/^[0-2]$/.test(card.dataset.masonryCol), 'card has a sticky column');
      assert.ok(/^translate\(/.test(card.style.transform), 'card is placed via translate');
      assert.strictEqual(card.style.position, 'absolute');
      assert.strictEqual(card.style.visibility, '', 'pre-hidden cards are revealed');
    });
    assert.ok(/px$/.test(body.style.height), 'body height is pinned to the tallest column');
  });
}

// ---------- ② 脏 body 作用域：只铺标脏的 body；无标脏 / All 铺全部 ----------
// 探针用 offsetHeight 读（每次铺都必读）而非 width 写（同值不重写）来判断「谁被铺了」。
{
  const log = [];
  const sb = loadPopup({ log, dictColumns: 2 });
  const container = setupContainer(sb);
  const bodyA = makeBody(sb, container, 3);
  const bodyB = makeBody(sb, container, 3);
  const laidOut = () => new Set(log.filter(e => e.op === 'read:height').map(e => e.el.parentElement));

  sb.window.__test.markMasonryDirty(bodyA);
  sb.window.__test.scheduleMasonry();
  assert.strictEqual(sb.__frames.length, 1, 'one coalesced frame is queued');
  log.length = 0;
  drainFrames(sb);
  assert.ok(laidOut().has(bodyA), 'the dirty body is laid out');
  assert.ok(!laidOut().has(bodyB), 'a clean body must NOT be re-laid out (scoped masonry)');
  assert.strictEqual(bodyB.dataset.masonryCols, undefined, 'clean body untouched');

  // 无标脏的 scheduleMasonry() = 全量（历史语义）。
  log.length = 0;
  sb.window.__test.scheduleMasonry();
  drainFrames(sb);
  assert.ok(laidOut().has(bodyA) && laidOut().has(bodyB),
    'scheduleMasonry() without any dirty mark lays out every body');

  // 标脏 A 后又来一个 All：同一帧必须铺全部（All 不能被已有的脏集合降级成 A-only）。
  log.length = 0;
  sb.window.__test.markMasonryDirty(bodyA);
  sb.window.__test.scheduleMasonry();
  sb.window.__test.scheduleMasonryAll();
  assert.strictEqual(sb.__frames.length, 1, 'still one coalesced frame');
  drainFrames(sb);
  assert.ok(laidOut().has(bodyB), 'scheduleMasonryAll after a scoped mark still lays out every body');

  // 帧跑完脏集合清空：下一次纯 scoped 调用不会把旧脏 body 带上。
  log.length = 0;
  sb.window.__test.markMasonryDirty(bodyB);
  sb.window.__test.scheduleMasonry();
  drainFrames(sb);
  assert.ok(laidOut().has(bodyB) && !laidOut().has(bodyA), 'dirty set is consumed per frame');
}

// ---------- ③ 尾批时间预算分片：一个宏任务建多块，但仍让出主线程 ----------
{
  // performance.now 每调一次前进 2ms：预算 6ms ⇒ 每个宏任务约建 3 块；
  // 沙箱无 MessageChannel ⇒ scheduleRenderTail 回落到 setTimeout（假队列，手动排空）。
  let clock = 0;
  const sb = loadPopup({
    performance: { now() { clock += 2; return clock; } },
    dictColumns: 1,
  });
  const container = setupContainer(sb);
  const gloss = (d) => ({ dictionary: 'Dict' + d, content: '"def"', definitionTags: '', termTags: '' });
  const entries = [];
  for (let e = 0; e < 6; e++) {
    entries.push({
      expression: '語' + e, reading: 'ご' + e, frequencies: [], pitches: [],
      glossaries: [0, 1, 2, 3].map(gloss),
    });
  }
  sb.window.lookupEntries = entries;
  sb.window.renderPopup();
  assert.strictEqual(sb.window._renderInProgress, true, 'tail is pending after first entry');

  let macrotasks = 0;
  while (sb.__timers.length) {
    const cb = sb.__timers.shift();
    macrotasks++;
    cb();
    assert.ok(macrotasks < 1000, 'tail never settles');
  }
  const totalBlocks = 6 * 4 - 1; // 首词条首块同步建
  assert.strictEqual(sb.window._renderInProgress, false, 'tail settled');
  assert.strictEqual(container.querySelectorAll(':scope > .entry').length, 6, 'every entry rendered');
  assert.ok(macrotasks >= 2, 'the tail still yields to the event loop (>= 2 macrotasks), got ' + macrotasks);
  assert.ok(macrotasks < totalBlocks,
    'time-budgeted slicing builds several blocks per macrotask: ' +
    macrotasks + ' macrotasks for ' + totalBlocks + ' deferred blocks');
}

// ---------- ④ scheduleRenderTail：有 MessageChannel 走它（FIFO），否则 setTimeout ----------
{
  const posted = [];
  class FakeMessageChannel {
    constructor() {
      const self = this;
      this.port1 = { onmessage: null };
      this.port2 = { postMessage(v) { posted.push(() => self.port1.onmessage({ data: v })); } };
    }
  }
  const sb = loadPopup({ MessageChannel: FakeMessageChannel, masonry: false });
  const order = [];
  sb.window.__test.scheduleRenderTail(() => order.push('a'));
  sb.window.__test.scheduleRenderTail(() => order.push('b'));
  assert.strictEqual(sb.__timers.length, 0, 'with MessageChannel present, setTimeout is not used');
  assert.strictEqual(posted.length, 2, 'each task posts one message');
  posted.forEach(deliver => deliver());
  assert.deepStrictEqual(order, ['a', 'b'], 'tasks run FIFO');

  const sb2 = loadPopup({ masonry: false });
  sb2.window.__test.scheduleRenderTail(() => order.push('c'));
  assert.strictEqual(sb2.__timers.length, 1, 'without MessageChannel, falls back to setTimeout');
}

console.log('all assertions passed');
