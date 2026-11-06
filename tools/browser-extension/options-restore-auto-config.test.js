// 设置页状态卡就地给「恢复自动配置」：此前 unauthorized 的说明叫用户「点“恢复自动配置”」，但那颗
// 按钮折在「高级 › 高级连接设置」<details> 里，状态卡所在的位置根本看不到。现在状态卡里直接有一颗，
// 与高级连接设置里的 #reset 走同一个 restoreAutoConfig；只在它确实能解决当前状态时出现。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const C = require('./connection-diagnostics.js');
const { makeFushiT } = require('./scripts/i18n-fixture.js');

const flush = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 20; i++) await flush(); }

const OPTIONS_HTML = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');

function fakeElement(id) {
  const listeners = {};
  const base = {
    id, value: '', placeholder: '', hidden: false, checked: false, disabled: false, open: false,
    textContent: '', innerHTML: '', title: '', dataset: {}, style: {}, options: [], children: [],
    listeners,
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    querySelector() { return fakeElement(); },
    querySelectorAll() { return []; },
    closest() { return fakeElement(); },
    appendChild(c) { return c; },
  };
  return new Proxy(base, {
    get(t, k) {
      if (k in t) return t[k];
      if (typeof k === 'symbol' || k === 'then') return undefined;
      return function () {};
    },
  });
}

