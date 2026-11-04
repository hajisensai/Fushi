const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');
const { decide, nextRate } = require('./video-shortcuts.js');
const optionsHtml = fs.readFileSync(require.resolve('./options.html'), 'utf8');
const optionsJs = fs.readFileSync(require.resolve('./options.js'), 'utf8');

// asb 移植：视频页快捷键判定矩阵。decide 是纯函数：ev={key,code,ctrl,shift,alt,editable}，
// ctx={enabled,hasVideo,hasTrack,cueShowing}，返回 {action} 或 null（null = 放行给站点）。

const CTX = { enabled: true, hasVideo: true, hasTrack: true, cueShowing: true };
const shortcutSettingIds = [
  'videoShortcutPrevCue',
  'videoShortcutNextCue',
  'videoShortcutReplayCue',
  'videoShortcutTogglePanel',
  'videoShortcutToggleSubtitleHide',
  'videoShortcutOffsetMinus',
  'videoShortcutOffsetPlus',
  'videoShortcutOffsetReset',
  'videoShortcutCopyCue',
  'videoShortcutRateDown',
  'videoShortcutRateUp',
  'videoShortcutSeekBack',
  'videoShortcutSeekForward',
  'videoShortcutHoldSpeed',
];

function ev(over) {
  return Object.assign({ key: '', code: '', ctrl: false, shift: false, alt: false, editable: false }, over);
}

function rect(left, top, width, height) {
  return { left, top, width, height, right: left + width, bottom: top + height };
}

// 页面上的 <video>：默认是视口里一个在播、有声的正片（受 Fushi 控制的目标）。
function fakeVideo(r = rect(0, 0, 1280, 720), extra = {}) {
  return Object.assign({
    tagName: 'VIDEO', playbackRate: 1, currentTime: 100, duration: 600,
    paused: false, ended: false, readyState: 4, muted: false, volume: 1,
    getBoundingClientRect: () => r,
  }, extra);
}

