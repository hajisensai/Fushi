const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 悬停查词离开即续播（对齐 app PR #1582 VideoFushiPage.shouldAutoResumeOnHoverLeave）。
// 「查词时暂停」把视频停住后，恢复播放的唯一出口是关弹窗；悬停发起的查词（Shift 悬停 /
// 悬浮字幕自动查词）本身不会关窗，用户每查一个词都得再点一下空白才能继续看片。这里在受控 vm
// 里真加载 content.js：Shift 悬停发查词 → 视频被暂停 → 指针离开字幕区与弹窗 → 320ms 意图确认
// 到期 → 弹窗关闭且视频续播；并逐条否决判据的每一道门（点击会话 / 指针在弹窗上 / 仍在字幕区 /
// 递归子层在场 / 用户自己暂停 / 设置关闭）。

const CONTENT = path.join(__dirname, 'content.js');
const FUSHI_DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const BRIDGE_SHIM = path.join(__dirname, 'bridge-shim.js');

function makeElement(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    style: {},
    dataset: {},
    isConnected: true,
    parentNode: null,
    children: [],
    listeners: Object.create(null),
    rect: { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 },
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    },
    removeEventListener() {},
    emit(type, ev) {
      for (const fn of this.listeners[type] || []) fn(ev || {});
    },
    appendChild(child) {
      if (child && typeof child === 'object') child.parentNode = this;
      this.children.push(child);
      return child;
    },
    insertBefore(child) { return this.appendChild(child); },
    setAttribute() {},
    getAttribute() { return null; },
    removeAttribute() {},
    remove() { this.isConnected = false; },
    contains(node) { return node === this; },
    closest() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getBoundingClientRect() { return this.rect; },
    focus() {},
    classList: { add() {}, remove() {}, contains() { return false; } },
    attachShadow() {
      const shadow = makeElement('#shadow');
      shadow.host = this;
      this.shadowRoot = shadow;
      return shadow;
    },
  };
  return el;
}

