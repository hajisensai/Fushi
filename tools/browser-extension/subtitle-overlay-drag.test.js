// 视频上的自绘字幕覆盖层可拖动（用户诉求：字幕挡住画面/进度条时能挪开，像 asbplayer 那样）。
//
// 本测试在受控 vm 里真加载 content.js + subtitle-panel.js，向覆盖层派发 pointer 事件，钉住：
//   ① 没拖过：居中、底边锚 88%（旧行为一字不改）。
//   ② 位移小于阈值只是点击 → 仍走 fushiLookupAtPoint 查词，位置不变、不写存储。
//   ③ 过阈值 → 覆盖层跟手；松手按**视频矩形的分数坐标**写 chrome.storage.local.subtitleOverlayPosition，
//      紧随其后的合成 click 被吞掉（不查词），再下一次点击照常查词。
//   ④ 位置是分数：视频盒变化（全屏/缩放）后按新盒重算，字幕留在画面里的同一相对位置；
//      每 200ms 的 tick 重摆也不把拖动中的字幕拽回原位。
//   ⑤ 拖出视频盒被夹回盒内；pointercancel 丢弃本次拖动回到原位；options 页删键即回默认。
//   ⑥ 存储里的坏值当没拖过，绝不把 NaN 写进 style。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');
const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const OVERLAY_ID = 'fushi-subtitle-overlay';
const POS_KEY = 'subtitleOverlayPosition';

function makeEl(tag) {
  const listeners = Object.create(null);
  const attrs = Object.create(null);
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    textContent: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    offsetHeight: 40,
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
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
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

// 建一个装好 content.js + subtitle-panel.js 的世界；覆盖层用「全轨覆盖层」偏好打开，
// 这样站点检测轨也画覆盖层，不必走外挂文件导入。
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
    rect: rectOf(100, 50, 1280, 720),
    getBoundingClientRect() { return video.rect; },
  };

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
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
    createElement: (tag) => makeEl(tag),
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
        // 同步 thenable：偏好在加载期就读好（理由见 subtitle-replace-native.test.js）。
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
          // 真实 chrome：本页写 storage 也会收到自己的 onChanged。
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
    fushiSelection: {
      getCharacterAtPoint: () => null,
      selectFromPosition: () => '',
      clearSelection() {},
    },
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  sandbox.globalThis = sandbox;
  sandbox.navigator = { clipboard: { writeText: () => Promise.resolve() } };

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  vm.runInContext(fs.readFileSync(PANEL, 'utf8'), sandbox, { filename: 'subtitle-panel.js' });
  // 覆盖层点击走 window.fushiLookupAtPoint；桩掉它以观察「有没有查词」。
  sandbox.window.fushiLookupAtPoint = (x, y, cue) => { lookups.push({ x, y, cue }); };

  const tick = () => { for (const it of intervals) if (it.ms === 200) it.fn(); };
  const overlayEl = () => findById(html, OVERLAY_ID);
  const setTrack = (lang, cues) => {
    const key = 'yt-abc123|' + lang;
    sandbox.window.fushiEpisodeCues[key] = cues;
    sandbox.window.fushiSubtitlePanelOnCues(key);
  };
  // 真实浏览器：pointerdown 在元素上，move/up 由 window 监听（面板挂在 window 上）。
  const winDispatch = (type, ev) => {
    const e = Object.assign({ type, preventDefault() {}, stopPropagation() {} }, ev || {});
    for (const fn of (winListeners[type] || []).slice()) fn(e);
  };
  const drag = (from, to, opts) => {
    const el = overlayEl();
    const id = (opts && opts.pointerId) || 7;
    el.dispatch('pointerdown', { pointerId: id, button: 0, clientX: from.x, clientY: from.y });
    winDispatch('pointermove', { pointerId: id, clientX: to.x, clientY: to.y });
    if (opts && opts.cancel) winDispatch('pointercancel', { pointerId: id });
    else winDispatch('pointerup', { pointerId: id, clientX: to.x, clientY: to.y });
    // 浏览器在 pointerup 后合成 click（capture 时目标就是覆盖层本身）。
    const target = overlayEl() || el;
    target.dispatch('click', { clientX: to.x, clientY: to.y });
  };
  const geom = () => {
    const el = overlayEl();
    return { left: parseFloat(el.style.left), top: parseFloat(el.style.top) };
  };
  return { sandbox, stored, tick, overlayEl, setTrack, video, drag, geom, lookups, winListeners };
}

const CUES = [
  { startMs: 0, endMs: 3000, text: '君の名は' },
  { startMs: 3000, endMs: 6000, text: '大丈夫だ' },
];

