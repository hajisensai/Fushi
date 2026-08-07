const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const A = require('./stream-bridge.js');

// asb 移植：通用流媒体字幕桥的纯函数 track 提取器。样例 JSON 形状逐一对照
// asbplayer extension/src/entrypoints/*-page.ts 的判定条件构造。

test('tverTracks：kind=captions 且 text/vtt 才收，label = srclang - label，http 升 https', () => {
  const tracks = A.tverTracks({
    name: '番組名',
    tracks: [
      { kind: 'captions', type: 'text/vtt', src: 'http://cdn.example/ja.vtt', srclang: 'ja', label: '日本語' },
      { kind: 'captions', type: 'text/webvtt', src: 'https://cdn.example/ja2.vtt', srclang: 'ja' },
      { kind: 'thumbnails', type: 'text/vtt', src: 'https://cdn.example/thumb.vtt', srclang: 'ja' },
      { kind: 'captions', type: 'application/x-mpegURL', src: 'https://cdn.example/x.m3u8', srclang: 'ja' },
      { kind: 'captions', type: 'text/vtt', srclang: 'ja' }, // 缺 src
    ],
  });
  assert.strictEqual(tracks.length, 2);
  assert.deepStrictEqual(tracks[0], { label: 'ja - 日本語', url: 'https://cdn.example/ja.vtt', format: 'webvtt' });
  assert.deepStrictEqual(tracks[1], { label: 'ja', url: 'https://cdn.example/ja2.vtt', format: 'webvtt' });
});

test('tverTracks：无 tracks / 非对象 → 空', () => {
  assert.deepStrictEqual(A.tverTracks(null), []);
  assert.deepStrictEqual(A.tverTracks({}), []);
  assert.deepStrictEqual(A.tverTracks({ tracks: 'x' }), []);
});

test('bilibiliTracks：data.subtitles[]，srt.url 优先，.json 判为 bbjson', () => {
  const tracks = A.bilibiliTracks({
    data: {
      subtitles: [
        { lang: '中文（简体）', lang_key: 'zh-Hans', url: 'https://cdn.example/zh.json?x=1' },
        { lang: '日本語', lang_key: 'ja', srt: { url: 'https://cdn.example/ja.srt' } },
        { lang_key: 'en', url: 'https://cdn.example/en.srt' }, // 缺 lang → 丢
        { lang: 'ko' },                                        // 缺 url → 丢
      ],
    },
  });
  assert.strictEqual(tracks.length, 2);
  assert.deepStrictEqual(tracks[0], { label: '中文（简体）', url: 'https://cdn.example/zh.json?x=1', format: 'bbjson' });
  assert.deepStrictEqual(tracks[1], { label: '日本語', url: 'https://cdn.example/ja.srt', format: 'srt' });
});

test('huluJpTracks：需 ref_id + kind=subtitles；返回 {videoId, tracks}', () => {
  const got = A.huluJpTracks({
    ref_id: 'ep123',
    name: 'ep123:タイトル',
    tracks: [
      { kind: 'subtitles', src: 'https://cdn.example/ja.vtt', srclang: 'ja', label: '日本語字幕' },
      { kind: 'audio', src: 'https://cdn.example/a.m4a', srclang: 'ja' },
      { kind: 'subtitles', srclang: 'ja' }, // 缺 src
    ],
  });
  assert.ok(got);
  assert.strictEqual(got.videoId, 'ep123');
  assert.strictEqual(got.tracks.length, 1);
  assert.deepStrictEqual(got.tracks[0], { label: '日本語字幕', url: 'https://cdn.example/ja.vtt', format: 'webvtt' });
});

test('huluJpTracks：无 ref_id / 无字幕轨 → null', () => {
  assert.strictEqual(A.huluJpTracks({ tracks: [] }), null);
  assert.strictEqual(A.huluJpTracks({ ref_id: 'x', tracks: [{ kind: 'audio' }] }), null);
  assert.strictEqual(A.huluJpTracks(null), null);
});

test('amazonCapture：只认 GetVodPlaybackResources 且带 titleId', () => {
  assert.deepStrictEqual(
    A.amazonCapture('https://atv-ps.amazon.co.jp/cdp/catalog/GetVodPlaybackResources?titleId=T123&x=1'),
    { kind: 'vod', titleId: 'T123' });
  assert.strictEqual(A.amazonCapture('https://atv-ps.amazon.co.jp/other?titleId=T123'), null);
  assert.strictEqual(A.amazonCapture('https://x/GetVodPlaybackResources?foo=1'), null);
  assert.strictEqual(A.amazonCapture(null), null);
});

test('amazonTracks：timedTextUrls.result.subtitleUrls[] → ttml 轨', () => {
  const tracks = A.amazonTracks({
    timedTextUrls: {
      result: {
        subtitleUrls: [
          { displayName: '日本語', languageCode: 'ja-jp', url: 'https://cdn.example/ja.dfxp' },
          { languageCode: 'en-us', url: 'https://cdn.example/en.dfxp' },
          { displayName: '坏轨' }, // 缺 url → 丢
        ],
      },
    },
  });
  assert.strictEqual(tracks.length, 2);
  assert.deepStrictEqual(tracks[0], { label: '日本語', url: 'https://cdn.example/ja.dfxp', format: 'ttml' });
  assert.deepStrictEqual(tracks[1], { label: 'en-us', url: 'https://cdn.example/en.dfxp', format: 'ttml' });
});

test('amazonTracks：stale session（无 result）→ 空', () => {
  assert.deepStrictEqual(A.amazonTracks({ timedTextUrls: {} }), []);
  assert.deepStrictEqual(A.amazonTracks(null), []);
});

test('siteForHost：站点路由（含 amazon 各区域 + primevideo）', () => {
  assert.strictEqual(A.siteForHost('tver.jp'), 'tver');
  assert.strictEqual(A.siteForHost('www.tver.jp'), 'tver');
  assert.strictEqual(A.siteForHost('www.bilibili.tv'), 'bilibili');
  assert.strictEqual(A.siteForHost('www.hulu.jp'), 'hulu-jp');
  assert.strictEqual(A.siteForHost('www.amazon.co.jp'), 'prime');
  assert.strictEqual(A.siteForHost('www.primevideo.com'), 'prime');
  assert.strictEqual(A.siteForHost('www.bilibili.com'), null); // 大陆站 API 不同，未适配
  assert.strictEqual(A.siteForHost('www.hulu.com'), null);     // 美国站未适配
  assert.strictEqual(A.siteForHost('example.com'), null);
});

test('asbplayer MIT notice is retained in source and bundled extension', () => {
  const sourceNotice = path.join(__dirname, 'THIRD_PARTY_LICENSES.md');
  const bundledNotice = path.resolve(
    __dirname,
    '../../fushi/assets/browser_extension/THIRD_PARTY_LICENSES.md',
  );
  const expected = 'Copyright (c) 2020-2026 asbplayer authors';
  assert.match(fs.readFileSync(sourceNotice, 'utf8'), /MIT License/);
  assert.match(fs.readFileSync(sourceNotice, 'utf8'), new RegExp(expected.replace(/[()]/g, '\\$&')));
  assert.strictEqual(
    fs.readFileSync(bundledNotice, 'utf8'),
    fs.readFileSync(sourceNotice, 'utf8'),
  );
});
