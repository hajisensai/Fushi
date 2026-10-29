// app 内浏览器的手机视频遥控（subtitle-panel.js「手机视频遥控」一节）：
// fushiRemoteState / fushiRemoteControl / fushiRemoteMineContext 三条消息的契约。
const { test } = require('node:test');
const assert = require('node:assert');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT();
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function makeEl(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(), id: '', children: [], parentNode: null,
    style: { setProperty() {}, getPropertyValue() { return ''; }, removeProperty() {} },
    setAttribute() {}, getAttribute() { return null; },
    addEventListener() {},
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    removeChild(child) { this.children = this.children.filter((it) => it !== child); },
  };
  el.classList = { add() {}, remove() {}, toggle() {} };
  return el;
}

// 带事件的假 <video>：play()/pause()/currentTime 写入会像浏览器那样异步派发事件。
function makeVideo() {
  const listeners = {};
  const queue = [];
  const video = {
    paused: true, ended: false, duration: 120, volume: 0.5, muted: false, playbackRate: 1.25,
    videoWidth: 0, videoHeight: 0, readyState: 4,
    _time: 0,
    get currentTime() { return this._time; },
    set currentTime(v) { this._time = v; queue.push('seeking'); },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((it) => it !== fn);
    },
    play() { if (this.paused) { this.paused = false; queue.push('play'); } return Promise.resolve(); },
    pause() { if (!this.paused) { this.paused = true; queue.push('pause'); } },
    getBoundingClientRect() { return { left: 0, top: 0, width: 1280, height: 720 }; },
  };
  // 派发排队的事件（模拟浏览器在任务边界上发事件）。
  video.flush = () => {
    while (queue.length) {
      const type = queue.shift();
      for (const fn of listeners[type] || []) fn({ type });
    }
  };
  // 电脑前的人直接操作（站点控制条 / 键盘）。
  video.user = (type) => {
    if (type === 'play') video.paused = false;
    if (type === 'pause') video.paused = true;
    for (const fn of listeners[type] || []) fn({ type });
  };
  video.listenerCount = () => Object.values(listeners).reduce((n, l) => n + l.length, 0);
  return video;
}

function load(options = {}) {
  const body = makeEl('body');
  const video = makeVideo();
  const runtimeListeners = [];
  const intervals = [];
  const posted = [];
  const windowObject = {
    fushiT: FUSHI_T,
    fushiEpisodeCues: options.store || {},
    addEventListener() {},
    postMessage(message) { posted.push(message); },
  };
  const sandbox = {
    window: windowObject,
    document: {
      body, title: options.title || 'テスト動画', fullscreenElement: null, documentElement: body,
      addEventListener() {}, getElementById() { return null; },
      querySelector(selector) { return selector === 'video' ? video : null; },
      querySelectorAll() { return []; },
      createElement: makeEl,
    },
    location: {
      hostname: options.hostname || 'example.com',
      pathname: options.pathname || '/video/1',
      href: 'https://' + (options.hostname || 'example.com') + (options.pathname || '/video/1'),
    },
    navigator: {},
    setInterval(fn) { intervals.push(fn); return intervals.length; },
    clearInterval(id) { intervals[id - 1] = null; },
    setTimeout() { return 0; },
    fetch: options.fetch,
    chrome: {
      storage: {
        local: { get(_k, cb) { if (cb) cb({}); return Promise.resolve({}); }, set() {} },
        onChanged: { addListener() {} },
      },
      runtime: { sendMessage() {}, onMessage: { addListener(fn) { runtimeListeners.push(fn); } } },
    },
  };
  if (options.clip !== undefined) sandbox.fushiClipSource = () => options.clip;
  if (options.site) sandbox.fushiSite = () => options.site;
  if (options.frame !== undefined) sandbox.fushiCaptureVideoFrame = () => options.frame;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'subtitle-adapters.js'), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8'), sandbox);

  function message(payload) {
    let response;
    let async = false;
    for (const listener of runtimeListeners) {
      const r = listener(payload, {}, (value) => { response = value; });
      if (r === true) async = true;
    }
    if (async) {
      return new Promise((resolve) => {
        const poll = () => (response !== undefined ? resolve(response) : setImmediate(poll));
        poll();
      });
    }
    return response;
  }
  // 推进试听计时器（setInterval 回调）。
  function tick() {
    for (const fn of intervals) if (fn) fn();
  }
  return { video, posted, message, tick, window: windowObject };
}

