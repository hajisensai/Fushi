// 用户报「浏览器扩展查词不取所在句子」的行为守卫。
//
// 根因：制卡例句的来源过去全部绑在**字幕**上——多句合一草稿 / Netflix 字幕 DOM / 当前字幕行 /
// 弹窗内选区。在一篇普通文章上 Shift 悬停查词，前三级恒空、弹窗里也没选任何东西 → 卡上没有
// 例句。而句子一直就在页面 DOM 里：`vendor/selection.js` 带着一份与 app 阅读器同源的
// `getSentence(node, offset)`，扩展 manifest 装了它，却**从来没有任何代码调用过**
// （零调用，grep 可证）。查词命中的 (文本节点, 偏移) 在 content.js 手里，制卡时却没人拿它取句。
//
// 这里断言的是接线本身：
//   1) Shift 悬停查词后，fushiMineContext().pageSentence = 命中点所在的整句（惰性算一次并缓存）；
//   2) 该句真的落进 bridge-shim 发出的 /api/mine 消息的 sentence 字段（普通网页立即出卡那条路）；
//   3) 优先级不夺权：有字幕行 / 有弹窗内选区时，例句仍是原来那一级，页面句只在它们都空时兜底；
//   4) 每次查词都重算：换词后不得把上一个词的句子带过去；侧栏直发词（无页面锚点）取不到句。
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

// 一段真实文章的最小替身：一个文本节点，两句话。getSentence 的桩按句末标点切句，与
// vendor/selection.js 的分隔符集合同语义（这里只需证明「宿主真的去调它了、拿对了锚点」）。
const ARTICLE = '昨日は雨だった。今日は世界がまぶしい。';
const ARTICLE_NODE = { textContent: ARTICLE, nodeType: 3 };

function sentenceAt(text, offset) {
  const enders = '。！？.!?\n';
  let start = offset;
  let end = offset;
  while (start > 0 && !enders.includes(text[start - 1])) start--;
  while (end < text.length && !enders.includes(text[end])) end++;
  return text.slice(start, Math.min(end + 1, text.length)).trim();
}

