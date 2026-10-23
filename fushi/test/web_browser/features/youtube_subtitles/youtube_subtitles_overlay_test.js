// node 驱动：assets/web_browser/youtube_subtitles.js 的纯逻辑 + 完整脚本块能否解析执行。
// 由 youtube_subtitles_feature_test.dart 调用：argv[2] = 拼好的脚本块文件路径。
'use strict';
const fs = require('fs');
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
  ctx.location = ctx.location;
  vm.createContext(ctx);
  vm.runInContext(source, ctx, { filename: 'bundle.js' });
  return ctx;
}

// ── 纯逻辑 ──
const overlay = fs.readFileSync('assets/web_browser/youtube_subtitles.js', 'utf8');
const w = run(overlay, 'www.youtube.com');
const p = w.__fushiYtSubs._pure;
const cue = (s, e, t) => ({ startMs: s, endMs: e, text: t });
const store = Object.create(null);
store['yt-A|日本語'] = [];               // 占位轨（未加载）
store['yt-A|live'] = [cue(0, 100, 'l')];
store['yt-A|English'] = [cue(0, 100, 'e')];
store['yt-A|日本語 (自动)'] = [cue(0, 100, 'j')];
store['yt-B|日本語'] = [cue(0, 100, 'b')];
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', null), 'yt-A|English', '登记顺序里第一条有 cue 的整轨');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-A|日本語 (自动)'), 'yt-A|日本語 (自动)', '当前轨仍有效则保持');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-B|日本語'), 'yt-A|English', '别的视频的轨不算');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-A|日本語'), 'yt-A|English', '空轨不当当前轨');
const onlyLive = Object.create(null);
onlyLive['yt-C|live'] = [cue(0, 1, 'x')];
onlyLive['yt-C|日本語'] = [];
assert.strictEqual(p.chooseTrackKey(onlyLive, 'yt-C', null), 'yt-C|live', '没有整轨才用 live');
assert.strictEqual(p.chooseTrackKey(store, 'yt-Z', null), null);
assert.strictEqual(p.chooseTrackKey(store, '', null), null);

const cues = [cue(0, 1000, 'a'), cue(1000, 2000, 'b'), cue(3000, 4000, 'c')];
assert.strictEqual(p.cueAt(cues, 0).text, 'a');
assert.strictEqual(p.cueAt(cues, 1500).text, 'b');
assert.strictEqual(p.cueAt(cues, 2500), null, '两句之间无字幕');
assert.strictEqual(p.cueAt(cues, -1), null);
assert.strictEqual(p.cueAt([], 10), null);
assert.strictEqual(p.langOf('yt-A|ja~3'), 'ja');

// providers 的新轨钩子被接上，且不吞掉先前的钩子。
let prevCalled = 0;
const w2 = fakeDom('www.youtube.com');
w2.fushiSubtitlePanelOnCues = () => { prevCalled++; };
vm.createContext(w2);
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
  assert.strictEqual(typeof yt.fushiVideoKey, 'function', 'providers 的 window 契约可见');
  assert.ok(yt.fushiEpisodeCues, 'store 可见');
  // 同一文档再执行一次（onLoadStop 补装）不应抛（providers 顶层 const 不重复声明）。
  vm.runInContext(bundle, yt);
  const other = run(bundle, 'example.com');
  assert.strictEqual(other.__fushiYtSubsBundle, undefined, '非 YouTube 不装');
  assert.strictEqual(other.__fushiYtSubs, undefined);
}

console.log('all assertions passed');
