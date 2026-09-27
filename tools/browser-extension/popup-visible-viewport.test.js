const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-2734：app 内查词框让 WebView 按外壳**最大**高度布局、外壳只做裁剪（内容增减不再
// 改原生表面尺寸），于是 window.innerHeight 大于用户看得见的高度。宿主经
// __fushiSetVisibleViewportHeight 注入可见高度，按钮提示 / 图片灯箱据此定位；内容在两次
// 渲染之间变高时要复报给宿主，否则多出的部分落进被裁掉、且滚不到的区域。
//
// 与 grammar-tooltip-single-surface.test.js 同一套做法：把 popup.js 的真源码切片丢进 vm
// 执行，切片锚点都断言过，源码重排会让本测试红而不是静默失效。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');
const SRC = fs.readFileSync(POPUP, 'utf8');

function sliceBetween(startAnchor, endAnchor) {
  const start = SRC.indexOf(startAnchor);
  assert.ok(start >= 0, `切片锚失效：找不到 ${startAnchor}`);
  const end = SRC.indexOf(endAnchor, start + startAnchor.length);
  assert.ok(end > start, `切片锚失效：找不到 ${endAnchor}`);
  return SRC.slice(start, end);
}

function sliceFunction(header) {
  const start = SRC.indexOf(header);
  assert.ok(start >= 0, `切片锚失效：找不到 ${header}`);
  const end = SRC.indexOf('\n}\n', start);
  assert.ok(end > start, `切片锚失效：${header} 没有收尾`);
  return SRC.slice(start, end + 3);
}

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    style: {},
    textContent: '',
    children: [],
    dataset: {},
    isConnected: true,
    _attrs: {},
    _listeners: {},
    _rect: null,
    setAttribute(k, v) { el._attrs[k] = String(v); },
    addEventListener(type, fn) { (el._listeners[type] ||= []).push(fn); },
    appendChild(child) { el.children.push(child); return child; },
    remove() { el.isConnected = false; },
    querySelector() { return null; },
    getBoundingClientRect() {
      return el._rect || { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
  };
  el.classList = {
    add(c) { el.className = (el.className + ' ' + c).trim(); },
    remove(c) { el.className = el.className.split(/\s+/).filter((x) => x && x !== c).join(' '); },
  };
  return el;
}

function load({ innerHeight = 450, visibleHeight, zoom = 1, tipSize } = {}) {
  const root = makeEl('div');
  const calls = [];
  const observers = [];
  const frames = [];
  const ctx = {
    console,
    Math,
    Number,
    isFinite,
    document: {
      createElement: (t) => makeEl(t),
      body: root,
      documentElement: { clientHeight: innerHeight, style: { zoom: String(zoom) } },
    },
    window: {
      innerHeight,
      __fushiVisibleViewportHeight: visibleHeight,
      flutter_inappwebview: { callHandler: (...args) => { calls.push(args); } },
    },
    // 真浏览器的 rAF 是异步的：排队，测试里显式冲帧（同步回调会让「句柄先清零、
    // 返回值再写回」的顺序颠倒，测出替身自己的 bug）。
    requestAnimationFrame: (cb) => { frames.push(cb); return frames.length; },
    setTimeout: () => 1,
    clearTimeout: () => {},
    ResizeObserver: class {
      constructor(cb) { this.cb = cb; this.targets = []; observers.push(this); }
      observe(t) { this.targets.push(t); }
    },
    __fushiOverlayParent: () => root,
    __fushiRootNode: () => root,
    __fushiContainer: () => null,
    __fushiViewportWidth: () => 800,
    __fushiPopupContentZoom: () => zoom,
    __contentHeight: 300,
    el(tag, props = {}) {
      const node = makeEl(tag);
      Object.assign(node, props);
      if (tipSize && String(props.className).includes('fushi-btn-tip')) {
        node._rect = { left: 0, top: 0, right: tipSize.width, bottom: tipSize.height, ...tipSize };
      }
      return node;
    },
  };
  ctx.__fushiReportedContentHeight = () => ctx.__contentHeight;
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  const code = [
    sliceFunction('function __fushiVisibleViewportHeight(){'),
    sliceFunction('function closeImageLightbox() {'),
    sliceFunction('function openImageLightbox(imageUrl, alt) {'),
    sliceBetween('let __fushiBtnTipEl = null;', 'function __fushiHideButtonTip() {'),
    sliceBetween('var __fushiContentResizeObserver = null;', '// popupRendered 的 args[0]'),
  ].join('\n');
  // 切片里的 let / function 声明在 vm 里要能从外面读到，统一挂到 globalThis 上。
  vm.runInContext(code + '\nglobalThis.__exports = { __fushiShowButtonTip, openImageLightbox };', ctx);
  const flushFrames = () => { while (frames.length) frames.shift()(0); };
  return { ctx, root, calls, observers, flushFrames };
}

