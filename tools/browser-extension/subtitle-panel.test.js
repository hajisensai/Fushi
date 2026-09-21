const { test } = require('node:test');
const assert = require('node:assert');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT(); // 文案走 i18n：壳里装 zh-CN 字典
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const PANEL = path.join(__dirname, 'subtitle-panel.js');
const MANIFEST = require('./manifest.json');

function makeEl(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(), id: '', children: [], parentNode: null,
    handlers: {}, style: { setProperty() {}, getPropertyValue() { return ''; }, removeProperty() {} },
    setAttribute(name, value) { if (name === 'id') this.id = String(value); },
    getAttribute() { return null; },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    removeChild(child) { this.children = this.children.filter((it) => it !== child); child.parentNode = null; },
    scrollIntoView() {},
  };
  el.classList = { add() {}, remove() {}, toggle() {} };
  return el;
}

function findById(root, id) {
  if (root.id === id) return root;
  for (const child of root.children || []) {
    const match = findById(child, id);
    if (match) return match;
  }
  return null;
}

function loadController(options = {}) {
  const source = fs.readFileSync(PANEL, 'utf8');
  const body = makeEl('body');
  const video = {
    currentTime: 0,
    getBoundingClientRect() { return { left: 0, top: 0, width: 1280, height: 720 }; },
  };
  const runtimeListeners = [];
  const storageListeners = [];
  const sent = [];
  const posted = [];
  const windowObject = {
    fushiT: FUSHI_T,
    fushiEpisodeCues: options.store || {},
    addEventListener() {},
    postMessage(message) { posted.push(message); },
    fushiPrepareLookupFromSidePanel(cue) { sent.push({ prepareLookup: cue }); return true; },
    fushiMineFromSidePanel(fields, cue) { sent.push({ mine: fields, cue }); return { ok: true }; },
  };
  const docListeners = {};
  const documentObject = {
    body,
    fullscreenElement: null,
    documentElement: body,
    addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
    getElementById(id) { return findById(body, id); },
    querySelector(selector) {
      if (selector !== 'video') return null;
      return options.noVideo ? null : video;
    },
    querySelectorAll() { return []; },
    createElement: makeEl,
    createDocumentFragment() { return makeEl('fragment'); },
  };
  const sandbox = {
    window: windowObject,
    document: documentObject,
    location: {
      hostname: options.hostname || 'example.com',
      pathname: options.pathname || '/video/1',
      origin: 'https://' + (options.hostname || 'example.com'),
    },
    navigator: { clipboard: { writeText() { return Promise.resolve(); } } },
    setInterval() { return 1; },
    clearInterval() {},
    chrome: {
      storage: {
        local: {
          get(_key, callback) {
            if (callback) { callback(options.stored || { netflixSubtitlePanel: true }); return; }
            return Promise.resolve(options.stored || { netflixSubtitlePanel: true });
          },
          set() {},
        },
        onChanged: { addListener(fn) { storageListeners.push(fn); } },
      },
      runtime: {
        sendMessage(message) { sent.push(message); },
        onMessage: { addListener(fn) { runtimeListeners.push(fn); } },
      },
    },
  };
  vm.runInNewContext(source, sandbox, { filename: 'subtitle-panel.js' });

  function message(payload) {
    let response;
    for (const listener of runtimeListeners) {
      listener(payload, {}, (value) => { response = value; });
      if (response !== undefined) break;
    }
    return response;
  }

  function fire(type, event) {
    for (const listener of docListeners[type] || []) listener(event);
    return event;
  }

  // storage.onChanged 的触发器：设置页改开关走的就是这条（面板没有别的入口）。
  function storageChange(changes) {
    for (const listener of storageListeners) listener(changes, 'local');
  }

  return { body, video, windowObject, sent, posted, message, fire, storageChange };
}

const TRACKS = {
  '81001|ja': [{ startMs: 1000, endMs: 2000, text: 'こんにちは' }],
  '81001|en': [{ startMs: 1000, endMs: 2000, text: 'Hello' }],
  '81001|live': [{ startMs: 0, endMs: 500, text: 'live' }],
};

test('manifest registers Chrome native side panel', () => {
  assert.ok(MANIFEST.permissions.includes('sidePanel'));
  assert.deepStrictEqual(MANIFEST.side_panel, { default_path: 'side-panel.html' });
});

test('content controller never mounts a subtitle list into the host page DOM', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-panel'), null);
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-reopen'), null);
  const state = harness.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.strictEqual(state.ok, true);
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-panel'), null);
});

test('side panel state exposes all tracks, keeps live last, and returns active cues on demand', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  const state = harness.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.deepStrictEqual(Array.from(state.tracks, (track) => track.lang), ['en', 'ja', 'live']);
  assert.strictEqual(state.activeLang, 'en');
  assert.strictEqual(state.cues[0].text, 'Hello');
  assert.strictEqual(state.tracks[2].label, '实时采集');
});

