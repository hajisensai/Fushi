// node 驱动：assets/web_browser/youtube_subtitles.js 的选轨 / 渲染几何 + 完整脚本块能否解析执行。
// 由 youtube_subtitles_feature_test.dart 调用：argv[2] = 拼好的脚本块文件路径。
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');

function fakeDom(hostname) {
  const el = () => ({
    style: {}, dataset: {}, childNodes: [], addEventListener() {}, appendChild(c) { this.childNodes.push(c); c.parentNode = this; },
    removeChild() {}, remove() {},
  });
  const document = {
    head: el(), documentElement: el(), body: el(),
    createElement: el, getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    addEventListener() {},
  };
  const window = {
    location: { hostname, pathname: '/watch', search: '?v=dQw4w9WgXcQ', href: 'https://' + hostname + '/watch?v=dQw4w9WgXcQ' },
    document, addEventListener() {}, postMessage() {}, setInterval: () => 1, clearInterval() {}, setTimeout: () => 1,
    clearTimeout() {}, console: { log() {}, warn() {}, error() {} }, navigator: { userAgent: 'node' },
    MutationObserver: function () { this.observe = () => {}; this.disconnect = () => {}; },
    URLSearchParams, URL, TextDecoder, fetch: () => Promise.reject(new Error('offline')),
  };
  window.window = window;
  window.self = window;
  window.globalThis = window;
  window.location.toString = () => window.location.href;
  return window;
}

function run(source, hostname) {
  const ctx = fakeDom(hostname);
  vm.createContext(ctx);
  vm.runInContext(source, ctx, { filename: 'bundle.js' });
  return ctx;
}

// ── 选轨：与扩展同一份规则 ──
// 字幕层不自带排序，调扩展 subtitle-adapters.js 的 fushiListSubtitleTracks /
// fushiResolveActiveSubtitleTrack（脚本块里先于字幕层装入）。这里把 adapters（扩展镜像）+ 字幕层
// 装进同一个世界，断言字幕层的轨列表 / 活动轨与扩展函数算出来的逐项相同。
const ADAPTERS_PATH = path.resolve('assets/browser_extension/subtitle-adapters.js');
const adaptersSrc = fs.readFileSync(ADAPTERS_PATH, 'utf8');
const ext = require(ADAPTERS_PATH); // 扩展自己的导出（module.exports）
const overlay = fs.readFileSync('assets/web_browser/youtube_subtitles.js', 'utf8');
const cue = (s, e, t) => ({ startMs: s, endMs: e, text: t });

// 能渲染的假页面：#movie_player + <video>，字幕层挂进播放器、读得到它的矩形。
function page(opts) {
  const w = fakeDom(opts.host || 'www.youtube.com');
  w.innerWidth = opts.innerWidth;
  const player = {
    style: {}, childNodes: [], clientHeight: opts.player.height,
    appendChild(c) { this.childNodes.push(c); c.parentNode = this; },
    removeChild(c) { this.childNodes = this.childNodes.filter((x) => x !== c); c.parentNode = null; },
    getBoundingClientRect: () => ({
      left: opts.player.left, right: opts.player.left + opts.player.width,
      top: 0, width: opts.player.width, height: opts.player.height,
    }),
  };
  const vr = opts.video || opts.player;
  const video = {
    currentTime: 0.05, closest: () => player, parentElement: player,
    getBoundingClientRect: () => ({ left: vr.left, right: vr.left + vr.width, top: vr.top || 0, width: vr.width, height: vr.height }),
  };
  w.document.querySelector = (sel) => (/video/.test(sel) ? video : null);
  w.fushiEpisodeCues = opts.store;
  w.fushiLazyTracks = opts.lazy || {};
  w.fushiTrackLabels = opts.labels || {};
  w.requested = [];
  w.fushiRequestLazyTrack = (key) => { w.requested.push(key); return true; };
  let key = opts.videoKey;
  w.fushiVideoKey = () => key;
  w.setVideoKey = (k) => { key = k; };
  vm.createContext(w);
  vm.runInContext(adaptersSrc, w, { filename: 'subtitle-adapters.js' });
  vm.runInContext(overlay, w, { filename: 'youtube_subtitles.js' });
  w.player = player;
  return w;
}
const plain = (o) => JSON.parse(JSON.stringify(o));
function extOrder(store, videoKey, lazy) {
  return ext.fushiListSubtitleTracks(store, videoKey, lazy, 'live').map((t) => t.lang);
}
function extActive(store, videoKey, lazy, activeLang) {
  const t = ext.fushiResolveActiveSubtitleTrack(
    ext.fushiListSubtitleTracks(store, videoKey, lazy, 'live'), activeLang, 'live');
  return t ? t.lang : null;
}
const desktop = { innerWidth: 1600, player: { left: 100, width: 800, height: 450 } };

