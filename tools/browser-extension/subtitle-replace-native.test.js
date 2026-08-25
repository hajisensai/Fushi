// 「用 Fushi 字幕替代站点原生字幕」的行为测试。
//
// 动机（用户报告，YouTube 自动生成字幕）：YouTube 的 ASR 字幕是**逐词滚动**渲染的——DOM 里
// 每隔几百毫秒多蹦一个词，一句话要好几秒才凑齐。扩展原本的 live 轨就是从这个 DOM 采样来的，
// 于是划词/制卡拿到的永远是半句。asbplayer 的做法是预取整条字幕轨、按整句显示；本仓的
// youtube-bridge.js 早就把整集 srv3 轨（<p> 段 = 整句）预取进 store 了，缺的只是渲染侧
// 「用它替代原生字幕」这一步。
//
// 本测试在受控 vm 里真加载 content.js + subtitle-panel.js，钉住四条不变式：
//   ① 替代生效时藏站点原生字幕，但**必须保留**自绘覆盖层——藏错一个就是满屏没字幕。
//   ② 整轨没到 / 当前是 live 轨 / 覆盖层被关 → 一律不藏原生（宁可双份也不能一份都没有）。
//   ③ 切视频导致轨清空时立刻放回原生字幕。
//   ④ 用户主动隐藏字幕（manual）仍然全藏，替代模式不得把它降级。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const STYLE_ID = 'fushi-hide-subs';
const OVERLAY_ID = 'fushi-subtitle-overlay';

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    textContent: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    setAttribute(k, v) { if (k === 'id') el._id = v; },
    getAttribute() { return null; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener() {},
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
      return { x: 0, y: 0, left: 0, top: 0, right: 1280, bottom: 720, width: 1280, height: 720 };
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

// 建一个装好 content.js + subtitle-panel.js 的世界。
// prefs：写进 chrome.storage.local 的初始偏好（含 subtitleReplaceNative / subtitleHidden）。
function loadWorld(prefs) {
  const head = makeEl('head');
  const body = makeEl('body');
  const html = makeEl('html');
  html.appendChild(head);
  html.appendChild(body);
  const stored = Object.assign({ netflixSubtitlePanel: true }, prefs || {});
  const changeListeners = [];
  const intervals = [];
  // 覆盖层的落点直接读 video 的 rect（放不出几何就不画），所以桩必须给出真实矩形。
  const video = {
    currentTime: 0, paused: false, playbackRate: 1, textTracks: [],
    getBoundingClientRect: () => (
      { x: 0, y: 0, left: 0, top: 0, right: 1280, bottom: 720, width: 1280, height: 720 }),
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
        // 面板用 `chrome.storage.local.get(key)` 的 Promise 形式读开关；真 Promise 会把
        // st.enabled 的置位推迟到微任务，而本测试是同步泵 tick 的 —— 那样面板永远是
        // disabled，所有断言都会变成「没轨所以没生效」的假绿。返回**同步 thenable**，
        // 让读取在加载期就完成，与真实运行里「tick 前偏好早已读好」一致。
        get: (keys, cb) => {
          const out = {};
          for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
          if (cb) { cb(out); return undefined; }
          return { then: (fn) => { fn(out); return { catch() {} }; }, catch() {} };
        },
        set: (patch, cb) => { Object.assign(stored, patch); if (cb) cb(); return Promise.resolve(); },
      },
      onChanged: { addListener: (fn) => changeListeners.push(fn) },
    },
  };
  sandbox.window = {
    addEventListener() {},
    postMessage() {},
    innerWidth: 1280,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
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
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  vm.runInContext(fs.readFileSync(PANEL, 'utf8'), sandbox, { filename: 'subtitle-panel.js' });

  // 面板的 tick 由 setInterval(tick, 200) 驱动；测试手动泵它，行为与真实运行一致。
  const tick = () => {
    for (const it of intervals) if (it.ms === 200) it.fn();
  };
  const styleText = () => {
    const el = findById(html, STYLE_ID);
    return el ? el.textContent : null;
  };
  const overlayEl = () => findById(body, OVERLAY_ID);
  // 写 store + 走 content.js 真实的通知链（fushiNotifyPanel → fushiSubtitlePanelOnCues），
  // 面板据此重新选轨。绕过通知直接改 store 是测试世界独有的假路径，不用。
  const setTrack = (lang, cues) => {
    const key = 'yt-abc123|' + lang;
    sandbox.window.fushiEpisodeCues[key] = cues;
    sandbox.window.fushiSubtitlePanelOnCues(key);
  };
  return { sandbox, html, body, stored, changeListeners, tick, styleText, overlayEl, setTrack, video };
}

const CUES = [
  { startMs: 0, endMs: 3000, text: 'not spending the next 40 years of your' },
  { startMs: 3000, endMs: 6000, text: 'life chasing some vision of yourself' },
];