// 运行时装配与 manifest 一致：video-target.js 先装（提供 fushiControlledVideo），再装 video-shortcuts.js。
// showing / hidden 模拟两个持有者：subtitle-panel.js 的 fushiSubtitleStudyState().showing 与
// content.js 的 fushiSubtitleManuallyHidden()（Shift+H）。缺省「有轨就在出字、未隐藏」。
function createRuntime(initialSettings = {}, {
  hasTrack = true, seekBy = true, videos = null, showing = hasTrack, hidden = false,
} = {}) {
  const subtitle = { showing, hidden };
  const source = fs.readFileSync(require.resolve('./video-shortcuts.js'), 'utf8');
  const targetSource = fs.readFileSync(require.resolve('./video-target.js'), 'utf8');
  let keydown;
  let keyup;
  let blur;
  let visibility;
  let storageChanged;
  let requestedKeys;
  const actions = [];
  const seeks = [];
  const toasts = [];
  const video = fakeVideo();
  const pageVideos = videos || [video];
  const doc = {
    visibilityState: 'visible',
    fullscreenElement: null,
    documentElement: {},
    querySelector(selector) {
      return selector === 'video' ? pageVideos[0] || null : null;
    },
    querySelectorAll(selector) {
      return selector === 'video' ? pageVideos : [];
    },
    addEventListener(type, handler) {
      if (type === 'visibilitychange') visibility = handler;
    },
  };
  const fakeWindow = {
    innerWidth: 1280,
    innerHeight: 720,
    fushiEpisodeCues: hasTrack ? { 'episode|ja': [{ start: 0, end: 1, text: '字幕' }] } : {},
    fushiVideoKey: () => 'episode',
    fushiSubtitleStudyState: () => ({ showing: subtitle.showing, any: hasTrack, lang: null, external: false }),
    fushiSubtitleManuallyHidden: () => subtitle.hidden,
    fushiSubtitleShortcut(action) {
      actions.push(action);
      return true;
    },
    fushiToast(text) { toasts.push(text); },
    addEventListener(type, handler) {
      if (type === 'keydown') keydown = handler;
      if (type === 'keyup') keyup = handler;
      if (type === 'blur') blur = handler;
    },
  };
  if (seekBy) {
    fakeWindow.fushiSubtitleSeekBy = (ms) => { seeks.push(ms); return true; };
  }
  const context = {
    self: fakeWindow,
    window: fakeWindow,
    document: doc,
    chrome: {
      storage: {
        local: {
          get(keys, callback) {
            requestedKeys = Array.isArray(keys) ? [...keys] : [keys];
            if (typeof callback === 'function') callback({ ...initialSettings });
          },
        },
        onChanged: {
          addListener(listener) {
            storageChanged = listener;
          },
        },
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(targetSource, context, { filename: 'video-target.js' });
  vm.runInContext(source, context, { filename: 'video-shortcuts.js' });
  assert.strictEqual(typeof fakeWindow.fushiControlledVideo, 'function');
  assert.strictEqual(typeof keydown, 'function');
  assert.strictEqual(typeof storageChanged, 'function');

  function fire(handler, overrides) {
    let prevented = false;
    let stopped = false;
    handler(Object.assign({
      key: '',
      code: '',
      repeat: false,
      shiftKey: false,
      ctrlKey: false,
      metaKey: false,
      altKey: false,
      target: null,
      preventDefault() { prevented = true; },
      stopPropagation() { stopped = true; },
    }, overrides));
    return { prevented, stopped };
  }

  return {
    actions,
    seeks,
    toasts,
    video,
    videos: pageVideos,
    requestedKeys,
    setShowing(on) { subtitle.showing = on; },
    setHidden(on) { subtitle.hidden = on; },
    removeStudyState() { delete fakeWindow.fushiSubtitleStudyState; },
    keyUp(overrides) { return fire(keyup, overrides); },
    blur() { blur(); },
    hide() { doc.visibilityState = 'hidden'; visibility(); },
    key(overrides) {
      let prevented = false;
      let stopped = false;
      keydown(Object.assign({
        key: '',
        code: '',
        shiftKey: false,
        ctrlKey: false,
        metaKey: false,
        altKey: false,
        target: null,
        preventDefault() { prevented = true; },
        stopPropagation() { stopped = true; },
      }, overrides));
      return { prevented, stopped };
    },
    change(key, newValue) {
      storageChanged({ [key]: { newValue } }, 'local');
    },
  };
}

function makeOptionsElement(id) {
  const listeners = Object.create(null);
  const element = {
    id,
    value: '',
    placeholder: '',
    checked: false,
    disabled: false,
    open: false,
    type: id === 'token' ? 'password' : '',
    textContent: '',
    dataset: {},
    classList: { add() {}, remove() {} },
    addEventListener(type, listener) {
      (listeners[type] = listeners[type] || []).push(listener);
    },
    async fire(type) {
      for (const listener of listeners[type] || []) {
        await listener({ preventDefault() {} });
      }
    },
    closest() {
      return {
        querySelector() {
          return { textContent: id };
        },
      };
    },
  };
  return element;
}

async function loadOptionsRuntime(initialSettings = {}) {
  const storage = { ...initialSettings };
  const writes = [];
  const storageListeners = [];
  const ids = [
    'nfSubList',
    'subtitleOverlayEnabled',
    'subtitleDragDropEnabled',
    'subtitleAutoScroll',
    'nfHideNext',
    'subtitlePauseOnLookup',
    'subtitleOverlayAutoLookup',
    'subtitleOverlayBlur',
    'subtitleOverlayAllTracks',
    'subtitleHidden',
    ...shortcutSettingIds,
    'host',
    'port',
    'token',
    'connectionCard',
    'connTitle',
    'connDetail',
    'connEndpoint',
    'check',
    'advancedConnection',
    'connectionForm',
    'reset',
    'showToken',
    'status',
    'updTitle',
    'updDetail',
    'updBuild',
  ];
  const elements = Object.fromEntries(ids.map((id) => [id, makeOptionsElement(id)]));
  const self = {
    FUSHI_DEFAULTS: { host: '127.0.0.1', port: 19633, token: '' },
    FUSHI_CONNECTION: {
      states: { unauthorized: 'unauthorized', wrongService: 'wrong-service' },
      copy() {
        return { tone: 'good', title: '已连接', detail: '测试连接正常' };
      },
    },
    FUSHI_SELF_UPDATE: {
      describeUpdateState() {
        return { title: '已是最新', detail: '测试 build', build: 'test' };
      },
    },
  };
  const context = {
    self,
    document: {
      getElementById(id) {
        return elements[id] || null;
      },
    },
    chrome: {
      runtime: {
        lastError: null,
        sendMessage(_message, callback) {
          callback({
            connection: {
              state: 'online',
              port: 19633,
              base: 'http://127.0.0.1:19633',
            },
          });
        },
      },
      storage: {
        local: {
          async get(keys) {
            const result = {};
            for (const key of Array.isArray(keys) ? keys : [keys]) {
              if (Object.hasOwn(storage, key)) result[key] = storage[key];
            }
            return result;
          },
          async set(patch) {
            writes.push(patch);
            Object.assign(storage, patch);
          },
        },
        onChanged: {
          addListener(listener) {
            storageListeners.push(listener);
          },
        },
      },
    },
    setTimeout() { return 1; },
    clearTimeout() {},
  };
  vm.runInNewContext(optionsJs, context, { filename: 'options.js' });
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  return { elements, storage, writes, storageListeners };
}

test('options 把每个视频快捷键动作拆成独立开关', () => {
  for (const id of shortcutSettingIds) {
    assert.ok(optionsHtml.includes(`id="${id}"`), `options.html 缺独立快捷键开关 ${id}`);
    assert.ok(optionsJs.includes(`${id}: '${id}'`), `options.js 未持久化 ${id}`);
  }
  assert.ok(!optionsHtml.includes('id="videoShortcutsEnabled"'), '不得保留把快捷键塞成一坨的总开关');
  assert.ok(!optionsHtml.includes('Shift+P/O/F'), '已删除的播放模式快捷键不得继续展示');
  assert.ok(optionsHtml.includes('id="subtitleHidden"'), '隐藏字幕实际状态仍须保留独立设置入口');
  assert.ok(optionsJs.includes("subtitleHidden: 'subtitleHidden'"), 'options.js 必须持久化隐藏字幕状态');
});

test('options runtime 真正回读默认/legacy/显式值，change 后 storage.set 并可重载读回', async () => {
  const defaults = await loadOptionsRuntime();
  assert.strictEqual(defaults.elements.videoShortcutPrevCue.checked, true,
    '无存量时逐动作快捷键默认开启');
  assert.strictEqual(defaults.elements.videoShortcutToggleSubtitleHide.checked, true,
    'Shift+H 独立动作无存量时默认开启');

  const legacy = await loadOptionsRuntime({
    videoShortcutsEnabled: false,
    videoShortcutPrevCue: true,
  });
  assert.strictEqual(legacy.elements.videoShortcutPrevCue.checked, true,
    '新单项显式 true 必须优先于 legacy false');
  assert.strictEqual(legacy.elements.videoShortcutNextCue.checked, false,
    '未显式的新单项必须回退 legacy false');

  legacy.elements.videoShortcutNextCue.checked = true;
  await legacy.elements.videoShortcutNextCue.fire('change');
  assert.strictEqual(legacy.writes.length, 1, 'change 必须真实调用 storage.set');
  assert.strictEqual(legacy.writes[0].videoShortcutNextCue, true,
    'storage.set 必须写入对应逐动作 key');
  assert.strictEqual(legacy.storage.videoShortcutNextCue, true,
    '持久化层必须保存 change 后的值');

  const reloaded = await loadOptionsRuntime(legacy.storage);
  assert.strictEqual(reloaded.elements.videoShortcutNextCue.checked, true,
    '重新加载 options 后必须读回刚持久化的显式值');
});

test('←/→/↑：有轨时接管为上一句/下一句/重播本句', () => {
  assert.deepStrictEqual(decide(ev({ key: 'ArrowLeft' }), CTX), { action: 'prev-cue' });
  assert.deepStrictEqual(decide(ev({ key: 'ArrowRight' }), CTX), { action: 'next-cue' });
  assert.deepStrictEqual(decide(ev({ key: 'ArrowUp' }), CTX), { action: 'replay-cue' });
});

test('←/→/↑：无字幕轨一律放行（站点自己的 5s 快进/音量不被抢）', () => {
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.strictEqual(decide(ev({ key: 'ArrowLeft' }), noTrack), null);
  assert.strictEqual(decide(ev({ key: 'ArrowRight' }), noTrack), null);
  assert.strictEqual(decide(ev({ key: 'ArrowUp' }), noTrack), null);
});

test('BUG-4053 ←/→：有轨但 Fushi 字幕没在出画时放行给站点，其它有轨动作不受影响', () => {
  const offScreen = { ...CTX, cueShowing: false };
  assert.strictEqual(decide(ev({ key: 'ArrowLeft', code: 'ArrowLeft' }), offScreen), null);
  assert.strictEqual(decide(ev({ key: 'ArrowRight', code: 'ArrowRight' }), offScreen), null);
  // 改了键也一样：门跟着动作走，不跟着键走。
  const combos = require('./video-shortcuts.js').resolveCombos({ 'prev-cue': 'KeyJ' });
  assert.strictEqual(decide(ev({ code: 'KeyJ' }), { ...offScreen, combos }), null);
  assert.deepStrictEqual(decide(ev({ code: 'KeyJ' }), { ...CTX, combos }), { action: 'prev-cue' });
  // 只收紧上一句 / 下一句：重播、侧边栏、偏移、复制仍按「有轨」判。
  assert.deepStrictEqual(decide(ev({ key: 'ArrowUp' }), offScreen), { action: 'replay-cue' });
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyS' }), offScreen), { action: 'toggle-panel' });
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, key: 'ArrowLeft' }), offScreen), { action: 'offset-minus' });
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, code: 'KeyZ' }), offScreen), { action: 'copy-cue' });
  // 按秒快退 / 快进与字幕无关，照常接管。
  assert.deepStrictEqual(decide(ev({ shift: true, key: 'ArrowLeft', code: 'ArrowLeft' }), offScreen), { action: 'seek-back' });
});

