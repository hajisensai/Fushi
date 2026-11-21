// 反馈 97pds8EODm：YouTube 自动字幕（ASR）分句整合（扩展设置 subtitleMergeAsrSentences）。
//
// ASR 轨的 cue 是「滚动行」——按屏幕宽度切，不按句子切，一句话常拆成两三行碎片，查词 / 制卡
// 只拿到半句。fushiMergeAsrSentenceCues（subtitle-adapters.js）按句重切；youtube-bridge.js 给
// ASR 轨的每行附上词级时间（json3 segs 的 tOffsetMs）并标 asr: true。
// 隔离世界的持有 / 开关切换 / 人工轨不受影响见 universal-subtitle-providers.test.js 同名用例。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const { fushiMergeAsrSentenceCues } = require('./subtitle-adapters.js');

const words = (pairs) => pairs.map(([offsetMs, text]) => ({ offsetMs, text }));

function assertMonotoneNoOverlap(cues) {
  for (let i = 0; i < cues.length; i++) {
    assert.ok(cues[i].endMs >= cues[i].startMs, 'cue ' + i + ' 时长不得为负');
    if (i) assert.ok(cues[i - 1].endMs <= cues[i].startMs, 'cue ' + (i - 1) + ' 越过了下一句开始');
  }
}

test('句号落在行中间：按下一个词的起点切开，前半句并进上一行', () => {
  const out = fushiMergeAsrSentenceCues([
    { startMs: 18800, endMs: 21800, text: "We're no strangers to", words: words([[0, "We're"], [700, ' no'], [1400, ' strangers'], [2200, ' to']]) },
    { startMs: 21800, endMs: 25960, text: 'love. You know the rules and so do', words: words([[0, 'love.'], [500, ' You'], [800, ' know'], [1100, ' the'], [1400, ' rules'], [1900, ' and'], [2300, ' so'], [3400, ' do']]) },
    { startMs: 25960, endMs: 29119, text: "I. I feel commitments from what I'm", words: words([[0, 'I.'], [600, ' I'], [800, ' feel'], [1200, ' commitments'], [2000, ' from'], [2300, ' what'], [2700, " I'm"]]) },
    { startMs: 29119, endMs: 34360, text: 'thinking' },
  ]);
  assert.deepStrictEqual(out, [
    { startMs: 18800, endMs: 22300, text: "We're no strangers to love." },
    { startMs: 22300, endMs: 26560, text: 'You know the rules and so do I.' },
    { startMs: 26560, endMs: 34360, text: "I feel commitments from what I'm thinking" },
  ]);
  assertMonotoneNoOverlap(out);
});

test('日语无标点：行间直接相连不补空格，词间停顿 ≥1.2s 断句', () => {
  const out = fushiMergeAsrSentenceCues([
    { startMs: 0, endMs: 1500, text: '今日は', words: words([[0, '今日'], [400, 'は']]) },
    { startMs: 1500, endMs: 4000, text: 'いい天気です', words: words([[0, 'いい'], [400, '天気'], [900, 'です']]) },
    // 「です」起点 2400 → 「明日」起点 4000：间隔 1.6s = 句间停顿。
    { startMs: 4000, endMs: 6000, text: '明日は雨', words: words([[0, '明日'], [400, 'は'], [700, '雨']]) },
  ]);
  assert.deepStrictEqual(out.map((c) => c.text), ['今日はいい天気です', '明日は雨']);
  assert.strictEqual(out[1].startMs, 4000);
  assertMonotoneNoOverlap(out);
});

test('没有标点也没有停顿：超过 12 秒在行边界断开，绝不在行中间切', () => {
  const lines = [];
  for (let i = 0; i < 8; i++) {
    const startMs = i * 3000;
    lines.push({ startMs, endMs: startMs + 3000, text: 'ab cd ef', words: words([[0, 'ab'], [1000, ' cd'], [2000, ' ef']]) });
  }
  const out = fushiMergeAsrSentenceCues(lines);
  assert.ok(out.length > 1, '必须封顶');
  for (const cue of out) {
    assert.ok(cue.endMs - cue.startMs <= 12000, '合并后不得超过 12 秒：' + JSON.stringify(cue));
    assert.strictEqual(cue.startMs % 3000, 0, '只在行边界断开');
    assert.ok(/^(ab cd ef)( ab cd ef)*$/.test(cue.text), '行文本完整：' + cue.text);
  }
  assert.strictEqual(out.map((c) => c.text).join(' '), Array(8).fill('ab cd ef').join(' '), '一个词都不丢');
  assertMonotoneNoOverlap(out);
});

test('中日文字数封顶 60 字（行边界）', () => {
  const line = 'あいうえおかきくけこさしすせそたちつてと'; // 20 字
  const out = fushiMergeAsrSentenceCues([0, 1, 2, 3, 4].map((i) => ({ startMs: i * 1000, endMs: (i + 1) * 1000, text: line })));
  assert.deepStrictEqual(out.map((c) => c.text.length), [60, 40]);
});

test('[音楽] / [Music] 整行括注单独成句，不并进前后台词', () => {
  const out = fushiMergeAsrSentenceCues([
    { startMs: 0, endMs: 1000, text: 'hello' },
    { startMs: 1000, endMs: 3000, text: '[Music]' },
    { startMs: 3000, endMs: 4000, text: 'and welcome' },
    { startMs: 4000, endMs: 5000, text: 'back' },
    { startMs: 5000, endMs: 6000, text: '［拍手］' },
  ]);
  assert.deepStrictEqual(out.map((c) => c.text), ['hello', '[Music]', 'and welcome back', '［拍手］']);
});

