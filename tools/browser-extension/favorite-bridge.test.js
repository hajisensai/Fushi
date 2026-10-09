// BUG-3141：查词弹窗 ☆/★ 收藏在浏览器扩展里点了没反应——图标不变、Fushi 收藏夹也没新行。
//
// 根因：vendor/popup.js 的收藏按钮调 callHandler('favoriteEntry') / callHandler('favoriteCheck')，
// 但扩展的三个弹窗宿主（页内 bridge-shim / Side Panel / 嵌套弹窗 host）都没接这两根桥 → 落到
// default 分支回 null → popup 把 null 当「没收藏」；background 没有对应消息、server 也没有端点。
// 本文件钉住扩展这一侧的整条链：
//   popup callHandler('favoriteEntry'|'favoriteCheck') → bridge-shim → background 'favorite'
//   → POST /api/extension/favorite {toggle,expression,reading,glossary,sentence} → {favorite}。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

function loadShim(responder, windowExtras) {
  const sent = [];
  const toasts = [];
  const chrome = {
    runtime: {
      sendMessage: (msg, cb) => {
        sent.push(msg);
        const res = responder(msg);
        if (typeof cb === 'function') cb(res);
        return Promise.resolve(res);
      },
    },
    storage: { onChanged: { addListener: () => {} } },
  };
  const windowObj = Object.assign({ fushiToast: (t) => toasts.push(t) }, windowExtras || {});
  const ctx = { window: windowObj, chrome };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'bridge-shim.js'), 'utf8'), ctx);
  return { call: windowObj.flutter_inappwebview.callHandler, sent, toasts };
}

test('bridge-shim favoriteEntry：切换收藏，带释义快照与当前句，回 server 的新状态', async () => {
  const { call, sent, toasts } = loadShim(
    (msg) => (msg.type === 'favorite' ? { ok: true, status: 200, data: { favorite: true } } : null),
    { fushiMineContext: () => ({ window: { text: 'カタクリの花が咲いた。' } }) },
  );
  const result = await call('favoriteEntry', { expression: '片栗', reading: 'かたくり', glossary: '早春の草本植物' });
  assert.strictEqual(result, true, 'popup 据此把 ☆ 翻成 ★');
  const msg = sent.find((m) => m.type === 'favorite');
  assert.ok(msg, '必须经 background 的 favorite 消息');
  assert.strictEqual(msg.toggle, true);
  assert.strictEqual(msg.expression, '片栗');
  assert.strictEqual(msg.reading, 'かたくり');
  assert.strictEqual(msg.glossary, '早春の草本植物');
  assert.strictEqual(msg.sentence, 'カタクリの花が咲いた。');
  assert.deepStrictEqual(toasts, []);
});

test('bridge-shim favoriteCheck：只读（toggle:false），不带释义、不 toast', async () => {
  const { call, sent, toasts } = loadShim(
    (msg) => (msg.type === 'favorite' ? { ok: true, status: 200, data: { favorite: true } } : null));
  assert.strictEqual(await call('favoriteCheck', { expression: '片栗', reading: 'かたくり' }), true);
  const msg = sent.find((m) => m.type === 'favorite');
  assert.strictEqual(msg.toggle, false);
  assert.strictEqual(msg.glossary, '');
  assert.deepStrictEqual(toasts, []);
});

test('bridge-shim 收藏：绝不回 null（null 被 popup 当「没收藏」，就是这个 bug 的症状）', async () => {
  const cases = [
    () => null,
    () => ({ ok: false, status: 404, data: null }),
    () => ({ ok: false, status: 401, data: null }),
    () => ({ ok: true, status: 200, data: {} }),
    () => { throw new Error('extension context invalidated'); },
  ];
  for (const responder of cases) {
    const { call, toasts } = loadShim(responder);
    assert.strictEqual(await call('favoriteCheck', { expression: '猫' }), false);
    assert.deepStrictEqual(toasts, [], '只读失败不打扰用户');
    assert.strictEqual(await call('favoriteEntry', { expression: '猫' }), false);
    assert.strictEqual(toasts.length, 1, '点了收藏没收藏上必须看得见');
  }
});

// ── background.js（转发到 server）────────────────────────────────────────
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

function loadBackground(serverReply) {
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
      posts.push({
        url: String(url),
        headers: (init && init.headers) || {},
        body: init && init.body ? JSON.parse(init.body) : null,
      });
      return Promise.resolve(serverReply);
    },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String, JSON, Array, Object, Math,
    performance, AbortController, AbortSignal, Error, RegExp, Map, Set, Boolean, isNaN, parseInt, parseFloat,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'),
      sandbox, { filename: 'background.js' });
  return {
    posts,
    send(msg) {
      const responses = [];
      for (const fn of messageListeners) fn(msg, {}, (r) => responses.push(r));
      return responses;
    },
  };
}

test('background favorite：POST /api/extension/favorite 带鉴权，回 {favorite}', async () => {
  const bg = loadBackground({ ok: true, status: 200, json: () => Promise.resolve({ favorite: true }) });
  const responses = bg.send({
    type: 'favorite', toggle: true, expression: '片栗', reading: 'かたくり', glossary: 'g', sentence: 's',
  });
  await flush();
  const hits = bg.posts.filter((p) => p.url.endsWith('/api/extension/favorite'));
  assert.strictEqual(hits.length, 1);
  assert.deepStrictEqual(hits[0].body,
    { toggle: true, expression: '片栗', reading: 'かたくり', glossary: 'g', sentence: 's' });
  assert.ok(/^Basic /.test(String(hits[0].headers.Authorization || '')));
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].ok, true);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(responses[0].data)), { favorite: true });
});

test('background favorite：旧 app 无端点（404）→ ok:false，不做连接诊断', async () => {
  const bg = loadBackground({ ok: false, status: 404, json: () => Promise.reject(new Error('no body')) });
  const responses = bg.send({ type: 'favorite', toggle: true, expression: '猫' });
  await flush();
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].ok, false);
  assert.strictEqual(responses[0].status, 404);
  assert.strictEqual(responses[0].connection, undefined);
});

// ── 另外两个弹窗宿主 ──────────────────────────────────────────────────────
test('nested-popup-host：favoriteEntry / favoriteCheck 在转发白名单里', () => {
  const src = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
  const m = src.match(/const allowed = new Set\(\[([\s\S]*?)\]\)/);
  assert.ok(m);
  assert.ok(/'favoriteEntry'/.test(m[1]) && /'favoriteCheck'/.test(m[1]));
});

test('side-panel：callHandler 接两根收藏桥，经 background favorite 消息', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  const start = src.indexOf("if (name === 'favoriteEntry' || name === 'favoriteCheck')");
  assert.ok(start >= 0, 'side-panel.js 的 callHandler 必须处理收藏桥');
  const block = src.slice(start, src.indexOf("if (name === 'resolveWordAudio')", start));
  assert.ok(/type: 'favorite'/.test(block));
  assert.ok(/return false;/.test(block), '失败回 false，不回 null');
});
