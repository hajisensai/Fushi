// BUG-2159 审查发现的流所有权缺口：offscreen.startCapture 对并发在途调用没有互斥。
// background.fushiIconClick 先写 storage 再起录，content 收到 storage 变化后 800ms 就发
// nfEnsureCapture；慢机上首个 getUserMedia 还没 resolve 时 isRecording 为 false → 再起一条。
// 两条流先后 resolve、后者覆盖 stream 变量，前者的音轨永远没人 stop → tabCapture 一直占着标签页
// 音频，批量结束后标签页持续无声（接回扬声器删掉之后这条泄漏才听得出来）。
//
// 这里在 vm 里跑真 offscreen.js，把 getUserMedia 的落地时机交给测试控制，断言：
//   1. 并发两次 startCapture 只开一条流，第二个调用等第一个；
//   2. 等待期间 stopCapture 过，落地的流立即停轨、不成为 stream；
//   3. 已落地后再 startCapture 直接复用（already），不再开流。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, 'offscreen.js'), 'utf8');

function makeStream() {
  const tracks = [0, 1].map(() => ({ stopped: false, stop() { this.stopped = true; } }));
  return {
    tracks,
    get active() { return tracks.some((t) => !t.stopped); },
    getTracks: () => tracks,
  };
}

function load() {
  const streams = [];
  const land = []; // 每次 getUserMedia 的 resolve，由测试决定何时落地
  let listener = null;
  const ctx = {
    navigator: {
      mediaDevices: {
        getUserMedia: () => new Promise((resolve) => {
          const s = makeStream();
          streams.push(s);
          land.push(() => resolve(s));
        }),
      },
    },
    MediaRecorder: Object.assign(function () {}, { isTypeSupported: () => true }),
    chrome: { runtime: { onMessage: { addListener: (fn) => { listener = fn; } } } },
    Date,
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx, { filename: 'offscreen.js' });
  assert.ok(listener, 'offscreen.js 未注册 onMessage 监听');
  const send = (msg) => new Promise((resolve) => {
    listener({ target: 'offscreen', ...msg }, null, resolve);
  });
  const flush = () => new Promise((r) => setImmediate(r));
  return { send, flush, streams, land };
}

test('并发两次 startCapture 只开一条流，第二个调用共用在途结果', async () => {
  const h = load();
  const a = h.send({ type: 'startCapture', streamId: 's1' });
  const b = h.send({ type: 'startCapture', streamId: 's2' });
  await h.flush();
  assert.strictEqual(h.streams.length, 1, '并发调用起了第二条 getUserMedia');
  h.land[0]();
  const [ra, rb] = await Promise.all([a, b]);
  assert.strictEqual(ra.ok, true);
  assert.strictEqual(rb.ok, true);
  const rec = await h.send({ type: 'isRecording' });
  assert.strictEqual(rec.recording, true);
  assert.ok(h.streams[0].active, '唯一那条流应仍活着');
});

test('getUserMedia 等待期间 stopCapture 过，落地的流立即停轨、不留无主流', async () => {
  const h = load();
  const a = h.send({ type: 'startCapture', streamId: 's1' });
  await h.flush();
  assert.strictEqual(h.streams.length, 1);
  await h.send({ type: 'stopCapture' });
  h.land[0]();
  const ra = await a;
  assert.strictEqual(ra.ok, false);
  assert.strictEqual(ra.error, 'stopped');
  assert.ok(h.streams[0].tracks.every((t) => t.stopped), '被 stop 抢先的流没有停轨（tab 会持续哑掉）');
  const rec = await h.send({ type: 'isRecording' });
  assert.strictEqual(rec.recording, false);
});

test('已落地后再 startCapture 直接复用，不再开流', async () => {
  const h = load();
  const a = h.send({ type: 'startCapture', streamId: 's1' });
  await h.flush();
  h.land[0]();
  await a;
  const rb = await h.send({ type: 'startCapture', streamId: 's2' });
  assert.strictEqual(rb.already, true);
  assert.strictEqual(h.streams.length, 1, '已在录仍重新 getUserMedia');
});

test('在途被 stop 抢先后 startInFlight 释放，下一次 startCapture 能重新开流', async () => {
  const h = load();
  const a = h.send({ type: 'startCapture', streamId: 's1' });
  await h.flush();
  await h.send({ type: 'stopCapture' });
  h.land[0]();
  assert.strictEqual((await a).ok, false);
  const b = h.send({ type: 'startCapture', streamId: 's2' });
  await h.flush();
  assert.strictEqual(h.streams.length, 2, '在途失败后第二次 startCapture 没有重新 getUserMedia');
  h.land[1]();
  assert.strictEqual((await b).ok, true);
  const rec = await h.send({ type: 'isRecording' });
  assert.strictEqual(rec.recording, true);
});
