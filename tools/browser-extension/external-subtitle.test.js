const { test } = require('node:test');
const assert = require('node:assert');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT(); // 文案走 i18n：壳里装 zh-CN 字典
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// B（asb 招牌）行为守卫：面板加载用户外挂字幕文件 + 时轴偏移。
// 在受控 vm 里真加载 subtitle-panel.js，桩掉 file input / FileReader / chrome.runtime.sendMessage，
// 驱动完整加载流，断言：
//   ① 选文件 → 经 server 解析 → 外挂轨写进 fushiEpisodeCues 并成为面板当前轨；
//   ② 时轴偏移 nudge：整轨 cue 时间随偏移平移（对齐视频）；
//   ③ 不支持格式 → 提示、不造轨。

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
    click() { /* file input：真实点击打开对话框；测试里由外部手动喂 files + 触发 change */ },
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


// 覆盖层根下有「文字层 + 拖柄」两个子节点，正文在 .fushi-subtitle-overlay-text 里。
function overlayText(el) {
  const text = el && el.children && el.children.find((c) => c.className === 'fushi-subtitle-overlay-text');
  return (text || el).textContent;
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
// 找到 title 含关键字的按钮（＋ 加载按钮）。
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
    pauseCount: 0,
    pause() { this.paused = true; this.pauseCount++; },
    getBoundingClientRect() { return { left: 100, top: 50, width: 800, height: 450 }; },
  };
  // 有状态的 chrome.storage.local：set / remove 真改这份内存（外挂字幕持久化要能「刷新」后读回）。
  const mem = Object.assign({}, opts.stored || {});
  const storageListeners = [];
  const runtimeListeners = [];
  const documentListeners = {};
  const intervals = [];
  const createdInputs = [];
  const toasts = [];
  let captionResp = opts.response;
  const windowObj = {
    fushiT: FUSHI_T,
    fushiEpisodeCues: opts.store || {},
    postMessage() {},
    addEventListener: (type, fn) => { (documentListeners[type] = documentListeners[type] || []).push(fn); },
    fushiToast: (m) => toasts.push(m),
  };
  // 覆盖层真实落点是 <html>（parentForOverlay = fullscreenElement || documentElement）。
  // 真实浏览器 documentElement 恒存，fake 也得有根——查覆盖层从 html 往下找。
  const htmlRoot = makeEl('html');
  htmlRoot.appendChild(body);
  const documentObj = {
    body,
    documentElement: htmlRoot,
    fullscreenElement: null,
    addEventListener: (type, fn) => { (documentListeners[type] = documentListeners[type] || []).push(fn); },
    getElementById: (id) => findByIdDeep(htmlRoot, id),
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: () => [],
    createElement: (t) => { const e = makeEl(t); if (t === 'input') createdInputs.push(e); return e; },
    createDocumentFragment: () => makeEl('fragment'),
  };
  function FileReaderStub() {}
  FileReaderStub.prototype.readAsText = function (file) {
    this.result = file && file._content != null ? file._content : '';
    if (typeof this.onload === 'function') this.onload();
  };
  const sandbox = {
    window: windowObj,
    document: documentObj,
    location: { hostname: opts.hostname || 'example.com', pathname: opts.pathname || '/video/1', origin: 'https://' + (opts.hostname || 'example.com') },
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    FileReader: FileReaderStub,
    chrome: {
      storage: {
        local: {
          get: (key, cb) => { if (typeof cb === 'function') { cb(mem); return undefined; } return { then(res) { res(mem); } }; },
          set: (patch) => { Object.assign(mem, JSON.parse(JSON.stringify(patch))); },
          remove: (keys) => { for (const k of [].concat(keys)) delete mem[k]; },
        },
        onChanged: { addListener: (fn) => storageListeners.push(fn) },
      },
      runtime: {
        lastError: null,
        sendMessage: (msg, cb) => {
          if (msg && msg.type === 'parseSubtitle' && typeof cb === 'function') cb(captionResp);
        },
        onMessage: { addListener: (fn) => runtimeListeners.push(fn) },
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'subtitle-adapters.js'), 'utf8'), sandbox, { filename: 'subtitle-adapters.js' }); // manifest：先于 subtitle-panel.js（共享轨判据）
  vm.runInContext(src, sandbox, { filename: 'subtitle-panel.js' });
  function message(payload) {
    let response;
    for (const listener of runtimeListeners) {
      listener(payload, {}, (value) => { response = value; });
      if (response !== undefined) break;
    }
    return response;
  }
  function fireToggle(v) { for (const fn of storageListeners) fn({ netflixSubtitlePanel: { newValue: v } }, 'local'); }
  return {
    body, mem,
    html: htmlRoot, video, windowObj, createdInputs, toasts,
    enable: () => fireToggle(true),
    panel: () => findByIdDeep(body, 'fushi-subtitle-panel'),
    reopen: () => findByIdDeep(body, 'fushi-subtitle-reopen'),
    setResponse: (r) => { captionResp = r; },
    tick: () => { const t = intervals.find((it) => it.ms === 200); if (t) t.fn(); },
    dropFiles: function (files) {
      const ev = {
        dataTransfer: { files, types: ['Files'], dropEffect: '' },
        prevented: false,
        preventDefault() { this.prevented = true; },
      };
      for (const fn of documentListeners.drop || []) fn(ev);
      return ev;
    },
    message,
    // Side Panel 已在扩展自己的 DOM 中读文件并经 server 解析；content 只接收解析后的 cue。
    loadFile: function (name, content) {
      void content;
      const cues = captionResp && captionResp.data && Array.isArray(captionResp.data.cues)
        ? captionResp.data.cues : [];
      return message({ type: 'fushiSubtitleSidePanelInstallTrack', filename: name, cues });
    },
  };
}

