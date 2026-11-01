// live 轨（DOM 字幕采样）回拖后无限累加的回归。
//
// 根因：YouTube 滚动自动字幕屏上同时有上下两行（两个 .caption-visual-line），旧采样把所有
// .ytp-caption-segment 拼成一句——每条 cue 都带着上一行；回拖后快照又按「句首相差 <750ms 且全文
// 相等」去重，对不上就插入一条重叠的新 cue，只增不删，Dart 侧把重叠 cue 全部叠画。
// 修法：按行采样（滚到上一行的旧行不再拼进来），写入按时间区间合并（live 轨 cue 两两不重叠），
// seek 后要等 DOM 真变过才接受第一份快照。这里在受控 vm 里真加载 subtitle-providers.js，手动驱动
// 200ms 采样器。Netflix 的 .player-timedtext 整句替换路径一并钉住。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');

function textNode(value) {
  return { nodeType: 3, nodeValue: value, textContent: value };
}

// 一个 .ytp-caption-segment：closest('.caption-visual-line') 回它所在的行节点。
function segmentNode(text, line) {
  return {
    nodeType: 1,
    tagName: 'SPAN',
    childNodes: [textNode(text)],
    textContent: text,
    closest(sel) { return sel === '.caption-visual-line' ? line : null; },
  };
}

function load(opts) {
  const intervals = [];
  const listeners = Object.create(null);
  const dom = { lines: [], netflix: '' };
  const video = {
    currentTime: 0,
    seeking: false,
    paused: false,
    textTracks: [],
    addEventListener(type, fn) { (listeners[type] || (listeners[type] = new Set())).add(fn); },
    removeEventListener(type, fn) { if (listeners[type]) listeners[type].delete(fn); },
    emit(type) { for (const fn of listeners[type] || []) fn.call(this); },
  };
  const host = (opts && opts.hostname) || 'www.youtube.com';
  const windowObj = { addEventListener() {}, postMessage() {} };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: {
      hostname: host,
      pathname: (opts && opts.pathname) || '/watch',
      search: (opts && opts.search) || '?v=vid1',
      href: 'https://' + host + ((opts && opts.pathname) || '/watch') + ((opts && opts.search) || '?v=vid1'),
      origin: 'https://' + host,
    },
    window: windowObj,
    document: {
      documentElement: { dataset: {} },
      body: {},
      fullscreenElement: null,
      addEventListener() {},
      querySelector: (sel) => (sel === 'video' ? video : null),
      querySelectorAll(sel) {
        if (sel === '.player-timedtext') {
          return dom.netflix ? [{ nodeType: 1, tagName: 'DIV', childNodes: [textNode(dom.netflix)] }] : [];
        }
        if (sel !== '.ytp-caption-segment') return [];
        const out = [];
        for (const line of dom.lines) {
          const lineNode = { line };
          for (const seg of line) out.push(segmentNode(seg, lineNode));
        }
        return out;
      },
      createElement: () => ({ style: {}, classList: { add() {} } }),
    },
    chrome: {
      runtime: { id: 't', onMessage: { addListener() {} }, sendMessage() {} },
      storage: { local: { get() {}, set() {} }, onChanged: { addListener() {} } },
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), ctx, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), ctx, { filename: 'subtitle-providers.js' });
  const sampler = intervals.find((i) => i.ms === 200);
  return {
    dom,
    video,
    windowObj,
    // 在视频时间 sec 采一次，屏上是 lines（每行若干 segment）。
    at(sec, lines) {
      video.currentTime = sec;
      dom.lines = lines;
      sampler.fn();
    },
    netflixAt(sec, text) {
      video.currentTime = sec;
      dom.netflix = text;
      sampler.fn();
    },
    seekTo(sec) {
      video.seeking = true;
      video.emit('seeking');
      video.currentTime = sec;
      video.seeking = false;
      video.emit('seeked');
    },
    track(key) {
      return JSON.parse(JSON.stringify(windowObj.fushiEpisodeCues[key] || []));
    },
  };
}

function assertNoOverlap(track) {
  for (let i = 1; i < track.length; i++) {
    assert.ok(track[i - 1].startMs <= track[i].startMs, 'live 轨按起点有序');
    assert.ok(track[i - 1].endMs <= track[i].startMs,
      `live 轨 cue 两两不重叠：${JSON.stringify(track[i - 1])} / ${JSON.stringify(track[i])}`);
  }
}

// 一段滚动自动字幕：每行逐字长出来，长满后滚到上一行，新行在下面接着长。
function playRolling(h, fromSec) {
  const t = fromSec;
  h.at(t + 0.0, [['We\'re']]);
  h.at(t + 0.4, [['We\'re no strangers']]);
  h.at(t + 0.8, [['We\'re no strangers to love']]);
  h.at(t + 1.2, [['We\'re no strangers to love'], ['You']]);
  h.at(t + 1.6, [['We\'re no strangers to love'], ['You know the']]);
  h.at(t + 2.0, [['We\'re no strangers to love'], ['You know the rules']]);
  h.at(t + 2.4, [['You know the rules'], ['and so']]);
  h.at(t + 2.8, [['You know the rules'], ['and so do I']]);
  h.at(t + 3.6, []);
}