test('Shift+S：仅有 Fushi 字幕轨时切换面板；旧 Shift+P/O/F 不再接管', () => {
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyP' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyO' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyF' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyS' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyP' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyO' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyF' }), CTX), null);
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyS' }), CTX), { action: 'toggle-panel' });
});

test('Shift+H：隐藏字幕不需要扩展字幕轨，并受独立动作开关控制', () => {
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.deepStrictEqual(
    decide(ev({ shift: true, code: 'KeyH' }), noTrack),
    { action: 'toggle-subtitle-hide' },
  );
  assert.strictEqual(
    decide(
      ev({ shift: true, code: 'KeyH' }),
      { ...noTrack, bindings: { 'toggle-subtitle-hide': false } },
    ),
    null,
  );
});

test('Shift+H：无视频 / 输入框 / 加 Ctrl 或 Alt 时不接管', () => {
  const noVideo = { enabled: true, hasVideo: false, hasTrack: false };
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyH' }), noVideo), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyH', editable: true }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, alt: true, code: 'KeyH' }), CTX), null);
  assert.strictEqual(decide(ev({ ctrl: true, shift: true, code: 'KeyH' }), CTX), null);
  assert.strictEqual(decide(ev({ key: 'h', code: 'KeyH' }), CTX), null);
});

test('每个快捷键动作可独立关闭，不影响其它动作', () => {
  const ctx = {
    ...CTX,
    bindings: {
      'prev-cue': false,
      'next-cue': true,
      'rate-down': false,
      'rate-up': true,
    },
  };
  assert.strictEqual(decide(ev({ key: 'ArrowLeft' }), ctx), null);
  assert.deepStrictEqual(decide(ev({ key: 'ArrowRight' }), ctx), { action: 'next-cue' });
  assert.strictEqual(
    decide(ev({ ctrl: true, shift: true, code: 'BracketLeft' }), ctx),
    null,
  );
  assert.deepStrictEqual(
    decide(ev({ ctrl: true, shift: true, code: 'BracketRight' }), ctx),
    { action: 'rate-up' },
  );
});