const OK = (cues, format) => ({ ok: true, status: 200, data: { format: format || 'srt', cues } });

test('① 选文件→server 解析→外挂轨写进 store 并成为当前轨', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { netflixSubtitlePanel: true },
    response: OK([{ text: '走り出した', startMs: 1500, endMs: 3500 }, { text: 'こんにちは', startMs: 4000, endMs: 5000 }]),
  });
  h.loadFile('movie.ja.srt', 'dummy');
  const key = 'example.com/video/1|外挂:movie.ja.srt';
  const store = h.windowObj.fushiEpisodeCues;
  assert.ok(store[key], '外挂轨必须写进 store');
  assert.strictEqual(store[key].length, 2);
  assert.strictEqual(store[key][0].startMs, 1500);
  assert.strictEqual(store[key][0].text, '走り出した');
  const state = h.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.strictEqual(state.activeLang, '外挂:movie.ja.srt');
  assert.strictEqual(state.cues.length, 2, 'Side Panel 状态必须返回外挂轨两句');
  assert.strictEqual(h.panel(), null, '字幕列表不得挂到宿主网页 DOM');
  assert.ok(h.toasts.some((t) => t.indexOf('已加载') >= 0), '必须提示加载成功');
});

test('② 时轴偏移：读取侧平移（面板/seek 用偏移值，store 保持原始 cue）', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { netflixSubtitlePanel: true },
    response: OK([{ text: 'a', startMs: 1000, endMs: 2000 }]),
  });
  h.loadFile('x.srt', 'dummy');
  const key = 'example.com/video/1|外挂:x.srt';
  const store = h.windowObj.fushiEpisodeCues;
  assert.strictEqual(store[key][0].startMs, 1000);
  const state = h.message({ type: 'fushiSubtitleSidePanelOffset', deltaMs: 500 });
  // asb 移植后偏移在读取侧套用：store 原始 cue 不动（provider 增量刷新不会打架），
  // 面板行 seek 与时间戳用偏移后的值。
  assert.strictEqual(store[key][0].startMs, 1000, 'store 必须保持原始 cue（读取侧偏移）');
  assert.strictEqual(store[key][0].endMs, 2000);
  h.message({ type: 'fushiSubtitleSidePanelSeek', ms: state.cues[0].startMs });
  assert.strictEqual(h.video.currentTime, 1.5, '行点击 seek 必须用偏移后的 1500ms');
});

test('③ 空解析结果 → 提示、不造轨', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { netflixSubtitlePanel: true },
    response: { ok: true, status: 200, data: { error: 'unsupported', cues: [] } },
  });
  h.loadFile('notes.srt', 'dummy');
  const store = h.windowObj.fushiEpisodeCues;
  assert.strictEqual(Object.keys(store).length, 0, '不支持格式不得造轨');
  assert.ok(h.toasts.some((t) => t.indexOf('字幕为空') >= 0), '必须提示字幕为空');
});

test('④ 拖放外挂字幕会自动开启列表并加载轨道', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { subtitleDragDropEnabled: true },
    response: OK([{ text: '拖放字幕', startMs: 1000, endMs: 3000 }]),
  });
  const ev = h.dropFiles([{ name: 'drop.ja.srt', size: 120, _content: 'dummy' }]);
  assert.strictEqual(ev.prevented, true, '支持的字幕文件 drop 必须被接管');
  assert.strictEqual(h.panel(), null, '拖放后列表仍不得注入宿主网页 DOM');
  assert.ok(h.windowObj.fushiEpisodeCues['example.com/video/1|外挂:drop.ja.srt']);
});

