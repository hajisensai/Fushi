// 窗口宿主档 DOM 字幕层（fushi/assets/web_video/web_video_dom_subtitles.js）契约测试：
// 在最小假 DOM 里真加载脚本，验证字形切分、cue 定位、渲染与点词载荷形状（Dart 侧
// parseWebVideoLookupPayload 按同一形状解析）。
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = fs.readFileSync(
  path.join(HERE, '..', '..', 'fushi', 'assets', 'web_video', 'web_video_dom_subtitles.js'),
  'utf8',
);

function fakeEl(tag) {
  const el = {
    tag, id: '', style: {}, dataset: {}, children: [], parentNode: null, listeners: {},
    textContent: '',
    get firstChild() { return el.children[0] || null; },
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); c.parentNode = el; el.children.push(c); return c; },
    removeChild(c) { el.children = el.children.filter((x) => x !== c); c.parentNode = null; return c; },
    addEventListener(type, fn) { (el.listeners[type] = el.listeners[type] || []).push(fn); },
    getBoundingClientRect() { return { left: 100 + (+el.dataset.fushiG || 0) * 20, top: 700, width: 20, height: 36 }; },
    fire(type, ev) { for (const fn of el.listeners[type] || []) fn(ev); },
  };
  return el;
}

function makeSandbox({ currentTime = 12.3 } = {}) {
  const body = fakeEl('body');
  const posted = [];
  const video = { currentTime };
  const document = {
    body,
    documentElement: body,
    fullscreenElement: null,
    createElement: fakeEl,
    querySelector: (sel) => (sel === 'video' ? video : null),
    addEventListener() {},
  };
  const window = {
    document,
    screenX: 50, screenY: 60, devicePixelRatio: 1.5,
    fushiEpisodeCues: {},
    flutter_inappwebview: { callHandler: (name, payload) => posted.push({ name, payload }) },
  };
  window.window = window;
  const timers = [];
  const sandbox = {
    window, document, Intl, Symbol, Array, String, Math, isFinite,
    setInterval: (fn) => { timers.push(fn); return timers.length; },
    clearInterval: () => {},
  };
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox, { filename: 'web_video_dom_subtitles.js' });
  return { sb: sandbox, api: window.__fushiDomSubs, body, posted, video, timers };
}

const CUES = [
  { startMs: 10000, endMs: 11500, text: '六万年前' },
  { startMs: 12000, endMs: 14000, text: '沙漠蝗🦗来了' },
  { startMs: 20000, endMs: 21000, text: 'later' },
];

// vm 上下文里的数组/对象原型与宿主不同，deepStrictEqual 会因原型不等而假红；按纯值比。
const plain = (v) => JSON.parse(JSON.stringify(v));

test('graphemes：Intl.Segmenter 按字形切（emoji 不拆成代理对）', () => {
  const { api } = makeSandbox();
  assert.deepStrictEqual(plain(api._pure.graphemes('沙漠蝗🦗来了')), ['沙', '漠', '蝗', '🦗', '来', '了']);
  assert.deepStrictEqual(plain(api._pure.graphemes('')), []);
});

test('cueAt：二分取覆盖当前时刻的 cue，间隙回 null', () => {
  const { api } = makeSandbox();
  assert.strictEqual(api._pure.cueAt(CUES, 10500).text, '六万年前');
  assert.strictEqual(api._pure.cueAt(CUES, 11800), null, '11500~12000 是间隙');
  assert.strictEqual(api._pure.cueAt(CUES, 13999).text, '沙漠蝗🦗来了');
  assert.strictEqual(api._pure.cueAt(CUES, 5000), null);
  assert.strictEqual(api._pure.cueAt([], 5000), null);
});

