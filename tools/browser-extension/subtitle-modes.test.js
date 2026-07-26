const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// asb 移植行为守卫：全轨读取侧偏移 / 句首自动暂停 / 快进无字幕段 / 悬停暂停 / 防剧透模糊 /
// 全轨覆盖层 / 快捷键执行端（window.hibikiSubtitleShortcut）。
// 在受控 vm 里真加载 subtitle-panel.js，store 预置「检测轨」（非外挂），驱动 200ms tick。

const PANEL = path.join(__dirname, 'subtitle-panel.js');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '', _attrs: {}, className: '', value: '', title: '', type: '',
    accept: '', files: null, children: [], parentNode: null, handlers: {},
    style: { _props: {}, setProperty(k, v) { this._props[k] = v; }, getPropertyValue(k) { return this._props[k] || ''; } },
    setAttribute(k, v) { el._attrs[k] = String(v); if (k === 'id') el._id = String(v); },
    getAttribute(k) { return k in el._attrs ? el._attrs[k] : null; },
    addEventListener(t, fn) { (el.handlers[t] = el.handlers[t] || []).push(fn); },
    fire(t, ev) { for (const fn of el.handlers[t] || []) fn(ev || { stopPropagation() {} }); },
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = el; el.children.push(child); return child;
    },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null; return child;
    },
    scrollIntoView() {},
    click() {},
  };
  el.classList = {
    _set: new Set(), add(c) { el.classList._set.add(c); }, remove(c) { el.classList._set.delete(c); },
    toggle(c, on) { on ? el.classList._set.add(c) : el.classList._set.delete(c); }, contains(c) { return el.classList._set.has(c); },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; el._attrs.id = v; } });
  let text = '';
  Object.defineProperty(el, 'textContent', { get: () => text, set: (v) => { text = v; if (v === '') el.children.length = 0; } });
  return el;
}

function findByIdDeep(el, id) {
  if (el._id === id) return el;
  for (const c of el.children || []) { const hit = findByIdDeep(c, id); if (hit) return hit; }
  return null;
}
function findByClassDeep(el, cls, out) {
  out = out || [];
  if (el.className === cls) out.push(el);
  for (const c of el.children || []) findByClassDeep(c, cls, out);
  return out;
}
function findBtnByTitle(el, kw, out) {
  out = out || [];
  if (el.tagName === 'BUTTON' && String(el.title || '').indexOf(kw) >= 0) out.push(el);
  for (const c of el.children || []) findBtnByTitle(c, kw, out);
  return out;
}

function loadPanel(opts) {
  opts = opts || {};
  const src = fs.readFileSync(PANEL, 'utf8');
  const body = makeEl('body');
  const video = {
    currentTime: 0,
    paused: false,
    playbackRate: 1,
    pauseCount: 0,
    playCount: 0,
    pause() { this.paused = true; this.pauseCount++; },
    play() { this.paused = false; this.playCount++; },
    getBoundingClientRect() { return { left: 100, top: 50, width: 800, height: 450 }; },
  };
  const storageListeners = [];
  const intervals = [];
  const toasts = [];
  const storageSets = [];
  const clipboard = [];
  const windowObj = {
    hibikiEpisodeCues: opts.store || {},
    postMessage() {},
    addEventListener() {},
    hibikiToast: (m) => toasts.push(m),
  };
  const documentObj = {
    body,
    fullscreenElement: null,
    addEventListener() {},
    getElementById: (id) => findByIdDeep(body, id),
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: () => [],
    createElement: (t) => makeEl(t),
    createDocumentFragment: () => makeEl('fragment'),
  };
  const sandbox = {
    window: windowObj,
    document: documentObj,
    location: { hostname: opts.hostname || 'example.com', pathname: opts.pathname || '/video/1', origin: 'https://example.com' },
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    navigator: { clipboard: { writeText: (t) => { clipboard.push(t); return { then() {} }; } } },
    chrome: {
      storage: {
        local: {
          get: (key, cb) => { if (typeof cb === 'function') { cb(opts.stored || {}); return undefined; } return { then(res) { res(opts.stored || {}); } }; },
          set: (obj) => { storageSets.push(obj); },
        },
        onChanged: { addListener: (fn) => storageListeners.push(fn) },
      },
      runtime: { lastError: null, sendMessage() {} },
    },
  };
  vm.runInNewContext(src, sandbox, { filename: 'subtitle-panel.js' });
  return {
    body, video, windowObj, toasts, storageSets, clipboard,
    panel: () => findByIdDeep(body, 'hibiki-subtitle-panel'),
    overlay: () => findByIdDeep(body, 'hibiki-subtitle-overlay'),
    tick: () => { const t = intervals.find((it) => it.ms === 200); if (t) t.fn(); },
    shortcut: (a) => windowObj.hibikiSubtitleShortcut(a),
  };
}

// 预置「检测轨」（非外挂）：ja 轨两句 1.0–2.0s / 4.0–5.0s。
function jaStore() {
  return {
    'example.com/video/1|ja': [
      { startMs: 1000, endMs: 2000, text: '走り出した' },
      { startMs: 4000, endMs: 5000, text: 'こんにちは' },
    ],
  };
}

