const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 查词「假空态」：结果还没到时弹窗先闪一下「No results」再跳成结果。根因是宿主推的搜索期
// 占位（空结果）被 renderPopup 当成「查完了、没有词条」。现在宿主注入 window.lookupPending，
// popup.js 据此画延迟出现的加载指示器；真正查完为空才画 .no-results。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');
const SRC = fs.readFileSync(POPUP, 'utf8');

function sliceFunction(header) {
  const start = SRC.indexOf(header);
  assert.ok(start >= 0, `切片锚失效：找不到 ${header}`);
  const end = SRC.indexOf('\n}\n', start);
  assert.ok(end > start, `切片锚失效：${header} 没有收尾`);
  return SRC.slice(start, end + 3);
}

function makeClassList() {
  return {
    set: new Set(),
    add(c) { this.set.add(c); },
    remove(c) { this.set.delete(c); },
    contains(c) { return this.set.has(c); },
  };
}

function makeContainer() {
  const node = { classList: makeClassList(), isConnected: true, innerHTML: '', offsetWidth: 0 };
  return {
    innerHTML: '',
    loadingNode: node,
    querySelector(sel) { return sel === '.popup-loading' ? node : null; },
  };
}

// 运行中的 infinite 动画只来自 .popup-loading-shape：DOM（容器 + 占位盒子）里没有
// 这个元素 ⇒ 没有空转的动画。
function hasAnimatedShape(c) {
  return /popup-loading-shape/.test(c.innerHTML + c.loadingNode.innerHTML);
}

