// 自动配置自愈：app 改了 API 密钥 / 端口后会就地重写已解压扩展里的 fushi-defaults.js（build 不变），
// 但 service worker 只在启动时 importScripts 过一次——此前扩展一直报「API 密钥不匹配」，直到用户
// 手动重载扩展。现在请求遇 401 / 连不上时重读磁盘上的 fushi-defaults.js，生效连接变了才重试一次；
// 用户在设置页手动覆盖过的字段绝不被静默替换。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const AC = require('./auto-config.js');
const { permissive, runtimeMock, bootBackground, sendToBackground } = require('./background-harness.test.js');

const flush = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 20; i++) await flush(); }

// 与 fushi/lib/src/lookup/browser_extension_installer.dart 的 buildBrowserExtensionDefaultsJs
// 逐行同形：host / token / build 是 JSON 字符串，port 是整数。
function generatedDefaults({ host, port, token, build }) {
  const lines = [
    '// TODO-1087: written by Fushi install helper on extract.',
    '// Priority: chrome.storage.local (manual override) > this file.',
    'self.FUSHI_DEFAULTS = {',
    '  host: ' + JSON.stringify(host) + ',',
    '  port: ' + port + ',',
    '  token: ' + JSON.stringify(token) + ',',
  ];
  if (build != null) lines.push('  build: ' + JSON.stringify(build) + ',');
  lines.push('};');
  return lines.join('\n') + '\n';
}

// ── 解析器 ──

test('解析生成格式：JSON 转义的 token（引号 / 反斜杠 / 非 ASCII）原样还原，build 不进连接三元组', () => {
  const token = 'a"b\\cé鍵 x';
  const parsed = AC.parseDefaultsSource(generatedDefaults({
    host: '127.0.0.1', port: 19700, token, build: '0123456789abcdef',
  }));
  assert.deepEqual(parsed, { host: '127.0.0.1', port: 19700, token });
});

test('解析随包占位文件（单引号、注释里也写着 host= / port=）', () => {
  const src = fs.readFileSync(path.join(__dirname, 'fushi-defaults.js'), 'utf8');
  assert.deepEqual(AC.parseDefaultsSource(src), { host: '127.0.0.1', port: 19633, token: '' });
});

test('注释行里的 token: 不会被当成真值', () => {
  const src = '// token: "evil"\n' + generatedDefaults({ host: 'h', port: 1, token: 'real' });
  assert.equal(AC.parseDefaultsSource(src).token, 'real');
});

test('残缺 / 越界 / 不认识的内容一律 null（调用方保持现值），绝不 eval', () => {
  assert.equal(AC.parseDefaultsSource(''), null);
  assert.equal(AC.parseDefaultsSource(null), null);
  assert.equal(AC.parseDefaultsSource('self.FUSHI_DEFAULTS = { host: "h", port: 1 };'), null, '缺 token');
  assert.equal(AC.parseDefaultsSource(generatedDefaults({ host: 'h', port: 70000, token: '' })), null);
  assert.equal(AC.parseDefaultsSource(generatedDefaults({ host: '', port: 1, token: '' })), null);
  assert.equal(AC.parseDefaultsSource('self.FUSHI_DEFAULTS = { host: h(), port: 1, token: "" };'), null);
  assert.equal(AC.parseDefaultsSource('<html>404</html>'), null);
});

test('sameConnection 只比 host / port / token', () => {
  assert.ok(AC.sameConnection({ host: 'h', port: 1, token: 't', build: 'x' }, { host: 'h', port: 1, token: 't' }));
  assert.ok(!AC.sameConnection({ host: 'h', port: 1, token: 't' }, { host: 'h', port: 1, token: 'u' }));
});

// ── background.js 端到端（真 importScripts 装载 auto-config.js / connection-diagnostics.js）──


/**
 * @param {object} o
 * @param {{host:string, port:number, token:string}} o.boot  SW 启动时 importScripts 读到的自动配置
 * @param {object} [o.saved] chrome.storage.local 里用户手动保存的 host / port / token
 * @param {string} o.serverKey app 当前密钥
 * @param {number} [o.serverPort] app 当前监听端口（其它端口拒绝连接）
 */
