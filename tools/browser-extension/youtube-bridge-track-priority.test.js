// BUG-2194：YouTube 轨枚举上限截掉原语言轨。
//
// 用户截图：自动配音视频的字幕列表里俄/孟/德/旁遮普/日/法/波/荷/葡/阿/韩/马拉雅拉姆 12 条
// 齐全，唯独没有英语——YouTube 原生菜单里明明有「英语（自动生成）」。根因：fetchAndPublish
// 按 YouTube 原始顺序截前 12 条，原语言排在后面就被截掉。现在上限之前先按「当前音轨默认
// 字幕轨 → 同语言 → 人工轨 → 其余」排优先级，上限提到 20。
//
// 在受控 vm 里真加载 youtube-bridge.js：#movie_player 假件给出 25 条 captionTracks，其中
// 英语 ASR 轨排在第 14 位并被 getAudioTrack() 标为默认；断言它一定被抓、且排第一。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.join(__dirname, 'youtube-bridge.js'), 'utf8');

function loadBridge(captionTracks, audioTrack) {
  const fetches = [];
  const posted = [];
  const windowObject = {
    ytcfg: { get() { return 'x'; } },
    addEventListener() {},
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
  return { fetches, posted, flush };
}

function tracks25() {
  const langs = ['ru', 'bn', 'de', 'pa', 'ja', 'fr', 'pl', 'nl', 'pt', 'ar', 'ko', 'ml', 'ta',
    'en', 'es', 'he', 'it', 'hi', 'id', 'tr', 'vi', 'th', 'uk', 'sv', 'fi'];
  return langs.map((l) => ({
    languageCode: l, kind: 'asr', name: { simpleText: l + ' (auto)' },
    baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=' + l + '&kind=asr',
  }));
}

test('BUG-2194：原语言轨排在第 14 位也必须被抓到，且排第一', async () => {
  const h = loadBridge(tracks25(), { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  const langs = h.posted.map((m) => m.lang);
  assert.ok(langs.includes('en (auto)'), '英语轨被上限截掉了：' + langs.join(','));
  assert.strictEqual(h.fetches.length, 20, '上限 20 条');
  assert.ok(/lang=en&/.test(h.fetches[0]), '默认字幕轨最先抓');
});

test('BUG-2194：没有默认索引时按音轨语言码匹配；人工轨优先于 ASR 轨', async () => {
  const list = tracks25();
  list.push({ languageCode: 'zh-Hans', kind: '', name: { simpleText: '中文（简体）' },
    baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=zh-Hans' });
  const h = loadBridge(list, { languageCode: 'en-US' });
  await h.flush();
  assert.ok(/lang=en&/.test(h.fetches[0]), '同语言（en-US ~ en）轨最先');
  assert.ok(/lang=zh-Hans/.test(h.fetches[1]), '人工轨紧随其后');
  assert.strictEqual(h.fetches.length, 20);
});

test('BUG-2194：无任何提示信息时保持原顺序（前 20 条）', async () => {
  const h = loadBridge(tracks25(), null);
  await h.flush();
  assert.ok(/lang=ru&/.test(h.fetches[0]));
  assert.strictEqual(h.fetches.length, 20);
});