// 加载 content.js，并返回可驱动的句柄：document 监听器、可控定时器、视频桩、字幕源元素。
// options.deferResponses：查词响应不再同步回调，由 respond() 逐笔放行（模拟查词在途）。
// options.withBridge：装上真 bridge-shim.js——取词桩像真 selection.js 一样发 textSelected。
// options.nested：装一个子层记录器当 window.fushiNestedPopups（open 即记一层）。
function loadContent(options) {
  options = options || {};
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const winCaptureListeners = Object.create(null);
  const storageListeners = [];
  const sent = [];
  const created = [];
  const callbackErrors = [];
  const pendingLookups = [];
  const video = {
    paused: false,
    ended: false,
    isConnected: true,
    pauseCount: 0,
    playCount: 0,
    handlers: {},
    addEventListener(type, fn, opts) {
      (this.handlers[type] = this.handlers[type] || []).push({ fn, once: !!(opts && opts.once) });
    },
    removeEventListener() {},
    emit(type) {
      const hs = this.handlers[type] || [];
      this.handlers[type] = hs.filter((h) => !h.once);
      for (const h of hs) h.fn();
    },
    pause() { this.paused = true; this.pauseCount++; },
    play() {
      this.paused = false;
      this.playCount++;
      this.emit('play');
      return { catch() {} };
    },
  };
  // 字幕源：命中字符的父元素（content.js 用它的几何框判「指针还在查词区」）。
  const sourceEl = makeElement('span');
  sourceEl.rect = { left: 200, top: 380, right: 600, bottom: 420, width: 400, height: 40 };
  const hitNode = { textContent: '世界の天気', nodeType: 3, parentElement: sourceEl, parentNode: sourceEl };
  const inSource = (x, y) => x >= sourceEl.rect.left && x <= sourceEl.rect.right &&
    y >= sourceEl.rect.top && y <= sourceEl.rect.bottom;

  // 可控定时器：content.js 的离开判定靠 setTimeout(320ms)；测试显式推进。
  const timers = [];
  let timerSeq = 0;
  const setTimeoutStub = (fn, delay) => {
    const id = ++timerSeq;
    timers.push({ id, fn, delay });
    return id;
  };
  const clearTimeoutStub = (id) => {
    const i = timers.findIndex((t) => t.id === id);
    if (i >= 0) timers.splice(i, 1);
  };
  // content.js 还会记别的定时器（BUG-1024 在途兜底 12s、样式落地兜底 800ms 等）；离开判定
  // 只看 320ms 那一档，推进也只推进它们。
  const LEAVE_MS = 320;
  const leaveTimers = () => timers.filter((t) => t.delay === LEAVE_MS);
  const runTimers = () => {
    const due = leaveTimers();
    for (const t of due) {
      const i = timers.indexOf(t);
      if (i >= 0) timers.splice(i, 1);
    }
    for (const t of due) t.fn();
  };

  const nowRef = { value: 1000000 };
  const RealDate = Date;
  function FakeDate(...args) { return new RealDate(...args); }
  FakeDate.now = () => nowRef.value;
  FakeDate.prototype = RealDate.prototype;

  const documentElement = makeElement('html');
  documentElement.dataset = {};
  const body = makeElement('body');
  const sandbox = {
    Date: FakeDate,
    console: { log() {}, warn() {}, error() {} },
    setTimeout: setTimeoutStub,
    clearTimeout: clearTimeoutStub,
    // 弹窗落点算法在 rAF 里跑；这里只登记不执行——被测的是会话/判定，不是落点。
    requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    NodeFilter: { SHOW_TEXT: 4 },
    performance: { now() { return 1000; }, timeOrigin: 1700000000000 },
    location: { hostname: 'example.com', href: 'https://example.com/page', pathname: '/page' },
  };
  sandbox.document = {
    documentElement,
    body,
    fullscreenElement: null,
    addEventListener: (t, fn) => {
      (docListeners[t] = docListeners[t] || []).push(fn);
    },
    removeEventListener() {},
    getElementById: () => null,
    querySelector: (selector) => selector === 'video' ? video : null,
    querySelectorAll: (selector) => selector === 'video' ? [video] : [],
    createElement: (tag) => {
      const el = makeElement(tag);
      created.push(el);
      return el;
    },
    createRange: () => ({ setStart() {}, setEnd() {}, getClientRects: () => [] }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      getURL: (p) => 'chrome-extension://test/' + p,
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb && options.deferResponses && msg && msg.type === 'lookup') {
          pendingLookups.push(cb);
          return;
        }
        if (cb) {
          // 渲染路径里的异常会被 fushiSendLookup 的 try/catch 吞掉（那是给「扩展上下文失效」
          // 准备的）；这里先截住记下来，测试据此断言渲染真的走完了。
          try {
            cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
          } catch (err) {
            callbackErrors.push(err);
            throw err;
          }
        }
      },
    },
    storage: {
      local: {
        get: (_keys, cb) => {
          const saved = options.stored || {};
          if (typeof cb === 'function') cb(saved);
          return Promise.resolve(saved);
        },
        set: async () => {},
      },
      onChanged: { addListener: (fn) => storageListeners.push(fn) },
    },
  };
  const nestedOpened = [];
  sandbox.window = {
    // 真实传播顺序：window 捕获阶段 → …… → document 冒泡阶段（fire 按此派发）。
    addEventListener(type, fn, opts) {
      const capture = opts === true || !!(opts && opts.capture);
      if (capture) (winCaptureListeners[type] = winCaptureListeners[type] || []).push(fn);
    },
    removeEventListener() {},
    innerWidth: 1200,
    innerHeight: 800,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    // 取词桩按位置命中：只有字幕源框里有字；x<400 落在「世界」，其余落在「天気」。像真
    // selection.js 一样先把选区存进 this.selection 再发 textSelected（装了桥才有人接）。
    fushiSelection: {
      selection: null,
      getCharacterAtPoint: (x, y) => inSource(x, y) ? { node: hitNode, offset: x < 400 ? 0 : 3 } : null,
      selectFromPosition(node, offset, _max, x) {
        const text = x < 400 ? '世界' : '天気';
        this.selection = { startNode: node, startOffset: offset, ranges: [], text };
        const bridge = sandbox.window.flutter_inappwebview;
        if (bridge) bridge.callHandler('textSelected', text, { x, y: 400, width: 20, height: 16 });
        return text;
      },
      getSelectionRect: () => ({ x: 300, y: 400, width: 20, height: 16 }),
      highlightSelection: () => ({ x: 300, y: 400, width: 20, height: 16 }),
      clearSelection() {},
    },
  };
  if (options.nested) {
    sandbox.window.fushiNestedPopups = {
      open(query) { nestedOpened.push(query); },
      clear() { nestedOpened.length = 0; },
      dismissChildren() { nestedOpened.length = 0; },
      active: () => nestedOpened.length > 0,
      pop: () => false,
    };
  }
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(FUSHI_DICT_MEDIA, 'utf8'), sandbox,
    { filename: 'vendor/dict-media.js' });
  if (options.withBridge) {
    vm.runInContext(fs.readFileSync(BRIDGE_SHIM, 'utf8'), sandbox, { filename: 'bridge-shim.js' });
  }
  vm.runInContext(src, sandbox, { filename: 'content.js' });

  const host = () => created.find((el) => el.id === 'hibiki-popup-host' && el.isConnected) || null;
  // ev.stopBeforeDocument：站点在冒泡阶段 stopPropagation（document 冒泡监听收不到）。
  const fire = (type, ev) => {
    for (const fn of winCaptureListeners[type] || []) fn(ev);
    if (ev && ev.stopBeforeDocument) return;
    for (const fn of docListeners[type] || []) fn(ev);
  };
  return {
    docListeners,
    storageListeners,
    sent,
    video,
    sourceEl,
    documentElement,
    timers,
    leaveTimers,
    callbackErrors,
    runTimers,
    nestedOpened,
    windowObj: sandbox.window,
    host,
    lookupTerms() { return sent.filter((m) => m && m.type === 'lookup').map((m) => m.term); },
    // 放行最早一笔在途查词（deferResponses 模式）。
    respond() {
      const cb = pendingLookups.shift();
      assert.ok(cb, '没有在途的查词可放行');
      cb({ ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } });
    },
    // Shift 悬停查词：命中字幕源元素里的字（字幕框外移动时 target 是 body，取词桩也不命中）。
    shiftHover(x, y) {
      fire('mousemove', { shiftKey: true, clientX: x, clientY: y, buttons: 0, target: inSource(x, y) ? sourceEl : body });
    },
    // 松开 Shift 后的普通指针移动（离开判定的驱动）。
    move(x, y, target) { fire('mousemove', { shiftKey: false, clientX: x, clientY: y, buttons: 0, target: target || body }); },
    // 站点播放器控制层上的移动：它在冒泡阶段 stopPropagation，document 冒泡监听收不到。
    moveOnSwallowingLayer(x, y) {
      fire('mousemove', { shiftKey: false, clientX: x, clientY: y, buttons: 0, target: body, stopBeforeDocument: true });
    },
    popupOpen() { return !!host() && sandbox.window.__fushiRoot != null; },
  };
}