test('Ctrl+Shift+←/→/↓/Z：偏移与复制（需字幕轨）', () => {
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, key: 'ArrowLeft' }), CTX), { action: 'offset-minus' });
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, key: 'ArrowRight' }), CTX), { action: 'offset-plus' });
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, key: 'ArrowDown' }), CTX), { action: 'offset-reset' });
  assert.deepStrictEqual(decide(ev({ ctrl: true, shift: true, code: 'KeyZ' }), CTX), { action: 'copy-cue' });
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.strictEqual(decide(ev({ ctrl: true, shift: true, code: 'KeyZ' }), noTrack), null);
});

test('Ctrl+Shift+[ / ]：变速用布局无关的 e.code（Shift 下 e.key 是 { }）', () => {
  assert.deepStrictEqual(
    decide(ev({ ctrl: true, shift: true, key: '{', code: 'BracketLeft' }), CTX),
    { action: 'rate-down' });
  assert.deepStrictEqual(
    decide(ev({ ctrl: true, shift: true, key: '}', code: 'BracketRight' }), CTX),
    { action: 'rate-up' });
});

test('输入框/可编辑区/Alt 组合/关闭开关/无视频：一律放行', () => {
  assert.strictEqual(decide(ev({ key: 'ArrowLeft', editable: true }), CTX), null);
  assert.strictEqual(decide(ev({ key: 'ArrowLeft', alt: true }), CTX), null);
  assert.strictEqual(decide(ev({ key: 'ArrowLeft' }), { enabled: false, hasVideo: true, hasTrack: true }), null);
  assert.strictEqual(decide(ev({ key: 'ArrowLeft' }), { enabled: true, hasVideo: false, hasTrack: true }), null);
});

test('普通打字与已移除的 Shift+P/O/F 不接管', () => {
  assert.strictEqual(decide(ev({ key: 'a', code: 'KeyA' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyQ' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyP' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyO' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyF' }), CTX), null);
  assert.strictEqual(decide(ev({ ctrl: true, code: 'KeyC' }), CTX), null); // Ctrl+C 复制绝不抢
});

test('nextRate：0.25 步进、clamp 0.25–4', () => {
  assert.strictEqual(nextRate(1, 0.25), 1.25);
  assert.strictEqual(nextRate(1, -0.25), 0.75);
  assert.strictEqual(nextRate(0.25, -0.25), 0.25);
  assert.strictEqual(nextRate(4, 0.25), 4);
  assert.strictEqual(nextRate(undefined, 0.25), 1.25); // 坏输入按 1x 起步
});

test('runtime 初始 storage 映射默认开启，legacy false 回退且新单项显式值优先', () => {
  const defaults = createRuntime();
  assert.ok(defaults.requestedKeys.includes('videoShortcutsEnabled'));
  for (const id of shortcutSettingIds) assert.ok(defaults.requestedKeys.includes(id), `runtime 未读取 ${id}`);
  assert.deepStrictEqual(
    defaults.key({ key: 'ArrowLeft', code: 'ArrowLeft' }),
    { prevented: true, stopped: true },
  );
  assert.deepStrictEqual(defaults.actions, ['prev-cue']);

  const legacyOff = createRuntime({ videoShortcutsEnabled: false });
  assert.deepStrictEqual(
    legacyOff.key({ key: 'ArrowLeft', code: 'ArrowLeft' }),
    { prevented: false, stopped: false },
  );

  const explicitWins = createRuntime({
    videoShortcutsEnabled: false,
    videoShortcutNextCue: true,
  });
  assert.deepStrictEqual(
    explicitWins.key({ key: 'ArrowLeft', code: 'ArrowLeft' }),
    { prevented: false, stopped: false },
  );
  assert.deepStrictEqual(
    explicitWins.key({ key: 'ArrowRight', code: 'ArrowRight' }),
    { prevented: true, stopped: true },
  );
  assert.deepStrictEqual(explicitWins.actions, ['next-cue']);
});

test('runtime storage.onChanged 热更新单项开关，不影响其它动作', () => {
  const runtime = createRuntime({
    videoShortcutPrevCue: true,
    videoShortcutNextCue: true,
  });
  runtime.change('videoShortcutPrevCue', false);
  assert.deepStrictEqual(
    runtime.key({ key: 'ArrowLeft', code: 'ArrowLeft' }),
    { prevented: false, stopped: false },
  );
  assert.deepStrictEqual(
    runtime.key({ key: 'ArrowRight', code: 'ArrowRight' }),
    { prevented: true, stopped: true },
  );
  runtime.change('videoShortcutPrevCue', true);
  assert.deepStrictEqual(
    runtime.key({ key: 'ArrowLeft', code: 'ArrowLeft' }),
    { prevented: true, stopped: true },
  );
  assert.deepStrictEqual(runtime.actions, ['next-cue', 'prev-cue']);
});

