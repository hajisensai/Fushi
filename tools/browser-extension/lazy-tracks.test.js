// BUG-2194：字幕轨按需加载——隔离世界这一侧（subtitle-providers.js）。
//
// 主世界桥先发整份清单 {__fushiStream:'tracks'}，这里登记成空 cue 的占位轨（面板列出来、
// 用户选中触发加载）；fushiRequestLazyTrack 发 {__fushiStream:'fetchTrack'} 让桥真取；cue 到了
// 占位标记即清。占位轨绝不能当主路径（pickPrimaryCueTrack / fushiHasFullEpisodeTrack 跳过空轨）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');

function loadProviders(loc) {
  const posted = [];
  const notified = [];
  const listeners = {};
  const windowObj = {
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    postMessage(msg) { posted.push(msg); },
    fushiSubtitlePanelOnCues(key) { notified.push(key); },
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: loc || { hostname: 'www.youtube.com', pathname: '/watch', search: '?v=vid1', href: 'https://www.youtube.com/watch?v=vid1', origin: 'https://www.youtube.com' },
    window: windowObj,
    document: {
      documentElement: { dataset: {} }, body: {}, fullscreenElement: null,
      addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
      createElement: () => ({ style: {}, classList: { add() {} } }),
    },
    chrome: { runtime: { id: 't', onMessage: { addListener() {} }, sendMessage() {} },
      storage: { local: { get() {}, set() {} }, onChanged: { addListener() {} } } },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), ctx, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), ctx, { filename: 'subtitle-providers.js' });
  return {
    windowObj, posted, notified, ctx,
    // 主世界 → 隔离世界的 message（同一 window）。
    send(data) { for (const fn of listeners.message || []) fn({ source: windowObj, data }); },
  };
}

test('清单到 → 占位轨登记（空 cue + lazy 标记 + 通知面板）；已有真 cue 的不覆盖', () => {
  const h = loadProviders();
  const store = h.windowObj.fushiEpisodeCues;
  store['yt-vid1|en (auto)'] = [{ startMs: 0, endMs: 1000, text: 'hi' }];
  h.send({ __fushiStream: 'tracks', videoKey: 'yt-vid1', tracks: [{ lang: 'en (auto)' }, { lang: 'ja (auto)' }, { lang: '' }] });
  assert.strictEqual(store['yt-vid1|en (auto)'].length, 1, '已有真 cue 的轨不被清单覆盖');
  // vm 跨 realm：数组原型不同，deepStrictEqual 必红，按 JSON 比。
  assert.strictEqual(JSON.stringify(store['yt-vid1|ja (auto)']), '[]', '占位轨 = 空 cue');
  assert.strictEqual(h.windowObj.fushiLazyTracks['yt-vid1|ja (auto)'], true);
  assert.strictEqual(h.windowObj.fushiLazyTracks['yt-vid1|en (auto)'], undefined);
  assert.deepStrictEqual(h.notified, ['yt-vid1|ja (auto)'], '占位轨也通知面板刷新列表');
  // 重复清单不重复通知。
  h.send({ __fushiStream: 'tracks', videoKey: 'yt-vid1', tracks: [{ lang: 'ja (auto)' }] });
  assert.strictEqual(h.notified.length, 1);
});

test('fushiRequestLazyTrack：占位轨 → 发 fetchTrack；cue 到了标记清除、再请求返回 false', () => {
  const h = loadProviders();
  h.send({ __fushiStream: 'tracks', videoKey: 'yt-vid1', tracks: [{ lang: 'ja (auto)' }] });
  assert.strictEqual(h.windowObj.fushiRequestLazyTrack('yt-vid1|ja (auto)'), true);
  assert.strictEqual(JSON.stringify(h.posted.filter((m) => m.__fushiStream === 'fetchTrack')),
    JSON.stringify([{ __fushiStream: 'fetchTrack', videoKey: 'yt-vid1', lang: 'ja (auto)' }]));
  assert.strictEqual(h.windowObj.fushiRequestLazyTrack('yt-vid1|nope'), false, '未登记的不请求');
  h.send({ __fushiStream: 'cues', videoKey: 'yt-vid1', lang: 'ja (auto)', format: 'cues',
    cues: [{ startMs: 0, endMs: 1000, text: 'こんにちは' }] });
  assert.strictEqual(h.windowObj.fushiEpisodeCues['yt-vid1|ja (auto)'].length, 1);
  assert.strictEqual(h.windowObj.fushiLazyTracks['yt-vid1|ja (auto)'], undefined, 'cue 到了不再是占位');
  assert.strictEqual(h.windowObj.fushiRequestLazyTrack('yt-vid1|ja (auto)'), false);
});