// 主路径：Shift 悬停 → 暂停 → 离开字幕区 → 320ms 到期 → 关窗 + 续播。
function hoverThenLeave(h) {
  h.shiftHover(300, 400);
  assert.deepStrictEqual(h.callbackErrors, [], '查词响应渲染路径不得抛异常（否则弹窗只建了一半）');
  assert.strictEqual(h.video.pauseCount, 1, 'Shift 悬停查词应先暂停视频');
  assert.ok(h.popupOpen(), '查词响应后弹窗应在场');
  h.move(300, 700); // 字幕框 y∈[380,420]，700 已在外面
}

test('判据真值表：全部门控成立才关栈续播，逐条否决', () => {
  const h = loadContent();
  const ok = {
    enabled: true, openedByHover: true, hasVisiblePopup: true, pausedForLookup: true,
    pointerOverPopup: false, overSubtitle: false, nestedPopupOpen: false, modalOpen: false,
  };
  const f = h.windowObj.fushiShouldAutoResumeOnHoverLeave;
  assert.strictEqual(f(ok), true);
  for (const key of ['enabled', 'openedByHover', 'hasVisiblePopup', 'pausedForLookup']) {
    assert.strictEqual(f({ ...ok, [key]: false }), false, key + ' 为 false 必须否决');
  }
  for (const key of ['pointerOverPopup', 'overSubtitle', 'nestedPopupOpen', 'modalOpen']) {
    assert.strictEqual(f({ ...ok, [key]: true }), false, key + ' 为 true 必须否决');
  }
  assert.strictEqual(f(null), false);
});

test('Shift 悬停查词后指针离开字幕区：320ms 意图确认到期即关弹窗并续播', () => {
  const h = loadContent();
  hoverThenLeave(h);
  assert.strictEqual(h.leaveTimers().length, 1, '离开字幕区应记一个意图确认定时器');
  assert.strictEqual(h.leaveTimers()[0].delay, 320, '意图确认窗口应为 320ms');
  assert.ok(h.popupOpen(), '到期前不得关窗');
  assert.strictEqual(h.video.playCount, 0, '到期前不得续播');
  h.runTimers();
  assert.ok(!h.popupOpen(), '到期后弹窗应关闭');
  assert.strictEqual(h.video.playCount, 1, '到期后应续播');
  assert.strictEqual(h.video.paused, false);
});

