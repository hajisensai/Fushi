// 反馈 #RvwGCEtAsd：YouTube 自动字幕 Shift 悬停站点原生字幕制卡错位——卡上的词是上一行的
// 「striking」，例句和片段时间窗却是下一行「algebraic like ways to concretely」。
//
// 根因：YouTube 滚动自动字幕屏上同时有上下两行 `.caption-visual-line`，整轨（ASR 轨经
// youtube-bridge clampRollingCues 截断）里上一行 A 的 endMs == 下一行 B 的 startMs。悬停原生
// 字幕查词走 fushiShiftScanAt → fushiSendLookup(term, rect, null, …)，cueWindow 恒为 null；
// 制卡时 fushiMineContext 只能按**播放时刻**到整轨里查（findCueIndexAt：startMs <= now 的最后
// 一条且 now < endMs），此刻只命中 B——用户悬停的那一行在查词时就丢了。
// 修法：悬停命中站点原生字幕时，按与 live 采样同一套分行规则（fushiCaptionLineGroups）认出被
// 悬停的那一行，用行文本在整轨里起点不晚于当前时刻的最近几条 cue 中匹配，匹配到就作为精确窗
// 传进 fushiSendLookup；匹配不到保持原行为（按播放时刻取整轨）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');
const BRIDGE = path.join(__dirname, 'bridge-shim.js');
const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');

const LINE_A = 'the most striking thing';
const LINE_B = 'algebraic like ways to concretely';
const TRACK = [
  { startMs: 0, endMs: 1000, text: 'so here we go' },
  { startMs: 1000, endMs: 3000, text: LINE_A },
  { startMs: 3000, endMs: 6000, text: LINE_B },
  { startMs: 6000, endMs: 8000, text: 'and then later' },
];

function element(classes, children) {
  const el = {
    nodeType: 1,
    tagName: 'DIV',
    classes: classes,
    childNodes: children || [],
    parentNode: null,
    parentElement: null,
    get textContent() { return this.childNodes.map((c) => c.textContent).join(''); },
    closest(sel) {
      let cur = this;
      while (cur) {
        if (cur.classes && cur.classes.indexOf(sel.replace(/^\./, '')) >= 0) return cur;
        cur = cur.parentElement;
      }
      return null;
    },
    contains(node) {
      let cur = node;
      while (cur) {
        if (cur === this) return true;
        cur = cur.parentNode;
      }
      return false;
    },
  };
  for (const c of el.childNodes) { c.parentNode = el; c.parentElement = el; }
  return el;
}

function textNode(value) {
  return { nodeType: 3, nodeValue: value, textContent: value, parentNode: null, parentElement: null };
}

// 真实 YouTube 结构：.ytp-caption-window-container > .captions-text > .caption-visual-line >
// .ytp-caption-segment > #text。
function captionDom() {
  const textA = textNode(LINE_A);
  const textB = textNode(LINE_B);
  const segA = element(['ytp-caption-segment'], [textA]);
  const segB = element(['ytp-caption-segment'], [textB]);
  const lineA = element(['caption-visual-line'], [segA]);
  const lineB = element(['caption-visual-line'], [segB]);
  const root = element(['captions-text'], [lineA, lineB]);
  const container = element(['ytp-caption-window-container'], [root]);
  return { textA, textB, segA, segB, lineA, lineB, root, container };
}