function loadBackground({ boot, saved, serverKey, serverPort }) {
  const state = {
    disk: generatedDefaults(Object.assign({ build: 'b1' }, boot)),
    serverKey,
    serverPort: serverPort || boot.port,
    hangPaths: new Set(),
    forbidText: null, // 非 null = app 的网络访问策略按来源地址拒绝（403 + 纯文本原因）
  };
  const calls = [];
  const listeners = [];
  const store = Object.assign({}, saved || {});
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'storage') {
        return {
          local: {
            get: async (keys) => {
              const out = {};
              for (const k of [].concat(keys || [])) if (k in store) out[k] = store[k];
              return out;
            },
            set: async (obj) => { Object.assign(store, obj); },
            remove: async () => {},
          },
          onChanged: { addListener() {} },
        };
      }
      if (key === 'runtime') return runtimeMock(listeners);
      return permissive();
    },
  });
  const fetchMock = async (url, init) => {
    url = String(url);
    if (url === 'chrome-extension://ext/fushi-defaults.js') {
      calls.push({ kind: 'defaults', cache: init && init.cache });
      return { ok: true, status: 200, text: async () => state.disk };
    }
    const u = new URL(url);
    const auth = (init && init.headers && init.headers.Authorization) || '';
    const token = auth.startsWith('Basic ')
      ? Buffer.from(auth.slice(6), 'base64').toString('utf8').replace(/^fushi:/, '') : null;
    calls.push({ kind: 'api', path: u.pathname, port: Number(u.port), token });
    if (Number(u.port) !== state.serverPort) throw new TypeError('Failed to fetch');
    if (state.hangPaths.has(u.pathname)) {
      const e = new Error('signal timed out'); e.name = 'TimeoutError'; throw e;
    }
    if (state.forbidText != null) {
      return { ok: false, status: 403, json: async () => { throw new SyntaxError('not json'); },
        text: async () => state.forbidText };
    }
    if (token !== state.serverKey) {
      return { ok: false, status: 401, json: async () => null, text: async () => 'Unauthorized' };
    }
    const body = u.pathname === '/api/extension/status'
      ? { app: 'fushi', ready: true } : { duplicate: true };
    return { ok: true, status: 200, json: async () => body, text: async () => JSON.stringify(body) };
  };
  bootBackground({ chrome: chromeMock, fetch: fetchMock, defaultsSource: state.disk });
  return {
    state, calls, store,
    api(p) { return calls.filter((c) => c.kind === 'api' && c.path === p); },
    defaultsReads() { return calls.filter((c) => c.kind === 'defaults'); },
    send: (msg) => sendToBackground(listeners, msg, settle),
    // 「app 里改了密钥 / 端口」：server 换值，同时就地重写已解压副本里的 fushi-defaults.js（build 不变）。
    appChanges({ key, port }) {
      if (key != null) state.serverKey = key;
      if (port != null) state.serverPort = port;
      state.disk = generatedDefaults({
        host: '127.0.0.1', port: state.serverPort, token: state.serverKey, build: 'b1',
      });
    },
  };
}

const BOOT = { host: '127.0.0.1', port: 19633, token: 'old' };

test('401 → 重读磁盘 defaults → token 变了 → 用新 token 重试一次并成功', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle(); // SW 启动时的版本检查用旧密钥正常通过
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' });

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.ok, true);
  assert.equal(resp.status, 200);
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.token), ['old', 'new'], '只重试一次');
  assert.equal(bg.defaultsReads().length, 1);
  assert.equal(bg.defaultsReads()[0].cache, 'no-store', '必须绕过缓存读磁盘当前内容');

  // 内存里的自动配置已更新：之后的请求直接用新密钥，不再先吃一次 401。
  bg.calls.length = 0;
  await bg.send({ type: 'duplicate', expression: '犬', reading: 'いぬ' });
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.token), ['new']);
  assert.equal(bg.defaultsReads().length, 0);
});

test('端口变了（旧端口拒绝连接）→ 重读 defaults → 新端口重试成功', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ port: 19700 });

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.ok, true);
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.port), [19633, 19700]);
});

