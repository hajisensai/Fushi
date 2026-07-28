const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');
const { decide, nextRate } = require('./video-shortcuts.js');

// asb 移植：视频页快捷键判定矩阵。decide 是纯函数：ev={key,code,ctrl,shift,alt,editable}，
// ctx={enabled,hasVideo,hasTrack}，返回 {action} 或 null（null = 放行给站点）。

const CTX = { enabled: true, hasVideo: true, hasTrack: true };

function ev(over) {
  return Object.assign({ key: '', code: '', ctrl: false, shift: false, alt: false, editable: false }, over);
}

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

test('Shift+P/O/F/S：仅有 Hibiki 字幕轨时切换播放模式与面板', () => {
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyP' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyO' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyF' }), noTrack), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyS' }), noTrack), null);
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyP' }), CTX), { action: 'toggle-autopause' });
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyO' }), CTX), { action: 'toggle-condensed' });
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyF' }), CTX), { action: 'toggle-fastforward' });
  assert.deepStrictEqual(decide(ev({ shift: true, code: 'KeyS' }), CTX), { action: 'toggle-panel' });
});

test('Shift+H：隐藏字幕**不需要**字幕轨（藏的是站点原生字幕）', () => {
  // 这是本键与 Shift+P/O/F/S 的关键差异，也是最容易写错的地方：hasTrack 问的是「扩展这边
  // 加载过字幕轨没有」，而隐藏字幕作用的是站点自带字幕 + 扩展覆盖层。绝大多数用户看的是
  // 站点原生字幕、从没往扩展里挂过轨——若卡在 hasTrack 门后面，这个键在主场景下永不触发。
  const noTrack = { enabled: true, hasVideo: true, hasTrack: false };
  assert.deepStrictEqual(
    decide(ev({ shift: true, code: 'KeyH' }), noTrack), { action: 'toggle-subtitle-hide' });
  assert.deepStrictEqual(
    decide(ev({ shift: true, code: 'KeyH' }), CTX), { action: 'toggle-subtitle-hide' });
});

test('Shift+H：无视频 / 输入框 / 加 Ctrl 或 Alt 时不接管', () => {
  const noVideo = { enabled: true, hasVideo: false, hasTrack: false };
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyH' }), noVideo), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyH', editable: true }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, alt: true, code: 'KeyH' }), CTX), null);
  // Ctrl+Shift+H 落进上面的 ctrl+shift 分支，未登记 → 放行（不误吞浏览器/站点组合键）。
  assert.strictEqual(decide(ev({ ctrl: true, shift: true, code: 'KeyH' }), CTX), null);
  // 裸 H 交给站点（很多播放器自己用它），只有带 Shift 才是我们的。
  assert.strictEqual(decide(ev({ key: 'h', code: 'KeyH' }), CTX), null);
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

test('普通打字（Shift+字母之外）不接管', () => {
  assert.strictEqual(decide(ev({ key: 'a', code: 'KeyA' }), CTX), null);
  assert.strictEqual(decide(ev({ shift: true, code: 'KeyQ' }), CTX), null);
  assert.strictEqual(decide(ev({ ctrl: true, code: 'KeyC' }), CTX), null); // Ctrl+C 复制绝不抢
});

test('nextRate：0.25 步进、clamp 0.25–4', () => {
  assert.strictEqual(nextRate(1, 0.25), 1.25);
  assert.strictEqual(nextRate(1, -0.25), 0.75);
  assert.strictEqual(nextRate(0.25, -0.25), 0.25);
  assert.strictEqual(nextRate(4, 0.25), 4);
  assert.strictEqual(nextRate(undefined, 0.25), 1.25); // 坏输入按 1x 起步
});

test('runtime leaves site Shift shortcuts untouched without a Hibiki track', () => {
  const source = fs.readFileSync(require.resolve('./video-shortcuts.js'), 'utf8');
  let keydown;
  const fakeWindow = {
    addEventListener(type, handler) {
      if (type === 'keydown') keydown = handler;
    },
  };
  const context = {
    self: fakeWindow,
    window: fakeWindow,
    document: {
      querySelector(selector) {
        return selector === 'video' ? { playbackRate: 1 } : null;
      },
    },
    chrome: {
      storage: {
        local: { get: () => Promise.resolve({ videoShortcutsEnabled: true }) },
        onChanged: { addListener() {} },
      },
    },
  };
  vm.runInNewContext(source, context);
  assert.strictEqual(typeof keydown, 'function');

  for (const code of ['KeyP', 'KeyO', 'KeyF', 'KeyS']) {
    let prevented = false;
    let stopped = false;
    keydown({
      key: code.slice(-1),
      code,
      shiftKey: true,
      ctrlKey: false,
      metaKey: false,
      altKey: false,
      target: null,
      preventDefault() { prevented = true; },
      stopPropagation() { stopped = true; },
    });
    assert.strictEqual(prevented, false, `${code} must remain available to the site`);
    assert.strictEqual(stopped, false, `${code} must continue propagating`);
  }
});