test('检测轨也有时轴偏移：读取侧平移，store 不动', () => {
  const h = loadPanel({ stored: { netflixSubtitlePanel: true }, store: jaStore() });
  const panel = h.panel();
  assert.ok(panel, '有轨时面板应显示');
  const offsetBar = findByClassDeep(panel, 'hibiki-sub-offset')[0];
  assert.ok(offsetBar, '检测轨也必须显示时轴偏移条（asb 全轨偏移）');
  assert.notStrictEqual(offsetBar.style._props.display, 'none');
  findBtnByTitle(offsetBar, '＋0.5')[0].fire('click');
  assert.strictEqual(h.windowObj.hibikiEpisodeCues['example.com/video/1|ja'][0].startMs, 1000,
    'store 保持原始 cue');
  const ts = findByClassDeep(h.panel(), 'hibiki-sub-ts')[0];
  ts.fire('click');
  assert.strictEqual(h.video.currentTime, 1.5, '行 seek 用偏移后的 1500ms');
});

test('句首自动暂停：新句开播即暂停一次，恢复播放后同句不再回按', () => {
  const h = loadPanel({
    stored: { netflixSubtitlePanel: true, subtitleAutoPause: true, subtitleAutoPauseAtStart: true },
    store: jaStore(),
  });
  h.video.currentTime = 1.1; // 句 1 开播 100ms（<400ms 句首窗）
  h.tick();
  assert.strictEqual(h.video.pauseCount, 1, '句首应暂停一次');
  h.video.paused = false; // 用户继续播放
  h.tick();
  assert.strictEqual(h.video.pauseCount, 1, '同句不得再次暂停');
  h.video.currentTime = 4.05; // 进句 2 句首
  h.tick();
  assert.strictEqual(h.video.pauseCount, 2, '下一句句首再暂停');
});

test('快进无字幕段：间隙 2.7x，进句恢复原速', () => {
  const h = loadPanel({
    stored: { netflixSubtitlePanel: true, subtitleFastForwardPlayback: true },
    store: jaStore(),
  });
  h.video.currentTime = 2.5; // 句 1 之后的长间隙（距句 2 还有 1.5s）
  h.tick();
  assert.strictEqual(h.video.playbackRate, 2.7, '无字幕段应提速到 2.7x');
  h.video.currentTime = 4.2; // 进句 2
  h.tick();
  assert.strictEqual(h.video.playbackRate, 1, '进句应恢复原速');
});

test('全轨覆盖层 + 防剧透模糊 + 悬停暂停', () => {
  const off = loadPanel({ stored: { netflixSubtitlePanel: true }, store: jaStore() });
  off.video.currentTime = 1.5;
  off.tick();
  assert.strictEqual(off.overlay(), null, '未开全轨覆盖层时检测轨不叠字');

  const h = loadPanel({
    stored: {
      netflixSubtitlePanel: true, subtitleOverlayAllTracks: true,
      subtitleOverlayBlur: true, subtitleHoverPause: true,
    },
    store: jaStore(),
  });
  h.video.currentTime = 1.5;
  h.tick();
  const overlay = h.overlay();
  assert.ok(overlay, '开启全轨覆盖层后检测轨应叠字');
  assert.strictEqual(overlay.textContent, '走り出した');
  assert.strictEqual(overlay.style.filter, 'blur(6px)', '防剧透默认模糊');
  overlay.fire('mouseenter');
  assert.strictEqual(overlay.style.filter, '', '悬停即清晰');
  assert.strictEqual(h.video.paused, true, '悬停暂停');
  overlay.fire('mouseleave');
  assert.strictEqual(h.video.paused, false, '移开恢复播放');
  assert.strictEqual(overlay.style.filter, 'blur(6px)', '移开重新模糊');
});

test('快捷键执行端：上一句/下一句/重播/复制/切换模式', () => {
  const h = loadPanel({ stored: { netflixSubtitlePanel: true }, store: jaStore() });
  // 下一句：0ms → 句 1 句首。
  assert.strictEqual(h.shortcut('next-cue'), true);
  assert.strictEqual(h.video.currentTime, 1);
  // 上一句：句 2 中间 → 句 1 句首（4500-600=3900 前最近句首是 1000）。
  h.video.currentTime = 4.5;
  assert.strictEqual(h.shortcut('prev-cue'), true);
  assert.strictEqual(h.video.currentTime, 1);
  // 重播本句：句内任意位置回句首。
  h.video.currentTime = 1.8;
  assert.strictEqual(h.shortcut('replay-cue'), true);
  assert.strictEqual(h.video.currentTime, 1);
  // 复制当前句到剪贴板（Hibiki 剪贴板监看联动）。
  h.video.currentTime = 1.5;
  assert.strictEqual(h.shortcut('copy-cue'), true);
  assert.deepStrictEqual(h.clipboard, ['走り出した']);
  // 切换精简播放：写穿 chrome.storage（options 页开关保持同步）。
  assert.strictEqual(h.shortcut('toggle-condensed'), true);
  assert.ok(h.storageSets.some((s) => s.subtitleCondensedPlayback === true), '必须写穿 storage');
  // 偏移快捷键：+100ms 两次 → 行 seek 用 1200ms。
  assert.strictEqual(h.shortcut('offset-plus'), true);
  assert.strictEqual(h.shortcut('offset-plus'), true);
  const ts = findByClassDeep(h.panel(), 'hibiki-sub-ts')[0];
  ts.fire('click');
  assert.strictEqual(h.video.currentTime, 1.2);
  assert.ok(h.toasts.some((t) => t.indexOf('+0.2s') >= 0), '偏移量应有 toast 反馈');
});
