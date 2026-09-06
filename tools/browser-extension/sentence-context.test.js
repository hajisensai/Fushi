// 多句合一制卡（扩展侧，与 app 内 MiningSentenceDraft 同一模型）的行为守卫。
//
// 用户诉求：「浏览器需要支持和本地一样的多句合一制卡」。app 内视频页/阅读器早有
// 「调整上下文」（上 N 句 / 下 N 句整体替换 → 句子 '\n' 连接、时间窗取并集）；扩展这边
// popup.js 是同一份字节、按钮与 handler 都在，只是宿主（content.js / bridge-shim.js）
// 从不接：fushiMineContext 只回一条 cue 窗，整轨和下标在 fushiFullTrackWindowAt 里算完
// 就丢。本文件在受控 vm 里真加载 subtitle-adapters/providers + content.js，断言：
//   1) setSentenceContext 整体替换、轨首/轨尾封顶、回传实际句数；
//   2) 入队项：sentence = 合成句（'\n'），录制窗 = 并集 ± 边距，cueStartV/cueEndV/mineAtV
//      仍是**当前句**（帧定位与 {clip-timestamp} 语义不变）；
//   3) 入队成功即归零（一次性草稿）；换词重渲染归零 + 门控 sentenceContextPreviewEnabled；
//   4) 没有整轨（只有 DOM 采样伪轨）时上下文不可用：计数 0、预览空、入队走单句。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const CONTENT = path.join(__dirname, 'content.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');

function loadContent(opts = {}) {
  const storageWrites = [];
  const intervals = [];
  const video = { currentTime: opts.currentTime || 0, paused: true, seeking: false, textTracks: [],
    addEventListener() {}, removeEventListener() {} };
  const windowObj = {
    addEventListener() {},
    postMessage() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now: () => 0 },
    location: {
      hostname: opts.hostname || 'www.netflix.com',
      href: 'https://' + (opts.hostname || 'www.netflix.com') + (opts.pathname || '/watch/81001'),
      pathname: opts.pathname || '/watch/81001',
      origin: 'https://' + (opts.hostname || 'www.netflix.com'),
      search: '',
    },
    window: windowObj,
    document: {
      documentElement: { dataset: {}, setAttribute() {} },
      head: { appendChild() {} },
      body: { appendChild() {}, style: {} },
      fullscreenElement: null,
      addEventListener() {},
      getElementById: () => null,
      querySelector: (sel) => (sel === 'video' ? video : null),
      querySelectorAll: () => [],
      createElement: () => ({
        style: {}, addEventListener() {}, appendChild() {}, setAttribute() {}, remove() {},
        classList: { add() {} },
      }),
    },
    chrome: {
      runtime: { id: 'test-ext-id', lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
      storage: {
        local: { get: () => {}, set(obj) { storageWrites.push(obj); } },
        onChanged: { addListener() {} },
      },
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), ctx, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), ctx, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), ctx, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), ctx, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx, { filename: 'content.js' });
  return { windowObj, video, storageWrites, ctx };
}

const TRACK = [
  { startMs: 1000, endMs: 2000, text: '第一句' },
  { startMs: 2500, endMs: 3500, text: '第二句' },
  { startMs: 4000, endMs: 5000, text: '第三句 当前' },
  { startMs: 5500, endMs: 6500, text: '第四句' },
  { startMs: 7000, endMs: 8000, text: '第五句' },
];

// 面板在场：活动轨即整轨（已应用时轴偏移的形态）。
function withTrack(h, cues) {
  h.windowObj.fushiActiveFullTrack = () => ({ lang: 'ja', cues: cues || TRACK });
}

function lastQueuedItem(h) {
  for (let i = h.storageWrites.length - 1; i >= 0; i--) {
    const q = h.storageWrites[i] && h.storageWrites[i].fushiQueue;
    if (Array.isArray(q) && q.length) return q[q.length - 1];
  }
  return null;
}