test('⑤ 外挂字幕按视频矩形叠到画面上，站点轨不重复叠字', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1',
    stored: { netflixSubtitlePanel: true, subtitleOverlayEnabled: true },
    response: OK([{ text: '画面上的外挂字幕', startMs: 1000, endMs: 3000 }]),
  });
  h.loadFile('overlay.srt', 'dummy');
  h.video.currentTime = 2;
  h.tick();
  const overlay = findByIdDeep(h.html, 'fushi-subtitle-overlay');
  assert.ok(overlay, '当前外挂 cue 应创建视频叠字');
  assert.strictEqual(overlayText(overlay), '画面上的外挂字幕');
  assert.strictEqual(overlay.style.left, '500px');
});

// BUG-3145：Chrome 自己的侧边栏入口 / 「查字幕」装轨不经拖放，字幕能力总门（netflixSubtitlePanel，
// 缺省关）没人去开——tick() 直接返回，覆盖层一个字都不画；用户要把「Fushi 字幕」拨关再拨开
// （那一下顺带写开总门）字幕才「导进去」。装外挂轨本身就是开门的用户意图。
test('⑥ 总门关着时经侧边栏装外挂轨：开门并立刻叠字（不必再拨一次开关）', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1',
    stored: { subtitleOverlayEnabled: true },
    response: OK([{ text: '侧边栏导入的字幕', startMs: 1000, endMs: 3000 }]),
  });
  h.video.currentTime = 2;
  h.loadFile('panel.srt', 'dummy');
  h.tick();
  const overlay = findByIdDeep(h.html, 'fushi-subtitle-overlay');
  assert.ok(overlay, '装轨后下一拍就该出字，而不是等用户拨开关');
  assert.strictEqual(overlayText(overlay), '侧边栏导入的字幕');
  const state = h.message({ type: 'fushiSubtitleSidePanelState', includeCues: false });
  assert.strictEqual(state.activeLang, '外挂:panel.srt');
});

// BUG-3143：全屏容器 / body 被站点 transform 时，fixed 覆盖层的视口坐标要折算进父级包含块，
// 否则整体偏移、切全屏后飞出屏幕。
test('⑦ 覆盖层坐标按父级包含块折算（video-target.js fushiFixedOrigin）', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1',
    stored: { netflixSubtitlePanel: true, subtitleOverlayEnabled: true },
    response: OK([{ text: '折算坐标', startMs: 1000, endMs: 3000 }]),
  });
  h.windowObj.fushiFixedOrigin = () => ({ x: 100, y: -40, sx: 1, sy: 1 });
  h.loadFile('o.srt', 'dummy');
  h.video.currentTime = 2;
  h.tick();
  const overlay = findByIdDeep(h.html, 'fushi-subtitle-overlay');
  assert.strictEqual(overlay.style.left, '400px', '视口 x=500 → 包含块里 400');
  // 视频 top 50 + 450×0.88 = 446 → 包含块里 486。
  assert.strictEqual(overlay.style.top, (50 + 450 * 0.88 + 40) + 'px');
});

// ── 反馈 HlBC5BcpED：外挂字幕刷新后消失 ────────────────────────────────────────
// 根因：外挂轨只写进页面内存 window.fushiEpisodeCues，刷新即丢。现按视频身份落盘 + 刷新后自动装回。
const { fushiPlanExternalSubtitleSave } = require('./subtitle-adapters.js');