{
  // 桌面：桥急取了「当前音轨默认字幕轨」日本語 (自动)，其余是占位；还有 DOM 采样 live。
  const store = Object.create(null);
  store['yt-A|live'] = [cue(0, 100, 'l')];
  store['yt-A|English'] = [];
  store['yt-A|日本語 (自动)'] = [cue(0, 100, 'j')];
  store['yt-A|Deutsch'] = [];
  store['yt-B|English'] = [cue(0, 100, 'b')];
  const lazy = { 'yt-A|English': true, 'yt-A|Deutsch': true };
  const w = page(Object.assign({
    store, lazy, videoKey: 'yt-A', labels: { 'yt-A|English': 'English (United States)' },
  }, desktop));
  w.__fushiYtSubs.setEnabled(true);
  const list = plain(w.__fushiYtSubs.trackList());
  assert.deepStrictEqual(list.tracks.map((t) => t.lang), extOrder(store, 'yt-A', lazy), '轨次序 = 扩展 fushiListSubtitleTracks');
  assert.deepStrictEqual(list.tracks.map((t) => t.lang), ['日本語 (自动)', 'Deutsch', 'English', 'live']);
  assert.strictEqual(list.active, extActive(store, 'yt-A', lazy, null), '活动轨 = 扩展 fushiResolveActiveSubtitleTrack');
  assert.strictEqual(list.active, '日本語 (自动)');
  assert.strictEqual(list.tracks[2].label, 'English (United States)', '显示名取 fushiTrackLabels');
  assert.strictEqual(list.tracks[1].pending, true);
  assert.strictEqual(list.tracks[3].live, true);
  assert.strictEqual(list.tracks[3].label, null, 'live 的显示名由 Dart 本地化');
  assert.deepStrictEqual(plain(w.requested), [], '活动轨已加载：不请桥');
  assert.strictEqual(w.player.childNodes.length, 1, '字幕画进播放器');
  assert.strictEqual(w.player.childNodes[0].childNodes[0].textContent, 'j');

  // 用户在「⋯ › 字幕轨」选占位轨：设为活动轨 + 请桥按需取；5 秒内不重复请求。
  assert.strictEqual(w.__fushiYtSubs.selectTrack('English'), true);
  assert.strictEqual(w.__fushiYtSubs.state().activeLang, 'English');
  assert.deepStrictEqual(plain(w.requested), ['yt-A|English']);
  w.__fushiYtSubs.selectTrack('English');
  assert.strictEqual(w.requested.length, 1, '同一占位轨不连发');
  assert.strictEqual(w.__fushiYtSubs.selectTrack('nope'), false, '不存在的轨');
  // 取到了：providers 写 store、清占位、调钩子 → 仍是用户选的那条，并画出它的句子。
  store['yt-A|English'] = [cue(0, 100, 'e')];
  delete lazy['yt-A|English'];
  w.fushiSubtitlePanelOnCues('yt-A|English');
  w.__fushiYtSubs.setEnabled(true);
  assert.strictEqual(w.__fushiYtSubs.state().activeLang, 'English');
  assert.strictEqual(w.player.childNodes[0].childNodes[0].textContent, 'e');

  // 换视频：清掉选择，按规则重选（扩展 tick 换视频时 activeLang = null）。
  w.setVideoKey('yt-B');
  w.__fushiYtSubs.setEnabled(true);
  assert.strictEqual(w.__fushiYtSubs.state().activeLang, 'English');
  assert.strictEqual(w.__fushiYtSubs.state().videoKey, 'yt-B');
}