test('用户手动覆盖过 token：重读不替换它，生效连接不变 → 不重试，401 原样上报', async () => {
  const bg = loadBackground({ boot: BOOT, saved: { token: 'mine' }, serverKey: 'mine' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' });

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.ok, false);
  assert.equal(resp.status, 401);
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.token), ['mine'], '手动 token 绝不被静默替换');
  assert.equal(bg.store.token, 'mine');
});

test('只手动覆盖了 host：token 仍跟随自动配置自愈，host 保持用户的值', async () => {
  const bg = loadBackground({ boot: BOOT, saved: { host: 'localhost' }, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' });

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.ok, true);
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.token), ['old', 'new']);
  const status = await bg.send({ type: 'connectionStatus', force: true });
  assert.equal(status.connection.base, 'http://localhost:19633');
});

test('磁盘上的 defaults 没变（密钥本就不对）→ 不重试', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.state.serverKey = 'other'; // app 密钥变了，但没有重写扩展目录（例如扩展从别处加载）

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.status, 401);
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.token), ['old']);
  assert.equal(bg.defaultsReads().length, 1);
});

test('超时（请求可能已被处理）不重读也不重发', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' });
  bg.state.hangPaths.add('/api/duplicate');

  const resp = await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  assert.equal(resp.ok, false);
  assert.equal(bg.api('/api/duplicate').length, 1);
});

test('连接诊断（设置页状态卡）同样自愈：401 → 重读 → connected，并回带 manual 覆盖信息', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.appChanges({ key: 'new' });

  const resp = await bg.send({ type: 'connectionStatus', force: true });
  assert.equal(resp.connection.state, 'connected');
  assert.deepEqual(JSON.parse(JSON.stringify(resp.connection.manual)),
    { host: false, port: false, token: false });
});

test('连接诊断：手动 token 过期 → unauthorized + manual.token=true（设置页据此给「恢复自动配置」）', async () => {
  const bg = loadBackground({ boot: BOOT, saved: { token: 'stale' }, serverKey: 'old' });
  await settle();
  const resp = await bg.send({ type: 'connectionStatus', force: true });
  assert.equal(resp.connection.state, 'unauthorized');
  assert.equal(resp.connection.manual.token, true);
});

// ── 403（网络访问策略拒绝来源地址）是独立状态：不归到「密钥不匹配」、不触发自愈重试 ──

test('403：诊断报 forbidden 并带出原因（不在白名单），不重读自动配置、不重测', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' }); // 即便磁盘上的密钥也变了：403 与密钥无关，不该去重读
  bg.state.forbidText = 'This address is not in the Fushi API allowed networks';

  const resp = await bg.send({ type: 'connectionStatus', force: true });
  assert.equal(resp.connection.state, 'forbidden');
  assert.equal(resp.connection.reason, 'not-allowed');
  assert.equal(bg.defaultsReads().length, 0);
  assert.equal(bg.api('/api/extension/status').length, 1);
  assert.equal(bg.api('/serverVersion').length, 0, '已认出是 Fushi 拒绝，不必再探 Yomitan');
});

test('403：诊断按 body 区分「没设密钥」与「仅本机」', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.state.forbidText = 'Fushi API only accepts requests from this device until an API key is set';
  assert.equal((await bg.send({ type: 'connectionStatus', force: true })).connection.reason, 'no-key');
  bg.state.forbidText = 'Fushi API only accepts requests from this device';
  assert.equal((await bg.send({ type: 'connectionStatus', force: true })).connection.reason, 'local-only');
  bg.state.forbidText = 'Forbidden';
  const generic = (await bg.send({ type: 'connectionStatus', force: true })).connection;
  assert.equal(generic.state, 'forbidden');
  assert.equal(generic.reason, null);
});

test('403：业务请求不重读、不重试，诊断给 forbidden', async () => {
  const bg = loadBackground({ boot: BOOT, serverKey: 'old' });
  await settle();
  bg.calls.length = 0;
  bg.appChanges({ key: 'new' });
  bg.state.forbidText = 'Fushi API only accepts requests from this device';

  const resp = await bg.send({ type: 'favorite', toggle: true, expression: '猫' });
  assert.equal(resp.ok, false);
  assert.equal(resp.status, 403);
  assert.equal(resp.connection.state, 'forbidden');
  assert.equal(bg.api('/api/extension/favorite').length, 1);
  assert.equal(bg.defaultsReads().length, 0);
});