test('generic seek changes video time while Netflix seek keeps the DRM bridge', () => {
  const generic = loadController({
    store: { 'example.com/video/1|ja': [{ startMs: 5000, endMs: 6000, text: '五秒' }] },
  });
  generic.message({ type: 'fushiSubtitleSidePanelSeek', ms: 5000 });
  assert.strictEqual(generic.video.currentTime, 5);

  const netflix = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  netflix.message({ type: 'fushiSubtitleSidePanelSeek', ms: 1000 });
  assert.strictEqual(netflix.video.currentTime, 0);
  assert.strictEqual(netflix.posted[0].__fushiNf, 'seek');
  assert.strictEqual(netflix.posted[0].ms, 1000);
});

test('track selection, offset and side-panel cue actions are routed through the content controller', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  let state = harness.message({ type: 'fushiSubtitleSidePanelSelectTrack', lang: 'ja' });
  assert.strictEqual(state.activeLang, 'ja');
  state = harness.message({ type: 'fushiSubtitleSidePanelOffset', deltaMs: 500 });
  assert.strictEqual(state.cues[0].startMs, 1500);
  assert.strictEqual(TRACKS['81001|ja'][0].startMs, 1000, 'raw store remains unchanged');
  let response = harness.message({
    type: 'fushiSubtitleSidePanelPrepareLookup', cue: state.cues[0],
  });
  assert.strictEqual(response.ok, true);
  assert.ok(harness.sent.some((entry) => entry.prepareLookup === state.cues[0]));
  response = harness.message({
    type: 'fushiSubtitleSidePanelMine', fields: { expression: '今日' }, cue: state.cues[0],
  });
  assert.strictEqual(response.ok, true);
  assert.ok(harness.sent.some((entry) => entry.mine && entry.mine.expression === '今日'));
});


// BUG-2194：按需加载的占位轨——面板侧：列出来（排在已加载轨之后、实时采集之前）、
// 选中即请桥真取（同一 key 5 秒内不重复）、cue 到了自然变成普通轨。
test('BUG-2194：占位轨列在已加载轨之后，选中触发 fushiRequestLazyTrack，5 秒内不重复请求', () => {
  const store = {
    'example.com/video/1|ja (auto)': [{ startMs: 1000, endMs: 2000, text: '一' }],
    'example.com/video/1|en (auto)': [],
    'example.com/video/1|live': [{ startMs: 0, endMs: 500, text: 'l' }],
  };
  const harness = loadController({ store });
  harness.windowObject.fushiLazyTracks = { 'example.com/video/1|en (auto)': true };
  const requested = [];
  harness.windowObject.fushiRequestLazyTrack = (key) => { requested.push(key); return true; };
  let state = harness.message({ type: 'fushiSubtitleSidePanelState' });
  assert.strictEqual(JSON.stringify(state.tracks.map((t) => [t.lang, t.pending, t.length])),
    JSON.stringify([['ja (auto)', false, 1], ['en (auto)', true, 0], ['live', false, 1]]));
  assert.strictEqual(state.activeLang, 'ja (auto)', '已加载轨优先当活动轨，占位轨不抢');
  assert.deepStrictEqual(requested, [], '没选中占位轨不请求');
  state = harness.message({ type: 'fushiSubtitleSidePanelSelectTrack', lang: 'en (auto)' });
  assert.strictEqual(state.activeLang, 'en (auto)');
  assert.deepStrictEqual(requested, ['example.com/video/1|en (auto)'], '选中占位轨即请桥真取');
  harness.message({ type: 'fushiSubtitleSidePanelState' });
  assert.strictEqual(requested.length, 1, '5 秒内轮询不重复请求');
  // cue 到了：占位标记清除，轨变普通轨。
  store['example.com/video/1|en (auto)'] = [{ startMs: 0, endMs: 900, text: 'hi' }];
  delete harness.windowObject.fushiLazyTracks['example.com/video/1|en (auto)'];
  state = harness.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  const en = state.tracks.find((t) => t.lang === 'en (auto)');
  assert.deepStrictEqual([en.pending, en.length], [false, 1]);
  assert.strictEqual(state.cues.length, 1);
});


// 拖放导入的范围：用户报「在任何网页拖文件都弹『松开以加载字幕』并糊住半个屏幕」。
// 判据收窄成「这一页确实有 <video>」，没有视频的普通网页连 preventDefault 都不做。
function dragEvent(files) {
  let prevented = false;
  return {
    dataTransfer: {
      types: ['Files'],
      files: files || [],
      set dropEffect(_v) {},
      get dropEffect() { return ''; },
    },
    preventDefault() { prevented = true; },
    get prevented() { return prevented; },
  };
}