test('runtime 实际 keydown 只接管已开启动作；Shift+H 无扩展轨仍可独立关闭', () => {
  const runtime = createRuntime({
    videoShortcutPrevCue: false,
    videoShortcutNextCue: true,
    videoShortcutToggleSubtitleHide: true,
  }, { hasTrack: false });

  for (const code of ['KeyP', 'KeyO', 'KeyF', 'KeyS']) {
    assert.deepStrictEqual(
      runtime.key({ key: code.slice(-1), code, shiftKey: true }),
      { prevented: false, stopped: false },
      `${code} must remain available to the site without a Fushi track`,
    );
  }
  assert.deepStrictEqual(
    runtime.key({ key: 'H', code: 'KeyH', shiftKey: true }),
    { prevented: true, stopped: true },
  );
  assert.deepStrictEqual(runtime.actions, ['toggle-subtitle-hide']);

  runtime.change('videoShortcutToggleSubtitleHide', false);
  assert.deepStrictEqual(
    runtime.key({ key: 'H', code: 'KeyH', shiftKey: true }),
    { prevented: false, stopped: false },
  );
});

// ── 自定义组合键（用户群 10-09「快捷键可自定义」）──
const VS = require('./video-shortcuts.js');

test('自定义组合键：comboFromEvent / normalizeCombo 规范形（修饰键排序、Meta=Ctrl、纯修饰键不成立）', () => {
  assert.strictEqual(VS.comboFromEvent(ev({ shift: true, ctrl: true, code: 'KeyJ' })), 'Ctrl+Shift+KeyJ');
  assert.strictEqual(VS.comboFromEvent(ev({ alt: true, code: 'Digit1' })), 'Alt+Digit1');
  assert.strictEqual(VS.comboFromEvent(ev({ key: 'ArrowLeft' })), 'ArrowLeft', '只给 key 的方向键也认');
  assert.strictEqual(VS.comboFromEvent(ev({ shift: true, code: 'ShiftLeft' })), '');
  assert.strictEqual(VS.normalizeCombo('Shift+Ctrl+KeyJ'), 'Ctrl+Shift+KeyJ');
  for (const bad of ['', 'Ctrl+', 'Hyper+KeyJ', 'Ctrl+ShiftLeft', 'Ctrl+K J', 42, null]) {
    assert.strictEqual(VS.normalizeCombo(bad), '', String(bad));
  }
});

test('自定义组合键：resolveCombos 只覆盖改过的动作，非法覆盖回落默认', () => {
  const combos = VS.resolveCombos({ 'prev-cue': 'KeyA', 'next-cue': 'garbage' });
  assert.strictEqual(combos['prev-cue'], 'KeyA');
  assert.strictEqual(combos['next-cue'], VS.DEFAULT_COMBOS['next-cue']);
  assert.strictEqual(combos['rate-up'], 'Ctrl+Shift+BracketRight');
  assert.strictEqual(VS.conflictOf(combos, 'replay-cue', 'KeyA'), 'prev-cue');
  assert.strictEqual(VS.conflictOf(combos, 'prev-cue', 'KeyA'), '', '自己不算冲突');
});

test('自定义组合键：decide 按新组合接管，旧默认键不再接管；独立开关与字幕轨门照旧', () => {
  const combos = VS.resolveCombos({ 'prev-cue': 'Alt+KeyA', 'toggle-subtitle-hide': 'KeyH' });
  const ctx = { ...CTX, combos };
  assert.deepStrictEqual(decide(ev({ alt: true, code: 'KeyA' }), ctx), { action: 'prev-cue' });
  assert.strictEqual(decide(ev({ key: 'ArrowLeft', code: 'ArrowLeft' }), ctx), null, '旧默认键让给站点');
  assert.deepStrictEqual(decide(ev({ code: 'KeyH' }), { ...ctx, hasTrack: false }), { action: 'toggle-subtitle-hide' });
  assert.strictEqual(decide(ev({ alt: true, code: 'KeyA' }), { ...ctx, hasTrack: false }), null, '上一句仍要字幕轨');
  assert.strictEqual(decide(ev({ alt: true, code: 'KeyA' }), { ...ctx, bindings: { 'prev-cue': false } }), null);
  assert.strictEqual(decide(ev({ code: 'KeyH', editable: true }), ctx), null, '输入框里照旧放行');
});

test('formatCombo：给人看的键名', () => {
  assert.strictEqual(VS.formatCombo('Ctrl+Shift+ArrowLeft'), 'Ctrl+Shift+←');
  assert.strictEqual(VS.formatCombo('Shift+KeyH'), 'Shift+H');
  assert.strictEqual(VS.formatCombo('Ctrl+Shift+BracketLeft'), 'Ctrl+Shift+[');
  assert.strictEqual(VS.formatCombo('Alt+Digit3'), 'Alt+3');
  assert.strictEqual(VS.formatCombo('bad+'), '');
});

test('BUG-4053 runtime：有轨但 Fushi 字幕没出画（showing=false）时 ←/→ 原样放给站点', () => {
  const rt = createRuntime({}, { hasTrack: true, showing: false });
  assert.deepStrictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }), { prevented: false, stopped: false });
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight' }), { prevented: false, stopped: false });
  assert.deepStrictEqual(rt.actions, [], '站点轨被预取进 store 不等于在出字，不能抢键');
  // 用户打开 Fushi 字幕后无需刷新即接管（每次按键现读状态）。
  rt.setShowing(true);
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight' }), { prevented: true, stopped: true });
  assert.deepStrictEqual(rt.actions, ['next-cue']);
});

