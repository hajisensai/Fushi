const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');
const { decide, nextRate } = require('./video-shortcuts.js');
const optionsHtml = fs.readFileSync(require.resolve('./options.html'), 'utf8');
const optionsJs = fs.readFileSync(require.resolve('./options.js'), 'utf8');

// asb 移植：视频页快捷键判定矩阵。decide 是纯函数：ev={key,code,ctrl,shift,alt,editable}，
// ctx={enabled,hasVideo,hasTrack}，返回 {action} 或 null（null = 放行给站点）。

const CTX = { enabled: true, hasVideo: true, hasTrack: true };
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
];

function ev(over) {
  return Object.assign({ key: '', code: '', ctrl: false, shift: false, alt: false, editable: false }, over);
}

function createRuntime(initialSettings = {}, { hasTrack = true } = {}) {
  const source = fs.readFileSync(require.resolve('./video-shortcuts.js'), 'utf8');
  let keydown;
  let storageChanged;
  let requestedKeys;
  const actions = [];
  const video = { playbackRate: 1 };
  const fakeWindow = {
    hibikiEpisodeCues: hasTrack ? { 'episode|ja': [{ start: 0, end: 1, text: '字幕' }] } : {},
    hibikiVideoKey: () => 'episode',
    hibikiSubtitleShortcut(action) {
      actions.push(action);
      return true;
    },
    addEventListener(type, handler) {
      if (type === 'keydown') keydown = handler;
    },
  };
  const context = {
    self: fakeWindow,
    window: fakeWindow,
    document: {
      querySelector(selector) {
        return selector === 'video' ? video : null;
      },
    },
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
  vm.runInNewContext(source, context);
  assert.strictEqual(typeof keydown, 'function');
  assert.strictEqual(typeof storageChanged, 'function');

  return {
    actions,
    requestedKeys,
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

test('Shift+S：仅有 Hibiki 字幕轨时切换面板；旧 Shift+P/O/F 不再接管', () => {
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
      `${code} must remain available to the site without a Hibiki track`,
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