function loadWorld(dom, hit) {
  const docListeners = Object.create(null);
  const video = { currentTime: 4.0, paused: true, seeking: false, textTracks: [],
    addEventListener() {}, removeEventListener() {} };
  const selection = {
    getCharacterAtPoint: () => hit,
    selectFromPosition: (node, offset) => {
      const text = String(node.textContent || '');
      const s = text.lastIndexOf(' ', offset) + 1;
      const e = text.indexOf(' ', offset);
      return text.slice(s, e < 0 ? text.length : e);
    },
    getSelectionRect: () => ({ x: 10, y: 10, width: 20, height: 16 }),
    highlightSelection: () => ({ x: 10, y: 10, width: 20, height: 16 }),
    clearSelection() {},
    getSentence: () => '',
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 0,
    clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    location: {
      hostname: 'www.youtube.com',
      href: 'https://www.youtube.com/watch?v=vid1',
      pathname: '/watch',
      origin: 'https://www.youtube.com',
      search: '?v=vid1',
    },
  };
  sandbox.document = {
    documentElement: { dataset: {}, setAttribute() {} },
    head: { appendChild() {} },
    body: { appendChild() {}, style: {} },
    title: 'video',
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    getElementById: () => null,
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: (sel) => {
      if (sel === '.ytp-caption-segment') return [dom.segA, dom.segB];
      if (sel === '.captions-text') return [dom.root];
      if (sel === '.ytp-caption-window-container') return [dom.container];
      return [];
    },
    createElement: () => ({
      style: {},
      dataset: {},
      classList: { add() {}, remove() {}, toggle() {} },
      addEventListener() {},
      removeEventListener() {},
      appendChild() {},
      setAttribute() {},
      remove() {},
      contains: () => false,
    }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        const reply = msg && msg.type === 'lookup'
          ? { ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } }
          : { ok: true, data: {} };
        if (typeof cb === 'function') cb(reply);
        return Promise.resolve(reply);
      },
    },
    storage: {
      local: {
        get: (_keys, cb) => { if (typeof cb === 'function') cb({}); return Promise.resolve({}); },
        set: async () => {},
      },
      onChanged: { addListener() {} },
    },
  };
  sandbox.window = {
    addEventListener() {},
    postMessage() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: selection,
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  // manifest content_scripts 的真实相对顺序（同一 isolated world 里互相提供全局）。
  vm.runInContext(fs.readFileSync(BRIDGE, 'utf8'), sandbox, { filename: 'bridge-shim.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  // 面板在场：活动轨即整轨（ASR 截断后的形态：A.endMs == B.startMs）。
  sandbox.window.fushiActiveFullTrack = () => ({ lang: 'en', cues: TRACK });
  return {
    windowObj: sandbox.window,
    hover: (x, y) => {
      const ev = { shiftKey: true, clientX: x, clientY: y, buttons: 0 };
      for (const fn of docListeners.mousemove || []) fn(ev);
    },
  };
}

test('悬停上一行 A 的词：制卡句子与时间窗取 A，而不是播放时刻命中的 B', () => {
  const dom = captionDom();
  const w = loadWorld(dom, { node: dom.textA, offset: LINE_A.indexOf('striking') + 2 });
  w.hover(300, 600);
  const ctx = w.windowObj.fushiMineContext();
  assert.ok(ctx.window, '应有当前字幕窗');
  assert.strictEqual(ctx.window.text, LINE_A,
    '例句取成了播放时刻那一行——用户悬停的是上一行');
  assert.strictEqual(ctx.window.startV, 1000);
  assert.strictEqual(ctx.window.endV, 3000);
});

test('悬停下一行 B 的词：仍取 B', () => {
  const dom = captionDom();
  const w = loadWorld(dom, { node: dom.textB, offset: LINE_B.indexOf('ways') + 1 });
  w.hover(300, 640);
  const ctx = w.windowObj.fushiMineContext();
  assert.ok(ctx.window, '应有当前字幕窗');
  assert.strictEqual(ctx.window.text, LINE_B);
  assert.strictEqual(ctx.window.startV, 3000);
  assert.strictEqual(ctx.window.endV, 6000);
});

test('行文本在整轨最近几条里对不上：保持原行为，按播放时刻取整轨', () => {
  const dom = captionDom();
  dom.textA.nodeValue = 'nothing like this anywhere';
  dom.textA.textContent = dom.textA.nodeValue;
  const w = loadWorld(dom, { node: dom.textA, offset: 2 });
  w.hover(300, 600);
  const ctx = w.windowObj.fushiMineContext();
  assert.ok(ctx.window, '应有当前字幕窗');
  assert.strictEqual(ctx.window.text, LINE_B);
  assert.strictEqual(ctx.window.startV, 3000);
});

test('不是站点原生字幕（普通页面文本）：不带精确窗，按播放时刻取整轨', () => {
  const dom = captionDom();
  const stray = textNode(LINE_A);
  element(['some-article'], [stray]);
  const w = loadWorld(dom, { node: stray, offset: 10 });
  w.hover(100, 100);
  const ctx = w.windowObj.fushiMineContext();
  assert.ok(ctx.window, '应有当前字幕窗');
  assert.strictEqual(ctx.window.text, LINE_B);
});
