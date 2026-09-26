// BUG-2629：YouTube 制卡音频多录了下一行的句子。
//
// YouTube 自动字幕是「滚动双行」显示：每一行 cue 的 dDurationMs / d 一直跨到**下下行**开头，
// 靠中间那条 `\n` 追加行截断。实测 dQw4w9WgXcQ（en asr）：
//   t=18800 d=7160  "We're no strangers to"        （→ 25960）
//   t=21790 d=4170  "\n"（a=1 追加行）
//   t=21800 d=7319  "love. You know the rules…"   （→ 29119）
//   t=25950 d=3169  "\n"
//   t=25960 …
// srv3 解析只在「下一行恰是 \n 行」时截断；json3 回落路径以前不截断——制卡按 cue 窗裁音频，
// 裁出来的是两行的声音，卡上却只有第一行的字。这里在受控 vm 里真加载 youtube-bridge.js，
// 走 json3（含**没有** \n 行的变体）取轨，断言发布出去的 cue 两两不重叠。
//
// BUG-2697（issue #1495）：桥跑在 MAIN world，YouTube 强制 Trusted Types，DOM 解析器的
// parseFromString 对裸字符串必抛 TrustedHTML 异常，srv3 路径已删、只取 json3。沙箱里的
// DOM 解析器换成「一调用就像真 YouTube 那样抛」的桩，并断言桥从不请求 fmt=srv3。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.join(__dirname, 'youtube-bridge.js'), 'utf8');

// 真实自动字幕形状（json3 events）。
const ROLLING_EVENTS = [
  { tStartMs: 0, dDurationMs: 211879, segs: [{ utf8: '' }] }, // 首条空占位事件（真实响应就有）
  { tStartMs: 320, dDurationMs: 14260, segs: [{ utf8: '[Music]' }] },
  { tStartMs: 18790, aAppend: 1, segs: [{ utf8: '\n' }] },
  { tStartMs: 18800, dDurationMs: 7160, segs: [{ utf8: "We're no strangers to" }] },
  { tStartMs: 21790, dDurationMs: 4170, aAppend: 1, segs: [{ utf8: '\n' }] },
  { tStartMs: 21800, dDurationMs: 7319, segs: [{ utf8: 'love. You know the rules and so do' }] },
  { tStartMs: 25950, dDurationMs: 3169, aAppend: 1, segs: [{ utf8: '\n' }] },
  { tStartMs: 25960, dDurationMs: 4319, segs: [{ utf8: "I. I feel commitments from what I'm" }] },
  { tStartMs: 29109, dDurationMs: 1170, aAppend: 1, segs: [{ utf8: '\n' }] },
  { tStartMs: 29119, dDurationMs: 5241, segs: [{ utf8: 'thinking' }] },
];

// 去掉 \n 追加行的同一形状（部分轨没有它，只剩重叠的正文行）。
const ROLLING_EVENTS_NO_APPEND = ROLLING_EVENTS.filter((e) => !e.aAppend);

// 真 YouTube 页面在 Trusted Types 强制下对裸字符串 parseFromString 的行为：直接抛。
function TrustedTypesDOMParser() {}
TrustedTypesDOMParser.prototype.parseFromString = function () {
  throw new TypeError("This document requires 'TrustedHTML' assignment and no 'default' policy for 'TrustedHTML' has been defined.");
};

function loadBridge(options) {
  const posted = [];
  const requests = [];
  const windowObject = {
    ytcfg: { get() { return 'x'; } },
    addEventListener() {},
    postMessage(msg) { posted.push(msg); },
  };
  const player = {
    getVideoData() { return { video_id: 'vid1' }; },
    getAudioTrack() {
      return {
        captionTracks: [{
          languageCode: 'en',
          // 默认自动字幕；传 kind: '' 模拟人工上传轨（YouTube 对人工轨不带 kind）。
          kind: options.kind === undefined ? 'asr' : options.kind,
          name: { simpleText: 'English (auto)' },
          baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=en&kind=asr',
        }],
        defaultCaptionTrackIndex: 0,
        languageCode: 'en',
      };
    },
  };
  const sandbox = {
    window: windowObject,
    document: {
      querySelector(sel) { return sel === '#movie_player' ? player : null; },
      addEventListener() {},
    },
    location: {
      get pathname() { return '/watch'; },
      get search() { return '?v=vid1'; },
      get href() { return 'https://www.youtube.com/watch?v=vid1'; },
    },
    URL, URLSearchParams, DOMParser: TrustedTypesDOMParser,
    Date: { now() { return 1000000; } },
    setInterval() { return 1; },
    clearInterval() {},
    fetch(url) {
      const u = String(url);
      requests.push(u);
      if (/fmt=json3/.test(u)) {
        if (!options.json3) return Promise.resolve({ ok: false, status: 404 });
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(options.json3) });
      }
      return Promise.resolve({ ok: false, status: 404 });
    },
  };
  vm.runInNewContext(SOURCE, sandbox, { filename: 'youtube-bridge.js' });
  const flush = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };
  return { posted, requests, flush };
}