test('滚动双行：每行各自成句，不把上一行拼进下一句', () => {
  const h = load();
  playRolling(h, 10);
  const track = h.track('yt-vid1|live');
  assert.deepStrictEqual(track.map((c) => c.text),
    ['We\'re no strangers to love', 'You know the rules', 'and so do I']);
  assert.deepStrictEqual(track.map((c) => [c.startMs, c.endMs]),
    [[10000, 11200], [11200, 12400], [12400, 13600]]);
  assertNoOverlap(track);
});

test('滚动双行：多个 segment 同在一行时拼成这一行，行与行仍分开', () => {
  const h = load();
  h.at(5, [['こんにちは', '世界']]);
  h.at(6, [['こんにちは', '世界'], ['また', '明日']]);
  h.at(7, []);
  assert.deepStrictEqual(h.track('yt-vid1|live').map((c) => c.text), ['こんにちは世界', 'また明日']);
});

test('回拖重放同一段：轨不增长、不重叠（无限累加回归）', () => {
  const h = load();
  playRolling(h, 10);
  const first = h.track('yt-vid1|live');
  for (let i = 0; i < 3; i++) {
    h.seekTo(10);
    playRolling(h, 10);
  }
  const after = h.track('yt-vid1|live');
  assert.deepStrictEqual(after.map((c) => c.text), first.map((c) => c.text));
  assertNoOverlap(after);
});

test('seek 落在句中先采到后半，之后从句首回放：并成一条（更早起点、更完整文本）', () => {
  const h = load();
  // 先 seek 到句中：屏上这一行已经长到一半。
  h.seekTo(11.5);
  h.at(11.5, [['You know the rules']]);
  h.at(12.0, [['You know the rules and so']]);
  h.at(12.8, []);
  const partial = h.track('yt-vid1|live');
  assert.strictEqual(partial.length, 1);
  assert.strictEqual(partial[0].startMs, 11500);

  // 回拖到句首，从头经过同一句。
  h.seekTo(10.5);
  h.at(10.5, [['You']]);
  h.at(11.0, [['You know']]);
  h.at(11.5, [['You know the rules']]);
  h.at(12.0, [['You know the rules and so']]);
  h.at(12.4, [['You know the rules and so do I']]);
  h.at(13.0, []);
  const track = h.track('yt-vid1|live');
  assert.strictEqual(track.length, 1, JSON.stringify(track));
  assert.strictEqual(track[0].text, 'You know the rules and so do I');
  assert.strictEqual(track[0].startMs, 10500);
  assert.strictEqual(track[0].endMs, 13000);
});

test('seek 落点上已有两行：上面那行是更早的句子，只从最后一行起采', () => {
  for (const playedBefore of [false, true]) {
    const h = load();
    // playedBefore=false：本代第一份快照（打开页面 / 开字幕时已是两行）；true：播放中真 seek。
    if (playedBefore) h.at(1, [['intro']]);
    h.seekTo(30);
    h.at(30, [['first line'], ['second']]);
    h.at(30.5, [['first line'], ['second line']]);
    h.at(31, [['second line'], ['third']]);
    h.at(32, []);
    const track = h.track('yt-vid1|live').filter((c) => c.text !== 'intro');
    assert.deepStrictEqual(track.map((c) => c.text), ['second line', 'third']);
    assert.strictEqual(track[0].startMs, 30000);
    assertNoOverlap(track);
  }
});

test('seek 后 DOM 还挂着旧位置的字幕：不按新时间入轨，等 DOM 变过再接受', () => {
  const h = load();
  h.at(50, [['old place line']]);
  h.at(51, [['old place line']]);
  h.seekTo(5);
  // 旧画面残留两拍。
  h.at(5.0, [['old place line']]);
  h.at(5.2, [['old place line']]);
  // 目标位置的字幕到了。
  h.at(5.4, [['new place line']]);
  h.at(6.4, []);
  const track = h.track('yt-vid1|live');
  assert.deepStrictEqual(track.map((c) => [c.text, c.startMs]),
    [['new place line', 5400], ['old place line', 50000]]);
  assert.strictEqual(track.find((c) => c.text === 'old place line').endMs, 51000, '旧句按 seek 前末次采样定格');
});

test('同一 DOM 节点持续扩长超过 12 秒：按新增后缀切成下一行', () => {
  const h = load();
  h.at(0, [['aaa']]);
  h.at(6, [['aaa bbb']]);
  h.at(12.5, [['aaa bbb ccc']]);
  h.at(14, []);
  const track = h.track('yt-vid1|live');
  assert.deepStrictEqual(track.map((c) => c.text), ['aaa bbb', 'ccc']);
  assert.deepStrictEqual(track.map((c) => [c.startMs, c.endMs]), [[0, 12500], [12500, 14000]]);
  assertNoOverlap(track);
});

test('Netflix .player-timedtext 整句替换：每句一条，回放不重复', () => {
  const h = load({ hostname: 'www.netflix.com', pathname: '/watch/81001', search: '' });
  const play = () => {
    h.netflixAt(100, '一句目です');
    h.netflixAt(102, '二句目です');
    h.netflixAt(104, '');
  };
  play();
  h.seekTo(100);
  play();
  const track = h.track('81001|live');
  assert.deepStrictEqual(track.map((c) => [c.text, c.startMs, c.endMs]),
    [['一句目です', 100000, 102000], ['二句目です', 102000, 104000]]);
});
