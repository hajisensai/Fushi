// 反馈 8KlXeA-A0f：X（twitter）上第一层查词完全没有单词发音，第二层正常。
// 根因：第一层弹窗跑在 content script realm，popup.js 的 playWordAudioInWebView 用
// `new Audio(url)` 建的 <audio> 属于页面文档，加载吃页面 CSP 的 media-src；X 只放自家 CDN +
// blob: / data:，sync server 的 http://127.0.0.1:…/api/lookup/audio/file 被拦。嵌套层是扩展
// 自己的 iframe（扩展源），不受页面 CSP 约束，所以正常。
// 修法：bridge-shim 打开 __fushiWordAudioViaHost，playWordAudioNative 经 background 交 offscreen
// 文档（扩展源）播；offscreen 不可用 / 播放失败才回落页面内 <audio>。
// 这里分别在 vm 里跑真 bridge-shim.js + popup.js 播放切片、真 offscreen.js、真 background.js。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { permissive, runtimeMock, bootBackground, sendToBackground } = require('./background-harness.test.js');

const flush = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 20; i++) await flush(); }

const SERVER_AUDIO = 'http://127.0.0.1:19633/api/lookup/audio/file?id=abc';
const POPUP_EXPORT = 'window.__fushiPlayWordAudioUrl = playWordAudio;';

function fakeAudioClass(log, { failUrls = [] } = {}) {
  function FakeAudio(url) {
    this.url = url;
    this.volume = 1;
    log.created.push(this);
  }
  FakeAudio.prototype.play = function () {
    return failUrls.includes(this.url)
      ? Promise.reject(Object.assign(new Error('blocked'), { name: 'NotSupportedError' }))
      : Promise.resolve();
  };
  FakeAudio.prototype.pause = function () { log.paused.push(this.url); };
  return FakeAudio;
}

/**
 * 页面层 realm：真 bridge-shim.js + popup.js 的 playWordAudio 切片，共享同一个 window，
 * 与 manifest content_scripts 的装载顺序一致。[bg] 模拟 background 对 playWordAudio 的回包。
 */
function loadPageRealm({ bg, windowInit = {} }) {
  const sent = [];
  const log = { created: [], paused: [] };
  const chrome = {
    runtime: {
      sendMessage: (msg) => {
        sent.push(msg);
        if (msg.type !== 'playWordAudio') return Promise.resolve(null);
        try { return Promise.resolve(bg(msg)); } catch (e) { return Promise.reject(e); }
      },
    },
    storage: { onChanged: { addListener() {} } },
  };
  const windowObj = Object.assign({}, windowInit);
  const ctx = { window: windowObj, chrome, Audio: fakeAudioClass(log) };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'bridge-shim.js'), 'utf8'), ctx,
    { filename: 'bridge-shim.js' });
  const popupSrc = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
  const start = popupSrc.indexOf('function playWordAudio(');
  const end = popupSrc.indexOf(POPUP_EXPORT);
  assert.ok(start >= 0 && end > start, 'vendor/popup.js 必须含 playWordAudio 及其导出');
  vm.runInContext(popupSrc.slice(start, end + POPUP_EXPORT.length), ctx, { filename: 'popup.js' });
  return { play: windowObj.__fushiPlayWordAudioUrl, sent, log, window: windowObj };
}

test('页面层：bridge-shim 打开宿主播放开关', () => {
  const { window: w } = loadPageRealm({ bg: () => ({ ok: true }) });
  assert.equal(w.__fushiWordAudioViaHost, true);
});

test('页面层：扩展能播时交 background/offscreen，页面里绝不构造 <audio>（不吃页面 CSP）', async () => {
  const { play, sent, log } = loadPageRealm({ bg: () => ({ ok: true }) });
  assert.equal(await play(SERVER_AUDIO), true);
  const msg = sent.find((m) => m.type === 'playWordAudio');
  assert.ok(msg, '必须发 playWordAudio 给 background');
  assert.equal(msg.url, SERVER_AUDIO);
  assert.equal(msg.volume, 1, '扩展未注入 lookupAudioVolume 时音量缺省 1');
  assert.equal(log.created.length, 0, '页面 realm 的 <audio> 会被 X 的 media-src 拦掉');
});

test('页面层：宿主注入的 lookupAudioVolume 随消息带给 offscreen', async () => {
  const { play, sent } = loadPageRealm({ bg: () => ({ ok: true }), windowInit: { lookupAudioVolume: 0.4 } });
  await play(SERVER_AUDIO);
  assert.equal(sent.find((m) => m.type === 'playWordAudio').volume, 0.4);
});

test('页面层：offscreen 不可用（回 ok:false）→ 回落页面内 <audio>', async () => {
  const { play, log } = loadPageRealm({ bg: () => ({ ok: false, error: 'no offscreen' }) });
  assert.equal(await play(SERVER_AUDIO), true);
  assert.deepEqual(log.created.map((a) => a.url), [SERVER_AUDIO]);
});

test('页面层：background 抛错 → 回落页面内 <audio>', async () => {
  const { play, log } = loadPageRealm({ bg: () => { throw new Error('sw gone'); } });
  assert.equal(await play(SERVER_AUDIO), true);
  assert.deepEqual(log.created.map((a) => a.url), [SERVER_AUDIO]);
});