test('指针仍在字幕区内挪动（换词）不算离开：不记定时器、不关窗', () => {
  const h = loadContent();
  h.shiftHover(300, 400);
  h.move(500, 410); // 仍在字幕框内
  assert.strictEqual(h.leaveTimers().length, 0, '在字幕区内移动不得记离开定时器');
  h.runTimers();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.playCount, 0);
});

test('横穿空白进弹窗：mouseenter 撤销在途判定；离开弹窗 mouseleave 再记一次，到期关窗续播', () => {
  const h = loadContent();
  hoverThenLeave(h);
  assert.strictEqual(h.leaveTimers().length, 1);
  const host = h.host();
  host.emit('mouseenter');
  assert.strictEqual(h.leaveTimers().length, 0, '指针进弹窗必须撤销在途的离开判定');
  h.runTimers();
  assert.ok(h.popupOpen(), '指针在弹窗上绝不关窗');
  host.emit('mouseleave');
  assert.strictEqual(h.leaveTimers().length, 1, '离开弹窗应重新记离开判定');
  h.runTimers();
  assert.ok(!h.popupOpen());
  assert.strictEqual(h.video.playCount, 1, '离开弹窗到期后应续播');
});

test('弹窗正好画在静止的指针底下（host 尚未收到 mouseenter）：几何兜底不关窗', () => {
  const h = loadContent();
  hoverThenLeave(h);
  const host = h.host();
  host.rect = { left: 250, top: 650, right: 650, bottom: 780, width: 400, height: 130 }; // 盖住 (300,700)
  h.runTimers();
  assert.ok(h.popupOpen(), '指针落在弹窗几何框内不得关窗');
  assert.strictEqual(h.video.playCount, 0);
});

test('点击发起的查词是显式「停在这儿看」：鼠标移开不关窗、不续播（既有行为不变）', () => {
  const h = loadContent();
  h.windowObj.fushiLookupAtPoint(300, 400, { startMs: 1000, endMs: 2000, text: '世界です' });
  assert.strictEqual(h.video.pauseCount, 1, '点击查词照样暂停');
  assert.ok(h.popupOpen());
  h.move(300, 700);
  assert.strictEqual(h.leaveTimers().length, 0, '点击会话不得记离开定时器');
  h.runTimers();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.playCount, 0);
});

test('悬浮字幕自动查词（auto）也是悬停会话：离开即关窗续播', () => {
  const h = loadContent();
  h.windowObj.fushiLookupAtPoint(300, 400, { startMs: 1000, endMs: 2000, text: '世界です' }, { auto: true });
  assert.strictEqual(h.video.pauseCount, 1);
  h.move(300, 700);
  assert.strictEqual(h.leaveTimers().length, 1, '自动悬停查词离开字幕区应记离开定时器');
  h.runTimers();
  assert.ok(!h.popupOpen());
  assert.strictEqual(h.video.playCount, 1);
});

test('悬停会话中途显式点了同一个词：降级成点击会话，之后不再自动关', () => {
  const h = loadContent();
  h.shiftHover(300, 400);
  h.windowObj.fushiLookupAtPoint(300, 400, null); // 同词点击（fushiShownTerm 去重路径）
  assert.strictEqual(h.sent.filter((m) => m && m.type === 'lookup').length, 1, '同词点击不重发');
  h.move(300, 700);
  assert.strictEqual(h.leaveTimers().length, 0, '降级后不得记离开定时器');
  h.runTimers();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.playCount, 0);
});

test('用户自己暂停的视频：悬停离开不关窗（没有可续播的，保持既有「点空白才关」）', () => {
  const h = loadContent();
  h.video.paused = true;
  h.shiftHover(300, 400);
  assert.strictEqual(h.video.pauseCount, 0);
  h.move(300, 700);
  h.runTimers();
  assert.ok(h.popupOpen(), '没有由查词暂停的视频时不得自动关窗');
  assert.strictEqual(h.video.playCount, 0);
  assert.strictEqual(h.video.paused, true);
});