test('占位轨绝不当主路径：只有占位时 pickPrimaryCueTrack / fushiHasFullEpisodeTrack 都为空', () => {
  const h = loadProviders();
  h.send({ __fushiStream: 'tracks', videoKey: 'yt-vid1', tracks: [{ lang: 'ja (auto)' }] });
  assert.strictEqual(h.ctx.pickPrimaryCueTrack(h.windowObj.fushiEpisodeCues, 'yt-vid1', 'live', null), null);
  assert.strictEqual(h.ctx.fushiHasFullEpisodeTrack('yt-vid1'), false);
});

test('Netflix 状态通道轨清单 → 占位轨（key=vid|lang~trackId，带显示名）；选中发 __fushiNf fetchTrack；cue 到即清占位', () => {
  const h = loadProviders({ hostname: 'www.netflix.com', pathname: '/watch/81001', search: '', href: 'https://www.netflix.com/watch/81001', origin: 'https://www.netflix.com' });
  const store = h.windowObj.fushiEpisodeCues;
  h.send({ __fushiNf: 'tracks', videoId: '81001', tracks: [
    { lang: 'ja', trackId: 'T:ja-cc', label: '日本語 [CC]' },
    { lang: 'en', trackId: 'T:en', label: 'English' },
    { lang: 'xx' },
  ] });
  assert.strictEqual(JSON.stringify(store['81001|ja~T:ja-cc']), '[]');
  assert.strictEqual(h.windowObj.fushiLazyTracks['81001|en~T:en'], true);
  assert.strictEqual(h.windowObj.fushiTrackLabels['81001|ja~T:ja-cc'], '日本語 [CC]');
  assert.deepStrictEqual(h.notified, ['81001|ja~T:ja-cc', '81001|en~T:en']);
  assert.strictEqual(h.windowObj.fushiRequestLazyTrack('81001|en~T:en'), true);
  const req = h.posted.find((m) => m && m.__fushiNf === 'fetchTrack');
  assert.ok(req, 'Netflix 占位轨走 netflix-bridge 的 fetchTrack');
  assert.strictEqual(req.trackId, 'T:en');
  assert.strictEqual(h.posted.some((m) => m && m.__fushiStream === 'fetchTrack'), false);
  h.send({ __fushiNf: 'cues', videoId: '81001', lang: 'en', trackId: 'T:en', label: 'English', format: 'webvtt',
    text: 'WEBVTT\n\n00:01.000 --> 00:02.000\nhello\n' });
  assert.strictEqual(store['81001|en~T:en'].length, 1);
  assert.strictEqual(h.windowObj.fushiLazyTracks['81001|en~T:en'], undefined, '真 cue 到了不再是占位');
});

// app 的 glue 按 fushiTrackLangCodes 上报语言码（偏好匹配），fushiTrackLabels 给显示名；
// 桥的 cuesFailed 回执经 fushiSubtitlePanelOnTrackFailed 交给消费端（与 Netflix 同一出口）。
test('YouTube 清单 / cue 带 languageCode → 记语言码与显示名；cuesFailed → 失败回执', () => {
  const h = loadProviders();
  const failed = [];
  h.windowObj.fushiSubtitlePanelOnTrackFailed = (key, err) => failed.push([key, err]);
  h.send({ __fushiStream: 'tracks', videoKey: 'yt-vid1', tracks: [
    { lang: '日本語 (自動生成)', languageCode: 'ja' }, { lang: 'English', languageCode: 'en' }, { lang: 'x' },
  ] });
  assert.strictEqual(h.windowObj.fushiTrackLangCodes['yt-vid1|日本語 (自動生成)'], 'ja');
  assert.strictEqual(h.windowObj.fushiTrackLabels['yt-vid1|日本語 (自動生成)'], '日本語 (自動生成)');
  assert.strictEqual(h.windowObj.fushiTrackLangCodes['yt-vid1|x'], undefined, '没带语言码不记');
  h.send({ __fushiStream: 'cues', videoKey: 'yt-vid1', lang: 'Deutsch', languageCode: 'de', format: 'cues',
    cues: [{ startMs: 0, endMs: 1000, text: 'hallo' }] });
  assert.strictEqual(h.windowObj.fushiTrackLangCodes['yt-vid1|Deutsch'], 'de');
  h.send({ __fushiStream: 'cuesFailed', videoKey: 'yt-vid1', lang: 'English', err: 'no cues' });
  assert.strictEqual(JSON.stringify(failed), JSON.stringify([['yt-vid1|English', 'no cues']]));
});
