// 内置网页播放器主世界胶水（fushi/assets/web_video/web_video_glue.js）的行为测试：
// 与扩展共用的 subtitle-adapters.js + subtitle-providers.js 真加载进 vm 沙箱，断言
//   1) providers 的 store 变化经 fushiSubtitlePanelOnCues → 节流 → callHandler('fushiWebVideo', {type:'track'})；
//   2) 播放态轮询只在变化时投递 {type:'state'}；
//   3) seek 路由：Netflix 走 bridge postMessage，其它站直接写 video.currentTime；
//   4) 站点原生字幕隐藏用 visibility（<style>）而非 display:none，可撤销。
// 不用 jsdom：胶水只碰 querySelector/createElement/getElementById 这几件，手工 stub 更能
// 精确控制 setInterval/setTimeout（与 tools/browser-extension 的 vm 测试同范式）。
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EXT = path.join(HERE, '..', '..', 'tools', 'browser-extension');
const GLUE = path.join(HERE, '..', '..', 'fushi', 'assets', 'web_video', 'web_video_glue.js');

function makeSandbox({ hostname = 'www.example.com', pathname = '/watch/1' } = {}) {
  const posted = []; // callHandler 载荷
  const messages = []; // window.postMessage 载荷
  const listeners = { window: {}, document: {} };
  const intervals = [];
  const timeouts = [];
  const styles = [];
  const video = {
    currentTime: 0,
    paused: true,
    duration: 100,
    videoWidth: 1280,
    videoHeight: 720,
    playbackRate: 1,
    volume: 1,
    muted: false,
    textTracks: { length: 0 },
    play() { this.paused = false; return Promise.resolve(); },
    pause() { this.paused = true; },
    addEventListener() {},
    removeEventListener() {},
  };
  const head = { appendChild(el) { styles.push(el); } };
  const document = {
    title: 'Example Title',
    fullscreenElement: null,
    head,
    documentElement: head,
    querySelector(sel) { return sel === 'video' ? video : null; },
    querySelectorAll() { return []; },
    getElementById(id) { return styles.find((s) => s.id === id) || null; },
    createElement(tag) {
      const el = { tag, id: '', textContent: '', remove() { const i = styles.indexOf(el); if (i >= 0) styles.splice(i, 1); } };
      return el;
    },
    addEventListener(type, fn) { (listeners.document[type] ||= []).push(fn); },
  };
  const window = {
    origin: 'https://' + hostname,
    addEventListener(type, fn) { (listeners.window[type] ||= []).push(fn); },
    postMessage(data) { messages.push(data); },
    flutter_inappwebview: { callHandler(name, payload) { posted.push({ name, payload }); } },
  };
  const location = { hostname, pathname, href: 'https://' + hostname + pathname, origin: 'https://' + hostname };
  const sandbox = {
    window, document, location, video,
    setInterval(fn, ms) { intervals.push({ fn, ms }); return intervals.length; },
    setTimeout(fn, ms) { timeouts.push({ fn, ms }); return timeouts.length; },
    clearTimeout() {},
    console, JSON, Object, Array, String, Number, Math, isFinite, WeakSet, Set, Map, Promise, Date, RegExp, Error,
    posted, messages, listeners, intervals, timeouts, styles,
  };
  sandbox.globalThis = sandbox;
  window.fushiEpisodeCues = undefined;
  const ctx = vm.createContext(sandbox);
  for (const f of ['subtitle-adapters.js', 'subtitle-providers.js']) {
    vm.runInContext(fs.readFileSync(path.join(EXT, f), 'utf8'), ctx, { filename: f });
  }
  vm.runInContext(fs.readFileSync(GLUE, 'utf8'), ctx, { filename: 'web_video_glue.js' });
  return sandbox;
}

// vm 沙箱里造的对象原型链与宿主不同，deepStrictEqual 会因 prototype 不同判不等；按纯数据比。
function assertPlainEqual(actual, expected) {
  assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)));
}

function deliver(sb, data) {
  for (const fn of sb.listeners.window.message || []) fn({ source: sb.window, origin: sb.window.origin, data });
}
function runTimeouts(sb) { const t = sb.timeouts.splice(0); for (const { fn } of t) fn(); }
function sampler(sb) { return sb.intervals.find((i) => i.ms === 250).fn; }

test('整集字幕轨：bridge cues → providers store → 节流后整轨投给 Dart', () => {
  const sb = makeSandbox({ hostname: 'www.netflix.com', pathname: '/watch/81236554' });
  assert.ok(typeof sb.window.fushiSubtitlePanelOnCues === 'function', 'glue 必须注册 store 变化钩子');
  deliver(sb, {
    __fushiNf: 'cues', videoId: '81236554', lang: 'ja', format: 'webvtt',
    text: 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nこんにちは\n\n00:00:03.000 --> 00:00:04.000\nさようなら\n',
  });
  assert.strictEqual(sb.posted.length, 0, '节流窗内不投递');
  runTimeouts(sb);
  const tracks = sb.posted.filter((p) => p.payload.type === 'track');
  assert.strictEqual(tracks.length, 1);
  assert.strictEqual(tracks[0].name, 'fushiWebVideo');
  assertPlainEqual(tracks[0].payload, {
    type: 'track', key: '81236554|ja', videoKey: '81236554', lang: 'ja',
    cues: [{ s: 1000, e: 2000, t: 'こんにちは' }, { s: 3000, e: 4000, t: 'さようなら' }],
  });
});

