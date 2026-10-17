// BUG-3146：查词 / 解析字幕失败时，限时连接诊断把「端口上的 Fushi 没应答」误报成「Fushi API
// 未开启，请去设置里打开」——用户明明开着 API，只会被误导去翻设置。连不上（拒绝连接）与
// 不应答（探测拖过时限）是两种状态，文案也必须不同；解析字幕也不能无上限地挂着。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const C = require('./connection-diagnostics.js');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

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

function loadBackground(fetchImpl) {
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
      return fetchImpl(String(url));
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


test('诊断：状态探测拖过时限 → no-response（不是 offline）', async () => {
  const bg = loadBackground((url) => (url.endsWith('/api/extension/favorite')
    ? Promise.resolve({ ok: false, status: 500, json: () => Promise.resolve(null) })
    : new Promise(() => {}))); // 状态探测永不应答 = app 在跑却卡住
  const responses = bg.send({ type: 'favorite', toggle: true, expression: '猫' });
  await wait(900);
  assert.strictEqual(responses.length, 1, '限时诊断必须让回调按时回来，不能一起挂住');
  assert.strictEqual(responses[0].connection.state, 'no-response');
});

test('诊断：连接被拒（端口没人听）→ offline，文案仍是「API 未开启」', async () => {
  const bg = loadBackground((url) => (url.endsWith('/api/extension/favorite')
    ? Promise.resolve({ ok: false, status: 502, json: () => Promise.resolve(null) })
    : Promise.reject(new TypeError('Failed to fetch'))));
  const responses = bg.send({ type: 'favorite', toggle: true, expression: '猫' });
  await wait(50);
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].connection.state, 'offline');
});

test('解析字幕：请求带上限，失败走限时诊断（此前无上限，app 不应答时「导入了没反应」）', () => {
  const src = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  const start = src.indexOf("msg.type === 'parseSubtitle'");
  const block = src.slice(start, src.indexOf('} else if', start + 10));
  assert.match(block, /signal: AbortSignal\.timeout\(\d+\)/);
  assert.match(block, /diagnoseConnectionCapped\(base\)/);
  assert.doesNotMatch(src, /await diagnoseConnection\(true\)\s*\.catch/, 'catch 分支不再用不限时的诊断');
});

test('文案：no-response 与 offline 是两条不同的说明', () => {
  globalThis.fushiT = require('./scripts/i18n-fixture.js').makeFushiT();
  try {
    const off = C.copy(C.states.offline, 19633);
    const nr = C.copy(C.states.noResponse, 19633);
    assert.notStrictEqual(nr.title, off.title);
    assert.notStrictEqual(nr.detail, off.detail);
    assert.strictEqual(C.states.noResponse, 'no-response');
  } finally { delete globalThis.fushiT; }
  const content = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
  assert.match(content, /c\.state === 'no-response'[\s\S]{0,80}conn_no_response/);
  const panel = fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8');
  assert.match(panel, /'no-response'\) return tr\('conn_no_response'\)/);
});