test('递归查词子层在场时不关栈（子层是独立 iframe，顶层收不到指针事件）', () => {
  const h = loadContent();
  hoverThenLeave(h);
  h.windowObj.fushiNestedPopups = { clear() {}, active: () => true };
  h.runTimers();
  assert.ok(h.popupOpen(), '子层在场不得关栈');
  assert.strictEqual(h.video.playCount, 0);
  h.windowObj.fushiNestedPopups = { clear() {}, active: () => false };
  h.move(300, 704);
  h.runTimers();
  assert.ok(!h.popupOpen(), '子层退出后再离开应关栈');
  assert.strictEqual(h.video.playCount, 1);
});

test('指针移出整个窗口（documentElement mouseleave）：即使最后坐标还落在贴边的字幕框里也算离开', () => {
  const h = loadContent();
  h.shiftHover(300, 400); // 最后已知坐标 (300,400) 在字幕框内
  h.host().emit('mouseenter'); // 先进弹窗
  h.runTimers();
  assert.ok(h.popupOpen(), '指针在弹窗上时不关');
  // 从弹窗直接滑出窗口：只投 documentElement 的 mouseleave，验证它独立成路且压过几何判定。
  h.documentElement.emit('mouseleave');
  assert.strictEqual(h.leaveTimers().length, 1, '移出窗口应记离开判定');
  h.runTimers();
  assert.ok(!h.popupOpen(), '移出窗口到期后应关窗');
  assert.strictEqual(h.video.playCount, 1, '移出窗口到期后应续播');
});

test('指针移出窗口后又移回字幕区：outside 状态被 mousemove 清回，不关窗', () => {
  const h = loadContent();
  h.shiftHover(300, 400);
  h.documentElement.emit('mouseleave');
  assert.strictEqual(h.leaveTimers().length, 1);
  h.move(400, 410); // 移回字幕框内
  assert.strictEqual(h.leaveTimers().length, 0, '回到字幕区必须撤销在途判定');
  h.runTimers();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.playCount, 0);
});

test('设置 subtitleResumeOnLookupLeave=false 关闭该行为；storage.onChanged 热更新即生效', () => {
  const off = loadContent({ stored: { subtitleResumeOnLookupLeave: false } });
  hoverThenLeave(off);
  off.runTimers();
  assert.ok(off.popupOpen(), '设置关闭时离开不得关窗');
  assert.strictEqual(off.video.playCount, 0);
  for (const listener of off.storageListeners) {
    listener({ subtitleResumeOnLookupLeave: { newValue: true } }, 'local');
  }
  off.move(300, 705);
  off.runTimers();
  assert.ok(!off.popupOpen(), '热更新开启后下一次离开应关窗');
  assert.strictEqual(off.video.playCount, 1);
});

test('关窗汇聚点复位会话：关窗后再普通移动不得再记定时器', () => {
  const h = loadContent();
  hoverThenLeave(h);
  h.runTimers();
  assert.ok(!h.popupOpen());
  h.move(500, 100);
  h.move(700, 200);
  assert.strictEqual(h.leaveTimers().length, 0, '会话已结束不得再记离开定时器');
  assert.strictEqual(h.video.playCount, 1, '不得重复 play');
});

// ---- 用户报「移出去还是暂停、暂停和继续反应不灵敏」（真 Chrome 探针复演出的几条根因）----

test('根弹窗在场时按住 Shift 在同一个词上挪动：页面选词的 textSelected 不叠同词子层，离开照常续播', () => {
  // 真 selection.js 的 selectFromPosition 每次都发 textSelected，bridge-shim 把它转给
  // __fushiOnLinkClick。页面扫描的选词若也开子层：同词微动 ≥4px 就叠出一层同词子层（外加白发
  // 一笔查词），子层在场使离开判定永远否决——视频一直停着。
  const h = loadContent({ withBridge: true, nested: true });
  h.shiftHover(300, 400);
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.pauseCount, 1);
  h.shiftHover(308, 402); // 仍在「世界」上挪了 8px
  h.shiftHover(316, 398);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.nestedOpened)), [],
    '页面上的选词不是弹窗内选词，不得开子层');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界'], '同词微动不得再发查词');
  h.move(300, 700);
  h.runTimers();
  assert.ok(!h.popupOpen(), '离开字幕区到期应关窗');
  assert.strictEqual(h.video.playCount, 1, '离开字幕区到期应续播');
});

test('站点控制层在冒泡阶段吞掉 mousemove：离开判定挂在 window 捕获阶段，照样关窗续播', () => {
  const h = loadContent();
  h.shiftHover(300, 400);
  assert.strictEqual(h.video.pauseCount, 1);
  h.moveOnSwallowingLayer(300, 520);
  assert.strictEqual(h.leaveTimers().length, 1, '被站点吞掉冒泡的移动也必须记离开判定');
  h.runTimers();
  assert.ok(!h.popupOpen());
  assert.strictEqual(h.video.playCount, 1);
});