test('同一轨 250ms 内多次变化合并成一次投递（DOM 采样逐字扩长不刷屏）', () => {
  const sb = makeSandbox();
  sb.window.fushiEpisodeCues['k|live'] = [{ startMs: 0, endMs: 1, text: 'a' }];
  sb.window.fushiSubtitlePanelOnCues('k|live');
  sb.window.fushiEpisodeCues['k|live'][0].text = 'ab';
  sb.window.fushiSubtitlePanelOnCues('k|live');
  assert.strictEqual(sb.timeouts.length, 1, '一个节流定时器');
  runTimeouts(sb);
  const tracks = sb.posted.filter((p) => p.payload.type === 'track');
  assert.strictEqual(tracks.length, 1);
  assert.strictEqual(tracks[0].payload.cues[0].t, 'ab', '投的是最新快照');
});

test('播放态轮询：变化才投递，静止不重复', () => {
  const sb = makeSandbox();
  const sample = sampler(sb);
  sample();
  let states = sb.posted.filter((p) => p.payload.type === 'state');
  assert.strictEqual(states.length, 1);
  assert.strictEqual(states[0].payload.hasVideo, true);
  assert.strictEqual(states[0].payload.paused, true);
  assert.strictEqual(states[0].payload.dur, 100000);
  assert.strictEqual(states[0].payload.vw, 1280);
  assert.strictEqual(states[0].payload.videoKey, 'www.example.com/watch/1');
  sample();
  states = sb.posted.filter((p) => p.payload.type === 'state');
  assert.strictEqual(states.length, 1, '无变化不重投');
  sb.video.currentTime = 1.234;
  sb.video.paused = false;
  sample();
  states = sb.posted.filter((p) => p.payload.type === 'state');
  assert.strictEqual(states.length, 2);
  assert.strictEqual(states[1].payload.t, 1234);
  assert.strictEqual(states[1].payload.paused, false);
});

test('seek：Netflix 走 bridge 消息（官方播放器 API），其它站直接写 currentTime', () => {
  const nf = makeSandbox({ hostname: 'www.netflix.com', pathname: '/watch/1' });
  assert.strictEqual(nf.window.__fushiWebVideo.seek(12345.6), 'bridge');
  assertPlainEqual(nf.messages.filter((m) => m.__fushiNf === 'seek'), [{ __fushiNf: 'seek', ms: 12346 }]);
  assert.strictEqual(nf.video.currentTime, 0, 'Netflix 绝不直接改 currentTime（M7375）');

  const other = makeSandbox({ hostname: 'www.example.com' });
  assert.strictEqual(other.window.__fushiWebVideo.seek(5000), 'direct');
  assert.strictEqual(other.video.currentTime, 5);
  assert.strictEqual(other.messages.filter((m) => m.__fushiNf === 'seek').length, 0);
});

test('seekDone 回执透传给 Dart', () => {
  const sb = makeSandbox({ hostname: 'www.netflix.com' });
  deliver(sb, { __fushiNf: 'seekDone', ok: true, err: '' });
  const done = sb.posted.filter((p) => p.payload.type === 'seekDone');
  assertPlainEqual(done.map((d) => d.payload), [{ type: 'seekDone', ok: true, err: '' }]);
});

test('隐藏站点原生字幕：visibility 而非 display:none，可撤销', () => {
  const sb = makeSandbox();
  assert.strictEqual(sb.window.__fushiWebVideo.setNativeSubtitlesHidden(true), true);
  assert.strictEqual(sb.styles.length, 1);
  assert.match(sb.styles[0].textContent, /visibility:hidden/);
  assert.doesNotMatch(sb.styles[0].textContent, /display\s*:\s*none/, 'display:none 会让 DOM 采样 live 轨读不到文本');
  sb.window.__fushiWebVideo.setNativeSubtitlesHidden(true);
  assert.strictEqual(sb.styles.length, 1, '幂等');
  sb.window.__fushiWebVideo.setNativeSubtitlesHidden(false);
  assert.strictEqual(sb.styles.length, 0);
});

test('replayCues 同时请求两类 bridge 重放并把 store 现有轨全部重投', () => {
  const sb = makeSandbox();
  sb.messages.length = 0;
  sb.window.fushiEpisodeCues['a|en'] = [{ startMs: 0, endMs: 1, text: 'x' }];
  const n = sb.window.__fushiWebVideo.replayCues();
  assert.strictEqual(n, 1);
  assert.ok(sb.messages.some((m) => m.__fushiNf === 'replayCues'));
  assert.ok(sb.messages.some((m) => m.__fushiStream === 'replayCues'));
  runTimeouts(sb);
  assert.ok(sb.posted.some((p) => p.payload.type === 'track' && p.payload.key === 'a|en'));
});