const STORE = { 'example.com/video/1|ja': [{ startMs: 5000, endMs: 6000, text: '五秒' }] };

test('fushiRemoteState 带回侧栏状态与播放态', () => {
  const h = load({ store: STORE, site: 'other' });
  h.video._time = 12.345;
  h.video.paused = false;
  const state = h.message({ type: 'fushiRemoteState', includeCues: true });
  assert.strictEqual(state.ok, true);
  assert.strictEqual(state.activeLang, 'ja');
  assert.strictEqual(state.cues[0].text, '五秒');
  assert.deepStrictEqual(
    { ...state.remote },
    {
      positionMs: 12345, durationMs: 120000, playing: true, rate: 1.25, volume: 50,
      controlRevision: 0, site: 'other', title: 'テスト動画',
    },
  );
  h.video.muted = true;
  assert.strictEqual(h.message({ type: 'fushiRemoteState' }).remote.volume, 0);
});

test('遥控下发的播放 / 暂停 / 跳转不计入 controlRevision，电脑前的人操作才计', () => {
  const h = load({ store: STORE });
  h.message({ type: 'fushiRemoteState' });
  let state = h.message({ type: 'fushiRemoteControl', action: 'play' });
  h.video.flush();
  assert.strictEqual(h.video.paused, false);
  h.message({ type: 'fushiRemoteControl', action: 'seek', ms: 5000 });
  h.video.flush();
  assert.strictEqual(h.video.currentTime, 5);
  h.message({ type: 'fushiRemoteControl', action: 'pause' });
  h.video.flush();
  state = h.message({ type: 'fushiRemoteState' });
  assert.strictEqual(state.remote.controlRevision, 0);
  assert.strictEqual(state.remote.playing, false);

  h.video.user('play');
  h.video.user('seeking');
  state = h.message({ type: 'fushiRemoteState' });
  assert.strictEqual(state.remote.controlRevision, 2);
});

test('目标态已满足的命令不留期望，不会吞掉之后的真手动操作', () => {
  const h = load({ store: STORE });
  h.message({ type: 'fushiRemoteState' });
  // 本来就暂停着：pause 不会派发事件。
  h.message({ type: 'fushiRemoteControl', action: 'pause' });
  h.video.user('play');
  assert.strictEqual(h.message({ type: 'fushiRemoteState' }).remote.controlRevision, 1);
});

test('Netflix 的遥控跳转走官方播放器桥', () => {
  const h = load({ hostname: 'www.netflix.com', pathname: '/watch/81001' });
  h.message({ type: 'fushiRemoteControl', action: 'seek', ms: 7000 });
  assert.strictEqual(h.posted[0].__fushiNf, 'seek');
  assert.strictEqual(h.posted[0].ms, 7000);
  assert.strictEqual(h.video.currentTime, 0);
});

test('音量 0..100，调大时解除静音', () => {
  const h = load();
  h.video.muted = true;
  const state = h.message({ type: 'fushiRemoteControl', action: 'volume', volume: 80 });
  assert.strictEqual(h.video.volume, 0.8);
  assert.strictEqual(h.video.muted, false);
  assert.strictEqual(state.remote.volume, 80);
});

test('试听播到终点自动暂停且不计数；中途有人操作即作废', () => {
  const h = load({ store: STORE });
  h.message({ type: 'fushiRemoteState' });
  h.video._time = 30; // 试听前停在别处
  const r = h.message({ type: 'fushiRemoteControl', action: 'playRange', startMs: 5000, endMs: 6000 });
  assert.strictEqual(r.ok, true);
  h.video.flush();
  assert.strictEqual(h.video.currentTime, 5);
  assert.strictEqual(h.video.paused, false);
  h.video._time = 5.5;
  h.tick();
  assert.strictEqual(h.video.paused, false);
  h.video._time = 6.01;
  h.tick();
  h.video.flush();
  assert.strictEqual(h.video.paused, true);
  assert.strictEqual(h.message({ type: 'fushiRemoteState' }).remote.controlRevision, 0);

  h.message({ type: 'fushiRemoteControl', action: 'playRange', startMs: 5000, endMs: 6000 });
  h.video.flush();
  h.video._time = 5.2;
  h.tick();
  h.video.user('seeking'); // 电脑前的人拖了进度条
  h.video._time = 9;
  h.tick();
  assert.strictEqual(h.video.paused, false, '试听已作废，不再到点暂停');
  assert.strictEqual(h.message({ type: 'fushiRemoteState' }).remote.controlRevision, 1);
});