test('BUG-4053 runtime：Shift+H 隐藏字幕也算关闭，←/→ 回到站点；取消隐藏后恢复接管', () => {
  const rt = createRuntime({}, { hasTrack: true, showing: true });
  assert.strictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }).prevented, true);
  rt.setHidden(true);
  assert.deepStrictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }), { prevented: false, stopped: false });
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight' }), { prevented: false, stopped: false });
  // 隐藏只影响上一句 / 下一句，重播本句仍接管。
  assert.strictEqual(rt.key({ key: 'ArrowUp', code: 'ArrowUp' }).prevented, true);
  rt.setHidden(false);
  assert.strictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight' }).prevented, true);
  assert.deepStrictEqual(rt.actions, ['prev-cue', 'replay-cue', 'next-cue']);
});

test('BUG-4053 runtime：面板脚本缺席（无 fushiSubtitleStudyState）一律当没在出字', () => {
  const rt = createRuntime({}, { hasTrack: true, showing: true });
  rt.removeStudyState();
  assert.deepStrictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }), { prevented: false, stopped: false });
  assert.deepStrictEqual(rt.actions, []);
});

test('runtime：videoShortcutKeys 初读与热更新都生效（改完不必刷新页面）', () => {
  const rt = createRuntime({ videoShortcutKeys: { 'prev-cue': 'KeyJ' } });
  assert.ok(rt.requestedKeys.includes('videoShortcutKeys'));
  assert.strictEqual(rt.key({ key: 'j', code: 'KeyJ' }).prevented, true);
  assert.deepStrictEqual(rt.actions, ['prev-cue']);
  assert.strictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }).prevented, false, '旧键放行');
  rt.change('videoShortcutKeys', { 'prev-cue': 'Shift+KeyJ' });
  assert.strictEqual(rt.key({ key: 'j', code: 'KeyJ' }).prevented, false);
  assert.strictEqual(rt.key({ key: 'J', code: 'KeyJ', shiftKey: true }).prevented, true);
  rt.change('videoShortcutKeys', undefined);
  assert.strictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }).prevented, true, '删键回到默认');
});

test('options：每个快捷键行的键帽都是可点的改键按钮，覆盖全部动作', () => {
  const actions = [...optionsHtml.matchAll(/data-shortcut-action="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(actions.slice().sort(), Object.keys(VS.DEFAULT_COMBOS).sort());
  assert.ok(/<script src="video-shortcuts\.js"><\/script>[\s\S]*<script src="options\.js"><\/script>/.test(optionsHtml),
    '设置页要先装 video-shortcuts.js 才能复用规范化 / 显示');
  assert.ok(/loadShortcutKeys\(\)/.test(optionsJs));
});

// ── 反馈 dQjjzl7XWj：按秒快退 / 快进与按住临时倍速（App 视频页有、扩展此前没有）──
test('Shift+←/→：按秒快退 / 快进，不需要字幕轨；与 ←/→（上一句 / 下一句）各自独立', () => {
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.deepStrictEqual(decide(ev({ shift: true, key: 'ArrowLeft', code: 'ArrowLeft' }), noTrack), { action: 'seek-back' });
  assert.deepStrictEqual(decide(ev({ shift: true, key: 'ArrowRight', code: 'ArrowRight' }), noTrack), { action: 'seek-forward' });
  assert.deepStrictEqual(decide(ev({ key: 'ArrowLeft', code: 'ArrowLeft' }), CTX), { action: 'prev-cue' });
  // 裸键 E 默认关（DEFAULT_OFF）：没显式打开就放行给站点。
  assert.strictEqual(decide(ev({ code: 'KeyE' }), noTrack), null);
  const holdOn = { ...noTrack, bindings: { 'hold-speed': true } };
  assert.deepStrictEqual(decide(ev({ code: 'KeyE' }), holdOn), { action: 'hold-speed' });
  assert.strictEqual(decide(ev({ code: 'KeyE', editable: true }), holdOn), null, '输入框里打 e 照旧放行');
  assert.strictEqual(decide(ev({ code: 'KeyE' }), { ...holdOn, hasVideo: false }), null, '没有目标视频照旧放行');
  assert.strictEqual(
    decide(ev({ shift: true, code: 'ArrowLeft' }), { ...noTrack, bindings: { 'seek-back': false } }), null);
});

test('seekSeconds / holdRate 只认取值表；seekTarget 夹在 [0, 时长]', () => {
  assert.strictEqual(VS.seekSeconds(undefined), 5);
  assert.strictEqual(VS.seekSeconds('10'), 10);
  assert.strictEqual(VS.seekSeconds(10), 10);
  assert.strictEqual(VS.seekSeconds('7'), 5, '表外值回落默认');
  assert.strictEqual(VS.holdRate(undefined), 2);
  assert.strictEqual(VS.holdRate('2.5'), 2.5);
  assert.strictEqual(VS.holdRate('99'), 2);
  assert.strictEqual(VS.seekTarget(3, -5, 600), 0);
  assert.strictEqual(VS.seekTarget(598, 5, 600), 600);
  assert.strictEqual(VS.seekTarget(100, 5, NaN), 105, '直播 / 未知时长不夹上界');
  assert.ok(VS.SEEK_SECONDS_OPTIONS.includes(VS.SEEK_SECONDS_DEFAULT));
  assert.ok(VS.HOLD_RATE_OPTIONS.includes(VS.HOLD_RATE_DEFAULT));
});

test('runtime：快退 / 快进经 subtitle-panel 的 fushiSubtitleSeekBy（Netflix 走官方 seek），秒数跟设置热更新', () => {
  const rt = createRuntime({}, { hasTrack: false });
  assert.ok(rt.requestedKeys.includes('videoSeekSeconds'));
  assert.ok(rt.requestedKeys.includes('videoHoldSpeedRate'));
  assert.deepStrictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft', shiftKey: true }), { prevented: true, stopped: true });
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true }), { prevented: true, stopped: true });
  assert.deepStrictEqual(rt.seeks, [-5000, 5000]);
  rt.change('videoSeekSeconds', '10');
  rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true });
  assert.deepStrictEqual(rt.seeks, [-5000, 5000, 10000]);
  // 无字幕轨时裸 ←/→ 仍放行给站点（站点自己的 5s 快进）。
  assert.deepStrictEqual(rt.key({ key: 'ArrowLeft', code: 'ArrowLeft' }), { prevented: false, stopped: false });
});