{
  // m.youtube.com 无音轨元数据：桥只能「人工轨先于自动轨」按 YouTube 原顺序，急取头一条德语。
  // 扩展在这种页上就显示德语——app 一样（用户拍板：与扩展完全一样），想看日语去轨菜单换。
  const store = Object.create(null);
  store['yt-M|Deutsch'] = [cue(0, 100, 'de')];
  store['yt-M|English'] = [];
  store['yt-M|English (auto-generated) (自动)'] = [];
  store['yt-M|Japanese'] = [];
  const lazy = { 'yt-M|English': true, 'yt-M|English (auto-generated) (自动)': true, 'yt-M|Japanese': true };
  const w = page({
    host: 'm.youtube.com', store, lazy, videoKey: 'yt-M',
    innerWidth: 400, player: { left: 0, width: 400, height: 860 },
    // 竖屏全屏：16:9 视频居中，上下是播放器黑边。
    video: { left: 0, top: 317, width: 400, height: 225 },
  });
  w.__fushiYtSubs.setEnabled(true);
  const list = plain(w.__fushiYtSubs.trackList());
  assert.deepStrictEqual(list.tracks.map((t) => t.lang), extOrder(store, 'yt-M', lazy));
  assert.strictEqual(list.active, extActive(store, 'yt-M', lazy, null));
  assert.strictEqual(list.active, 'Deutsch');
  assert.strictEqual(w.__fushiYtSubs.selectTrack('Japanese'), true);
  assert.deepStrictEqual(plain(w.requested), ['yt-M|Japanese']);
  // 手机竖屏全屏：播放器 400×860。字号随视口宽（与扩展覆盖层同一条 clamp），不按播放器高放大；
  // 行宽按扩展 placeOverlay：中心 200、近侧屏缘 200 → (200-6)*2=388，上限 94% 视口 = 376；
  // 底边锚在视频矩形 88% 处 = 317+198=515，离播放器底 860-515=345px（旧版锚播放器 14%，落在黑边里）。
  store['yt-M|Japanese'] = [cue(0, 100, 'ja')];
  delete lazy['yt-M|Japanese'];
  w.fushiSubtitlePanelOnCues('yt-M|Japanese');
  w.__fushiYtSubs.setEnabled(true);
  const box = w.player.childNodes[0];
  const line = box.childNodes[0];
  assert.strictEqual(line.textContent, 'ja');
  assert.strictEqual(line.style.fontSize, 'clamp(18px, 2.2vw, 32px)');
  assert.strictEqual(line.style.maxWidth, '376px');
  assert.strictEqual(box.style.bottom, '345px', '底边锚在视频 88%（扩展 OVERLAY_POS_DEFAULT）');
}

