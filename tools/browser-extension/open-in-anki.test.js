// Issue #1409（B 部分）：查词弹窗 ↗「在 Anki 中打开这个词的卡」在浏览器扩展里恒提示打不开。
//
// 根因：vendor/popup.js 的 openWordInAnki 调 callHandler('openInAnki')，但扩展三个宿主
// （页内 bridge-shim / Side Panel / 嵌套弹窗 host）都没接这根桥 → 落到默认分支回 null →
// popup 按「宿主没接这根桥」提示「无法在 Anki 中打开」；background 也没有对应消息、
// server 也没有端点。本文件钉住扩展这一侧的整条链：
//   popup callHandler('openInAnki') → bridge-shim → background 'openInAnki'
//   → POST /api/anki/open {expression,reading} → {outcome} 三态名原样回 popup。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

// ── bridge-shim.js（页内弹窗宿主）────────────────────────────────────────
function loadShim(responder) {
  const sent = [];
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
  const windowObj = {};
  const ctx = { window: windowObj, chrome };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'bridge-shim.js'), 'utf8'), ctx);
  return { call: windowObj.flutter_inappwebview.callHandler, sent };
}

for (const outcome of ['opened', 'noMatch', 'failed']) {
  test(`bridge-shim openInAnki：server 回 ${outcome} → 原样交给 popup`, async () => {
    const { call, sent } = loadShim((msg) => (msg.type === 'openInAnki'
      ? { ok: true, status: 200, data: { outcome } } : null));
    const result = await call('openInAnki', { expression: '走る', reading: 'はしる' });
    assert.strictEqual(result, outcome);
    const msg = sent.find((m) => m.type === 'openInAnki');
    assert.ok(msg, 'expected an openInAnki runtime message');
    assert.strictEqual(msg.expression, '走る');
    assert.strictEqual(msg.reading, 'はしる');
  });
}

test('bridge-shim openInAnki：绝不回 null（null 专指宿主没接这根桥）', async () => {
  const cases = [
    () => null, // background 无应答
    () => ({ ok: false, status: 404, data: null }), // 旧 app 无端点
    () => ({ ok: false, status: 401, data: null }), // token 错
    () => ({ ok: true, status: 200, data: { outcome: 'weird' } }), // 不认识的结局
    () => ({ ok: true, status: 200, data: {} }),
    () => { throw new Error('extension context invalidated'); },
  ];
  for (const responder of cases) {
    const { call } = loadShim(responder);
    assert.strictEqual(await call('openInAnki', { expression: '猫', reading: '' }), 'failed');
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
    send(msg) {
      const responses = [];
      for (const fn of messageListeners) fn(msg, {}, (r) => responses.push(r));
      return responses;
    },
  };
}

test('background openInAnki：POST /api/anki/open {expression,reading} 带鉴权，回 server 的 outcome', async () => {
  const bg = loadBackground({
    ok: true, status: 200, json: () => Promise.resolve({ outcome: 'opened' }),
  });
  const responses = bg.send({ type: 'openInAnki', expression: '走る', reading: 'はしる' });
  await flush();
  const hits = bg.posts.filter((p) => p.url.endsWith('/api/anki/open'));
  assert.strictEqual(hits.length, 1, '应当只发一次 /api/anki/open，实际 ' + hits.length);
  assert.deepStrictEqual(hits[0].body, { expression: '走る', reading: 'はしる' });
  assert.ok(/^Basic /.test(String(hits[0].headers.Authorization || '')),
    '必须与 lookup/mine/duplicate 同源 Basic 鉴权');
  assert.strictEqual(responses.length, 1);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(responses[0])),
    { ok: true, status: 200, data: { outcome: 'opened' } });
});

test('background openInAnki：server 非 2xx → ok:false、data:null（shim 据此回 failed）', async () => {
  const bg = loadBackground({ ok: false, status: 404, json: () => Promise.reject(new Error('no body')) });
  const responses = bg.send({ type: 'openInAnki', expression: '猫', reading: '' });
  await flush();
  assert.strictEqual(responses.length, 1);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(responses[0])),
    { ok: false, status: 404, data: null });
});

// ── 另外两个弹窗宿主：Side Panel 与嵌套弹窗 host ─────────────────────────────
test('nested-popup-host：openInAnki 在转发白名单里（否则嵌套弹窗里的 ↗ 同样回 null）', () => {
  const src = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
  const m = src.match(/const allowed = new Set\(\[([\s\S]*?)\]\)/);
  assert.ok(m, 'nested-popup-host.js 必须有 allowed 转发白名单');
  assert.ok(/'openInAnki'/.test(m[1]), 'allowed 必须含 openInAnki');
});

test('side-panel：callHandler 接 openInAnki 并回三态名（不回 null）', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  const start = src.indexOf("if (name === 'openInAnki')");
  assert.ok(start >= 0, 'side-panel.js 的 callHandler 必须处理 openInAnki');
  const block = src.slice(start, src.indexOf("if (name === 'resolveWordAudio')", start));
  assert.ok(/type: 'openInAnki'/.test(block), '必须经 background openInAnki 消息');
  assert.ok(/'failed'/.test(block), '失败必须回 failed，不能回 null');
});