test('无视频的普通网页拖文件：不接管拖放，也不挂 drop 提示', () => {
  const harness = loadController({ noVideo: true });
  const over = harness.fire('dragover', dragEvent());
  assert.strictEqual(over.prevented, false, '不 preventDefault，宿主页上传行为零改动');
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-drop-hint'), null);
  const drop = harness.fire('drop', dragEvent([{ name: 'a.srt' }]));
  assert.strictEqual(drop.prevented, false, '没有视频就不吞字幕文件');
});

test('有视频的页面拖文件：接管拖放并挂唯一 drop 提示', () => {
  const harness = loadController();
  const over = harness.fire('dragover', dragEvent());
  assert.strictEqual(over.prevented, true);
  assert.ok(findById(harness.body, 'fushi-subtitle-drop-hint'), '提示挂上了');
  harness.fire('dragleave', { relatedTarget: null });
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-drop-hint'), null, '离开即摘');
});

test('drop 提示是右上角小角标，不是整屏覆盖', () => {
  const css = fs.readFileSync(path.join(__dirname, 'scripts', 'content-css-overlay.css'), 'utf8');
  const rule = css.slice(css.indexOf('#fushi-subtitle-drop-hint'));
  const block = rule.slice(0, rule.indexOf('}') + 1);
  assert.ok(/position:\s*fixed/.test(block));
  assert.ok(/top:\s*16px/.test(block) && /right:\s*16px/.test(block), '锚在右上角');
  assert.ok(!/inset:/.test(block), '不得再用 inset 铺满整屏');
  assert.ok(!/bottom:/.test(block) && !/left:/.test(block), '不占左侧与底部');
  assert.ok(/max-width:/.test(block), '限宽，别横贯整行');
});

const settle = () => new Promise((resolve) => setImmediate(resolve));

// 学习统计的字幕门（study-tracker.js）就架在这个出口上：它说 showing=false，
// 网页视频的沉浸时间就一秒不计。语义弄反直接体现为用户统计里多出 / 少掉几小时。
test('字幕门状态出口：整集轨在用 = showing；live 伪轨只算 any；无轨两者都假', async () => {
  const full = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  await settle();
  const state = full.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(state.showing, true, '整集轨已选中且有 cue');
  assert.strictEqual(state.any, true);
  assert.strictEqual(state.lang, 'en');
  assert.strictEqual(state.external, false);

  const liveOnly = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001',
    store: { '81001|live': [{ startMs: 0, endMs: 500, text: 'live' }] },
  });
  await settle();
  const liveState = liveOnly.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(liveState.showing, false, 'live 伪轨 = 用户在读站点原生字幕，不算用 Fushi 字幕');
  assert.strictEqual(liveState.any, true, '但确实“这个视频有字幕”');
  assert.strictEqual(liveState.lang, null);

  const empty = loadController({ hostname: 'www.netflix.com', pathname: '/watch/81001', store: {} });
  await settle();
  const emptyState = empty.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(emptyState.showing, false);
  assert.strictEqual(emptyState.any, false);
});

test('字幕门状态出口：看片中途关掉面板，门立刻关（不等换视频或刷新）', async () => {
  // teardownAll() 撤覆盖层、放回原生字幕，但不清 activeLang / cues（重开不用重抓）。
  // 门只看 activeLang 就会卡在「开」，沉浸统计一直计到换视频或刷新为止。
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  await settle();
  assert.strictEqual(harness.windowObject.fushiSubtitleStudyState().showing, true);
  harness.storageChange({ netflixSubtitlePanel: { newValue: false } });
  const off = harness.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(off.showing, false, '面板关掉 = 用户已经看不到 Fushi 字幕');
  assert.strictEqual(off.lang, null);
  assert.strictEqual(off.any, true, '轨还在 store 里，放宽档照旧算数');
  harness.storageChange({ netflixSubtitlePanel: { newValue: true } });
  assert.strictEqual(
    harness.windowObject.fushiSubtitleStudyState().showing,
    true,
    '重新打开立刻续上，不用重抓轨',
  );
});

test('字幕门状态出口：外挂字幕算 showing 并标 external；面板没开时 showing 为假', async () => {
  const ext = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001',
    store: { '81001|外挂:ep01.srt': [{ startMs: 0, endMs: 900, text: '外挂一句' }] },
  });
  await settle();
  const state = ext.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(state.showing, true);
  assert.strictEqual(state.external, true, '拖进来的字幕文件与抓到的整集轨同等地算数');

  // netflixSubtitlePanel 没开 = 用户没用 Fushi 字幕：轨就在 store 里也不算在读。
  const off = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS, stored: {},
  });
  await settle();
  const offState = off.windowObject.fushiSubtitleStudyState();
  assert.strictEqual(offState.showing, false);
  assert.strictEqual(offState.any, true);
});