test('按钮提示：外壳被收矮时下方放不下就翻到按钮上方，而不是落进裁掉的区域', () => {
  const env = load({ innerHeight: 450, visibleHeight: 150, tipSize: { width: 80, height: 30 } });
  const button = makeEl('button');
  button.dataset.fushiTip = '收藏';
  button._rect = { left: 100, top: 110, right: 130, bottom: 130, width: 30, height: 20 };

  env.ctx.__exports.__fushiShowButtonTip(button);

  const tip = env.root.children.find((c) => String(c.className).includes('fushi-btn-tip'));
  const top = parseFloat(tip.style.top);
  assert.strictEqual(top, 110 - 30 - 6, '下方 136..166 越过可见区 150，应翻到上方');
});

test('按钮提示：未注入可见高度时照旧按 innerHeight（下方放得下）', () => {
  const env = load({ innerHeight: 450, tipSize: { width: 80, height: 30 } });
  const button = makeEl('button');
  button.dataset.fushiTip = '收藏';
  button._rect = { left: 100, top: 110, right: 130, bottom: 130, width: 30, height: 20 };

  env.ctx.__exports.__fushiShowButtonTip(button);

  const tip = env.root.children.find((c) => String(c.className).includes('fushi-btn-tip'));
  assert.strictEqual(tip.style.top, '136px');
});

test('图片灯箱：外壳被收矮时收进可见高度（style 按内容 zoom 折回 layout px）', () => {
  const env = load({ innerHeight: 450, visibleHeight: 150, zoom: 2 });
  env.ctx.__exports.openImageLightbox('x.png', '');
  const overlay = env.root.children.find((c) => c.className === 'dict-image-lightbox');
  assert.ok(overlay, '灯箱应挂上');
  assert.strictEqual(overlay.style.bottom, 'auto');
  assert.strictEqual(overlay.style.height, (150 / 2) + 'px');
});

test('图片灯箱：未注入可见高度时保持 inset:0 铺满（不写 height）', () => {
  const env = load({ innerHeight: 450 });
  env.ctx.__exports.openImageLightbox('x.png', '');
  const overlay = env.root.children.find((c) => c.className === 'dict-image-lightbox');
  assert.strictEqual(overlay.style.height, undefined);
  assert.strictEqual(overlay.style.bottom, undefined);
});

test('注入可见高度即开始观察内容尺寸，变化才复报 popupContentResized', () => {
  const env = load({ innerHeight: 450 });
  assert.strictEqual(env.observers.length, 0, '没注入前不装观察器（扩展 / 其它宿主零开销）');

  env.ctx.window.__fushiSetVisibleViewportHeight(150);
  assert.strictEqual(env.ctx.window.__fushiVisibleViewportHeight, 150);
  assert.strictEqual(env.observers.length, 1);
  assert.strictEqual(env.observers[0].targets[0], env.root, '无 #entries-container 时回落 body');

  env.observers[0].cb([]);
  env.observers[0].cb([]);
  env.flushFrames();
  assert.deepStrictEqual(env.calls, [['popupContentResized', 300, 450]],
    '同一帧内多次尺寸变化合并成一次复报');

  env.observers[0].cb([]);
  env.flushFrames();
  assert.strictEqual(env.calls.length, 1, '高度没变不重复复报');

  env.ctx.__contentHeight = 420;
  env.observers[0].cb([]);
  env.flushFrames();
  assert.deepStrictEqual(env.calls[1], ['popupContentResized', 420, 450]);

  env.ctx.window.__fushiSetVisibleViewportHeight(200);
  assert.strictEqual(env.observers.length, 1, '观察器只装一次');
});

test('注入 null 撤销可见高度，回到 innerHeight', () => {
  const env = load({ innerHeight: 450 });
  env.ctx.window.__fushiSetVisibleViewportHeight(150);
  env.ctx.window.__fushiSetVisibleViewportHeight(null);
  assert.strictEqual(env.ctx.window.__fushiVisibleViewportHeight, null);
  assert.strictEqual(env.ctx.__fushiVisibleViewportHeight(), 450);
});