test('外挂轨按视频身份落盘；「刷新」（新 content script 读同一份 storage）后自动装回并成为当前轨', () => {
  const cues = [{ text: '走り出した', startMs: 1500, endMs: 3500 }, { text: 'こんにちは', startMs: 4000, endMs: 5000 }];
  const first = loadPanel({
    hostname: 'www.nicovideo.jp', pathname: '/watch/so46975082', stored: { netflixSubtitlePanel: true },
    response: OK(cues),
  });
  first.loadFile('ep04.ja.srt', 'dummy');
  const id = 'externalSubtitle:www.nicovideo.jp/watch/so46975082|外挂:ep04.ja.srt';
  assert.ok(Array.isArray(first.mem.externalSubtitleIndex), '账本必须落盘');
  assert.strictEqual(first.mem.externalSubtitleIndex.length, 1);
  assert.strictEqual(first.mem.externalSubtitleIndex[0].id, id);
  assert.deepStrictEqual(first.mem[id].cues.map((c) => c.text), ['走り出した', 'こんにちは']);

  // 偏移随轨记账。
  first.message({ type: 'fushiSubtitleSidePanelOffset', absoluteMs: 1200 });
  assert.strictEqual(first.mem.externalSubtitleIndex[0].offsetMs, 1200);

  // 刷新：全新页面内存，只剩 storage。
  const reloaded = loadPanel({ hostname: 'www.nicovideo.jp', pathname: '/watch/so46975082', stored: first.mem });
  const key = 'www.nicovideo.jp/watch/so46975082|外挂:ep04.ja.srt';
  assert.ok(reloaded.windowObj.fushiEpisodeCues[key], '刷新后外挂轨必须自动装回 store');
  const state = reloaded.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.strictEqual(state.activeLang, '外挂:ep04.ja.srt', '刷新前看的外挂轨仍是当前轨');
  assert.strictEqual(state.cues.length, 2);
  assert.strictEqual(state.offsetMs, 1200, '偏移一起恢复');
  assert.strictEqual(state.cues[0].startMs, 1500 + 1200);
});

test('别的视频不会装回这条外挂轨', () => {
  const first = loadPanel({
    hostname: 'www.nicovideo.jp', pathname: '/watch/so1', stored: { netflixSubtitlePanel: true },
    response: OK([{ text: 'a', startMs: 0, endMs: 1000 }]),
  });
  first.loadFile('a.srt', 'dummy');
  const other = loadPanel({ hostname: 'www.nicovideo.jp', pathname: '/watch/so2', stored: first.mem });
  assert.deepStrictEqual(Object.keys(other.windowObj.fushiEpisodeCues), []);
  // 账本里本视频以外的条目原样保留。
  assert.strictEqual(other.mem.externalSubtitleIndex.length, 1);
});

test('账本条目的正文缺失（被清 / 写盘失败）：跳过并自愈剔除，不造空轨', () => {
  const index = [{ id: 'externalSubtitle:example.com/video/1|外挂:x.srt', video: 'example.com/video/1', label: '外挂:x.srt', bytes: 10, at: 1, offsetMs: 0 }];
  const h = loadPanel({ stored: { netflixSubtitlePanel: true, externalSubtitleIndex: index } });
  assert.deepStrictEqual(Object.keys(h.windowObj.fushiEpisodeCues), []);
  assert.deepStrictEqual(h.mem.externalSubtitleIndex, []);
});

test('LRU 账本：条数 / 总字节封顶从最旧淘汰，新条目绝不淘汰；超大单条不存；同 id 覆盖不算淘汰', () => {
  const limits = { maxEntries: 3, maxBytes: 100, maxEntryBytes: 60 };
  const mk = (id, bytes, at) => ({ id, video: 'v' + id, label: 'L', bytes, at, offsetMs: 0 });
  let plan = fushiPlanExternalSubtitleSave([mk('a', 10, 1), mk('b', 10, 2), mk('c', 10, 3)], mk('d', 10, 4), limits);
  assert.deepStrictEqual(plan.index.map((e) => e.id), ['b', 'c', 'd']);
  assert.deepStrictEqual(plan.evicted, ['a']);
  assert.strictEqual(plan.stored, true);

  plan = fushiPlanExternalSubtitleSave([mk('a', 40, 1), mk('b', 40, 2)], mk('c', 50, 3), limits);
  assert.deepStrictEqual(plan.index.map((e) => e.id), ['b', 'c']);
  assert.deepStrictEqual(plan.evicted, ['a']);

  plan = fushiPlanExternalSubtitleSave([mk('a', 10, 1)], mk('big', 61, 2), limits);
  assert.strictEqual(plan.stored, false);
  assert.deepStrictEqual(plan.index.map((e) => e.id), ['a']);

  plan = fushiPlanExternalSubtitleSave([mk('a', 10, 1), mk('big', 10, 2)], mk('big', 61, 3), limits);
  assert.deepStrictEqual(plan.evicted, ['big'], '同 id 新档太大：旧档也删，免得刷新装回过期正文');

  plan = fushiPlanExternalSubtitleSave([mk('a', 10, 1), mk('b', 10, 2)], mk('a', 20, 3), limits);
  assert.deepStrictEqual(plan.index.map((e) => e.id), ['b', 'a'], '重存挪到最新端');
  assert.deepStrictEqual(plan.evicted, [], '同 id 重存不能把刚写的正文删掉');

  plan = fushiPlanExternalSubtitleSave('garbage', mk('a', 10, 1), limits);
  assert.deepStrictEqual(plan.index.map((e) => e.id), ['a']);
});