test('没拖过：居中、底边锚 88%（旧默认不变）', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.ok(el, '全轨覆盖层开着，站点轨也要画覆盖层');
  assert.deepStrictEqual(w.geom(), { left: 100 + 640, top: 50 + 720 * 0.88 });
  assert.strictEqual(w.stored[POS_KEY], undefined, '没拖过不写存储');
});

test('位移小于阈值 = 点击：照常查词，位置不变、不写存储', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  w.drag({ x: 740, y: 680 }, { x: 743, y: 682 });
  assert.strictEqual(w.lookups.length, 1, '微抖动仍是点击，必须查词');
  assert.strictEqual(w.lookups[0].cue.text, CUES[0].text);
  assert.deepStrictEqual(w.geom(), { left: 740, top: 683.6 });
  assert.strictEqual(w.stored[POS_KEY], undefined);
  assert.ok(!w.overlayEl().hasAttribute('data-dragging'));
});

test('过阈值 = 拖动：跟手、按视频分数坐标持久化、吞掉尾随 click；下一次点击照常查词', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  // 从默认点 (740, 683.6) 拖到左上 200px / 300px。
  w.drag({ x: 740, y: 683.6 }, { x: 540, y: 383.6 });
  assert.strictEqual(w.lookups.length, 0, '拖完松手的 click 不是查词');
  const g = w.geom();
  assert.ok(Math.abs(g.left - 540) < 1e-6 && Math.abs(g.top - 383.6) < 1e-6, '覆盖层跟手落在松手处');
  const pos = w.stored[POS_KEY];
  assert.ok(pos, '松手必须持久化');
  assert.ok(Math.abs(pos.x - (540 - 100) / 1280) < 1e-9, 'x 是视频宽的分数');
  assert.ok(Math.abs(pos.y - (383.6 - 50) / 720) < 1e-9, 'y 是视频高的分数');
  assert.ok(!w.overlayEl().hasAttribute('data-dragging'), '松手后拖动态样式要撤');
  // tick 重摆不会拽回默认位。
  w.tick();
  assert.ok(Math.abs(w.geom().left - 540) < 1e-6);
  // 之后的普通点击又是查词。
  w.overlayEl().dispatch('click', { clientX: 540, clientY: 380 });
  assert.strictEqual(w.lookups.length, 1, '拖动只吞自己那一次 click');
});

test('位置是分数：视频盒变化（全屏/缩放）后按新盒重算，留在画面同一相对位置', () => {
  const w = loadWorld({ [POS_KEY]: { x: 0.25, y: 0.5 } });
  w.setTrack('ja', CUES);
  w.tick();
  assert.deepStrictEqual(w.geom(), { left: 100 + 1280 * 0.25, top: 50 + 720 * 0.5 });
  w.video.rect = rectOf(0, 0, 1600, 900); // 全屏
  w.tick();
  assert.deepStrictEqual(w.geom(), { left: 400, top: 450 });
});

test('拖动中 tick 重摆用会话里的实时位置，不把字幕拽回原位', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  el.dispatch('pointerdown', { pointerId: 3, button: 0, clientX: 740, clientY: 683.6 });
  const move = (x, y) => {
    for (const fn of (w.winListeners.pointermove || []).slice()) {
      fn({ type: 'pointermove', pointerId: 3, clientX: x, clientY: y, preventDefault() {} });
    }
  };
  move(640, 583.6);
  assert.ok(el.hasAttribute('data-dragging'), '过阈值后进入拖动态');
  assert.ok(Math.abs(w.geom().left - 640) < 1e-6);
  w.tick();
  assert.ok(Math.abs(w.geom().left - 640) < 1e-6, 'tick 不得把拖动中的字幕拽回默认位');
  assert.ok(Math.abs(w.geom().top - 583.6) < 1e-6);
  assert.strictEqual(w.stored[POS_KEY], undefined, '没松手不写存储');
});

test('拖出视频盒被夹回盒内（中心离左右缘 ≥8px，底锚在视频底缘与「块整个在视频里」之间）', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  w.drag({ x: 740, y: 683.6 }, { x: -500, y: 2000 });
  const pos = w.stored[POS_KEY];
  assert.ok(Math.abs(pos.x - 8 / 1280) < 1e-9, 'x 夹到左缘 +8px');
  assert.strictEqual(pos.y, 1, 'y 夹到视频底缘');
  const w2 = loadWorld();
  w2.setTrack('ja', CUES);
  w2.tick();
  w2.drag({ x: 740, y: 683.6 }, { x: 5000, y: -5000 });
  const pos2 = w2.stored[POS_KEY];
  assert.ok(Math.abs(pos2.x - (1280 - 8) / 1280) < 1e-9, 'x 夹到右缘 -8px');
  // 块高 40px（桩的 offsetHeight）：底锚最高只能到视频顶 +40，文本块不出画面上缘。
  assert.ok(Math.abs(pos2.y - 40 / 720) < 1e-9, 'y 夹到「块整个还在视频里」');
});