test('setSentenceContext：整体替换 + 轨首/轨尾封顶 + 回传实际句数', () => {
  const h = loadContent({ currentTime: 4.2 });
  withTrack(h);
  assert.strictEqual(h.windowObj.fushiSetSentenceContext(1, 1), 2);
  // 整体替换（不累加）：再设 1/1 仍是 2，不是 4。
  assert.strictEqual(h.windowObj.fushiSetSentenceContext(1, 1), 2);
  // 越过轨首/轨尾按真句封顶：前面只有 2 句、后面只有 2 句。
  assert.strictEqual(h.windowObj.fushiSetSentenceContext(9, 9), 4);
  const p = h.windowObj.fushiSentenceContextPreview({ matched: '当前' });
  // vm 里的数组/对象来自另一个 realm，deepStrictEqual 会因原型不同判不等，按 JSON 比。
  assert.strictEqual(JSON.stringify(p.prev), JSON.stringify(['第一句', '第二句']));
  assert.strictEqual(p.current, '第三句 当前');
  assert.strictEqual(p.currentOffset, 4, '所查词在当前句里的偏移（高亮用）');
  assert.strictEqual(JSON.stringify(p.next), JSON.stringify(['第四句', '第五句']));
  assert.strictEqual(p.total, 4);
  assert.strictEqual(p.prevAtMax, true);
  assert.strictEqual(p.nextAtMax, true);
  assert.strictEqual(h.windowObj.fushiClearSentenceDraft(), 0);
  assert.strictEqual(h.windowObj.fushiSentenceContextPreview({}).total, 0);
});

test('入队：合成句 + 并集录制窗；cueStartV/cueEndV/mineAtV 仍指当前句', () => {
  const h = loadContent({ currentTime: 4.2 });
  withTrack(h);
  h.windowObj.fushiSetSentenceContext(1, 2);
  const ctx = h.windowObj.fushiMineContext();
  assert.strictEqual(ctx.contextSentence, '第二句\n第三句 当前\n第四句\n第五句',
    "合成句必须与 app 内 joinMinedSentences 同形：逐句 trim、'\\n' 连接");
  assert.strictEqual(JSON.stringify(ctx.contextWindow), JSON.stringify({ startV: 2500, endV: 8000 }), '并集 = 首句起→末句止');
  assert.strictEqual(ctx.window.startV, 4000, '当前句窗不变');
  const r = h.windowObj.fushiEnqueue({ expression: '当前' }, '弹窗给的单句');
  assert.ok(r && r.ok);
  const item = lastQueuedItem(h);
  assert.strictEqual(item.sentence, '第二句\n第三句 当前\n第四句\n第五句', '合成句压过单句来源');
  assert.strictEqual(item.startV, 2300, '录制窗 = 并集 startMs - 200');
  assert.strictEqual(item.endV, 8200, '录制窗 = 并集 endMs + 200');
  assert.strictEqual(item.cueStartV, 4000, '静态帧「字幕开头」档仍定位当前句句首');
  assert.strictEqual(item.cueEndV, 5000, '{clip-timestamp} 仍是当前句字幕窗');
  assert.strictEqual(item.mineAtV, 4200, '制卡那一刻仍落在当前句内');
  // 一次性草稿：入队即归零，下一张卡回到单句。
  assert.strictEqual(h.windowObj.fushiSentenceContextPreview({}).total, 0);
  const again = h.windowObj.fushiMineContext();
  assert.strictEqual(again.contextSentence, null);
  assert.strictEqual(again.contextWindow, null);
});

test('未选上下文时入队与旧行为逐字节一致（单句、当前句窗 ± 边距）', () => {
  const h = loadContent({ currentTime: 4.2 });
  withTrack(h);
  h.windowObj.fushiEnqueue({ expression: '当前' }, '');
  const item = lastQueuedItem(h);
  assert.strictEqual(item.sentence, '第三句 当前');
  assert.strictEqual(item.startV, 3800);
  assert.strictEqual(item.endV, 5200);
});