// content.js + bridge-shim.js 装进同一个受控 content-script 世界（真实运行时里它们本来就
// 同世界、同页面：manifest content_scripts 顺序是 bridge-shim → … → content）。
function loadWorld(opts) {
  const options = opts || {};
  const sent = [];
  const docListeners = Object.create(null);
  const dataset = {};
  const getSentenceCalls = [];
  const selection = {
    getCharacterAtPoint: () => ({
      node: ARTICLE_NODE,
      offset: options.offset === undefined ? 12 : options.offset,
    }),
    selectFromPosition: () => options.term || '世界',
    getSelectionRect: () => ({ x: 10, y: 10, width: 20, height: 16 }),
    highlightSelection: () => ({ x: 10, y: 10, width: 20, height: 16 }),
    clearSelection() {},
    getSentence: (node, offset) => {
      getSentenceCalls.push({ node, offset });
      if (options.sentence !== undefined) return options.sentence;
      return sentenceAt(String(node.textContent || ''), offset);
    },
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
      hostname: 'example.com',
      href: 'https://example.com/a',
      pathname: '/a',
      origin: 'https://example.com',
      search: '',
    },
  };
  sandbox.document = {
    documentElement: { dataset, setAttribute() {} },
    head: { appendChild() {} },
    body: { appendChild() {}, style: {} },
    title: '記事タイトル',
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
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
        // bridge-shim 加载时的 dictMediaConfig 探测与制卡无关，滤掉免得占住 sent[0]。
        if (!msg || msg.type !== 'dictMediaConfig') sent.push(msg);
        const reply = msg && msg.type === 'lookup'
          ? { ok: true, data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] } }
          : { ok: true, data: { result: 'success' } };
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
  // manifest content_scripts 的真实顺序（同一 isolated world 里这些脚本互相提供全局）。
  vm.runInContext(fs.readFileSync(BRIDGE, 'utf8'), sandbox, { filename: 'bridge-shim.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });

  return {
    sent,
    getSentenceCalls,
    windowObj: sandbox.window,
    hover: (x, y) => {
      const ev = {
        shiftKey: true,
        clientX: x === undefined ? 300 : x,
        clientY: y === undefined ? 400 : y,
        buttons: 0,
      };
      for (const fn of docListeners.mousemove || []) fn(ev);
    },
    mine: (fields) =>
      sandbox.window.flutter_inappwebview.callHandler('mineEntry', fields || FIELDS),
  };
}

const FIELDS = { expression: '世界', reading: 'せかい', popupSelectionText: '' };

test('普通网页 Shift 悬停查词后，制卡上下文带上命中点所在的整句', () => {
  const w = loadWorld();
  w.hover();
  assert.strictEqual(
    w.windowObj.fushiMineContext().pageSentence,
    '今日は世界がまぶしい。',
    '页面 DOM 里的句子没有被取出来——这正是用户报的「查词不取所在句子」');
});

test('该句真的落进 /api/mine 的 sentence 字段（普通网页立即出卡）', async () => {
  const w = loadWorld();
  w.hover();
  const ok = await w.mine();
  assert.strictEqual(ok, true);
  const mines = w.sent.filter((m) => m && m.type === 'mine');
  assert.strictEqual(mines.length, 1, '普通网页应立即出卡，不进批量队列');
  assert.strictEqual(mines[0].sentence, '今日は世界がまぶしい。', '卡上的例句仍是空的');
});

test('取句是惰性的：悬停本身不算句，要句子时才算，且同一次查词只算一次', async () => {
  const w = loadWorld();
  w.hover();
  assert.strictEqual(w.getSentenceCalls.length, 0,
    'Shift 悬停是每几像素一次的高频路径，不得在这里算句');
  w.windowObj.fushiMineContext();
  w.windowObj.fushiMineContext();
  await w.mine();
  assert.strictEqual(w.getSentenceCalls.length, 1, '同一次查词内取句结果必须缓存');
  assert.strictEqual(w.getSentenceCalls[0].offset, 12,
    '取句锚点必须是本次查词真正命中的字符偏移');
});

test('换词重查：不得把上一个词的句子带到下一张卡上', () => {
  const w = loadWorld();
  w.hover(300, 400);
  assert.strictEqual(w.windowObj.fushiMineContext().pageSentence, '今日は世界がまぶしい。');
  // 第二次查词命中前一句（偏移落在「昨日は雨だった。」内），词也换了 → 必须重算。
  w.windowObj.fushiSelection.getCharacterAtPoint = () => ({ node: ARTICLE_NODE, offset: 3 });
  w.windowObj.fushiSelection.selectFromPosition = () => '雨';
  w.hover(600, 500);
  assert.strictEqual(w.windowObj.fushiMineContext().pageSentence, '昨日は雨だった。',
    '页面句没有跟着查词刷新，卡上会出现上一个词的句子');
});

test('侧栏把词直接交回来（没有页面命中点）时取不到句，行为与改动前一致', () => {
  const w = loadWorld();
  w.hover();
  assert.ok(w.windowObj.fushiMineContext().pageSentence);
  w.windowObj.fushiShowLookupFromSidePanel('世界', null, 0.5);
  assert.strictEqual(w.windowObj.fushiMineContext().pageSentence, '',
    '无页面锚点时必须留空，不得拿上一次悬停的句子顶替');
});

test('无句末标点的超长块不入卡：宁可没有例句，也不塞一整段进 Anki 字段', () => {
  const w = loadWorld({ sentence: 'あ'.repeat(400) });
  w.hover();
  assert.strictEqual(w.windowObj.fushiMineContext().pageSentence, '',
    '整段无标点时应判定「这里没有可用的句子」');
});

test('优先级不夺权：有当前字幕行时例句仍来自字幕轨', async () => {
  const w = loadWorld();
  w.hover();
  const real = w.windowObj.fushiMineContext;
  w.windowObj.fushiMineContext = () => Object.assign(real(), {
    window: { text: '正道ではなく邪道', startV: 61000, endV: 64500 },
    site: 'other',
    clip: null,
    youtubeId: null,
    netflixId: null,
    mineAtV: 62200,
  });
  await w.mine();
  const mines = w.sent.filter((m) => m && m.type === 'mine');
  assert.strictEqual(mines[0].sentence, '正道ではなく邪道',
    '页面句抢了字幕行的位置——字幕站点的例句必须保持原样');
});

test('优先级不夺权：用户在弹窗里选了释义文本时，那份显式选区优先', async () => {
  const w = loadWorld();
  w.hover();
  await w.mine(Object.assign({}, FIELDS, { popupSelectionText: '選んだテキスト' }));
  const mines = w.sent.filter((m) => m && m.type === 'mine');
  assert.strictEqual(mines[0].sentence, '選んだテキスト',
    '用户在弹窗内主动选的文本是显式意图，不得被自动取的页面句盖掉');
});