test('pointercancel 丢弃本次拖动回到原位，且不写存储、不吞下一次点击的查词', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  w.drag({ x: 740, y: 683.6 }, { x: 540, y: 383.6 }, { cancel: true });
  assert.strictEqual(w.stored[POS_KEY], undefined);
  assert.deepStrictEqual(w.geom(), { left: 740, top: 683.6 }, '取消后回默认位');
  assert.strictEqual(w.lookups.length, 0, '取消后紧随的合成 click 同样不查词（那次按下确实拖过）');
  w.overlayEl().dispatch('click', { clientX: 740, clientY: 680 });
  assert.strictEqual(w.lookups.length, 1);
});

test('options 页「重置位置」删键 → 已打开的视频页立刻回默认', () => {
  const w = loadWorld({ [POS_KEY]: { x: 0.25, y: 0.5 } });
  w.setTrack('ja', CUES);
  w.tick();
  assert.deepStrictEqual(w.geom(), { left: 420, top: 410 });
  w.sandbox.chrome.storage.local.remove(POS_KEY);
  assert.deepStrictEqual(w.geom(), { left: 740, top: 683.6 }, '不等 tick 就重摆');
});

test('另一标签页拖过（storage.onChanged 带新位置）→ 本页同步跟随', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  w.sandbox.chrome.storage.local.set({ [POS_KEY]: { x: 0.5, y: 0.2 } });
  assert.deepStrictEqual(w.geom(), { left: 740, top: 50 + 720 * 0.2 });
});

test('存储里的坏值当没拖过：不把 NaN 写进 style', () => {
  for (const bad of [{ x: 'a', y: 0.5 }, { x: NaN, y: 0.1 }, 'nope', 42, null, { x: 5, y: -3 }]) {
    const w = loadWorld({ [POS_KEY]: bad });
    w.setTrack('ja', CUES);
    w.tick();
    const g = w.geom();
    assert.ok(Number.isFinite(g.left) && Number.isFinite(g.top), `坏值 ${JSON.stringify(bad)} 不得产出 NaN`);
  }
  // 越界的数值被夹进 [0,1]，而不是丢弃。
  const w = loadWorld({ [POS_KEY]: { x: 5, y: -3 } });
  w.setTrack('ja', CUES);
  w.tick();
  assert.deepStrictEqual(w.geom(), { left: 100 + 1280, top: 50 });
});

test('拖动中不触发悬浮字幕自动查词', () => {
  const w = loadWorld({ subtitleOverlayAutoLookup: true });
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  el.dispatch('mousemove', { clientX: 700, clientY: 680 });
  assert.strictEqual(w.lookups.length, 1, '未拖动时悬停自动查词照常');
  el.dispatch('pointerdown', { pointerId: 9, button: 0, clientX: 740, clientY: 683.6 });
  for (const fn of (w.winListeners.pointermove || []).slice()) {
    fn({ type: 'pointermove', pointerId: 9, clientX: 640, clientY: 583.6, preventDefault() {} });
  }
  el.dispatch('mousemove', { clientX: 600, clientY: 560 });
  assert.strictEqual(w.lookups.length, 1, '拖动中划过的词不查');
});

test('CSS：拖动态抓手 + 禁选区、覆盖层 touch-action:none（触屏拖字幕不被滚页抢走）', () => {
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.match(css, /#fushi-subtitle-overlay\[data-dragging\]\s*\{[^}]*cursor:\s*grabbing/);
  assert.match(css, /#fushi-subtitle-overlay\[data-dragging\]\s*\{[^}]*user-select:\s*none/);
  assert.match(css, /#fushi-subtitle-overlay\s*\{[^}]*touch-action:\s*none/);
});

test('options 页有「重置位置」按钮且 options.js 删的是同一把键', () => {
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  const js = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  assert.match(html, /id="resetSubtitleOverlayPosition"/);
  assert.match(js, /on\('resetSubtitleOverlayPosition',\s*'click'/);
  assert.match(js, /chrome\.storage\.local\.remove\('subtitleOverlayPosition'\)/);
});