{
  // 只有 live：用 live；整轨到达后自动升级（扩展 fullTrackArrived）。
  const store = Object.create(null);
  store['yt-C|live'] = [cue(0, 100, 'x')];
  const w = page(Object.assign({ store, videoKey: 'yt-C' }, desktop));
  w.__fushiYtSubs.setEnabled(true);
  assert.strictEqual(w.__fushiYtSubs.state().activeLang, 'live');
  store['yt-C|日本語'] = [cue(0, 100, 'j')];
  w.fushiSubtitlePanelOnCues('yt-C|日本語');
  assert.strictEqual(w.__fushiYtSubs.state().activeLang, '日本語');
  // 行宽：桌面播放器中心 500、近侧 500 → 988 < 94% × 1600。
  const L = w.__fushiYtSubs._pure.overlayLayout;
  assert.deepStrictEqual(plain(L(w.player.getBoundingClientRect(), null, 1600)), { maxWidth: 988, bottom: 54 });
  // 视频贴着视口左缘：近侧屏缘 200 → 行宽被夹到 388；夹不到 200 以下。
  assert.strictEqual(L({ left: 0, top: 0, width: 400, height: 300 }, null, 1600).maxWidth, 388);
  assert.strictEqual(L({ left: 0, top: 0, width: 100, height: 300 }, null, 1600).maxWidth, 200);
  assert.strictEqual(L(null, null, 1600), null);
  // 没有轨：null，不画。
  const empty = page(Object.assign({ store: Object.create(null), videoKey: 'yt-Z' }, desktop));
  empty.__fushiYtSubs.setEnabled(true);
  assert.strictEqual(empty.__fushiYtSubs.state().activeLang, null);
  assert.strictEqual(empty.__fushiYtSubs.trackList().tracks.length, 0);
}

const p = page(Object.assign({ store: Object.create(null), videoKey: '' }, desktop)).__fushiYtSubs._pure;
const cues = [cue(0, 1000, 'a'), cue(1000, 2000, 'b'), cue(3000, 4000, 'c')];
assert.strictEqual(p.cueAt(cues, 0).text, 'a');
assert.strictEqual(p.cueAt(cues, 1500).text, 'b');
assert.strictEqual(p.cueAt(cues, 2500), null, '两句之间无字幕');
assert.strictEqual(p.cueAt(cues, -1), null);
assert.strictEqual(p.cueAt([], 10), null);

// providers 的新轨钩子被接上，且不吞掉先前的钩子。
let prevCalled = 0;
const w2 = fakeDom('www.youtube.com');
w2.fushiSubtitlePanelOnCues = () => { prevCalled++; };
vm.createContext(w2);
vm.runInContext(adaptersSrc, w2);
vm.runInContext(overlay, w2);
w2.fushiSubtitlePanelOnCues('k');
assert.strictEqual(prevCalled, 1);

// ── 完整脚本块（bridge + adapters + providers + overlay）：在 YouTube 上装起来、在别的站上什么都不做 ──
const bundlePath = process.argv[2];
if (bundlePath) {
  const bundle = fs.readFileSync(bundlePath, 'utf8');
  const yt = run(bundle, 'm.youtube.com');
  assert.strictEqual(yt.__fushiYtSubsBundle, true, 'YouTube 上应装上');
  assert.strictEqual(typeof yt.__fushiYtSubs.setEnabled, 'function');
  // 选轨函数来自扩展 adapters（同一脚本块里先装入、块内函数声明挂到全局），字幕层够得着。
  assert.strictEqual(typeof yt.fushiListSubtitleTracks, 'function');
  assert.strictEqual(typeof yt.fushiResolveActiveSubtitleTrack, 'function');
  assert.strictEqual(yt.__fushiYtSubs.setEnabled(true), true);
  assert.strictEqual(typeof yt.__fushiYtSubs.trackList().tracks.length, 'number');
  yt.__fushiYtSubs.setEnabled(false);
  assert.strictEqual(typeof yt.fushiVideoKey, 'function', 'providers 的 window 契约可见');
  assert.ok(yt.fushiEpisodeCues, 'store 可见');
  // 同一文档再执行一次（onLoadStop 补装）不应抛（providers 顶层 const 不重复声明）。
  vm.runInContext(bundle, yt);
  const other = run(bundle, 'example.com');
  assert.strictEqual(other.__fushiYtSubsBundle, undefined, '非 YouTube 不装');
  assert.strictEqual(other.__fushiYtSubs, undefined);
}

console.log('all assertions passed');