function loadOffscreen({ failUrls = [] } = {}) {
  const log = { created: [], paused: [] };
  let listener = null;
  const ctx = {
    navigator: { mediaDevices: { getUserMedia: () => new Promise(() => {}) } },
    MediaRecorder: Object.assign(function () {}, { isTypeSupported: () => true }),
    Audio: fakeAudioClass(log, { failUrls }),
    chrome: { runtime: { onMessage: { addListener: (fn) => { listener = fn; } } } },
    Date,
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'offscreen.js'), 'utf8'), ctx,
    { filename: 'offscreen.js' });
  // 回包是 vm realm 的对象：转成本 realm 的纯对象再比，deepStrictEqual 才不卡原型。
  const send = (msg) => new Promise((resolve) => listener({ target: 'offscreen', ...msg }, null,
    (r) => resolve(JSON.parse(JSON.stringify(r)))));
  return { send, log };
}

test('offscreen：播放成功回 ok，音量夹到 0..1', async () => {
  const { send, log } = loadOffscreen();
  assert.deepEqual(await send({ type: 'playWordAudio', url: SERVER_AUDIO, volume: 3 }), { ok: true });
  assert.equal(log.created.length, 1);
  assert.equal(log.created[0].url, SERVER_AUDIO);
  assert.equal(log.created[0].volume, 1);
});

test('offscreen：新一段先掐掉上一段（interrupt）', async () => {
  const { send, log } = loadOffscreen();
  await send({ type: 'playWordAudio', url: 'http://127.0.0.1:1/a' });
  await send({ type: 'playWordAudio', url: 'http://127.0.0.1:1/b' });
  assert.deepEqual(log.paused, ['http://127.0.0.1:1/a']);
});

test('offscreen：play() 失败回 ok:false 与原因，供页面层回落', async () => {
  const { send } = loadOffscreen({ failUrls: [SERVER_AUDIO] });
  assert.deepEqual(await send({ type: 'playWordAudio', url: SERVER_AUDIO }),
    { ok: false, error: 'NotSupportedError' });
});

test('offscreen：只播 http(s) / data:audio，其它 scheme 拒绝且不构造 Audio', async () => {
  const { send, log } = loadOffscreen();
  for (const url of ['javascript:alert(1)', 'chrome-extension://x/y', '', undefined]) {
    assert.deepEqual(await send({ type: 'playWordAudio', url }), { ok: false, error: 'BadUrl' });
  }
  assert.equal(log.created.length, 0);
});

/** background：offscreen API 与 runtime.sendMessage 由测试控制。 */
function loadBackground({ offscreen }) {
  const listeners = [];
  const forwarded = [];
  const baseRuntime = runtimeMock(listeners);
  const runtime = new Proxy({}, {
    get(_t, key) {
      if (key === 'sendMessage') {
        return async (msg) => {
          forwarded.push(msg);
          return msg.type === 'playWordAudio' ? { ok: true } : { ok: true, recording: false };
        };
      }
      return baseRuntime[key];
    },
  });
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'storage') {
        return {
          local: { get: async () => ({}), set: async () => {}, remove: async () => {} },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'runtime') return runtime;
      if (key === 'offscreen') return offscreen;
      return permissive();
    },
  });
  bootBackground({
    chrome: chromeMock,
    fetch: async () => ({ ok: false, status: 404, text: async () => '', json: async () => ({}) }),
    defaultsSource: '',
  });
  return { listeners, forwarded };
}

test('background：并发两次发音只建一个 offscreen 文档，声明 AUDIO_PLAYBACK 并转发给 offscreen', async () => {
  let has = false;
  const created = [];
  const offscreen = {
    hasDocument: async () => has,
    createDocument: async (opts) => {
      created.push(opts);
      await flush();
      has = true;
    },
  };
  const { listeners, forwarded } = loadBackground({ offscreen });
  await settle();
  const msg = { type: 'playWordAudio', url: SERVER_AUDIO, volume: 0.5 };
  const [a, b] = await Promise.all([
    sendToBackground(listeners, msg, settle),
    sendToBackground(listeners, { ...msg, url: SERVER_AUDIO + '2' }, settle),
  ]);
  assert.equal(created.length, 1, '同一扩展只能有一个 offscreen 文档，并发 create 会抛');
  assert.ok(created[0].reasons.includes('AUDIO_PLAYBACK'));
  assert.ok(created[0].reasons.includes('USER_MEDIA'), '录制用途仍须声明');
  assert.equal(a.ok, true);
  assert.equal(b.ok, true);
  const plays = forwarded.filter((m) => m.type === 'playWordAudio');
  assert.deepEqual(plays.map((m) => [m.target, m.url, m.volume]).sort(),
    [['offscreen', SERVER_AUDIO, 0.5], ['offscreen', SERVER_AUDIO + '2', 0.5]]);
});

test('background：浏览器没有 offscreen API → ok:false（页面层据此回落）', async () => {
  const { listeners } = loadBackground({ offscreen: undefined });
  await settle();
  const resp = await sendToBackground(listeners, { type: 'playWordAudio', url: SERVER_AUDIO }, settle);
  assert.equal(resp.ok, false);
});
