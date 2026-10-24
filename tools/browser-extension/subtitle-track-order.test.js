// 字幕轨列表次序与活动轨的共享判据（subtitle-adapters.js fushiListSubtitleTracks /
// fushiResolveActiveSubtitleTrack）。扩展面板 / Side Panel / 播放器内嵌菜单与 app 内浏览器的
// YouTube 页内字幕（fushi/assets/web_browser/youtube_subtitles.js）都调这一份——这里钉住规则本身，
// app 侧的 node 测试再钉「app 真的在调它」。
const { test } = require('node:test');
const assert = require('node:assert');
const { fushiListSubtitleTracks, fushiResolveActiveSubtitleTrack } = require('./subtitle-adapters.js');

const LIVE = 'live';
const cue = (t) => ({ startMs: 0, endMs: 1000, text: t });
const langs = (tracks) => tracks.map((t) => t.lang);

test('列表：已加载整轨 → 占位轨 → live；同档按语言段字典序；别的视频 / 未登记空轨不列', () => {
  const store = Object.create(null);
  store['yt-A|live'] = [cue('l')];
  store['yt-A|日本語'] = [];
  store['yt-A|English'] = [cue('e')];
  store['yt-A|Deutsch'] = [];
  store['yt-A|Español'] = [cue('s')];
  store['yt-A|Français'] = []; // 空、但不是占位（没进 lazy 表）→ 不列
  store['yt-B|English'] = [cue('b')];
  const lazy = { 'yt-A|日本語': true, 'yt-A|Deutsch': true };
  const tracks = fushiListSubtitleTracks(store, 'yt-A', lazy, LIVE);
  assert.deepStrictEqual(langs(tracks), ['English', 'Español', 'Deutsch', '日本語', 'live']);
  assert.strictEqual(tracks[2].pending, true);
  assert.strictEqual(tracks[0].pending, undefined);
  assert.strictEqual(tracks[0].key, 'yt-A|English');
  assert.deepStrictEqual(fushiListSubtitleTracks(store, '', lazy, LIVE), []);
  assert.deepStrictEqual(fushiListSubtitleTracks(null, 'yt-A', lazy, LIVE), []);
});

test('活动轨：保持已选；没选 / 已选的消失 → 第一条；live 遇整轨到达自动升级', () => {
  const t = [{ lang: 'English' }, { lang: 'ja', pending: true }, { lang: LIVE }];
  assert.strictEqual(fushiResolveActiveSubtitleTrack(t, null, LIVE).lang, 'English');
  assert.strictEqual(fushiResolveActiveSubtitleTrack(t, 'ja', LIVE).lang, 'ja', '用户选了占位轨也保持（调用方去按需取）');
  assert.strictEqual(fushiResolveActiveSubtitleTrack(t, 'gone', LIVE).lang, 'English');
  assert.strictEqual(fushiResolveActiveSubtitleTrack(t, LIVE, LIVE).lang, 'English', 'live → 整轨');
  assert.strictEqual(fushiResolveActiveSubtitleTrack([{ lang: LIVE }], LIVE, LIVE).lang, LIVE, '只有 live 时留在 live');
  assert.strictEqual(fushiResolveActiveSubtitleTrack([], 'x', LIVE), null);
});

test('m.youtube 无音轨元数据：桥急取的头一条（人工轨按 YouTube 原顺序）就是活动轨，其余是占位', () => {
  // 桥拿不到 getAudioTrack()（m.youtube 常态，走 android 接口兜底）→ prioritizeCaptionTracks
  // 只剩「人工轨先于自动轨」，头一条德语人工轨被急取，其余登记成占位。扩展在这种页面上显示的
  // 就是它；想看别的语言由用户在轨菜单里换。
  const store = Object.create(null);
  store['yt-M|Deutsch'] = [cue('de')];
  store['yt-M|English'] = [];
  store['yt-M|English (auto-generated) (自动)'] = [];
  store['yt-M|Japanese'] = [];
  const lazy = { 'yt-M|English': true, 'yt-M|English (auto-generated) (自动)': true, 'yt-M|Japanese': true };
  const tracks = fushiListSubtitleTracks(store, 'yt-M', lazy, LIVE);
  assert.deepStrictEqual(langs(tracks), ['Deutsch', 'English', 'English (auto-generated) (自动)', 'Japanese']);
  assert.strictEqual(fushiResolveActiveSubtitleTrack(tracks, null, LIVE).lang, 'Deutsch');
  // 用户选了 Japanese（占位）：保持选中，取到后仍是它，并且排进已加载档。
  assert.strictEqual(fushiResolveActiveSubtitleTrack(tracks, 'Japanese', LIVE).lang, 'Japanese');
  store['yt-M|Japanese'] = [cue('ja')];
  delete lazy['yt-M|Japanese'];
  const after = fushiListSubtitleTracks(store, 'yt-M', lazy, LIVE);
  assert.deepStrictEqual(langs(after).slice(0, 2), ['Deutsch', 'Japanese']);
  assert.strictEqual(fushiResolveActiveSubtitleTrack(after, 'Japanese', LIVE).lang, 'Japanese');
});
