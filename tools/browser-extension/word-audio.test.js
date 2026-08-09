const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1132 / 1139②：bridge-shim.js 把 popup.js 的 callHandler('resolveWordAudio')
// /('playWordAudio') 垫成扩展逻辑——resolveWordAudio 经 background 向 server 取音频 URL，
// playWordAudio 用 HTML5 Audio 播放。bridge-shim 声明 window.flutter_inappwebview，加载时
// 还有一个读 dict-media 配置的 IIFE（要 chrome.runtime/storage stub）。载入受控 vm context。
const SRC = path.join(__dirname, 'bridge-shim.js');
const src = fs.readFileSync(SRC, 'utf8');

function load({ responder } = {}) {
  const sent = [];
  const played = [];
  const paused = [];
  function FakeAudio(url) {
    this.url = url;
    this._failPlay = url === 'FAIL';
    played.push(url);
  }
  FakeAudio.prototype.play = function () {
    return this._failPlay ? Promise.reject(new Error('play failed')) : Promise.resolve();
  };
  FakeAudio.prototype.pause = function () { paused.push(this.url); };

  const chrome = {
    runtime: {
      sendMessage: (msg, cb) => {
        sent.push(msg);
        const res = responder ? responder(msg) : null;
        if (typeof cb === 'function') cb(res);
        return Promise.resolve(res);
      },
    },
    storage: { onChanged: { addListener: () => {} } },
  };
  const windowObj = {};
  const ctx = { window: windowObj, chrome, Audio: FakeAudio };
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return { call: windowObj.flutter_inappwebview.callHandler, sent, played, paused, window: windowObj };
}

test('resolveWordAudio: 发 lookupAudio 消息并返回 server 给的 url', async () => {
  const { call, sent } = load({
    responder: (msg) => msg.type === 'lookupAudio'
      ? { ok: true, url: 'http://127.0.0.1:19633/api/lookup/audio/file?id=abc' }
      : null,
  });
  const url = await call('resolveWordAudio', { expression: '走る', reading: 'はしる' });
  assert.strictEqual(url, 'http://127.0.0.1:19633/api/lookup/audio/file?id=abc');
  const audioMsg = sent.find((m) => m.type === 'lookupAudio');
  assert.ok(audioMsg, 'expected a lookupAudio message');
  assert.strictEqual(audioMsg.expression, '走る');
  assert.strictEqual(audioMsg.reading, 'はしる');
});

test('resolveWordAudio: server 未命中 (url null) → 返回 null', async () => {
  const { call } = load({ responder: () => ({ ok: false, url: null }) });
  const url = await call('resolveWordAudio', { expression: '猫', reading: 'ねこ' });
  assert.strictEqual(url, null);
});

test('resolveWordAudio: background 抛错 (无 responder 抛) → 返回 null（不阻断查词）', async () => {
  const { call } = load({ responder: () => { throw new Error('bg down'); } });
  const url = await call('resolveWordAudio', { expression: 'x', reading: 'y' });
  assert.strictEqual(url, null);
});

// 89294bf4b (land PR#278) 起 playWordAudio 桥已从 bridge-shim 删除：播放收敛进
// vendor/popup.js 的 playWordAudio（三端同一 HTML5 <audio> 路径，导出为
// window.__fushiPlayWordAudioUrl）。以下用源码切片在受控 vm 里断言新契约。
const POPUP_EXPORT = 'window.__fushiPlayWordAudioUrl = playWordAudio;';

function loadPopupPlayer() {
  const popupSrc = fs.readFileSync(
    path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
  const start = popupSrc.indexOf('function playWordAudio(');
  const end = popupSrc.indexOf(POPUP_EXPORT);
  assert.ok(start >= 0 && end > start,
    'vendor/popup.js 必须含 playWordAudio 及其 __fushiPlayWordAudioUrl 导出');
  const slice = popupSrc.slice(start, end + POPUP_EXPORT.length);
  const played = [];
  const paused = [];
  function FakeAudio(url) {
    this.url = url;
    this._failPlay = url === 'FAIL';
    played.push(url);
  }
  FakeAudio.prototype.play = function () {
    return this._failPlay
      ? Promise.reject(new Error('play failed')) : Promise.resolve();
  };
  FakeAudio.prototype.pause = function () { paused.push(this.url); };
  const windowObj = {};
  const ctx = { window: windowObj, Audio: FakeAudio };
  vm.createContext(ctx);
  vm.runInContext(slice, ctx);
  return { play: windowObj.__fushiPlayWordAudioUrl, played, paused };
}

test('playWordAudio(popup): 用 HTML5 Audio 播放并返回 true', async () => {
  const { play, played } = loadPopupPlayer();
  assert.strictEqual(await play('http://h/file?id=1'), true);
  assert.deepStrictEqual(played, ['http://h/file?id=1']);
});

test('playWordAudio(popup): interrupt 模式先掐掉上一段', async () => {
  const { play, paused } = loadPopupPlayer();
  await play('http://h/a');
  await play('http://h/b');
  assert.deepStrictEqual(paused, ['http://h/a']);
});

test('playWordAudio(popup): 空 url → false 且不构造 Audio', async () => {
  const { play, played } = loadPopupPlayer();
  assert.strictEqual(await play(''), false);
  assert.strictEqual(played.length, 0);
});

test('playWordAudio(popup): play() 失败 → false（不抛）', async () => {
  const { play } = loadPopupPlayer();
  assert.strictEqual(await play('FAIL'), false);
});