test('stopRange 停下试听并暂停（遥控自己的暂停，不计数）', () => {
  const h = load({ store: STORE });
  h.message({ type: 'fushiRemoteControl', action: 'playRange', startMs: 5000, endMs: 6000 });
  h.video.flush();
  h.message({ type: 'fushiRemoteControl', action: 'stopRange' });
  h.video.flush();
  assert.strictEqual(h.video.paused, true);
  assert.strictEqual(h.message({ type: 'fushiRemoteState' }).remote.controlRevision, 0);
});

test('selectTrack 只认本视频的轨', () => {
  const h = load({
    store: {
      'example.com/video/1|ja': [{ startMs: 0, endMs: 1, text: 'a' }],
      'example.com/video/1|en': [{ startMs: 0, endMs: 1, text: 'b' }],
    },
  });
  assert.strictEqual(h.message({ type: 'fushiRemoteControl', action: 'selectTrack', lang: 'ja' }).activeLang, 'ja');
  assert.strictEqual(h.message({ type: 'fushiRemoteControl', action: 'selectTrack', lang: 'xx' }).ok, false);
});

test('未知动作回 ok:false', () => {
  const h = load();
  assert.strictEqual(h.message({ type: 'fushiRemoteControl', action: 'nope' }).ok, false);
});

test('制卡素材：普通站点带当前帧；YouTube 不取帧', async () => {
  const generic = load({ clip: null, site: 'other', frame: { base64: 'QUJD' } });
  const g = await generic.message({ type: 'fushiRemoteMineContext' });
  assert.strictEqual(g.ok, true);
  assert.strictEqual(g.screenshotBase64, 'QUJD');
  assert.strictEqual(g.title, 'テスト動画');

  const yt = load({ clip: { kind: 'youtube', id: 'abc', mode: 'queue' }, site: 'youtube', frame: { base64: 'QUJD' } });
  const y = await yt.message({ type: 'fushiRemoteMineContext' });
  assert.strictEqual(y.clip.kind, 'youtube');
  assert.strictEqual(y.screenshotBase64, undefined);
});

test('制卡素材：B 站稿件在页面里取 playurl 响应体', async () => {
  const calls = [];
  const fetch = (url) => {
    calls.push(url);
    if (url.includes('/x/web-interface/view')) {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve({ code: 0, data: { cid: 1, pages: [{ cid: 11 }, { cid: 22 }] } }),
      });
    }
    return Promise.resolve({ ok: true, text: () => Promise.resolve('{"playurl":1}') });
  };
  const h = load({
    clip: { kind: 'bilibili', id: 'BV1xx', mode: 'immediate', part: 2 }, site: 'bilibili', fetch,
    frame: { base64: 'RlJN' },
  });
  const ctx = await h.message({ type: 'fushiRemoteMineContext' });
  assert.strictEqual(ctx.playurlBody, '{"playurl":1}');
  assert.strictEqual(ctx.screenshotBase64, 'RlJN');
  assert.ok(calls[1].includes('cid=22'), 'part 2 → 第二个分 P 的 cid');
});

test('被动读状态不替用户取占位轨；手机明确选中时才取', () => {
  const h = load({
    store: { 'example.com/video/1|en (auto)': [] },
  });
  const requested = [];
  h.window.fushiLazyTracks = { 'example.com/video/1|en (auto)': true };
  h.window.fushiRequestLazyTrack = (key) => requested.push(key);
  h.message({ type: 'fushiRemoteState' });
  assert.deepStrictEqual(requested, []);
  const lang = h.message({ type: 'fushiRemoteState' }).tracks[0].lang;
  h.message({ type: 'fushiRemoteControl', action: 'selectTrack', lang });
  assert.deepStrictEqual(requested, ['example.com/video/1|en (auto)']);
});
