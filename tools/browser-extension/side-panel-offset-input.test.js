// 用户群 10-09：字幕延迟要能手动输入数值（与 app 视频页一致）——盗版源片头常多出几十秒，
// ±0.1 / ±0.5 按不过来。两个入口：播放器内嵌菜单（player-controls.js）与 Side Panel。
// 本文件钉住：① 两份解析器同一语义（Side Panel 页面不装 player-controls.js，只能各留一份）；
// ② Side Panel 发出的绝对偏移在 subtitle-panel.js 里按「绝对值、0 = 复位」落地。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const PC = require('./player-controls.js');

function extract(src, name) {
  const start = src.indexOf('function ' + name + '(');
  assert.ok(start >= 0, name + ' 不见了');
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error('unbalanced ' + name);
}

test('Side Panel 与播放器菜单的偏移解析 / 显示逐例同义', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(extract(src, 'parseOffsetSeconds') + '\n' + extract(src, 'formatOffsetSeconds'), ctx);
  for (const input of ['1.5', '+90', '−12.25', '－3', '2,5', '7s', '7 秒', '', 'abc', '1.2.3', '--1', '3601', '0', '.5']) {
    assert.strictEqual(ctx.parseOffsetSeconds(input), PC.parseOffsetSeconds(input), JSON.stringify(input));
  }
  for (const ms of [0, 1500, -42000, 123, 100, -100, 4, -4, -1]) {
    assert.strictEqual(ctx.formatOffsetSeconds(ms), PC.formatOffsetSeconds(ms), String(ms));
  }
});

test('Side Panel 的偏移框是可输入的 <input>，回车 / 失焦发绝对偏移', () => {
  const html = fs.readFileSync(path.join(__dirname, 'side-panel.html'), 'utf8');
  assert.match(html, /<input id="offset-value" type="text" inputmode="decimal"/);
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  assert.match(src, /type: 'fushiSubtitleSidePanelOffset', absoluteMs: ms/);
});

// ── subtitle-panel.js 落地：绝对值、0 = 复位 ─────────────────────────────
function loadPanel() {
  const listeners = [];
  const toasts = [];
  const video = { currentTime: 0, getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 450 }) };
  const el = () => ({
    style: {}, children: [], setAttribute() {}, getAttribute: () => null, appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}, removeChild() {}, classList: { add() {}, remove() {}, toggle() {} },
  });
  const html = el();
  const windowObj = {
    fushiT: (k) => k,
    fushiToast: (m) => toasts.push(m),
    fushiEpisodeCues: { 'example.com/v|ja': [{ startMs: 1000, endMs: 2000, text: 'a' }] },
    addEventListener() {},
  };
  const sandbox = {
    window: windowObj,
    document: {
      documentElement: html, body: html, fullscreenElement: null,
      addEventListener() {}, getElementById: () => null,
      querySelector: (s) => (s === 'video' ? video : null), querySelectorAll: () => [],
      createElement: el,
    },
    location: { hostname: 'example.com', pathname: '/v' },
    setInterval: () => 1, clearInterval() {},
    chrome: {
      storage: {
        local: { get: (_k, cb) => { if (cb) cb({ netflixSubtitlePanel: true }); }, set() {} },
        onChanged: { addListener() {} },
      },
      runtime: { lastError: null, sendMessage() {}, onMessage: { addListener: (fn) => listeners.push(fn) } },
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8'), sandbox);
  return {
    windowObj, toasts,
    send(msg) {
      let out;
      for (const fn of listeners) { fn(msg, {}, (v) => { out = v; }); if (out !== undefined) break; }
      return out;
    },
  };
}

test('fushiSubtitleSidePanelOffset {absoluteMs}：直接设成该值，0 = 复位，增量调用照旧', () => {
  const p = loadPanel();
  p.send({ type: 'fushiSubtitleSidePanelState', includeCues: false });
  let s = p.send({ type: 'fushiSubtitleSidePanelOffset', absoluteMs: -42000 });
  assert.strictEqual(s.offsetMs, -42000);
  s = p.send({ type: 'fushiSubtitleSidePanelOffset', deltaMs: 100 });
  assert.strictEqual(s.offsetMs, -41900, '±0.1 按钮在手填值上继续累加');
  s = p.send({ type: 'fushiSubtitleSidePanelOffset', absoluteMs: 0 });
  assert.strictEqual(s.offsetMs, 0);
});

test('播放器菜单入口 fushiSubtitleSetOffset / fushiSubtitleSelectTrack / fushiSubtitleTrackList', () => {
  const p = loadPanel();
  const list = p.windowObj.fushiSubtitleTrackList();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(list.tracks.map((t) => t.lang))), ['ja']);
  assert.strictEqual(list.active, 'ja');
  assert.strictEqual(p.windowObj.fushiSubtitleSetOffset(12500), true);
  assert.strictEqual(p.windowObj.fushiSubtitleTrackList().offsetMs, 12500);
  assert.ok(p.toasts.length, '设偏移给一条可见反馈');
  assert.strictEqual(p.windowObj.fushiSubtitleSelectTrack('nope'), false, '不存在的轨不切');
  assert.strictEqual(p.windowObj.fushiSubtitleSelectTrack('ja'), true);
});
