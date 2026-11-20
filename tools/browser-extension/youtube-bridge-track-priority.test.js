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

// options.playerResponse → #movie_player.getPlayerResponse()；options.initialResponse →
// window.ytInitialPlayerResponse（服务端 JSON，键名不混淆）。
function loadBridge(captionTracks, audioTrack, options = {}) {
  const fetches = [];
  let fetchStatus = 200; // setFetchStatus 改它模拟服务端失败
  const posted = [];
  const winListeners = {};
  const windowObject = {
    ytcfg: { get() { return 'x'; } },
    addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
    postMessage(msg) { posted.push(msg); },
  };
  if (options.initialResponse) windowObject.ytInitialPlayerResponse = options.initialResponse;
  const player = {
    getVideoData() { return { video_id: 'vid1' }; },
    getAudioTrack() { return Object.assign({ captionTracks: captionTracks }, audioTrack || {}); },
  };
  if (options.playerResponse) player.getPlayerResponse = () => options.playerResponse;
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
    URL, URLSearchParams,
    Date: { now() { return 1000000; } },
    setInterval() { return 1; },
    clearInterval() {},
    fetch(url) {
      const u = String(url);
      // 桥只取 json3（BUG-2697：MAIN world 下 srv3 解析会撞 Trusted Types）；这里只让 json3 成功，
      // 断言按 json3 请求计数（每轨恰好一次）。
      if (!/fmt=json3/.test(u)) return Promise.resolve({ ok: false, status: 404 });
      fetches.push(u);
      if (fetchStatus !== 200 || /broken=1/.test(u)) return Promise.resolve({ ok: false, status: fetchStatus === 200 ? 500 : fetchStatus });
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
    setFetchStatus(status) { fetchStatus = status; },
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

// app 的语言偏好匹配只认语言码：清单与 cue 消息都带 languageCode（store key 的语言段仍是显示名，
// 同语言人工轨 / ASR 轨靠它区分）；按需取轨取不到时发 cuesFailed 回执，不静默。
test('清单与 cue 消息带 languageCode；按需取轨失败发 cuesFailed', async () => {
  const list = tracks25();
  list[4].baseUrl = 'https://www.youtube.com/api/timedtext?v=vid1&lang=ja&kind=asr&broken=1';
  const h = loadBridge(list, { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  const tracks = h.posted.find((m) => m.__fushiStream === 'tracks').tracks;
  assert.strictEqual(tracks[0].lang, 'en (auto)');
  assert.strictEqual(tracks[0].languageCode, 'en');
  assert.strictEqual(tracks.find((t) => t.lang === 'ja (auto)').languageCode, 'ja');
  const cues = h.posted.find((m) => m.__fushiStream === 'cues');
  assert.strictEqual(cues.languageCode, 'en');

  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'nope' });
  const failed = h.posted.filter((m) => m.__fushiStream === 'cuesFailed');
  assert.strictEqual(failed.length, 1, '清单里没有的轨：确定失败');
  assert.strictEqual(failed[0].videoKey, 'yt-vid1');
  assert.strictEqual(failed[0].lang, 'nope');
});

test('按需取轨请求失败 / 空轨：发 cuesFailed，不发 cues', async () => {
  const h = loadBridge(tracks25(), { defaultCaptionTrackIndex: 13, languageCode: 'en' });
  await h.flush();
  const before = h.posted.length;
  // 让下一次 json3 请求 500。
  h.setFetchStatus(500);
  await h.send({ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'ta (auto)' });
  const after = h.posted.slice(before);
  assert.strictEqual(after.filter((m) => m.__fushiStream === 'cues').length, 0);
  const failed = after.filter((m) => m.__fushiStream === 'cuesFailed');
  assert.strictEqual(failed.length, 1);
  assert.strictEqual(failed[0].lang, 'ta (auto)');
});

// ── 反馈 0RgCNJFQmJ / GitHub #3401：默认挂上无关语言的翻译轨 ──
// getAudioTrack() 返回的是播放器内部类实例，字段名被压缩混淆：defaultCaptionTrackIndex /
// languageCode 读出来都是空。旧排序于是退化成「原始顺序里第一条人工轨」——阿拉伯语。
// 排序信号要从结构稳定的数据来：同视频的播放器响应（服务端 JSON）与 ASR 轨的语言。
function track(lang, kind, name) {
  const asr = kind === 'asr';
  return {
    languageCode: lang, kind: asr ? 'asr' : '', vssId: (asr ? 'a.' : '.') + lang,
    name: { simpleText: name },
    baseUrl: 'https://www.youtube.com/api/timedtext?v=vid1&lang=' + lang + (asr ? '&kind=asr' : '&kind=manual'),
  };
}
// 混淆后的音轨对象：有 captionTracks（播放器自己要用），默认轨索引 / 语言藏在压缩字段名下。
const OBFUSCATED_AUDIO = { Xa: 3, zE: 'ja' };

test('#3401：音轨字段被混淆、无播放器响应 → 按唯一 ASR 语言认出音轨语言，同语言人工轨先挂', async () => {
  const list = [
    track('ja', 'asr', '日本語 (auto)'),
    track('ar', '', 'العربية'),
    track('ru', '', 'Русский'),
    track('ko', '', '한국어'),
    track('ja', '', '日本語'),
  ];
  const h = loadBridge(list, OBFUSCATED_AUDIO);
  await h.flush();
  const order = h.posted.find((m) => m.__fushiStream === 'tracks').tracks.map((t) => t.languageCode + '/' + t.lang);
  assert.deepStrictEqual(Array.from(order.slice(0, 2)), ['ja/日本語', 'ja/日本語 (auto)'],
    '音轨语言（ja）的人工轨第一、ASR 轨第二，无关翻译轨在后');
  assert.strictEqual(h.fetches.length, 1);
  assert.ok(/lang=ja&kind=manual/.test(h.fetches[0]), '急取的是日语人工轨，不是阿拉伯语');
});

test('#3401：播放器响应的 audioTracks.defaultCaptionTrackIndex 给出默认轨（按 vssId 对上运行时轨）', async () => {
  const list = [track('ar', '', 'Arabic'), track('en', 'asr', 'English (auto)'), track('en', '', 'English'), track('fr', '', 'French')];
  const response = {
    videoDetails: { videoId: 'vid1' },
    captions: { playerCaptionsTracklistRenderer: {
      captionTracks: [track('ar', '', 'Arabic'), track('en', 'asr', 'English (auto)'), track('en', '', 'English'), track('fr', '', 'French')],
      audioTracks: [{ captionTrackIndices: [0, 1, 2, 3], defaultCaptionTrackIndex: 3, hasDefaultTrack: true }],
      defaultAudioTrackIndex: 0,
    } },
  };
  const h = loadBridge(list, OBFUSCATED_AUDIO, { playerResponse: response });
  await h.flush();
  const order = h.posted.find((m) => m.__fushiStream === 'tracks').tracks.map((t) => t.lang);
  assert.deepStrictEqual(Array.from(order.slice(0, 3)), ['French', 'English', 'English (auto)'],
    '上传者设的默认轨第一，其后音轨语言（唯一 ASR = en）人工轨、ASR 轨');
  assert.ok(/lang=fr&/.test(h.fetches[0]));
});

test('#3401：hasDefaultTrack=false 时默认索引不作数；自动配音多 ASR 时按当前音轨的 captionTrackIndices 认语言', async () => {
  const langs = ['ru', 'de', 'ar', 'en', 'ko'];
  const list = langs.map((l) => track(l, 'asr', l + ' (auto)'));
  const response = {
    videoDetails: { videoId: 'vid1' },
    captions: { playerCaptionsTracklistRenderer: {
      captionTracks: langs.map((l) => track(l, 'asr', l + ' (auto)')),
      audioTracks: [
        { captionTrackIndices: [0], defaultCaptionTrackIndex: 0, hasDefaultTrack: false },
        { captionTrackIndices: [3], defaultCaptionTrackIndex: 0, hasDefaultTrack: false },
      ],
      defaultAudioTrackIndex: 1,
    } },
  };
  const h = loadBridge(list, OBFUSCATED_AUDIO, { playerResponse: response });
  await h.flush();
  const order = h.posted.find((m) => m.__fushiStream === 'tracks').tracks.map((t) => t.lang);
  assert.strictEqual(order[0], 'en (auto)', '原声音轨（默认音轨）范围里唯一的 ASR 语言 = en');
  assert.ok(/lang=en&/.test(h.fetches[0]));
});

test('#3401：SPA 换视频后残留的 ytInitialPlayerResponse（别的视频）不当排序依据', async () => {
  const list = [track('ar', '', 'Arabic'), track('ja', 'asr', 'Japanese (auto)'), track('ja', '', 'Japanese')];
  const stale = {
    videoDetails: { videoId: 'other' },
    captions: { playerCaptionsTracklistRenderer: {
      captionTracks: [track('ar', '', 'Arabic')],
      audioTracks: [{ captionTrackIndices: [0], defaultCaptionTrackIndex: 0, hasDefaultTrack: true }],
      defaultAudioTrackIndex: 0,
    } },
  };
  const h = loadBridge(list, OBFUSCATED_AUDIO, { initialResponse: stale });
  await h.flush();
  const order = h.posted.find((m) => m.__fushiStream === 'tracks').tracks.map((t) => t.lang);
  assert.strictEqual(order[0], 'Japanese', '上一个视频的默认轨（ar）不得带到这个视频');
});

// 审查 #3487：第三路兜底（页面里的播放器响应）以前直接用 ytInitialPlayerResponse，不核对
// videoId——SPA 换片后会把上一个视频的整份轨清单当成当前视频发布。
test('#3401：运行时 / Android 都取不到时，兜底只用 videoId 对得上的播放器响应', async () => {
  const renderer = (tracks) => ({ playerCaptionsTracklistRenderer: {
    captionTracks: tracks,
    audioTracks: [{ captionTrackIndices: tracks.map((_, i) => i), defaultCaptionTrackIndex: 0, hasDefaultTrack: true }],
    defaultAudioTrackIndex: 0,
  } });
  const staleTrack = track('ar', '', 'Arabic');
  staleTrack.baseUrl = 'https://www.youtube.com/api/timedtext?v=other&lang=ar&kind=manual';
  const stale = loadBridge([], null, {
    initialResponse: { videoDetails: { videoId: 'other' }, captions: renderer([staleTrack]) },
  });
  await stale.flush();
  assert.strictEqual(stale.posted.filter((m) => m.__fushiStream === 'tracks').length, 0,
    '上一个视频的轨清单不得当成当前视频发布');
  assert.ok(!stale.fetches.some((u) => /v=other/.test(u)), stale.fetches.join('\n'));

  const fresh = loadBridge([], null, {
    initialResponse: { videoDetails: { videoId: 'vid1' }, captions: renderer([track('ja', '', 'Japanese')]) },
  });
  await fresh.flush();
  const published = fresh.posted.find((m) => m.__fushiStream === 'tracks');
  assert.ok(published, '当前视频自己的响应照常作为兜底');
  assert.strictEqual(published.tracks[0].lang, 'Japanese');
});