test('面板行精确窗（fushiPendingCueWindow）也能定位整轨位置取上下文', () => {
  const h = loadContent({ currentTime: 0 }); // 播放头不在该句上
  withTrack(h);
  // 面板行制卡入口把该行的精确窗塞进 pending。
  h.windowObj.fushiSetSentenceContext(1, 0);
  const r = h.windowObj.fushiMineFromSidePanel({ expression: '第四' },
    { text: '第四句', startMs: 5500, endMs: 6500 });
  assert.ok(r && r.ok);
  const item = lastQueuedItem(h);
  assert.strictEqual(item.sentence, '第三句 当前\n第四句');
  assert.strictEqual(item.cueStartV, 5500);
  assert.strictEqual(item.startV, 3800, '并集从上一句起');
});

test('没有整轨（只有 DOM 采样伪轨）：上下文不可用，计数 0 / 预览空，入队走单句', () => {
  const h = loadContent({ currentTime: 4.2 });
  // 不装 fushiActiveFullTrack，也没有整轨 store → fushiCurrentCueLocation 为 null。
  assert.strictEqual(h.windowObj.fushiSetSentenceContext(2, 2), 0);
  assert.strictEqual(Object.keys(h.windowObj.fushiSentenceContextPreview({})).length, 0);
  const ctx = h.windowObj.fushiMineContext();
  assert.strictEqual(ctx.contextSentence, null);
});

test('换词重渲染：草稿归零、popup 镜像归零、门控只在整轨可定位时打开、embedMedia 恒真', () => {
  const h = loadContent({ currentTime: 4.2 });
  withTrack(h);
  h.windowObj.fushiSetSentenceContext(1, 1);
  let mirrorReset = 0;
  h.windowObj.resetSentenceContextMirror = () => { mirrorReset++; };
  h.windowObj.renderPopup = () => {};
  // fushiRenderEntries 是 content.js 顶层函数声明（隔离世界全局），不挂在 window 上。
  assert.strictEqual(h.ctx.fushiRenderEntries('[]'), true);
  assert.strictEqual(mirrorReset, 1, '换词必须把 popup.js 的上/下计数镜像归零');
  assert.strictEqual(h.windowObj.fushiSentenceContextPreview({}).total, 0, '宿主计数也归零');
  assert.strictEqual(h.windowObj.sentenceContextPreviewEnabled, true, '整轨可定位 → 渲染「调整上下文」按钮');
  assert.strictEqual(h.windowObj.embedMedia, true,
    'BUG-2190：外字必须登记进 dictionaryMedia 并导出 <img>，否则退化 alt 文本压正文');
  assert.ok(h.windowObj.i18nCtx && h.windowObj.i18nCtx.adjust, '模态文案已注入');

  // 播放头落在字幕间隙 → 当前句定位不到 → 按钮不渲染（诚实：此刻没有上下文可调）。
  h.video.currentTime = 2.2;
  h.ctx.fushiRenderEntries('[]');
  assert.strictEqual(h.windowObj.sentenceContextPreviewEnabled, false);
});

test('fushiComposeCueContext 纯函数：越界 null、封顶、空句丢弃、并集', () => {
  const { fushiComposeCueContext } = require('./subtitle-adapters.js');
  assert.strictEqual(fushiComposeCueContext(TRACK, -1, 1, 1), null);
  assert.strictEqual(fushiComposeCueContext(TRACK, 5, 1, 1), null);
  assert.strictEqual(fushiComposeCueContext(null, 0, 1, 1), null);
  const c = fushiComposeCueContext(
    [{ startMs: 0, endMs: 900, text: '  ' }, { startMs: 1000, endMs: 2000, text: ' 中 ' }, { startMs: 1500, endMs: 3000, text: '后' }],
    1, 1, 1);
  assert.strictEqual(c.sentence, '中\n后', '空句丢弃、逐句 trim（同 Dart joinMinedSentences）');
  assert.strictEqual(JSON.stringify(c.prev), JSON.stringify(['  ']));
  assert.strictEqual(c.startV, 0);
  assert.strictEqual(c.endV, 3000);
  const solo = fushiComposeCueContext(TRACK, 2, 0, 0);
  assert.strictEqual(solo.sentence, '第三句 当前');
  assert.strictEqual(solo.prevAtMax, false);
  assert.strictEqual(solo.nextAtMax, false);
});
