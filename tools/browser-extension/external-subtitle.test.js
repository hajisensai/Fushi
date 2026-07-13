const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// B（asb 招牌）行为守卫：面板加载用户外挂字幕文件 + 时轴偏移。
// 在受控 vm 里真加载 subtitle-panel.js，桩掉 file input / FileReader / chrome.runtime.sendMessage，
// 驱动完整加载流，断言：
//   ① 选文件 → 经 server 解析 → 外挂轨写进 hibikiEpisodeCues 并成为面板当前轨；
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
  const video = { currentTime: 0 };
  const storageListeners = [];
  const createdInputs = [];
  const toasts = [];
  let captionResp = opts.response;
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
    setInterval: (fn, ms) => ({ fn, ms }),
    clearInterval() {},
    FileReader: FileReaderStub,
    chrome: {
      storage: {
        local: { get: (key, cb) => { if (typeof cb === 'function') { cb(opts.stored || {}); return undefined; } return { then(res) { res(opts.stored || {}); } }; } },
        onChanged: { addListener: (fn) => storageListeners.push(fn) },
      },
      runtime: {
        lastError: null,
        sendMessage: (msg, cb) => { if (msg && msg.type === 'parseSubtitle' && typeof cb === 'function') cb(captionResp); },
      },
    },
  };
  vm.runInNewContext(src, sandbox, { filename: 'subtitle-panel.js' });
  function fireToggle(v) { for (const fn of storageListeners) fn({ netflixSubtitlePanel: { newValue: v } }, 'local'); }
  return {
    body, video, windowObj, createdInputs, toasts,
    enable: () => fireToggle(true),
    panel: () => findByIdDeep(body, 'hibiki-subtitle-panel'),
    reopen: () => findByIdDeep(body, 'hibiki-subtitle-reopen'),
    setResponse: (r) => { captionResp = r; },
    // 驱动加载：点重开片→点＋→喂文件→触发 change。
    loadFile: function (name, content) {
      const chip = findByIdDeep(body, 'hibiki-subtitle-reopen');
      if (chip && chip.handlers.click) chip.handlers.click[0]({ stopPropagation() {} });
      const panel = findByIdDeep(body, 'hibiki-subtitle-panel');
      const loadBtn = findBtnByTitle(panel, '加载外挂字幕')[0];
      assert.ok(loadBtn, '缺 ＋ 加载外挂字幕按钮');
      loadBtn.handlers.click[0]({ stopPropagation() {} });
      const inp = createdInputs[createdInputs.length - 1];
      assert.ok(inp, 'openFilePicker 必须创建 file input');
      inp.files = [{ name, _content: content }];
      inp.handlers.change[0]();
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
  const store = h.windowObj.hibikiEpisodeCues;
  assert.ok(store[key], '外挂轨必须写进 store');
  assert.strictEqual(store[key].length, 2);
  assert.strictEqual(store[key][0].startMs, 1500);
  assert.strictEqual(store[key][0].text, '走り出した');
  // 面板显示该轨（当前轨 + 行渲染）。
  const panel = h.panel();
  assert.ok(panel, '加载后面板必须显示');
  const rows = findByClassDeep(panel, 'hibiki-sub-text');
  assert.strictEqual(rows.length, 2, '外挂轨两句必须渲染成行');
  assert.ok(h.toasts.some((t) => t.indexOf('已加载') >= 0), '必须提示加载成功');
});

test('② 时轴偏移：nudge 让整轨 cue 时间平移', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { netflixSubtitlePanel: true },
    response: OK([{ text: 'a', startMs: 1000, endMs: 2000 }]),
  });
  h.loadFile('x.srt', 'dummy');
  const key = 'example.com/video/1|外挂:x.srt';
  const store = h.windowObj.hibikiEpisodeCues;
  assert.strictEqual(store[key][0].startMs, 1000);
  // 偏移条可见（当前轨为外挂），点 +0.5s 按钮。
  const panel = h.panel();
  const offsetBar = findByClassDeep(panel, 'hibiki-sub-offset')[0];
  assert.ok(offsetBar, '外挂轨必须显示时轴偏移条');
  assert.notStrictEqual(offsetBar.style._props.display, 'none');
  const plus = findBtnByTitle(offsetBar, '＋0.5')[0];
  assert.ok(plus, '缺 ＋0.5 偏移按钮');
  plus.handlers.click[0]({ stopPropagation() {} });
  assert.strictEqual(store[key][0].startMs, 1500, '偏移 +0.5s 后 cue 起点平移 500ms');
  assert.strictEqual(store[key][0].endMs, 2500);
});

test('③ 不支持格式 → 提示、不造轨', () => {
  const h = loadPanel({
    hostname: 'example.com', pathname: '/video/1', stored: { netflixSubtitlePanel: true },
    response: { ok: true, status: 200, data: { error: 'unsupported', cues: [] } },
  });
  h.loadFile('notes.txt', 'dummy');
  const store = h.windowObj.hibikiEpisodeCues;
  assert.strictEqual(Object.keys(store).length, 0, '不支持格式不得造轨');
  assert.ok(h.toasts.some((t) => t.indexOf('不支持') >= 0), '必须提示格式不支持');
});