test('替代生效：藏站点原生字幕，但自绘覆盖层必须留着（否则满屏没字幕）', () => {
  const w = loadWorld({ subtitleReplaceNative: true });
  w.setTrack('English (自动)', CUES);
  w.tick();

  const css = w.styleText();
  assert.ok(css, '替代生效时必须注入遮蔽样式');
  assert.match(css, /\.ytp-caption-window-container/, '必须藏 YouTube 原生字幕层');
  assert.match(css, /visibility:hidden/, '只能用 visibility（display:none 会连制卡取词一起废掉）');
  assert.doesNotMatch(css, /#fushi-subtitle-overlay/,
    '替代模式绝不能连自绘覆盖层一起藏——那等于把字幕全关了');

  const overlay = w.overlayEl();
  assert.ok(overlay, '替代模式必须画出自绘覆盖层');
  assert.strictEqual(overlay.textContent, CUES[0].text,
    '覆盖层显示的应是整轨里的**整句**，不是逐词快照');
});

test('live 轨不触发替代：它本身就是从原生 DOM 逐词采来的，替代毫无意义', () => {
  const w = loadWorld({ subtitleReplaceNative: true });
  w.setTrack('live', CUES);
  w.tick();
  assert.strictEqual(w.styleText(), null, 'live 轨不得藏原生字幕');
});

test('整轨还没到（轨空）时保持原生字幕可见', () => {
  const w = loadWorld({ subtitleReplaceNative: true });
  w.tick();
  assert.strictEqual(w.styleText(), null, '没有任何轨时不得藏原生字幕');
});

test('覆盖层被用户关掉时不替代（替代品都没了还藏原生 = 一句字幕都看不到）', () => {
  const w = loadWorld({ subtitleReplaceNative: true, subtitleOverlayEnabled: false });
  w.setTrack('English (自动)', CUES);
  w.tick();
  assert.strictEqual(w.styleText(), null);
});

test('设置关着时行为不变：站点原生字幕照常可见，自绘覆盖层不叠字', () => {
  const w = loadWorld({ subtitleReplaceNative: false });
  w.setTrack('English (自动)', CUES);
  w.tick();
  assert.strictEqual(w.styleText(), null, '未开启替代时不得动站点字幕');
  assert.strictEqual(w.overlayEl(), null, '检测轨默认不重复叠字（既有行为）');
});

test('切视频/换轨导致轨清空：立刻把原生字幕放回来', () => {
  const w = loadWorld({ subtitleReplaceNative: true });
  w.setTrack('English (自动)', CUES);
  w.tick();
  assert.ok(w.styleText(), '前置条件：替代已生效');

  // SPA 换视频：store 里旧 key 还在，但 videoKey 变了 → 当前视频一条轨都没有。
  w.sandbox.location.search = '?v=zzz999';
  w.sandbox.location.href = 'https://www.youtube.com/watch?v=zzz999';
  w.tick();
  assert.strictEqual(w.styleText(), null,
    '换到没有字幕轨的视频后必须撤销遮蔽，否则用户看不到任何字幕');
});

test('用户主动隐藏字幕（Shift+H）仍然全藏：替代模式不得把它降级', () => {
  const w = loadWorld({ subtitleReplaceNative: true, subtitleHidden: true });
  w.setTrack('English (自动)', CUES);
  w.tick();
  const css = w.styleText();
  assert.ok(css);
  assert.match(css, /#fushi-subtitle-overlay/,
    'manual 隐藏语义是「什么都别显示」，自绘覆盖层也要藏');
  assert.match(css, /\.ytp-caption-window-container/);
});

test('关掉字幕列表功能时撤销替代：把站点原生字幕放回来', () => {
  const w = loadWorld({ subtitleReplaceNative: true });
  w.setTrack('English (自动)', CUES);
  w.tick();
  assert.ok(w.styleText(), '前置条件：替代已生效');

  for (const fn of w.changeListeners) {
    fn({ netflixSubtitlePanel: { newValue: false } }, 'local');
  }
  assert.strictEqual(w.styleText(), null,
    '面板关掉后自绘覆盖层没了，必须立刻把原生字幕放回来');
  w.tick();
  assert.strictEqual(w.styleText(), null, 'tick 不得把关掉的面板又「唤醒」');
  assert.strictEqual(w.overlayEl(), null, '关掉面板后不得再画自绘覆盖层');
});

test('在设置页开关经 storage.onChanged 实时生效，无需刷新页面', () => {
  const w = loadWorld({ subtitleReplaceNative: false });
  w.setTrack('English (自动)', CUES);
  w.tick();
  assert.strictEqual(w.styleText(), null);

  for (const fn of w.changeListeners) {
    fn({ subtitleReplaceNative: { newValue: true } }, 'local');
  }
  w.tick();
  assert.ok(w.styleText(), '改设置后当前页面应立刻进入替代模式');
});