function load({ eink = false, reduced = false } = {}) {
  let timers = [];
  let now = 1000;
  const listeners = {};
  const doc = {
    visibilityState: 'visible',
    documentElement: { classList: { contains: (c) => eink && c === 'eink' } },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
  };
  const ctx = {
    Math,
    performance: { now: () => now },
    setTimeout: (fn, ms) => { const t = { fn, ms, id: timers.length + 1, live: true }; timers.push(t); return t.id; },
    clearTimeout: (id) => { const t = timers.find((x) => x.id === id); if (t) t.live = false; },
    matchMedia: () => ({ matches: reduced }),
    document: doc,
    lookupPending: true,
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  const head = SRC.slice(SRC.indexOf('const POPUP_LOADING_DELAY_MS'), SRC.indexOf('function __fushiPopupReducedMotion'));
  const tailStart = SRC.indexOf('function __fushiPopupDocumentHidden(');
  const tailEnd = SRC.indexOf('// 本次渲染要替换掉一个已露出的加载指示器');
  assert.ok(tailStart > 0 && tailEnd > tailStart, '切片锚失效：加载指示器生命周期段');
  vm.runInContext([
    head.replace(/^let /gm, 'var ').replace(/^const /gm, 'var '),
    sliceFunction('function __fushiPopupReducedMotion('),
    SRC.slice(tailStart, tailEnd),
    sliceFunction('function popupLoadingHoldRemaining('),
  ].join('\n'), ctx);
  const live = () => timers.filter((t) => t.live);
  return {
    ctx,
    live,
    advance: (ms) => { now += ms; },
    fire: () => { const ts = live(); timers = []; ts.forEach((t) => t.fn()); return ts; },
    setHidden: (hidden) => {
      doc.visibilityState = hidden ? 'hidden' : 'visible';
      (listeners.visibilitychange || []).forEach((fn) => fn());
    },
  };
}

test('初始化 / 复位的占位是不带动画的空盒子；查询中过 150ms 阈值才插入指示器', () => {
  const { ctx, live, fire } = load();
  const c = makeContainer();
  ctx.renderPopupLoading(c);
  assert.match(c.innerHTML, /class="popup-loading"/);
  assert.match(c.innerHTML, /role="status"/);
  assert.doesNotMatch(c.innerHTML, /no-results/);
  assert.ok(!hasAnimatedShape(c), '复位 / 初始化渲染后 DOM 里不得有动画元素');
  assert.ok(!c.loadingNode.classList.contains('visible'), '延迟期内不可见');
  assert.deepStrictEqual(live().map((t) => t.ms), [150]);
  fire();
  assert.match(c.loadingNode.innerHTML, /popup-loading-shape/);
  assert.doesNotMatch(c.loadingNode.innerHTML, /popup-loading-dots/, '只插入实际显示的那一种');
  assert.ok(c.loadingNode.classList.contains('visible'));
});

test('阈值前查询已结束（lookupPending 撤销）：不插入指示器', () => {
  const { ctx, fire } = load();
  const c = makeContainer();
  ctx.renderPopupLoading(c);
  ctx.lookupPending = false;
  fire();
  assert.ok(!hasAnimatedShape(c));
  assert.ok(!c.loadingNode.classList.contains('visible'));
});

test('结果换掉 DOM：指示器被摘除、露出计时作废', () => {
  const { ctx, live, fire } = load();
  const c = makeContainer();
  ctx.renderPopupLoading(c);
  fire();
  assert.ok(hasAnimatedShape(c));
  // renderPopup 换 DOM 前的收尾（与 window.renderPopup 内同一组调用）。
  ctx.__fushiUnmountPopupLoadingIndicator();
  ctx.__fushiLoadingNode = null;
  assert.ok(!hasAnimatedShape(c), '查询结束后指示器必须消失');
  assert.strictEqual(ctx.__fushiLoadingShownAt, 0);
  assert.strictEqual(live().length, 0);
});

test('文档隐藏：不插入 / 立即摘除；重新可见且仍 pending 时按阈值重新插入', () => {
  const { ctx, live, fire, setHidden } = load();
  const c = makeContainer();
  setHidden(true);
  ctx.renderPopupLoading(c);
  assert.strictEqual(live().length, 0, '隐藏文档里不排露出计时');
  setHidden(false);
  assert.deepStrictEqual(live().map((t) => t.ms), [150]);
  fire();
  assert.ok(hasAnimatedShape(c));
  setHidden(true);
  assert.ok(!hasAnimatedShape(c), '转隐藏即摘除动画元素');
  assert.ok(!c.loadingNode.classList.contains('visible'));
  assert.strictEqual(ctx.__fushiLoadingShownAt, 0, '摘除后不再拖住结果渲染');
  // 计时中途转隐藏：计时作废，阈值到也不插入。
  setHidden(false);
  setHidden(true);
  fire();
  assert.ok(!hasAnimatedShape(c));
});

test('墨水屏 / 减少动态效果：只插入静止三点，没有动画元素', () => {
  for (const opts of [{ eink: true }, { reduced: true }]) {
    const { ctx, fire } = load(opts);
    const c = makeContainer();
    ctx.renderPopupLoading(c);
    fire();
    assert.ok(c.loadingNode.classList.contains('is-static'));
    assert.match(c.loadingNode.innerHTML, /popup-loading-dots/);
    assert.ok(!hasAnimatedShape(c));
  }
});

test('最短停留：露出不足 300ms 时结果渲染要等，露出前 / 超过 300ms 不等', () => {
  const { ctx } = load();
  assert.strictEqual(ctx.popupLoadingHoldRemaining(1000, 0, 300), 0, '没露出过：立即渲染');
  assert.strictEqual(ctx.popupLoadingHoldRemaining(1100, 1000, 300), 200);
  assert.strictEqual(ctx.popupLoadingHoldRemaining(1400, 1000, 300), 0);
});

test('renderPopup：只有 lookupPending 时画加载态；真实空结果仍是 .no-results；结果替换指示器时淡入', () => {
  const body = SRC.slice(SRC.indexOf('window.renderPopup = function() {'),
    SRC.indexOf('// TODO-833: entries that the hidden-dictionary filter'));
  const pendingAt = body.indexOf("window.lookupPending === true) {\n        // 搜索期占位");
  const emptyAt = body.indexOf('<div class="no-results">');
  assert.ok(pendingAt > 0 && emptyAt > pendingAt, '加载态判定必须在 .no-results 之前');
  assert.match(body, /renderPopupLoading\(container\)/);
  assert.match(body, /popupLoadingHoldRemaining\(/);
  assert.match(body, /__fushiUnmountPopupLoadingIndicator\(\);\s+__fushiLoadingNode = null;/, '换 DOM 前必须摘除指示器');
  assert.match(body, /container\.animate\(\[\{ opacity: 0 \}, \{ opacity: 1 \}\]/);
});

test('CSS：Expressive 变形指示器 + 静止三点 + 生成物保留 keyframes', () => {
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8');
  assert.match(css, /\.popup-loading-shape\s*\{[^}]*animation: fushi-popup-loading-morph/);
  assert.match(css, /@keyframes fushi-popup-loading-morph/);
  assert.match(css, /\.popup-loading\.is-static \.popup-loading-dots\s*\{[^}]*display: flex/);
  const content = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.match(content, /@keyframes fushi-popup-loading-morph/);
});