function loadOptions({ saved, disk, statuses }) {
  const els = new Map();
  const getEl = (id) => {
    if (!els.has(id)) els.set(id, fakeElement(id));
    return els.get(id);
  };
  const store = Object.assign({}, saved || {});
  const sets = [];
  const statusRequests = [];
  const queue = statuses.slice();
  const chrome = {
    storage: {
      local: {
        get: async (keys) => {
          const out = {};
          for (const k of [].concat(keys || [])) if (k in store) out[k] = store[k];
          return out;
        },
        set: async (obj) => { sets.push(obj); Object.assign(store, obj); },
        remove: async () => {},
      },
      onChanged: { addListener() {} },
    },
    runtime: {
      lastError: undefined,
      getURL: (p) => 'chrome-extension://ext/' + p,
      getManifest: () => ({ version: '0.1.0' }),
      sendMessage(msg, cb) {
        if (msg && msg.type === 'connectionStatus') {
          statusRequests.push(msg);
          const connection = queue.length > 1 ? queue.shift() : queue[0];
          setTimeout(() => cb({ ok: true, connection }), 0);
        } else if (cb) {
          setTimeout(() => cb(null), 0);
        }
      },
    },
  };
  const document = {
    getElementById: getEl,
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: () => fakeElement(),
    documentElement: fakeElement('html'),
    head: fakeElement('head'),
    body: fakeElement('body'),
    activeElement: null,
    addEventListener() {},
  };
  const sandbox = {
    chrome, document, console,
    fetch: async (url) => {
      if (String(url) === 'chrome-extension://ext/fushi-defaults.js') {
        return { ok: true, status: 200, text: async () => disk };
      }
      throw new TypeError('Failed to fetch');
    },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener() {}, removeEventListener() {},
    navigator: { clipboard: { writeText: async () => {} }, language: 'zh-CN' },
    URL, Promise, Date, Number, String, JSON, Array, Object, Math, Error, TypeError, RegExp, Map,
    Set, Boolean, isNaN, parseInt, parseFloat,
    fushiT: makeFushiT(),
  };
  sandbox.self = sandbox;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  // 装载顺序同 options.html：fushi-defaults.js（页面打开那一刻的旧值）在 auto-config.js 之前。
  vm.runInContext("self.FUSHI_DEFAULTS = { host: '127.0.0.1', port: 19633, token: 'old' };", sandbox);
  for (const f of ['auto-config.js', 'connection-diagnostics.js', 'self-update.js', 'options.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, f), 'utf8'), sandbox, { filename: f });
  }
  return { el: getEl, store, sets, statusRequests };
}

const NEW_DISK = [
  '// TODO-1087: written by Fushi install helper on extract.',
  'self.FUSHI_DEFAULTS = {',
  '  host: "127.0.0.1",',
  '  port: 19700,',
  '  token: "new",',
  '  build: "b1",',
  '};',
].join('\n');

const unauthorizedManual = {
  state: 'unauthorized', base: 'http://127.0.0.1:19633', port: 19633,
  manual: { host: false, port: false, token: true },
};
const connected = {
  state: 'connected', base: 'http://127.0.0.1:19700', port: 19700,
  manual: { host: false, port: false, token: false },
};

test('状态卡里有「恢复自动配置」按钮（默认隐藏，文案复用 opt_reset_button），且就在 #connectionCard 内', () => {
  const card = OPTIONS_HTML.slice(OPTIONS_HTML.indexOf('id="connectionCard"'),
      OPTIONS_HTML.indexOf('</section>', OPTIONS_HTML.indexOf('id="connectionCard"')));
  assert.match(card, /<button class="text-button connection-restore" id="connRestoreAuto" type="button" hidden data-i18n="opt_reset_button">/);
  assert.match(OPTIONS_HTML, /<script src="fushi-defaults\.js"><\/script>\s*<script src="auto-config\.js"><\/script>/);
});

test('unauthorized（手动 token 过期）：状态卡出现按钮；点击走与 #reset 同一 restoreAutoConfig，清覆盖并用磁盘最新自动配置', async () => {
  const page = loadOptions({ saved: { token: 'stale' }, disk: NEW_DISK, statuses: [unauthorizedManual, connected] });
  await settle();

  const restore = page.el('connRestoreAuto');
  assert.equal(restore.hidden, false, 'unauthorized 且有手动覆盖时状态卡必须给出按钮');
  assert.equal(page.el('connDetail').textContent, makeFushiT()('conn_state_unauthorized_detail'));
  // 页面打开时就重读了磁盘：占位显示的是 app 刚写入的端口，而不是 <script> 读到的旧值。
  assert.equal(page.el('port').placeholder, '19700');

  const resetHandlers = page.el('reset').listeners.click;
  const restoreHandlers = restore.listeners.click;
  assert.equal(restoreHandlers.length, 1);
  assert.equal(restoreHandlers[0], resetHandlers[0], '两颗按钮必须共用同一处理函数');

  page.el('token').value = 'stale';
  const before = page.statusRequests.length;
  await restoreHandlers[0]();
  await settle();
  assert.deepEqual(JSON.parse(JSON.stringify(page.sets[page.sets.length - 1])),
    { host: '', port: 0, token: '' });
  assert.equal(page.el('token').value, '');
  assert.equal(page.el('token').placeholder, makeFushiT()('opt_token_auto_placeholder'));
  assert.equal(page.statusRequests.length, before + 1);
  assert.equal(page.statusRequests[page.statusRequests.length - 1].force, true);
  assert.equal(restore.hidden, true, '恢复后连上了，按钮收起');
  assert.equal(page.el('connTitle').textContent, makeFushiT()('conn_state_connected_title'));
});

test('unauthorized 但没有任何手动覆盖：清空是空操作，不给按钮；说明改指向重新运行安装助手', async () => {
  const page = loadOptions({
    disk: NEW_DISK,
    statuses: [{ state: 'unauthorized', base: 'http://127.0.0.1:19633', port: 19633,
      manual: { host: false, port: false, token: false } }],
  });
  await settle();
  assert.equal(page.el('connRestoreAuto').hidden, true);
  assert.equal(page.el('connDetail').textContent, makeFushiT()('conn_state_unauthorized_auto_detail'));
});

test('autoConfigFixable 判据：密钥被拒 + 任一手动覆盖；连不上 / 别的服务 / Yomitan 占端口 + 手动改过 host 或 port', () => {
  const none = { host: false, port: false, token: false };
  assert.equal(C.autoConfigFixable(C.states.unauthorized, { ...none, token: true }), true);
  assert.equal(C.autoConfigFixable(C.states.unauthorized, { ...none, host: true }), true);
  assert.equal(C.autoConfigFixable(C.states.unauthorized, none), false);
  assert.equal(C.autoConfigFixable(C.states.unauthorized, null), false, '旧 SW 不回带 manual：不显示');
  for (const s of [C.states.offline, C.states.wrongService, C.states.yomitanConflict]) {
    assert.equal(C.autoConfigFixable(s, { ...none, port: true }), true, s);
    assert.equal(C.autoConfigFixable(s, { ...none, token: true }), false, s);
  }
  assert.equal(C.autoConfigFixable(C.states.connected, { host: true, port: true, token: true }), false);
  assert.equal(C.autoConfigFixable(C.states.noResponse, { ...none, port: true }), false);
});

// ── 403：Fushi 按来源地址拒绝（网络访问策略），与密钥无关 ──

test('classify：403 是 forbidden，不再并进 unauthorized；401 仍是 unauthorized', () => {
  assert.equal(C.classify({ status: 403 }), C.states.forbidden);
  assert.equal(C.classify({ status: 404 }, { status: 403 }), C.states.forbidden);
  assert.equal(C.classify({ status: 401 }), C.states.unauthorized);
  assert.notEqual(C.states.forbidden, C.states.unauthorized);
});

test('forbiddenReason 按 app 的三种 403 文案区分，认不出给 null', () => {
  const r = (text) => C.forbiddenReason({ status: 403, text });
  assert.equal(r('Fushi API only accepts requests from this device until an API key is set'), 'no-key');
  assert.equal(r('This address is not in the Fushi API allowed networks'), 'not-allowed');
  assert.equal(r('Fushi API only accepts requests from this device'), 'local-only');
  assert.equal(r('Forbidden'), null);
  assert.equal(C.forbiddenReason({ status: 401, text: 'Unauthorized' }), null);
});

test('forbidden 文案：标题独立于「密钥不匹配」，四种原因各有说明且都指向 Fushi 的「本机服务」', () => {
  const t = makeFushiT();
  globalThis.fushiT = t;
  try {
    const details = [null, 'no-key', 'not-allowed', 'local-only'].map((reason) => {
      const c = C.copy(C.states.forbidden, 19633, null, reason);
      assert.equal(c.title, t('conn_state_forbidden_title'));
      assert.notEqual(c.title, t('conn_state_unauthorized_title'));
      assert.match(c.detail, /本机服务/);
      assert.match(c.detail, /允许连接|API 密钥/);
      return c.detail;
    });
    assert.equal(new Set(details).size, 4);
    assert.equal(details[0], t('conn_state_forbidden_detail'));
    assert.equal(details[1], t('conn_state_forbidden_no_key_detail'));
    assert.equal(details[2], t('conn_state_forbidden_not_allowed_detail'));
    assert.equal(details[3], t('conn_state_forbidden_local_only_detail'));
  } finally { delete globalThis.fushiT; }
});

test('autoConfigFixable(forbidden)：只有手动改过 host 才能靠恢复自动配置解决（自动配置指向本机回环，恒放行）', () => {
  const none = { host: false, port: false, token: false };
  assert.equal(C.autoConfigFixable(C.states.forbidden, { ...none, host: true }), true);
  assert.equal(C.autoConfigFixable(C.states.forbidden, { ...none, port: true, token: true }), false);
  assert.equal(C.autoConfigFixable(C.states.forbidden, null), false);
});

test('设置页：forbidden + 手动 host → 状态卡给按钮并按原因显示说明；无手动 host → 不给按钮', async () => {
  const forbidden = (manual, reason) => ({
    state: 'forbidden', base: 'http://192.168.1.20:19633', port: 19633, manual, reason,
  });
  const withHost = loadOptions({ saved: { host: '192.168.1.20' }, disk: NEW_DISK,
    statuses: [forbidden({ host: true, port: false, token: false }, 'no-key')] });
  await settle();
  assert.equal(withHost.el('connRestoreAuto').hidden, false);
  assert.equal(withHost.el('connTitle').textContent, makeFushiT()('conn_state_forbidden_title'));
  assert.equal(withHost.el('connDetail').textContent, makeFushiT()('conn_state_forbidden_no_key_detail'));

  const noHost = loadOptions({ saved: { token: 'x' }, disk: NEW_DISK,
    statuses: [forbidden({ host: false, port: false, token: true }, 'not-allowed')] });
  await settle();
  assert.equal(noHost.el('connRestoreAuto').hidden, true);
  assert.equal(noHost.el('connDetail').textContent, makeFushiT()('conn_state_forbidden_not_allowed_detail'));
});

test('页面内提示（查词 toast / 字幕面板 / 工具栏菜单）对 forbidden 有专门文案，不再显示「密钥不匹配」', () => {
  const content = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
  assert.match(content, /c\.state === 'forbidden'\) \{\s*message = fushiTr\('conn_forbidden'\)/);
  const panel = fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8');
  assert.match(panel, /c\.state === 'forbidden'\) return tr\('conn_forbidden'\)/);
  const popup = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.js'), 'utf8');
  assert.match(popup, /FUSHI_CONNECTION\.copy\(c\.state, c\.port, c\.manual, c\.reason\)/);
});
