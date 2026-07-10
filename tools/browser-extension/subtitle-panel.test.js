const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1219 复诉 + TODO-1363 行为守卫：字幕列表面板。
// 在受控 vm 里真加载 subtitle-panel.js，断言四条用户诉求的行为契约：
//   ① 勾选即出（无需刷新）：storage.onChanged 收到 netflixSubtitlePanel=true、且 store 里已有
//      当前视频的字幕轨时，面板立刻挂到 body（不依赖任何页面刷新/新 cue 事件）。
//   ② 不挂空壳：store 里只有**别的视频**的轨（如 Netflix 预取的下一集）时，勾选/新 cue 事件都
//      不得挂出空面板。
//   ③ 全语言：多语言轨（ja/en/zh）全部列进语言下拉，不偏向任何语言；live 采样轨垫底。
//   ④ 通用化：非 Netflix 站点（example.com）同样可用；时间戳点击在通用站点直接改
//      video.currentTime，Netflix 站点仍走 __hibikiNf:'seek' 桥（DRM 平台边界）。

const PANEL = path.join(__dirname, 'subtitle-panel.js');

// 极简 DOM 元素桩：支持面板构建所需的全部操作（append/remove/attr/style/事件捕获）。
function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    _attrs: {},
    className: '',
    value: '',
    title: '',
    type: '',
    children: [],
    parentNode: null,
    handlers: {},
    style: {
      _props: {},
      setProperty(k, v) { this._props[k] = v; },
      getPropertyValue(k) { return this._props[k] || ''; },
    },
    setAttribute(k, v) { el._attrs[k] = String(v); if (k === 'id') el._id = String(v); },
    getAttribute(k) { return k in el._attrs ? el._attrs[k] : null; },
    addEventListener(t, fn) { (el.handlers[t] = el.handlers[t] || []).push(fn); },
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = el;
      el.children.push(child);
      return child;
    },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    scrollIntoView() {},
  };
  el.classList = {
    _set: new Set(),
    add(c) { el.classList._set.add(c); },
    remove(c) { el.classList._set.delete(c); },
    toggle(c, on) { on ? el.classList._set.add(c) : el.classList._set.delete(c); },
    contains(c) { return el.classList._set.has(c); },
  };
  Object.defineProperty(el, 'id', {
    get: () => el._id,
    set: (v) => { el._id = v; el._attrs.id = v; },
  });
  // textContent = '' 清空子节点（rebuildList 依赖）。
  let text = '';
  Object.defineProperty(el, 'textContent', {
    get: () => text,
    set: (v) => { text = v; if (v === '') el.children.length = 0; },
  });
  return el;
}

function findByIdDeep(el, id) {
  if (el._id === id) return el;
  for (const c of el.children || []) {
    const hit = findByIdDeep(c, id);
    if (hit) return hit;
  }
  return null;
}

function findByClassDeep(el, cls, out) {
  out = out || [];
  if (el.className === cls) out.push(el);
  for (const c of el.children || []) findByClassDeep(c, cls, out);
  return out;
}

// 加载面板脚本进受控 vm。opts: hostname/pathname/stored(初始 storage)/store(hibikiEpisodeCues)。
function loadPanel(opts) {
  const src = fs.readFileSync(PANEL, 'utf8');
  const body = makeEl('body');
  const video = { currentTime: 0 };
  const storageListeners = [];
  const intervals = [];
  const posted = [];
  const windowObj = {
    hibikiEpisodeCues: opts.store || {},
    postMessage: (msg) => posted.push(msg),
    addEventListener() {},
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
    location: {
      hostname: opts.hostname,
      pathname: opts.pathname || '/',
      origin: 'https://' + opts.hostname,
    },
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    chrome: {
      storage: {
        local: {
          // 同步 thenable：readEnabled 探测返回值的 then 走 Promise 分支，且回调同步执行，
          // 测试无需 await（真 chrome 是异步 Promise，这里同步化只为让断言直白）。
          get: (key, cb) => {
            if (typeof cb === 'function') { cb(opts.stored || {}); return undefined; }
            return { then(res) { res(opts.stored || {}); } };
          },
        },
        onChanged: { addListener: (fn) => storageListeners.push(fn) },
      },
    },
  };
  vm.runInNewContext(src, sandbox, { filename: 'subtitle-panel.js' });
  function fireToggle(value) {
    for (const fn of storageListeners) {
      fn({ netflixSubtitlePanel: { newValue: value } }, 'local');
    }
  }
  return {
    body,
    video,
    posted,
    windowObj,
    enable: () => fireToggle(true),
    disable: () => fireToggle(false),
    panel: () => findByIdDeep(body, 'hibiki-subtitle-panel'),
  };
}

const NF_TRACKS = {
  '81001|ja': [{ startMs: 1000, endMs: 2000, text: 'konnichiwa' }],
  '81001|en': [{ startMs: 1000, endMs: 2000, text: 'Hello' }],
  '81001|zh': [{ startMs: 1000, endMs: 2000, text: 'nihao' }],
};