test('runtime：执行端缺席时直接改 <video>.currentTime，夹在 [0, 时长]', () => {
  const rt = createRuntime({ videoSeekSeconds: '30' }, { seekBy: false });
  rt.video.currentTime = 10;
  rt.key({ key: 'ArrowLeft', code: 'ArrowLeft', shiftKey: true });
  assert.strictEqual(rt.video.currentTime, 0);
  rt.video.currentTime = 590;
  rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true });
  assert.strictEqual(rt.video.currentTime, 600);
});

test('runtime：按住 E 临时倍速，自动重复被吞，松开同一个键恢复原速', () => {
  const rt = createRuntime({ videoHoldSpeedRate: '3', videoShortcutHoldSpeed: true }, { hasTrack: false });
  rt.video.playbackRate = 1.25;
  assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE' }), { prevented: true, stopped: true });
  assert.strictEqual(rt.video.playbackRate, 3);
  assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE', repeat: true }), { prevented: true, stopped: true },
    '按住期间的自动重复不漏给站点');
  assert.strictEqual(rt.video.playbackRate, 3);
  assert.deepStrictEqual(rt.keyUp({ key: 'x', code: 'KeyX' }), { prevented: false, stopped: false }, '别的键松开不相干');
  assert.strictEqual(rt.video.playbackRate, 3);
  assert.deepStrictEqual(rt.keyUp({ key: 'e', code: 'KeyE' }), { prevented: true, stopped: true });
  assert.strictEqual(rt.video.playbackRate, 1.25, '恢复按下前的原速，不是 1x');
  assert.deepStrictEqual(rt.keyUp({ key: 'e', code: 'KeyE' }), { prevented: false, stopped: false }, '没在按住态时放行');
});

test('runtime：按住临时倍速时失焦 / 切走标签页（收不到 keyup）也恢复原速', () => {
  const rt = createRuntime({ videoShortcutHoldSpeed: true }, { hasTrack: false });
  rt.key({ key: 'e', code: 'KeyE' });
  assert.strictEqual(rt.video.playbackRate, 2);
  rt.blur();
  assert.strictEqual(rt.video.playbackRate, 1);
  rt.key({ key: 'e', code: 'KeyE' });
  assert.strictEqual(rt.video.playbackRate, 2);
  rt.hide();
  assert.strictEqual(rt.video.playbackRate, 1);
  // 关掉独立开关后 E 放行给站点。
  rt.change('videoShortcutHoldSpeed', false);
  assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE' }), { prevented: false, stopped: false });
  assert.strictEqual(rt.video.playbackRate, 1);
});

test('options：快退秒数 / 按住倍速下拉的取值与 video-shortcuts.js 取值表一致', () => {
  for (const [id, opts, dflt] of [
    ['videoSeekSeconds', VS.SEEK_SECONDS_OPTIONS, VS.SEEK_SECONDS_DEFAULT],
    ['videoHoldSpeedRate', VS.HOLD_RATE_OPTIONS, VS.HOLD_RATE_DEFAULT],
  ]) {
    const m = new RegExp('<select[^>]*id="' + id + '"[^>]*>([\\s\\S]*?)</select>').exec(optionsHtml);
    assert.ok(m, 'options.html 缺 ' + id);
    const values = [...m[1].matchAll(/value="([^"]+)"/g)].map((x) => x[1]);
    assert.deepStrictEqual(values, opts);
    assert.ok(optionsJs.includes(`${id}: { key: '${id}', fallback: '${dflt}' }`), 'options.js selectSettings 缺 ' + id);
  }
});

// 反馈 dQjjzl7XWj：快捷键可自定义之后，设置页说明里不能再写死某个键（改了键说明就错）。
test('设置页说明不再写死可改的快捷键（Shift+S / Shift+H）', () => {
  const path = require('node:path');
  const stale = /Shift\+S|Shift\+H|<kbd>/;
  const keys = ['opt_nfSubList_desc', 'opt_subtitleHidden_desc'];
  const enSrc = fs.readFileSync(require.resolve('./locales/en.js'), 'utf8');
  for (const key of keys) {
    const m = new RegExp('\\n  ' + key + ": '([^\\n]*)',\\n").exec(enSrc);
    assert.ok(m, key);
    assert.ok(!stale.test(m[1]), 'en ' + key + ' 仍写死了键：' + m[1]);
  }
  const dir = path.join(__dirname, 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.json'))) {
    const d = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    for (const key of keys) assert.ok(!stale.test(d[key]), f + ' ' + key + '：' + d[key]);
  }
  for (const key of keys) {
    const m = new RegExp('<small[^>]*="' + key + '"[^>]*>([\\s\\S]*?)</small>').exec(optionsHtml);
    assert.ok(m, 'options.html 缺 ' + key);
    assert.ok(!stale.test(m[1]), 'options.html 回退文案：' + m[1]);
  }
});

