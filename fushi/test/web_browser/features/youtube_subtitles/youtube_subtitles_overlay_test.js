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
// 不指定学习语言：原声（与自动字幕同语言）优先，首选（日語人工轨）还没取到时先用自动轨。
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', null), 'yt-A|日本語 (自动)', '原声自动轨先于别的人工轨');
assert.strictEqual(p.preferredTrackKey(store, 'yt-A', {}), 'yt-A|日本語', '首选是原声人工轨（占位，待取）');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-A|English'), 'yt-A|English', '首选还在取时当前轨仍有效则保持');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-B|日本語'), 'yt-A|日本語 (自动)', '别的视频的轨不算');
assert.strictEqual(p.chooseTrackKey(store, 'yt-A', 'yt-A|日本語'), 'yt-A|日本語 (自动)', '空轨不当当前轨');
// 首选轨取到 cue 后换过去（不再死守当前轨）。
const loaded = Object.assign(Object.create(null), store, { 'yt-A|日本語': [cue(0, 100, 'J')] });
assert.strictEqual(p.chooseTrackKey(loaded, 'yt-A', 'yt-A|日本語 (自动)'), 'yt-A|日本語');

// m.youtube.com 真实回归：拿不到音轨元数据，bridge 退回字母序把德语人工轨排第一并急取。
// 学习语言 ja 必须压过登记顺序：日语轨还是占位时先显示原声 / 英文，绝不选德语。
const mobile = Object.create(null);
mobile['yt-M|Deutsch'] = [cue(0, 100, 'de')];
mobile['yt-M|English'] = [];
mobile['yt-M|English (auto-generated)'] = [cue(0, 100, 'en-asr')];
mobile['yt-M|Japanese'] = [];
const ja = { lang: 'ja', uiLangs: ['en'] };
assert.strictEqual(p.preferredTrackKey(mobile, 'yt-M', ja), 'yt-M|Japanese', '学习语言日语排第一（按语言名识别）');
assert.strictEqual(p.chooseTrackKey(mobile, 'yt-M', null, ja), 'yt-M|English (auto-generated)', '日语未取到：原声（英文自动轨）先于德语');
mobile['yt-M|Japanese'] = [cue(0, 100, 'ja')];
assert.strictEqual(p.chooseTrackKey(mobile, 'yt-M', 'yt-M|English (auto-generated)', ja), 'yt-M|Japanese', '日语取到后换过去');
// 标签是日文界面下的名字、带「(自動生成)」也认。
const jaUi = Object.create(null);
jaUi['yt-J|ドイツ語'] = [cue(0, 1, 'de')];
jaUi['yt-J|日本語 (自動生成) (自动)'] = [cue(0, 1, 'ja')];
assert.strictEqual(p.chooseTrackKey(jaUi, 'yt-J', null, { lang: 'ja', uiLangs: ['ja'] }), 'yt-J|日本語 (自動生成) (自动)');
// 有页面元数据时按语言码，不靠名字；默认轨算原声。
const meta = Object.create(null);
meta['yt-X|Foo'] = [cue(0, 1, 'foo')];
meta['yt-X|Bar'] = [cue(0, 1, 'bar')];
meta['yt-X|Baz'] = [cue(0, 1, 'baz')];
const metaOpts = { lang: 'ko', meta: { Foo: { lang: 'de', asr: false }, Bar: { lang: 'ko', asr: false }, Baz: { lang: 'fr', asr: false, def: true } } };
assert.strictEqual(p.chooseTrackKey(meta, 'yt-X', null, metaOpts), 'yt-X|Bar', '元数据语言码命中学习语言');
assert.strictEqual(p.chooseTrackKey(meta, 'yt-X', null, { meta: metaOpts.meta }), 'yt-X|Baz', '没有学习语言轨：默认（原声）轨');
// 没有学习语言 / 原声线索时：人工轨先于英文自动轨，英文自动轨先于其它自动轨。
const plain = Object.create(null);
plain['yt-P|Français (auto-generated)'] = [cue(0, 1, 'fr')];
plain['yt-P|English (auto-generated)'] = [cue(0, 1, 'en')];
assert.deepStrictEqual(Array.from(p.rankTrackKeys(plain, 'yt-P', { lang: 'ko', uiLangs: ['en'] })),
  ['yt-P|Français (auto-generated)', 'yt-P|English (auto-generated)'], '第一条自动轨视为原声');
assert.strictEqual(p.baseName('日本語 (自動生成) (自动)'), '日本語');
assert.strictEqual(p.baseName('English (United States)'), 'english');
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
  // Dart 下发的学习语言随 setEnabled 记下。
  yt.__fushiYtSubs.setEnabled(true, 'ja');
  assert.strictEqual(yt.__fushiYtSubs.state().lang, 'ja');
  yt.__fushiYtSubs.setEnabled(false);
  assert.strictEqual(yt.__fushiYtSubs.state().lang, 'ja', '只关不改语言');
  assert.strictEqual(typeof yt.fushiVideoKey, 'function', 'providers 的 window 契约可见');
  assert.ok(yt.fushiEpisodeCues, 'store 可见');
  // 同一文档再执行一次（onLoadStop 补装）不应抛（providers 顶层 const 不重复声明）。
  vm.runInContext(bundle, yt);
  const other = run(bundle, 'example.com');
  assert.strictEqual(other.__fushiYtSubsBundle, undefined, '非 YouTube 不装');
  assert.strictEqual(other.__fushiYtSubs, undefined);
}

console.log('all assertions passed');
