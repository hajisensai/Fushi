// BUG-4394：词典媒体 <img> 的 query 凭据。host 在 /api/extension/status 里报
// dictionaryMediaKey: 'fmk1' 时，扩展改发由 token 派生的作用域 key（吊销签发凭据即失效、
// 不把主凭据原值拼进 URL）；没有这个能力位（旧 host / FushiApiServer）照旧发原 token。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const nodeCrypto = require('node:crypto');
const DMK = require('./dict-media-key.js');
const { permissive, runtimeMock, bootBackground, sendToBackground } = require('./background-harness.test.js');

const flush = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 20; i++) await flush(); }

// 与 packages/fushi_engine/lib/sync/fushi_sync_server.dart 的 dictionaryMediaKeyFor 同一定义，
// 这里用 node:crypto 独立实现一遍做对照（Dart 侧的逐字节对照在
// fushi/test/build/browser_extension_dict_media_key_test.dart）。
function expectedKey(token) {
  return 'fmk1.' + nodeCrypto.createHmac('sha256', Buffer.from(token, 'utf8'))
    .update('fushi-dictionary-media-v1', 'utf8').digest('base64url');
}

test('derive：fmk1. + 无填充 base64url(HMAC-SHA256(token, 常量))', async () => {
  for (const t of ['k', '', 'a"b\\cé鍵 x']) {
    assert.equal(await DMK.derive(t), expectedKey(t));
  }
});

/**
 * @param {object} o
 * @param {(n:number) => object|null} o.status 第 n 次（从 1 起）status 请求的回包体；null = 500
 */
function loadBackground({ status }) {
  const listeners = [];
  const calls = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'storage') {
        return {
          local: { get: async () => ({}), set: async () => {}, remove: async () => {} },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'runtime') return runtimeMock(listeners);
      return permissive();
    },
  });
  const fetchMock = async (url) => {
    url = String(url);
    if (url.startsWith('chrome-extension://')) return { ok: false, status: 404, text: async () => '' };
    const path = new URL(url).pathname;
    calls.push(path);
    let body = {};
    let code = 200;
    if (path === '/api/extension/status') {
      body = status(calls.filter((p) => p === path).length);
      if (body == null) code = 500;
    }
    return {
      ok: code === 200, status: code,
      headers: { get: () => null },
      json: async () => body, text: async () => JSON.stringify(body),
    };
  };
  bootBackground({
    chrome: chromeMock,
    fetch: fetchMock,
    defaultsSource: "self.FUSHI_DEFAULTS = { host: '127.0.0.1', port: 19633, token: 'k', build: 'b1' };",
  });
  return {
    statusCalls: () => calls.filter((p) => p === '/api/extension/status').length,
    send: (msg) => sendToBackground(listeners, msg, settle),
  };
}

test('status 报 fmk1：dictMediaConfig 回派生 key，不再回原 token', async () => {
  const bg = loadBackground({ status: () => ({ app: 'fushi', ready: true, dictionaryMediaKey: 'fmk1' }) });
  await settle();
  const r = await bg.send({ type: 'dictMediaConfig' });
  assert.equal(r.ok, true);
  assert.equal(r.base, 'http://127.0.0.1:19633');
  assert.equal(r.token, expectedKey('k'));
});

test('status 无能力位（旧 host）：回原 token', async () => {
  const bg = loadBackground({ status: () => ({ app: 'fushi', ready: true }) });
  await settle();
  const r = await bg.send({ type: 'dictMediaConfig' });
  assert.equal(r.token, 'k');
  // 启动检查已写入缓存：dictMediaConfig 不再额外查 status。
  assert.equal(bg.statusCalls(), 1);
});

test('启动检查失败：dictMediaConfig 自己查一次 status（单飞），之后命中缓存', async () => {
  const bg = loadBackground({
    status: (n) => (n === 1 ? null : { app: 'fushi', ready: true, dictionaryMediaKey: 'fmk1' }),
  });
  await settle();
  assert.equal(bg.statusCalls(), 1);
  const [a, b] = await Promise.all([
    bg.send({ type: 'dictMediaConfig' }),
    bg.send({ type: 'dictMediaConfig' }),
  ]);
  assert.equal(a.token, expectedKey('k'));
  assert.equal(b.token, expectedKey('k'));
  assert.equal(bg.statusCalls(), 2);
  await bg.send({ type: 'dictMediaConfig' });
  assert.equal(bg.statusCalls(), 2);
});

test('能力位查询失败：本次回原 token、不写缓存，下次再查', async () => {
  const bg = loadBackground({ status: () => null });
  await settle();
  const r = await bg.send({ type: 'dictMediaConfig' });
  assert.equal(r.token, 'k');
  const before = bg.statusCalls();
  await bg.send({ type: 'dictMediaConfig' });
  assert.equal(bg.statusCalls(), before + 1);
});