function publishedCues(h) {
  const msg = h.posted.find((m) => m.__fushiStream === 'cues');
  assert.ok(msg, '桥必须发布 cues');
  return JSON.parse(JSON.stringify(msg.cues)); // 跨 vm 上下文的数组原型不同，deepStrictEqual 会把它当不同类型
}

function assertNoOverlap(cues) {
  for (let i = 0; i < cues.length - 1; i++) {
    assert.ok(
      cues[i].endMs <= cues[i + 1].startMs,
      'cue ' + i + ' "' + cues[i].text + '" 结束 ' + cues[i].endMs + ' 越过了下一行开始 ' + cues[i + 1].startMs,
    );
    assert.ok(cues[i].endMs > cues[i].startMs, 'cue ' + i + ' 时长必须为正');
  }
}

test('BUG-2629：json3 回落路径——滚动双行的 cue 结束收到下一行开始，不再跨两行', async () => {
  const h = loadBridge({ json3: { events: ROLLING_EVENTS } });
  await h.flush();
  const cues = publishedCues(h);
  assert.deepStrictEqual(cues.map((c) => c.text), [
    '[Music]', "We're no strangers to", 'love. You know the rules and so do',
    "I. I feel commitments from what I'm", 'thinking',
  ]);
  assertNoOverlap(cues);
  const line = cues.find((c) => c.text === "We're no strangers to");
  assert.strictEqual(line.startMs, 18800);
  assert.strictEqual(line.endMs, 21800, '这一行的音频窗必须止于下一行开始（原来是 25960，把下一行整句录进去）');
  const music = cues[0];
  assert.strictEqual(music.endMs, 320 + 14260, '本就不重叠的 cue 时长原样保留');
});

test('BUG-2697：只取 json3，从不请求 srv3（MAIN world 下 srv3 解析必撞 TrustedHTML）', async () => {
  const h = loadBridge({ json3: { events: ROLLING_EVENTS } });
  await h.flush();
  const captionRequests = h.requests.filter((u) => /\/api\/timedtext/.test(u));
  assert.ok(captionRequests.length > 0, '必须取过字幕');
  for (const u of captionRequests) {
    assert.ok(/fmt=json3/.test(u), '字幕请求必须是 json3：' + u);
    assert.ok(!/fmt=srv3/.test(u), '不得再白发 srv3 请求：' + u);
  }
  assert.strictEqual(captionRequests.length, 1, '一条轨恰好一次请求');
  assert.strictEqual(publishedCues(h).length, 5, '沙箱 DOM 解析器会抛，cue 仍须完整发布');
});

test('BUG-2629：json3 没有 \\n 追加行（正文行背靠背重叠）——同样收到下一行开始', async () => {
  const h = loadBridge({ json3: { events: ROLLING_EVENTS_NO_APPEND } });
  await h.flush();
  const cues = publishedCues(h);
  assert.strictEqual(cues.length, 5);
  assertNoOverlap(cues);
  const line = cues.find((c) => c.text === 'love. You know the rules and so do');
  assert.strictEqual(line.startMs, 21800);
  assert.strictEqual(line.endMs, 25960);
});

test('BUG-2629：人工轨（非 asr）的有意重叠 cue 不截断——滚动双行是自动字幕独有的形态', async () => {
  // 双人同说 / 歌词 + 对白：两条 cue 时间上重叠是作者的本意。截断只是 ASR 的逆运算。
  const events = [
    { tStartMs: 0, dDurationMs: 4000, segs: [{ utf8: 'A（旁白）' }] },
    { tStartMs: 1000, dDurationMs: 2000, segs: [{ utf8: 'B（对白）' }] },
  ];
  const h = loadBridge({ kind: '', json3: { events } });
  await h.flush();
  const cues = publishedCues(h);
  assert.deepStrictEqual(cues.map((c) => [c.text, c.startMs, c.endMs]), [
    ['A（旁白）', 0, 4000], ['B（对白）', 1000, 3000],
  ], '人工轨的 A 不得被砍到 B 开头（1000）');
});

test('BUG-2629：不重叠的手工轨原样不动，乱序输入按开始时间排好', async () => {
  const events = [
    { tStartMs: 5000, dDurationMs: 2000, segs: [{ utf8: 'B' }] },
    { tStartMs: 0, dDurationMs: 3000, segs: [{ utf8: 'A' }] },
    { tStartMs: 9000, dDurationMs: 1000, segs: [{ utf8: 'C' }] },
  ];
  const h = loadBridge({ json3: { events } });
  await h.flush();
  const cues = publishedCues(h);
  assert.deepStrictEqual(cues.map((c) => [c.text, c.startMs, c.endMs]), [
    ['A', 0, 3000], ['B', 5000, 7000], ['C', 9000, 10000],
  ]);
});
