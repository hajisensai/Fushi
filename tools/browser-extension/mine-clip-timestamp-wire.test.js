// BUG-2080 守卫：Netflix 录制片段制卡的**卡面时间窗**必须真的走上 wire。
//
// 复诉根因：`{clip-timestamp}` 对扩展 Netflix 用户结构性恒空，因为服务端
// `buildImmersionRequest` 把 clipStartMs/clipEndMs 硬编码成 0。把服务端改成透传之后
// 症状仍在——因为**扩展这一侧压根不发这两个键**：content.js 的 mineClip 消息只带
// cueStartMs/mineAtMs，background.js 的 /api/mine body 同样没有（对比 mineYoutube
// 分支一直发着 clipStartMs/clipEndMs）。两侧都补上，链路才通。
//
// 本文件钉住 background.js 那一段（wire 成形处，可在 vm 里真跑）。content.js 的取值
// 侧由 queue-item 形态断言守着：卡面要显示的是**字幕窗** cueStartV/cueEndV，不是带
// ±200ms 录制余量的 startV/endV。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
}

function loadBackground() {
  const posts = [];
  const messageListeners = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'onMessage') return { addListener(fn) { messageListeners.push(fn); } };
            return permissive();
          },
        });
      }
      return permissive();
    },
  });
  const sandbox = {
    chrome: chromeMock, console,
    fetch: (url, init) => {
      posts.push({ url, body: init && init.body ? JSON.parse(init.body) : null });
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ ok: true }) });
    },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String, JSON, Array, Object, Math,
    performance, AbortController, Error, RegExp, Map, Set, Boolean, isNaN, parseInt, parseFloat,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'),
      sandbox, { filename: 'background.js' });
  return {
    posts,
    send(msg) { for (const fn of messageListeners) fn(msg, {}, () => {}); },
  };
}

function mineClipMsg(extra) {
  return Object.assign({
    type: 'mineClip', fields: { expression: '走る' }, sentence: '彼は走る',
    clipBase64: 'AAA', clipDurationMs: 4000,
  }, extra || {});
}

async function postFor(extra) {
  const bg = loadBackground();
  bg.send(mineClipMsg(extra));
  await flush();
  const mine = bg.posts.filter((p) => String(p.url).endsWith('/api/mine'));
  assert.equal(mine.length, 1, '应当只发一次 /api/mine，实际 ' + mine.length);
  return mine[0].body;
}

test('BUG-2080：mineClip 带两端窗时，clipStartMs/clipEndMs 原样进 /api/mine', async () => {
  const body = await postFor({ clipStartMs: 754000, clipEndMs: 758000 });
  assert.equal(body.clipStartMs, 754000);
  assert.equal(body.clipEndMs, 758000);
});

test('BUG-2080：老队列项没有窗（两端 undefined）→ 两个键都不发，服务端退回 0/0 旧行为', async () => {
  const body = await postFor({});
  assert.ok(!('clipStartMs' in body), 'clipStartMs 不该出现');
  assert.ok(!('clipEndMs' in body), 'clipEndMs 不该出现');
});

test('BUG-2080：只有半个窗时两个键都不发——半个窗会让 end > start 判据结果不可预期', async () => {
  const onlyStart = await postFor({ clipStartMs: 754000, clipEndMs: null });
  assert.ok(!('clipStartMs' in onlyStart), '只有起点时 clipStartMs 也不该发');
  assert.ok(!('clipEndMs' in onlyStart));
  const onlyEnd = await postFor({ clipStartMs: null, clipEndMs: 758000 });
  assert.ok(!('clipStartMs' in onlyEnd));
  assert.ok(!('clipEndMs' in onlyEnd), '只有终点时 clipEndMs 也不该发');
});

test('BUG-2080：content.js 队列项成对存字幕窗，且发的是字幕窗不是录制余量窗', () => {
  const src = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
  // 入队：cueStartV/cueEndV 成对存下（startV/endV 带 ±200ms 录制余量，不是卡面要的窗）。
  assert.match(src, /cueStartV:\s*w\.startV,/, '队列项必须存 cueStartV');
  assert.match(src, /cueEndV:\s*w\.endV,/, '队列项必须成对存 cueEndV');
  // 发送：取的是 cue 窗，不是 q.startV/q.endV。
  assert.match(src, /clipStartMs:\s*\(typeof q\.cueStartV === 'number' \? q\.cueStartV : null\)/,
      'mineClip 必须把 cueStartV 作为 clipStartMs 发出');
  assert.match(src, /clipEndMs:\s*\(typeof q\.cueEndV === 'number' \? q\.cueEndV : null\)/,
      'mineClip 必须把 cueEndV 作为 clipEndMs 发出');
  assert.ok(!/clipStartMs:\s*\(typeof q\.startV/.test(src),
      '卡面窗不得取带录制余量的 q.startV');
});
