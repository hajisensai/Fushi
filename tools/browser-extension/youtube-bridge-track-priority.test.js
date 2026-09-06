// BUG-2194：YouTube 轨枚举上限截掉原语言轨 → 改按需加载。
//
// 用户截图：自动配音视频的字幕列表里俄/孟/德/旁遮普/日/法/波/荷/葡/阿/韩/马拉雅拉姆 12 条
// 齐全，唯独没有英语——YouTube 原生菜单里明明有「英语（自动生成）」。根因：fetchAndPublish
// 按 YouTube 原始顺序截前 12 条，原语言排在后面就被截掉。现在：整份清单（只有标签）立刻
// 发 {__fushiStream:'tracks'}；只急取排优先级后的头一条（当前音轨默认字幕轨）；其余等隔离
// 世界发 {__fushiStream:'fetchTrack'} 再取，取过的直接重放缓存。
//
// 在受控 vm 里真加载 youtube-bridge.js：#movie_player 假件给出 25 条 captionTracks，英语 ASR
// 轨排在第 14 位并被 getAudioTrack() 标为默认。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.join(__dirname, 'youtube-bridge.js'), 'utf8');

function loadBridge(captionTracks, audioTrack) {
  const fetches = [];
  const posted = [];
  const winListeners = {};
  const windowObject = {
    ytcfg: { get() { return 'x'; } },
    addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
    postMessage(msg) { posted.push(msg); },
  };
  const player = {
    getVideoData() { return { video_id: 'vid1' }; },
    getAudioTrack() { return Object.assign({ captionTracks: captionTracks }, audioTrack || {}); },
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
    URL, URLSearchParams, DOMParser: function () {},
    Date: { now() { return 1000000; } },
    setInterval() { return 1; },
    clearInterval() {},
    fetch(url) {
      const u = String(url);
      // 沙箱没有真 DOMParser，srv3 解析必空 → 桥会退到 json3；这里只让 json3 成功，
      // 断言按 json3 请求计数（每轨恰好一次）。
      if (!/fmt=json3/.test(u)) return Promise.resolve({ ok: false, status: 404 });
      fetches.push(u);
      const lang = new URL(u).searchParams.get('lang') || 'und';
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ events: [{ tStartMs: 0, dDurationMs: 1000, segs: [{ utf8: lang }] }] }),
      });
    },
  };
  vm.runInNewContext(SOURCE, sandbox, { filename: 'youtube-bridge.js' });
  const flush = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };
  return {
    fetches, posted, flush,
    // 隔离世界 → 主世界的 postMessage（同一 window，source === window）。
    async send(data) {
      for (const fn of winListeners.message || []) fn({ source: windowObject, data });
      await flush();
    },
  };
}

function tracks25() {
  const langs = ['ru', 'bn', 'de', 'pa', 'ja', 'fr', 'pl', 'nl', 'pt', 'ar', 'ko', 'ml', 'ta',
    'en', 'es', 'he', 'it', 'hi', 'id', 'tr', 'vi', 'th', 'uk', 'sv', 'fi'];
  return langs.map((l) => ({
    languageCode: l, kind: 'asr', name: { simpleText: l + ' (auto)' },
    baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=' + l + '&kind=asr',
  }));
}

test('BUG-2194：整份清单立刻到（25 条全在，含英语）；只急取默认那一条', async () => {
  const h = loadBridge(tracks25(), { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  const list = h.posted.find((m) => m.__fushiStream === 'tracks');
  assert.ok(list, '必须先发轨清单');
  assert.strictEqual(list.videoKey, 'yt-vid1');
  assert.strictEqual(list.tracks.length, 25, '清单不设上限');
  assert.ok(list.tracks.some((t) => t.lang === 'en (auto)'), '英语在清单里');
  assert.strictEqual(list.tracks[0].lang, 'en (auto)', '默认轨排第一');
  assert.strictEqual(h.fetches.length, 1, '只急取一条');
  assert.ok(/lang=en&/.test(h.fetches[0]), '急取的是默认字幕轨');
  const cues = h.posted.filter((m) => m.__fushiStream === 'cues');
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].lang, 'en (auto)');
});

test('BUG-2194：fetchTrack 按需取一条；重复请求重放缓存不再下载；未知轨忽略', async () => {
  const h = loadBridge(tracks25(), { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'ta (auto)' });
  assert.strictEqual(h.fetches.length, 2);
  assert.ok(/lang=ta&/.test(h.fetches[1]));
  const ta = h.posted.filter((m) => m.__fushiStream === 'cues' && m.lang === 'ta (auto)');
  assert.strictEqual(ta.length, 1);
  assert.strictEqual(ta[0].cues[0].text, 'ta');
  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'ta (auto)' });
  assert.strictEqual(h.fetches.length, 2, '已取过的不再下载');
  assert.strictEqual(h.posted.filter((m) => m.__fushiStream === 'cues' && m.lang === 'ta (auto)').length, 2, '重放缓存');
  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'nope' });
  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-other', lang: 'ta (auto)' });
  assert.strictEqual(h.fetches.length, 2, '未知轨 / 别的视频不取');
});

test('BUG-2194：replayCues 把清单和已取的轨一起重放（隔离世界晚到也拿得到清单）', async () => {
  const h = loadBridge(tracks25(), { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  const before = h.posted.length;
  await h.send({ __fushiStream: 'replayCues' });
  const replayed = h.posted.slice(before);
  assert.ok(replayed.some((m) => m.__fushiStream === 'tracks' && m.tracks.length === 25), '清单被重放');
  assert.ok(replayed.some((m) => m.__fushiStream === 'cues' && m.lang === 'en (auto)'), '已取轨被重放');
});

test('BUG-2194：没有默认索引时按音轨语言码匹配急取；人工轨在清单里排在 ASR 轨前', async () => {
  const list = tracks25();
  list.push({ languageCode: 'zh-Hans', kind: '', name: { simpleText: '中文（简体）' },
    baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=zh-Hans' });
  const h = loadBridge(list, { languageCode: 'en-US' });
  await h.flush();
  assert.strictEqual(h.fetches.length, 1);
  assert.ok(/lang=en&/.test(h.fetches[0]), '同语言（en-US ~ en）轨急取');
  const tracks = h.posted.find((m) => m.__fushiStream === 'tracks').tracks.map((t) => t.lang);
  assert.strictEqual(tracks[0], 'en (auto)');
  assert.strictEqual(tracks[1], '中文（简体）', '人工轨紧随其后');
});