// ── 审查 major（BUG-4052 后续）：裸键 E 默认接管 + 门槛只看「DOM 里有 <video>」 → 任意带视频的
// 网页按 E 都被 capture 阶段吞掉（含 keyup），隐藏的 / 预告片 / 静音预览的 <video> 还被改成 2 倍速。
test('runtime：E 默认不接管——无存量、旧总开关 true 都放行给站点，视频不变速', () => {
  for (const settings of [{}, { videoShortcutsEnabled: true }]) {
    const rt = createRuntime(settings, { hasTrack: false });
    assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE' }), { prevented: false, stopped: false }, JSON.stringify(settings));
    assert.deepStrictEqual(rt.keyUp({ key: 'e', code: 'KeyE' }), { prevented: false, stopped: false });
    assert.strictEqual(rt.video.playbackRate, 1);
  }
  assert.strictEqual(VS.bindingDefault('hold-speed', true), false);
  assert.strictEqual(VS.bindingDefault('seek-back', undefined), true);
  assert.strictEqual(VS.bindingDefault('seek-back', false), false);
});

test('runtime：页面上只有隐藏 / 视口外 / 零尺寸的 <video> 时任何键都不接管、不碰视频', () => {
  const hidden = fakeVideo(rect(0, 0, 0, 0));
  const offscreen = fakeVideo(rect(0, 3000, 640, 360));
  const rt = createRuntime({ videoShortcutHoldSpeed: true }, { hasTrack: false, videos: [hidden, offscreen] });
  const passed = { prevented: false, stopped: false };
  assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE' }), passed);
  assert.deepStrictEqual(rt.keyUp({ key: 'e', code: 'KeyE' }), passed);
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true }), passed);
  assert.deepStrictEqual(rt.key({ key: '}', code: 'BracketRight', ctrlKey: true, shiftKey: true }), passed);
  assert.deepStrictEqual(rt.key({ key: 'H', code: 'KeyH', shiftKey: true }), passed);
  for (const v of [hidden, offscreen]) assert.strictEqual(v.playbackRate, 1);
  assert.deepStrictEqual(rt.seeks, []);
  assert.deepStrictEqual(rt.actions, []);
});

test('runtime：可见的只有静音预览时放行；Fushi 已挂字幕轨（在用 Fushi 看）时静音也算目标', () => {
  const preview = fakeVideo(rect(0, 0, 640, 360), { muted: true });
  const rt = createRuntime({ videoShortcutHoldSpeed: true }, { hasTrack: false, videos: [preview] });
  assert.deepStrictEqual(rt.key({ key: 'e', code: 'KeyE' }), { prevented: false, stopped: false });
  assert.deepStrictEqual(rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true }), { prevented: false, stopped: false });
  assert.strictEqual(preview.playbackRate, 1);

  const tracked = createRuntime({ videoShortcutHoldSpeed: true }, { hasTrack: true, videos: [preview] });
  assert.deepStrictEqual(tracked.key({ key: 'e', code: 'KeyE' }), { prevented: true, stopped: true });
  assert.strictEqual(preview.playbackRate, 2);
});

test('runtime：所有动作操作的是同一个目标视频，不是文档里第一个 <video>', () => {
  const trailer = fakeVideo(rect(0, 0, 0, 0)); // 排在前面的隐藏预告片
  const mutedHero = fakeVideo(rect(0, 0, 1280, 300), { muted: true }); // 静音自动播放位，比正片还大
  const main = fakeVideo(rect(0, 320, 960, 270));
  const rt = createRuntime({ videoShortcutHoldSpeed: true }, { hasTrack: false, seekBy: false, videos: [trailer, mutedHero, main] });
  rt.key({ key: '}', code: 'BracketRight', ctrlKey: true, shiftKey: true });
  assert.strictEqual(main.playbackRate, 1.25);
  rt.key({ key: 'ArrowRight', code: 'ArrowRight', shiftKey: true });
  assert.strictEqual(main.currentTime, 105);
  rt.key({ key: 'e', code: 'KeyE' });
  assert.strictEqual(main.playbackRate, 2);
  rt.keyUp({ key: 'e', code: 'KeyE' });
  assert.strictEqual(main.playbackRate, 1.25);
  for (const v of [trailer, mutedHero]) {
    assert.strictEqual(v.playbackRate, 1);
    assert.strictEqual(v.currentTime, 100);
  }
});

test('options：按住临时倍速开关无存量 / 旧总开关 true 时都默认不勾；其余动作照旧跟旧总开关', async () => {
  const defaults = await loadOptionsRuntime();
  assert.strictEqual(defaults.elements.videoShortcutHoldSpeed.checked, false);
  assert.strictEqual(defaults.elements.videoShortcutSeekBack.checked, true);
  const legacyOn = await loadOptionsRuntime({ videoShortcutsEnabled: true });
  assert.strictEqual(legacyOn.elements.videoShortcutHoldSpeed.checked, false);
  const explicit = await loadOptionsRuntime({ videoShortcutHoldSpeed: true });
  assert.strictEqual(explicit.elements.videoShortcutHoldSpeed.checked, true);
});