test('1 勾选即出：storage.onChanged 开开关时面板立刻挂载（无需刷新/新 cue）', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: NF_TRACKS,
    stored: {},
  });
  assert.strictEqual(h.panel(), null, '默认关：加载后不得有面板');
  h.enable();
  assert.ok(h.panel(), '勾选后面板必须立刻出现（不依赖页面刷新）');
});

test('关开关即拆：storage.onChanged newValue=false 拆掉面板', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: NF_TRACKS,
    stored: { netflixSubtitlePanel: true },
  });
  assert.ok(h.panel(), '开关已开 + 有轨：加载即挂面板');
  h.disable();
  assert.strictEqual(h.panel(), null, '关开关必须立即拆面板');
});

test('3 全语言：ja/en/zh 轨全部列出，语言下拉可见', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: NF_TRACKS,
    stored: { netflixSubtitlePanel: true },
  });
  const panel = h.panel();
  assert.ok(panel);
  const sel = findByClassDeep(panel, 'hibiki-sub-lang')[0];
  assert.ok(sel, '缺语言下拉');
  const langs = sel.children.map((o) => o.value).sort();
  assert.deepStrictEqual(langs, ['en', 'ja', 'zh'], '三种语言轨必须全部列出');
  assert.notStrictEqual(sel.style.display, 'none', '多语言时下拉必须可见');
});

test('3 live 采样轨垫底且显示中文标签', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: Object.assign({ '81001|live': [{ startMs: 0, endMs: 500, text: 'x' }] }, NF_TRACKS),
    stored: { netflixSubtitlePanel: true },
  });
  const sel = findByClassDeep(h.panel(), 'hibiki-sub-lang')[0];
  const last = sel.children[sel.children.length - 1];
  assert.strictEqual(last.value, 'live', 'live 轨必须排最后');
  assert.strictEqual(last.textContent, '实时采集', 'live 轨显示中文标签');
});

test('2 不挂空壳：store 只有别的视频的轨时，勾选与 cue 事件都不挂面板', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: { '99999|ja': [{ startMs: 0, endMs: 1000, text: 'prefetch-next-episode' }] },
    stored: {},
  });
  h.enable();
  assert.strictEqual(h.panel(), null, '别的视频的轨不得挂出（空）面板');
  h.windowObj.hibikiSubtitlePanelOnCues('99999|ja');
  assert.strictEqual(h.panel(), null, '别的视频的 cue 事件不得挂出（空）面板');
});

test('4 通用化：非 Netflix 站点可用，时间戳点击直接改 video.currentTime', () => {
  const key = 'example.com/video/1';
  const h = loadPanel({
    hostname: 'example.com',
    pathname: '/video/1',
    store: { [key + '|en']: [{ startMs: 5000, endMs: 8000, text: 'generic site cue' }] },
    stored: { netflixSubtitlePanel: true },
  });
  const panel = h.panel();
  assert.ok(panel, '非 Netflix 站点开关开 + 有轨：面板必须挂载（通用化）');
  const ts = findByClassDeep(panel, 'hibiki-sub-ts')[0];
  assert.ok(ts, '缺时间戳按钮');
  ts.handlers.click[0]({ stopPropagation() {} });
  assert.strictEqual(h.video.currentTime, 5, '通用站点 seek 必须直接落到 video.currentTime');
  assert.strictEqual(h.posted.length, 0, '通用站点不得走 Netflix seek 桥');
});

test('4 Netflix 站点时间戳点击仍走 __hibikiNf seek 桥（DRM 边界不回退）', () => {
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store: NF_TRACKS,
    stored: { netflixSubtitlePanel: true },
  });
  const ts = findByClassDeep(h.panel(), 'hibiki-sub-ts')[0];
  ts.handlers.click[0]({ stopPropagation() {} });
  assert.strictEqual(h.video.currentTime, 0, 'Netflix 不得直接改 currentTime（M7375）');
  assert.strictEqual(h.posted.length, 1);
  // vm 上下文对象原型不同，deepStrictEqual 会因 prototype 不等误报——逐属性断言。
  assert.strictEqual(h.posted[0].__hibikiNf, 'seek');
  assert.strictEqual(h.posted[0].ms, 1000);
});

test('新 cue 到达（onCues）时勾选态面板自动出现（cue 晚于开关的时序）', () => {
  const store = {};
  const h = loadPanel({
    hostname: 'www.netflix.com',
    pathname: '/watch/81001',
    store,
    stored: { netflixSubtitlePanel: true },
  });
  assert.strictEqual(h.panel(), null, '尚无轨：不挂面板');
  store['81001|ja'] = [{ startMs: 0, endMs: 1000, text: 'late cue' }];
  h.windowObj.hibikiSubtitlePanelOnCues('81001|ja');
  assert.ok(h.panel(), 'cue 到达后面板必须自动出现');
});