test('无词级时间（本地 server 兜底轨）：只按标点合并；有真空白（≥0.6s）也断', () => {
  const out = fushiMergeAsrSentenceCues([
    { startMs: 0, endMs: 1000, text: 'so this is' },
    { startMs: 1000, endMs: 2000, text: 'the end?' },
    { startMs: 2000, endMs: 3000, text: 'maybe' },
    { startMs: 4000, endMs: 5000, text: 'not' },
  ]);
  assert.deepStrictEqual(out, [
    { startMs: 0, endMs: 2000, text: 'so this is the end?' },
    { startMs: 2000, endMs: 3000, text: 'maybe' },
    { startMs: 4000, endMs: 5000, text: 'not' },
  ]);
});

test('词级数据与行文本对不上 / 坏时间：整行当一个词，不信任坏数据', () => {
  const out = fushiMergeAsrSentenceCues([
    { startMs: 0, endMs: 2000, text: 'one. two', words: words([[0, 'uno.'], [500, ' dos']]) },
    { startMs: 2000, endMs: 4000, text: 'three. four', words: words([[300, 'three.'], [100, ' four']]) },
  ]);
  // 第一行词对不上 → 整行一个词元（句号不在行尾，不断）；第二行倒序 offset 被夹成单调。
  assert.deepStrictEqual(out, [
    { startMs: 0, endMs: 2300, text: 'one. two three.' },
    { startMs: 2300, endMs: 4000, text: 'four' },
  ]);
  assertMonotoneNoOverlap(out);
});

test('输入乱序 / 空文本 / 非数组：按起点排序、跳过空行、非数组回空', () => {
  assert.deepStrictEqual(fushiMergeAsrSentenceCues(null), []);
  const out = fushiMergeAsrSentenceCues([
    { startMs: 1000, endMs: 2000, text: 'world.' },
    { startMs: 500, endMs: 600, text: '   ' },
    { startMs: 0, endMs: 1000, text: 'hello' },
  ]);
  assert.deepStrictEqual(out, [{ startMs: 0, endMs: 2000, text: 'hello world.' }]);
});

// ── youtube-bridge.js：ASR 轨带词级时间与 asr 标记，人工轨不带 ──
const BRIDGE = fs.readFileSync(path.join(__dirname, 'youtube-bridge.js'), 'utf8');

function loadBridge(kind, events) {
  const posted = [];
  const sandbox = {
    window: { ytcfg: { get() { return 'x'; } }, addEventListener() {}, postMessage(msg) { posted.push(msg); } },
    document: {
      querySelector(sel) {
        if (sel !== '#movie_player') return null;
        return {
          getVideoData() { return { video_id: 'vid1' }; },
          getAudioTrack() {
            return {
              captionTracks: [{
                languageCode: 'en', kind, name: { simpleText: 'English' },
                baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=en',
              }],
              defaultCaptionTrackIndex: 0,
              languageCode: 'en',
            };
          },
        };
      },
      addEventListener() {},
    },
    location: {
      get pathname() { return '/watch'; },
      get search() { return '?v=vid1'; },
      get href() { return 'https://www.youtube.com/watch?v=vid1'; },
    },
    URL, URLSearchParams,
    Date: { now() { return 1000000; } },
    setInterval() { return 1; },
    clearInterval() {},
    fetch(url) {
      if (/fmt=json3/.test(String(url))) {
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ events }) });
      }
      return Promise.resolve({ ok: false, status: 404 });
    },
  };
  vm.runInNewContext(BRIDGE, sandbox, { filename: 'youtube-bridge.js' });
  return {
    posted,
    flush: async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); },
  };
}

const JSON3_EVENTS = [
  { tStartMs: 18800, dDurationMs: 7160, segs: [{ utf8: "We're" }, { utf8: ' no', tOffsetMs: 700 }, { utf8: ' strangers', tOffsetMs: 1400 }] },
  { tStartMs: 21790, dDurationMs: 4170, aAppend: 1, segs: [{ utf8: '\n' }] },
  { tStartMs: 21800, dDurationMs: 4160, segs: [{ utf8: 'love.' }] },
];

test('桥：ASR 轨消息带 asr: true，多词行带 words（相对行起点），单词行不带', async () => {
  const b = loadBridge('asr', JSON3_EVENTS);
  await b.flush();
  const msg = b.posted.find((m) => m.__fushiStream === 'cues');
  assert.ok(msg, '桥必须发布 cues');
  assert.strictEqual(msg.asr, true);
  const cues = JSON.parse(JSON.stringify(msg.cues));
  assert.deepStrictEqual(cues[0].words, [
    { offsetMs: 0, text: "We're" }, { offsetMs: 700, text: ' no' }, { offsetMs: 1400, text: ' strangers' },
  ]);
  assert.strictEqual(cues[0].endMs, 21800, '滚动双行截断照旧');
  assert.strictEqual(cues[1].words, undefined, '单 seg 行没有可用的词级时间');
});

test('桥：人工轨不带 asr 标记也不带 words（数据契约不变）', async () => {
  const b = loadBridge('', JSON3_EVENTS);
  await b.flush();
  const msg = b.posted.find((m) => m.__fushiStream === 'cues');
  assert.ok(msg);
  assert.strictEqual(msg.asr, undefined);
  for (const cue of msg.cues) assert.strictEqual(cue.words, undefined);
});