test('指针在弹窗上移动（host 截住冒泡）：捕获阶段即识别为在弹窗上，撤销在途判定', () => {
  const h = loadContent();
  hoverThenLeave(h);
  assert.strictEqual(h.leaveTimers().length, 1);
  const host = h.host();
  h.move(320, 720, host); // 捕获阶段看到的 target 已重定向为 host
  assert.strictEqual(h.leaveTimers().length, 0, '指针在弹窗上必须撤销离开判定');
  h.runTimers();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.playCount, 0);
});

test('意图确认到期时查词还在途：不关窗（否则在途结果弹出一个不再自动关的窗、视频也不再归查词管）', () => {
  const h = loadContent({ deferResponses: true });
  h.shiftHover(300, 400);
  h.respond(); // 「世界」弹窗在场
  assert.ok(h.popupOpen());
  h.shiftHover(500, 400); // 扫到「天気」：在途
  h.move(500, 700); // 松开 Shift 离开
  assert.strictEqual(h.leaveTimers().length, 1);
  h.runTimers();
  assert.ok(h.popupOpen(), '在途时到期不得关窗');
  assert.strictEqual(h.video.playCount, 0, '在途时到期不得续播');
  assert.strictEqual(h.leaveTimers().length, 1, '应顺延离开判定，等在途结束再复核');
  h.respond(); // 「天気」结果到：换词
  h.runTimers();
  assert.ok(!h.popupOpen(), '在途结束后指针仍在外面：应关窗');
  assert.strictEqual(h.video.playCount, 1, '在途结束后应续播');
  assert.strictEqual(h.video.paused, false);
});

test('在途闸吞掉的最后一次 Shift 悬停：结果回来后补查指针停下的那个词', () => {
  const h = loadContent({ deferResponses: true });
  h.shiftHover(300, 400); // 「世界」在途
  h.shiftHover(500, 400); // 挪到「天気」停住：被在途闸吞掉
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界']);
  h.respond();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界', '天気'],
    '结果回来后应补查指针最终停下的词');
  h.respond();
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.pauseCount, 1, '补查不重复暂停');
});

test('在途期间松开 Shift：被吞的那次作废，结果回来后不补查', () => {
  const h = loadContent({ deferResponses: true });
  h.shiftHover(300, 400);
  h.shiftHover(500, 400); // 被吞
  h.move(510, 404); // 松开 Shift
  h.respond();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界']);
});

test('悬浮字幕自动查词在途时滑到下一个词：结果回来后补查；指针离开覆盖层则作废', () => {
  const cue = { startMs: 1000, endMs: 2000, text: '世界の天気' };
  const h = loadContent({ deferResponses: true });
  h.windowObj.fushiLookupAtPoint(300, 400, cue, { auto: true });
  h.windowObj.fushiLookupAtPoint(500, 400, cue, { auto: true }); // 被吞
  h.respond();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界', '天気']);
  h.respond();

  const left = loadContent({ deferResponses: true });
  left.windowObj.fushiLookupAtPoint(300, 400, cue, { auto: true });
  left.windowObj.fushiLookupAtPoint(500, 400, cue, { auto: true }); // 被吞
  left.windowObj.fushiResetAutoLookupDedupe(); // 覆盖层 mouseleave
  left.respond();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(left.lookupTerms())), ['世界'],
    '人已离开覆盖层，不得补查弹出来');
});

test('按住 Shift 离开 → 续播 → 按住 Shift 回到同一个词：再查一次、再暂停', () => {
  const h = loadContent();
  h.shiftHover(300, 400);
  assert.strictEqual(h.video.pauseCount, 1);
  h.shiftHover(300, 700); // 按住 Shift 离开到空白处（取词不命中）
  h.runTimers();
  assert.ok(!h.popupOpen());
  assert.strictEqual(h.video.playCount, 1);
  h.shiftHover(300, 400); // 回到「世界」
  assert.deepStrictEqual(JSON.parse(JSON.stringify(h.lookupTerms())), ['世界', '世界'],
    '弹窗已关，同一个词必须能再查');
  assert.ok(h.popupOpen());
  assert.strictEqual(h.video.pauseCount, 2, '再查即再暂停');
});

module.exports = { loadContent };
