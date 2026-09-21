// 视频上的自绘字幕覆盖层可从**右下角拖拽改大小**（用户 2026-09-21：「浏览器插件右下角可以做成
// 跟查词弹窗一样可以拖动大小。并且支持自适应调整缩放包括大小和可展示内容多少」）。
//
// 本测试在受控 vm 里真加载 content.js + subtitle-panel.js，向把手派发 pointer 事件，钉住：
//   ① 覆盖层带一枚右下角把手（class + i18n title），且**不带文本节点**（取词遍历不能把它当正文）。
//   ② 拖把手 = 改尺寸：底板宽高按视频盒百分比写进 subtitleStyle（与 options 两根滑杆同一份真相源），
//      同时把位置写成「左上角钉在原处」——右下角跟手是这类把手唯一不别扭的手感。
//   ③ 拖拽越界被夹进滑杆同一组上下限；拖得再小也只落到下限，绝不翻成「随内容」那个 0。
//   ④ pointercancel 丢弃整次拖拽，一个键都不写；拖完紧随其后的合成 click 不查词。
//   ⑤ 触屏按在把手上是改尺寸，不是把整块字幕拖走。
//   ⑥ 双击把手 = 底板回「随内容」。
//   ⑦ 自适应缩放：底板有高度时覆盖层根上写 --fushi-sub-fit；关掉开关即交还 CSS。
const test = require('node:test');
const assert = require('node:assert');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT(); // 文案走 i18n：壳里装 zh-CN 字典
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');
const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const STYLE = path.join(__dirname, 'subtitle-style.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const OVERLAY_ID = 'fushi-subtitle-overlay';

// 视频盒与默认落点（subtitle-panel 的 OVERLAY_POS_DEFAULT = 居中、底锚 88%）。
const VIDEO = { left: 100, top: 50, width: 1280, height: 720 };
// 没设底板尺寸时覆盖层的「随内容」实测尺寸（壳里给一个固定值，够算左上角即可）。
const AUTO_W = 300;
const AUTO_H = 44;

function makeEl(tag) {
  const listeners = Object.create(null);
  const attrs = Object.create(null);
  const props = new Map(); // setProperty 写进来的 CSS 变量（--fushi-sub-fit 等）
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    textContent: '',
    style: {
      cssText: '',
      setProperty(k, v) { props.set(k, v); },
      removeProperty(k) { props.delete(k); },
      getPropertyValue: (k) => (props.has(k) ? props.get(k) : ''),
    },
    cssProps: props,
    dataset: {},
    children: [],
    parentNode: null,
    offsetHeight: AUTO_H,
    clientWidth: AUTO_W,
    setAttribute(k, v) { if (k === 'id') el._id = v; attrs[k] = String(v); },
    removeAttribute(k) { delete attrs[k]; },
    getAttribute(k) { return k in attrs ? attrs[k] : null; },
    hasAttribute(k) { return k in attrs; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener(type, fn) {
      const l = listeners[type] || [];
      const i = l.indexOf(fn);
      if (i >= 0) l.splice(i, 1);
    },
    dispatch(type, ev) {
      const e = Object.assign({
        type, stopPropagation() {}, preventDefault() {}, stopImmediatePropagation() {},
      }, ev || {});
      for (const fn of (listeners[type] || []).slice()) fn(e);
      return e;
    },
    setPointerCapture() {},
    releasePointerCapture() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    closest(sel) {
      let node = el;
      while (node) {
        if (sel === '.' + node.className || sel === '#' + node._id) return node;
        node = node.parentNode;
      }
      return null;
    },
    getBoundingClientRect() {
      return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findById(root, id) {
  if (root._id === id) return root;
  for (const c of root.children) {
    const hit = findById(c, id);
    if (hit) return hit;
  }
  return null;
}

function rectOf(left, top, width, height) {
  return { x: left, y: top, left, top, right: left + width, bottom: top + height, width, height };
}

function loadWorld(prefs) {
  const head = makeEl('head');
  const body = makeEl('body');
  const html = makeEl('html');
  html.appendChild(head);
  html.appendChild(body);
  const stored = Object.assign(
    { netflixSubtitlePanel: true, subtitleOverlayAllTracks: true }, prefs || {});
  const changeListeners = [];
  const intervals = [];
  const winListeners = Object.create(null);
  const lookups = [];
  const video = {
    currentTime: 0, paused: false, playbackRate: 1, textTracks: [],
    rect: rectOf(VIDEO.left, VIDEO.top, VIDEO.width, VIDEO.height),
    getBoundingClientRect() { return video.rect; },
  };

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    requestAnimationFrame: () => 0,
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: {
      hostname: 'www.youtube.com',
      href: 'https://www.youtube.com/watch?v=abc123',
      pathname: '/watch',
      search: '?v=abc123',
    },
  };
  sandbox.document = {
    documentElement: html,
    head,
    body,
    fullscreenElement: null,
    addEventListener() {},
    getElementById: (id) => findById(html, id),
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: () => [],
    // 真浏览器里 createElement 出来的节点都带 ownerDocument；自适应缩放要经它拿 getComputedStyle。
    createElement: (tag) => {
      const e = makeEl(tag);
      e.ownerDocument = sandbox.document;
      return e;
    },
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      getURL: (rel) => `chrome-extension://test-ext-id/${rel}`,
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage() {},
    },
    storage: {
      local: {
        get: (keys, cb) => {
          const out = {};
          for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
          if (cb) { cb(out); return undefined; }
          return { then: (fn) => { fn(out); return { catch() {} }; }, catch() {} };
        },
        set: (patch, cb) => {
          const changes = {};
          for (const k of Object.keys(patch)) {
            changes[k] = { oldValue: stored[k], newValue: patch[k] };
            stored[k] = patch[k];
          }
          for (const fn of changeListeners) fn(changes, 'local');
          if (cb) cb();
          return Promise.resolve();
        },
        remove: (keys) => {
          const changes = {};
          for (const k of [].concat(keys)) {
            changes[k] = { oldValue: stored[k] };
            delete stored[k];
          }
          for (const fn of changeListeners) fn(changes, 'local');
          return Promise.resolve();
        },
      },
      onChanged: { addListener: (fn) => changeListeners.push(fn) },
    },
  };
  sandbox.window = {
    fushiT: FUSHI_T,
    addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
    removeEventListener(type, fn) {
      const l = winListeners[type] || [];
      const i = l.indexOf(fn);
      if (i >= 0) l.splice(i, 1);
    },
    postMessage() {},
    innerWidth: 1600,
    innerHeight: 900,
    matchMedia: () => ({ matches: false }),
    getSelection: () => ({ removeAllRanges() {} }),
    // 底板内边距按 CSS 默认（6px 12px 7px）；自适应缩放要从盒尺寸里扣掉它。
    getComputedStyle: () => ({
      paddingTop: '6px', paddingBottom: '7px', paddingLeft: '12px', paddingRight: '12px',
      getPropertyValue: () => '',
    }),
    fushiSelection: {
      getCharacterAtPoint: () => null,
      selectFromPosition: () => '',
      clearSelection() {},
    },
  };
  sandbox.document.defaultView = sandbox.window;
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  sandbox.globalThis = sandbox;
  sandbox.navigator = { clipboard: { writeText: () => Promise.resolve() } };

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(STYLE, 'utf8'), sandbox, { filename: 'subtitle-style.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  vm.runInContext(fs.readFileSync(PANEL, 'utf8'), sandbox, { filename: 'subtitle-panel.js' });
  sandbox.window.fushiLookupAtPoint = (x, y, cue) => { lookups.push({ x, y, cue }); };

  const tick = () => { for (const it of intervals) if (it.ms === 200) it.fn(); };
  const overlayEl = () => findById(html, OVERLAY_ID);
  const childBy = (cls) => {
    const el = overlayEl();
    return el && el.children.find((c) => c.className === cls);
  };
  const resizeEl = () => childBy('fushi-subtitle-overlay-resize');
  const textEl = () => childBy('fushi-subtitle-overlay-text');
  const setTrack = (lang, cues) => {
    const key = 'yt-abc123|' + lang;
    sandbox.window.fushiEpisodeCues[key] = cues;
    sandbox.window.fushiSubtitlePanelOnCues(key);
  };
  const winDispatch = (type, ev) => {
    const e = Object.assign({ type, preventDefault() {}, stopPropagation() {} }, ev || {});
    for (const fn of (winListeners[type] || []).slice()) fn(e);
  };

  // 覆盖层的实测矩形：锚点是「水平中心 + 底边」，尺寸取 placeOverlay/applyBox 写进 style 的值
  // （没写 = 随内容，用壳里的固定值）。真浏览器由排版给出，这里按同一套锚点约定算。
  const installOverlayRect = () => {
    const el = overlayEl();
    if (!el || el.__rectHooked) return el;
    el.__rectHooked = true;
    el.getBoundingClientRect = () => {
      const w = parseFloat(el.style.width) || AUTO_W;
      const h = parseFloat(el.style.minHeight) || AUTO_H;
      const cx = parseFloat(el.style.left) || 0;
      const by = parseFloat(el.style.top) || 0;
      return rectOf(cx - w / 2, by - h, w, h);
    };
    // 文字层的实测尺寸：字号 = 30 × fit，一行装 floor(可用宽 / 字号) 个字。
    const text = textEl();
    const fit = () => parseFloat(el.style.getPropertyValue('--fushi-sub-fit') || '1') || 1;
    Object.defineProperty(text, 'scrollHeight', {
      configurable: true,
      get() {
        const font = 30 * fit();
        const availW = Math.max(1, (parseFloat(el.style.width) || AUTO_W) - 24);
        const perLine = Math.max(1, Math.floor(availW / font));
        const chars = (text.textContent || '').length || 12;
        return Math.ceil(chars / perLine) * font * 1.45;
      },
    });
    Object.defineProperty(text, 'scrollWidth', {
      configurable: true,
      get() { return Math.min(((text.textContent || '').length || 12) * 30 * fit(), AUTO_W); },
    });
    return el;
  };

  // 从右下角把手拖到 (to.x, to.y)。start 省略时从把手当前所在的右下角起手。
  const resizeDrag = (to, opts) => {
    const el = installOverlayRect();
    const box = el.getBoundingClientRect();
    const id = (opts && opts.pointerId) || 9;
    const type = (opts && opts.pointerType) || 'mouse';
    const target = resizeEl();
    const down = { pointerId: id, button: 0, clientX: box.right, clientY: box.bottom, target, pointerType: type };
    if (opts && opts.viaRoot) el.dispatch('pointerdown', down);
    target.dispatch('pointerdown', down);
    // nudge：只在按下点附近挪一点点（阈值门用例），不走到 to。
    if (opts && opts.nudge) {
      winDispatch('pointermove', {
        pointerId: id,
        clientX: box.right + opts.nudge.dx,
        clientY: box.bottom + opts.nudge.dy,
      });
      winDispatch('pointerup', {
        pointerId: id,
        clientX: box.right + opts.nudge.dx,
        clientY: box.bottom + opts.nudge.dy,
      });
      const settled = overlayEl() || el;
      settled.dispatch('click', { clientX: box.right, clientY: box.bottom, target: settled });
      return box;
    }
    winDispatch('pointermove', { pointerId: id, clientX: to.x, clientY: to.y });
    if (opts && opts.cancel) winDispatch('pointercancel', { pointerId: id });
    else winDispatch('pointerup', { pointerId: id, clientX: to.x, clientY: to.y });
    const after = overlayEl() || el;
    after.dispatch('click', { clientX: to.x, clientY: to.y, target: after });
    return box;
  };

  return {
    sandbox, stored, tick, overlayEl, resizeEl, textEl, setTrack, video,
    resizeDrag, installOverlayRect, lookups, winListeners,
  };
}

const CUES = [
  { startMs: 0, endMs: 3000, text: '今日はいい天気ですね' },
  { startMs: 3000, endMs: 6000, text: '大丈夫だ' },
];

function show(prefs) {
  const w = loadWorld(prefs);
  w.setTrack('ja', CUES);
  w.tick();
  w.installOverlayRect();
  return w;
}

// 覆盖层左上角在视频里的分数坐标（拖拽把手时必须钉住不动）。
function topLeftOf(w) {
  const el = w.overlayEl();
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top };
}

test('覆盖层带右下角缩放把手：i18n title、无文本节点、与拖柄是两枚不同把手', () => {
  const w = show();
  const el = w.overlayEl();
  const resize = w.resizeEl();
  assert.ok(resize, '覆盖层应有 .fushi-subtitle-overlay-resize');
  assert.strictEqual(resize.getAttribute('title'), FUSHI_T('overlay_resize_title'));
  assert.strictEqual(resize.getAttribute('aria-hidden'), 'true');
  // 把手靠 CSS ::before 画图形：带上文本节点的话 content.js 取词兜底会把它当正文取进去。
  assert.strictEqual(resize.textContent, '');
  assert.strictEqual(resize.children.length, 0);
  const grip = el.children.find((c) => c.className === 'fushi-subtitle-overlay-grip');
  assert.ok(grip && grip !== resize, '挪位拖柄与缩放把手各自独立');
});

test('拖把手 = 改尺寸：底板宽高按视频盒百分比落进 subtitleStyle，左上角钉在原处', () => {
  const w = show();
  const before = topLeftOf(w);
  w.resizeDrag({ x: 1000, y: 700 });

  const style = w.stored.subtitleStyle;
  assert.ok(style, '必须落盘到 subtitleStyle（与 options 滑杆同一份真相源）');
  // 宽 = 指针 x - 左缘，高 = 指针 y - 上缘，各自折成视频盒百分比。
  assert.strictEqual(style.boxWidth, Math.floor((1000 - before.left) / VIDEO.width * 100));
  assert.strictEqual(style.boxHeight, Math.floor((700 - before.top) / VIDEO.height * 100));
  // 位置随之改写，使左上角仍停在原处（右下角跟手）。
  const pos = w.stored.subtitleOverlayPosition;
  assert.ok(pos && isFinite(pos.x) && isFinite(pos.y));
  const after = topLeftOf(w);
  assert.ok(Math.abs(after.left - before.left) <= 1, '左缘钉住，实得 ' + after.left + ' vs ' + before.left);
  assert.ok(Math.abs(after.top - before.top) <= 1, '上缘钉住，实得 ' + after.top + ' vs ' + before.top);
  // 底板真的按新尺寸落到了 style 上。
  const el = w.overlayEl();
  assert.strictEqual(parseFloat(el.style.width), Math.round(VIDEO.width * style.boxWidth / 100));
  assert.strictEqual(parseFloat(el.style.minHeight), Math.round(VIDEO.height * style.boxHeight / 100));
  // 拖完那一下的合成 click 不是查词。
  assert.strictEqual(w.lookups.length, 0);
  // 再点一次照常查词（吞掉的只是拖拽尾巴那一次）。
  w.overlayEl().dispatch('click', { clientX: 700, clientY: 660, target: w.textEl() });
  assert.strictEqual(w.lookups.length, 1);
});

test('拖出画面被夹回视频盒内；顶到百分比上限就停在上限', () => {
  // ① 从默认落点（居中、底锚 88%）往右下角狂拖：底板不许探出视频盒。
  const w = show();
  w.resizeDrag({ x: 5000, y: 5000 });
  const el = w.overlayEl();
  const r = el.getBoundingClientRect();
  assert.ok(r.right <= VIDEO.left + VIDEO.width + 1, '右缘不出视频盒，实得 ' + r.right);
  assert.ok(r.bottom <= VIDEO.top + VIDEO.height + 1, '下缘不出视频盒，实得 ' + r.bottom);

  // ② 先把字幕挪到左上角再狂拖：这次真的顶到百分比上限（宽 100% / 高 60%）。
  const corner = show({ subtitleOverlayPosition: { x: 0.05, y: 0.2 } });
  corner.resizeDrag({ x: 5000, y: 5000 });
  assert.strictEqual(corner.stored.subtitleStyle.boxWidth, 100);
  assert.strictEqual(corner.stored.subtitleStyle.boxHeight, 60);

  // ③ 反方向拖到负坐标：只落到下限，绝不翻成「随内容」那个 0。
  const small = show();
  small.resizeDrag({ x: -500, y: -500 });
  assert.strictEqual(small.stored.subtitleStyle.boxWidth, 20, '宽下限 20%');
  assert.strictEqual(small.stored.subtitleStyle.boxHeight, 5, '高下限 5%（不是 0 = 随内容）');
});

test('按住把手几乎没动就松手：一个键都不写（点一下不该把「随内容」变成固定尺寸）', () => {
  const w = show();
  const before = JSON.stringify(w.stored);
  // 阈值内的微动：鼠标 1px 抖、触屏双击复位时每一次按下都长这样。
  w.resizeDrag({ x: 0, y: 0 }, { nudge: { dx: 2, dy: 2 } });
  assert.strictEqual(JSON.stringify(w.stored), before, '既不写 subtitleStyle 也不写位置');
  assert.strictEqual(
    w.overlayEl().getAttribute('data-resizing'),
    null,
    '没过阈值就不该进入拖拽态',
  );
});

test('pointercancel 丢弃整次缩放：不写尺寸、不写位置', () => {
  const w = show();
  w.resizeDrag({ x: 1000, y: 700 }, { cancel: true });
  assert.strictEqual(w.stored.subtitleStyle, undefined);
  assert.strictEqual(w.stored.subtitleOverlayPosition, undefined);
});

test('触屏按在把手上是改尺寸，不是把整块字幕拖走', () => {
  const w = show();
  const before = topLeftOf(w);
  // viaRoot：真浏览器里 pointerdown 会先冒泡到覆盖层根（触屏那条路径整块可拖），
  // 根必须让开，否则把手在触屏上永远只会把字幕拖走。
  w.resizeDrag({ x: 1000, y: 700 }, { pointerType: 'touch', viaRoot: true });
  assert.ok(w.stored.subtitleStyle, '触屏也应写出尺寸');
  const after = topLeftOf(w);
  assert.ok(Math.abs(after.left - before.left) <= 1, '左缘仍钉住（不是整块跟着手指跑）');
  assert.ok(Math.abs(after.top - before.top) <= 1);
});

test('双击把手：底板回到「随内容」', () => {
  const w = show({ subtitleStyle: { boxWidth: 60, boxHeight: 20 } });
  w.resizeEl().dispatch('dblclick', { target: w.resizeEl() });
  const style = w.stored.subtitleStyle;
  // 整份回到默认时按约定删键（不留等值副本）。
  assert.ok(!style || (style.boxWidth === 0 && style.boxHeight === 0));
  w.tick();
  const el = w.overlayEl();
  assert.strictEqual(el.style.width, '', '随内容：交还 CSS');
  assert.strictEqual(el.style.minHeight, '');
  assert.strictEqual(el.style.getPropertyValue('--fushi-sub-fit'), '', '自适应倍率一并交还');
});

test('自适应缩放：底板有高度就按实测内容写 --fushi-sub-fit；关掉开关即交还 CSS', () => {
  const w = show();
  const el = w.overlayEl();
  // 壳里的实测尺寸是在覆盖层建出来之后才挂上的，所以经设置变更触发一次重算
  // （这条路径本身也是真路径：用户在设置页调完底板大小，覆盖层当场重新自适应）。
  // 底板 30% 宽 × 6% 高 = 384 × 43px：整句在默认字号下放不下 → 必须缩小。
  w.sandbox.chrome.storage.local.set({ subtitleStyle: { boxWidth: 30, boxHeight: 6 } });
  w.tick();
  const fit = parseFloat(el.style.getPropertyValue('--fushi-sub-fit'));
  assert.ok(fit > 0 && fit < 1, '长句应缩小，实得 ' + el.style.getPropertyValue('--fushi-sub-fit'));
  assert.ok(w.textEl().scrollHeight <= 43 - 13 + 0.5, '收手时整句真的放得下（扣掉上下内边距 13）');

  // 底板拉大一倍（40% 高 = 288px）：同一句话的字跟着变大 = 「大小随盒自适应」。
  w.sandbox.chrome.storage.local.set({ subtitleStyle: { boxWidth: 60, boxHeight: 40 } });
  w.tick();
  const bigger = parseFloat(el.style.getPropertyValue('--fushi-sub-fit'));
  assert.ok(bigger > fit, '底板越大字越大：' + bigger + ' 应 > ' + fit);

  // 关掉自适应（设置页开关）→ 倍率交还 CSS，字号回到用户设的「大小」。
  w.sandbox.chrome.storage.local.set({ subtitleStyle: { boxWidth: 60, boxHeight: 40, boxAutoFit: false } });
  w.tick();
  assert.strictEqual(el.style.getPropertyValue('--fushi-sub-fit'), '');
});