test('setTrack 早于轨到达：不渲染；轨进 store 后 refresh 才渲染；只挂一个定时器', () => {
  const { sb, api, body, timers } = makeSandbox({ currentTime: 12.3 });
  api.setEnabled(true);
  api.setEnabled(true);
  assert.strictEqual(timers.length, 1, '重复启用不叠定时器');
  assert.strictEqual(api.setTrack('81236554|zh-Hans'), 0);
  assert.strictEqual(body.children.length, 0, '轨不存在 → 不渲染');
  sb.window.fushiEpisodeCues['81236554|zh-Hans'] = CUES;
  assert.strictEqual(api.refresh(), 3, 'refresh 重读 store');
  assert.strictEqual(body.children.length, 1);
  assert.deepStrictEqual(plain(api.current()), { startMs: 12000, endMs: 14000, text: '沙漠蝗🦗来了' });
});

test('渲染 + 点击载荷形状（Dart parseWebVideoLookupPayload 契约）', () => {
  const { sb, api, body, posted } = makeSandbox({ currentTime: 12.3 });
  sb.window.fushiEpisodeCues['81236554|zh-Hans'] = CUES;
  api.setEnabled(true);
  api.setTrack('81236554|zh-Hans');
  assert.strictEqual(body.children.length, 1, '当前 cue 渲染进 body');
  const line = body.children[0].children[0];
  assert.strictEqual(line.children.length, 6, '6 个字形 span');
  assert.strictEqual(line.children[3].textContent, '🦗');
  assert.strictEqual(line.children[3].dataset.fushiG, '3');

  const ev = { target: line.children[3], clientX: 170, clientY: 710, stopPropagation() {}, preventDefault() {} };
  line.fire('click', ev);
  assert.strictEqual(posted.length, 1);
  const p = posted[0].payload;
  assert.strictEqual(posted[0].name, 'fushiWebVideo');
  assert.strictEqual(p.type, 'lookup');
  assert.strictEqual(p.kind, 'click');
  assert.strictEqual(p.sentence, '沙漠蝗🦗来了');
  assert.strictEqual(p.index, 3);
  assert.strictEqual(p.cueStart, 12000);
  assert.strictEqual(p.cueEnd, 14000);
  assert.deepStrictEqual(plain(p.rect), { x: 160, y: 700, w: 20, h: 36 });
  assert.strictEqual(p.screenX, 50);
  assert.strictEqual(p.screenY, 60);
  assert.strictEqual(p.dpr, 1.5);
});

test('悬停自动查词：默认关；开后 4px 阈值 + 同字形去重；离开重置', () => {
  const { sb, api, body, posted } = makeSandbox({ currentTime: 10.5 });
  sb.window.fushiEpisodeCues['k'] = CUES;
  api.setEnabled(true);
  api.setTrack('k');
  const line = body.children[0].children[0];
  const mv = (i, x) => line.fire('mousemove', { target: line.children[i], clientX: x, clientY: 700 });
  mv(0, 100);
  assert.strictEqual(posted.length, 0, 'hoverAuto 默认关');
  api.setHoverAuto(true);
  mv(0, 100);
  mv(0, 102);
  assert.strictEqual(posted.length, 1, '2px 位移不触发');
  mv(0, 120);
  assert.strictEqual(posted.length, 1, '同一字形不重复');
  mv(1, 140);
  assert.strictEqual(posted.length, 2);
  assert.strictEqual(posted[1].payload.kind, 'hover');
  line.fire('mouseleave', {});
  mv(1, 160);
  assert.strictEqual(posted.length, 3, '离开后同字形可再触发');
});

test('时间走到间隙 / 关闭层：字幕元素从 DOM 摘掉；换轨重绘', () => {
  const { sb, api, body, video, timers } = makeSandbox({ currentTime: 10.5 });
  sb.window.fushiEpisodeCues['a'] = CUES;
  sb.window.fushiEpisodeCues['b'] = [{ startMs: 10000, endMs: 11000, text: 'B' }];
  api.setEnabled(true);
  api.setTrack('a');
  assert.strictEqual(body.children[0].children[0].children.length, 4);
  video.currentTime = 11.8;
  timers[0]();
  assert.strictEqual(body.children.length, 0, '间隙时摘掉');
  video.currentTime = 10.5;
  api.setTrack('b');
  assert.strictEqual(body.children[0].children[0].children[0].textContent, 'B');
  api.setEnabled(false);
  assert.strictEqual(body.children.length, 0);
  assert.strictEqual(api.current(), null);
});
