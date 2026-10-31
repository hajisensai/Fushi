// 反馈 biLEesNqWb：扩展里手动切换 Fushi 配置（Profile）。
// 纯逻辑（profile-selection.js）+ background.js 端到端（真 importScripts）+ 工具栏菜单接线。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

globalThis.fushiT = require('./scripts/i18n-fixture.js').makeFushiT();
const P = require('./profile-selection.js');
const { permissive, runtimeMock, bootBackground, sendToBackground } = require('./background-harness.test.js');

// ── 纯逻辑 ──

test('选择归一：只认正整数 id，坏值一律 = 跟随 Fushi', () => {
  assert.deepEqual(P.fushiNormalizeProfileSelection({ id: 3, name: '英语' }), { id: 3, name: '英语' });
  assert.deepEqual(P.fushiNormalizeProfileSelection({ id: '4' }), { id: 4, name: '' });
  for (const bad of [null, undefined, 'x', {}, { id: 0 }, { id: -1 }, { id: 1.5 }, { id: 'abc' }]) {
    assert.equal(P.fushiNormalizeProfileSelection(bad), null, JSON.stringify(bad));
  }
});

test('请求头：选了配置才加 X-Fushi-Profile-Id，不改原对象', () => {
  const base = { 'Content-Type': 'application/json', Authorization: 'Basic x' };
  const withProfile = P.fushiProfileRequestHeaders(base, 7);
  assert.equal(withProfile['X-Fushi-Profile-Id'], '7');
  assert.equal(withProfile.Authorization, 'Basic x');
  assert.equal(base['X-Fushi-Profile-Id'], undefined);
  assert.deepEqual(P.fushiProfileRequestHeaders(base, null), base);
  assert.deepEqual(P.fushiProfileRequestHeaders(base, 0), base);
});

test('列表解析丢掉坏条目，形状不对返回 null', () => {
  assert.deepEqual(
    P.fushiParseProfileList({ profiles: [{ id: 1, name: '默认' }, { id: 'x' }, null, { id: 2 }], activeProfileId: 1 }),
    { profiles: [{ id: 1, name: '默认' }, { id: 2, name: '2' }], activeProfileId: 1 },
  );
  assert.equal(P.fushiParseProfileList(null), null);
  assert.equal(P.fushiParseProfileList({ profiles: 'no' }), null);
});

test('校正：所选配置被删 → 回退跟随 Fushi + removed 提示', () => {
  const r = P.fushiReconcileProfileSelection({ id: 5, name: '旧' }, { profiles: [{ id: 1, name: '默认' }] });
  assert.equal(r.selection, null);
  assert.deepEqual(r.notice, { kind: 'removed', name: '旧' });
  assert.equal(r.changed, true);
});

test('校正：所选配置改名 → 更新名字 + renamed 提示；未变则不写', () => {
  const r = P.fushiReconcileProfileSelection({ id: 2, name: 'EN' }, { profiles: [{ id: 2, name: 'English' }] });
  assert.deepEqual(plain(r.selection), { id: 2, name: 'English' });
  assert.deepEqual(r.notice, { kind: 'renamed', oldName: 'EN', name: 'English' });
  assert.equal(r.changed, true);
  const same = P.fushiReconcileProfileSelection({ id: 2, name: 'English' }, { profiles: [{ id: 2, name: 'English' }] });
  assert.equal(same.changed, false);
  assert.equal(same.notice, null);
  const follow = P.fushiReconcileProfileSelection(null, { profiles: [{ id: 2, name: 'English' }] });
  assert.equal(follow.changed, false);
  assert.equal(follow.selection, null);
});

test('响应头 missing 只在与当前选择同 id 时回退', () => {
  const headers = (map) => (name) => (name in map ? map[name] : null);
  const sel = { id: 3, name: '日语' };
  assert.deepEqual(
    P.fushiProfileFallbackFromResponse(sel, headers({ 'X-Fushi-Profile-Missing': '3' })),
    { selection: null, notice: { kind: 'removed', name: '日语' } },
  );
  assert.equal(P.fushiProfileFallbackFromResponse(sel, headers({ 'X-Fushi-Profile-Missing': '9' })), null,
    '请求途中用户改选了别的配置：旧 id 的 missing 不能误伤新选择');
  assert.equal(P.fushiProfileFallbackFromResponse(sel, headers({})), null);
  assert.equal(P.fushiProfileFallbackFromResponse(null, headers({ 'X-Fushi-Profile-Missing': '3' })), null);
});

test('提示文案带配置名', () => {
  assert.match(P.fushiProfileNoticeText({ kind: 'removed', name: '旧' }), /旧/);
  const renamed = P.fushiProfileNoticeText({ kind: 'renamed', oldName: 'EN', name: 'English' });
  assert.match(renamed, /EN/);
  assert.match(renamed, /English/);
  assert.equal(P.fushiProfileNoticeText(null), '');
  assert.equal(P.fushiProfileNoticeText({ kind: 'other' }), '');
});

test('下拉选项：首项跟随 Fushi（带当前激活名），离线时保留已存选择', () => {
  const list = { profiles: [{ id: 1, name: '默认' }, { id: 2, name: '英语' }], activeProfileId: 1 };
  const view = P.fushiProfileOptions(list, { id: 2, name: '英语' });
  assert.deepEqual(view.options.map((o) => o.value), ['', '1', '2']);
  assert.match(view.options[0].label, /默认/);
  assert.equal(view.value, '2');
  const offline = P.fushiProfileOptions(null, { id: 4, name: '离线存的' });
  assert.deepEqual(offline.options.map((o) => o.value), ['', '4']);
  assert.equal(offline.options[1].label, '离线存的');
  assert.equal(offline.value, '4');
  assert.equal(P.fushiProfileOptions(list, null).value, '');
});

test('en.js 与 16 种语言都有配置相关文案', () => {
  const keys = ['ap_profile_label', 'ap_profile_hint', 'ap_profile_follow_app', 'ap_profile_follow_app_plain',
    'ap_profile_unavailable', 'ap_profile_notice_removed', 'ap_profile_notice_renamed', 'ap_profile_notice_dismiss'];
  const enSrc = fs.readFileSync(path.join(__dirname, 'locales', 'en.js'), 'utf8');
  for (const k of keys) assert.match(enSrc, new RegExp('\\b' + k + ':'), k);
  for (const fn of fs.readdirSync(path.join(__dirname, 'locales'))) {
    if (!fn.endsWith('.json')) continue;
    const dict = JSON.parse(fs.readFileSync(path.join(__dirname, 'locales', fn), 'utf8'));
    for (const k of keys) assert.equal(typeof dict[k], 'string', fn + ' ' + k);
  }
});

// ── background.js 端到端 ──

const flush = () => new Promise((r) => setImmediate(r));
// vm 沙箱里造的对象原型不同，deepStrictEqual 前转成本 realm 的普通值。
const plain = (v) => JSON.parse(JSON.stringify(v));
async function settle() { for (let i = 0; i < 30; i++) await flush(); }


/**
 * @param {object} o
 * @param {object} [o.saved] chrome.storage.local 初值
 * @param {Array<{id:number,name:string}>} [o.profiles] app 当前的配置
 * @param {number} [o.activeProfileId]
 */
function loadBackground({ saved, profiles, activeProfileId } = {}) {
  const app = { profiles: profiles || [{ id: 1, name: '默认' }, { id: 2, name: '英语' }], activeProfileId: activeProfileId || 1 };
  const calls = [];
  const listeners = [];
  const changeListeners = [];
  const store = Object.assign({}, saved || {});
  const emit = (changes) => { for (const fn of changeListeners) fn(changes, 'local'); };
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
            set: async (obj) => {
              const changes = {};
              for (const [k, v] of Object.entries(obj)) { changes[k] = { oldValue: store[k], newValue: v }; store[k] = v; }
              emit(changes);
            },
            remove: async (keys) => {
              const changes = {};
              for (const k of [].concat(keys || [])) { if (k in store) { changes[k] = { oldValue: store[k] }; delete store[k]; } }
              emit(changes);
            },
          },
          onChanged: { addListener(fn) { changeListeners.push(fn); } },
        };
      }
      if (key === 'runtime') return runtimeMock(listeners);
      return permissive();
    },
  });
  const fetchMock = async (url, init) => {
    url = String(url);
    if (url.startsWith('chrome-extension://')) return { ok: false, status: 404, text: async () => '' };
    const u = new URL(url);
    const h = (init && init.headers) || {};
    const requested = h['X-Fushi-Profile-Id'] != null ? Number(h['X-Fushi-Profile-Id']) : null;
    calls.push({ path: u.pathname, profile: requested });
    const respHeaders = new Map();
    if (requested != null) {
      // app 契约：所选配置只决定这次请求读哪份设置，App 的激活配置不动；响应头回报实际生效的那份。
      const found = app.profiles.some((p) => p.id === requested);
      if (!found) respHeaders.set('x-fushi-profile-missing', String(requested));
      respHeaders.set('x-fushi-profile-active', String(found ? requested : app.activeProfileId));
    }
    let body = { duplicate: false };
    if (u.pathname === '/api/extension/profiles') body = { profiles: app.profiles, activeProfileId: app.activeProfileId };
    if (u.pathname === '/api/extension/status') body = { app: 'fushi', ready: true };
    return {
      ok: true, status: 200,
      headers: { get: (name) => respHeaders.get(String(name).toLowerCase()) ?? null },
      json: async () => body, text: async () => JSON.stringify(body),
    };
  };
  bootBackground({
    chrome: chromeMock,
    fetch: fetchMock,
    defaultsSource: "self.FUSHI_DEFAULTS = { host: '127.0.0.1', port: 19633, token: 'k', build: 'b1' };",
  });
  return {
    app, calls, store,
    api(p) { return calls.filter((c) => c.path === p); },
    send: (msg) => sendToBackground(listeners, msg, settle),
  };
}

test('跟随 Fushi（没选）：查重 / 制卡请求不带配置头', async () => {
  const bg = loadBackground();
  await settle();
  await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  await bg.send({ type: 'mine', fields: { expression: '猫' }, sentence: '猫' });
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.profile), [null]);
  assert.deepEqual(bg.api('/api/mine').map((c) => c.profile), [null]);
});

test('选了配置：查词 / 制卡 / 查重 / 音频 / 在 Anki 中打开都带它，其余端点不带', async () => {
  const bg = loadBackground({ saved: { fushiProfileSelection: { id: 2, name: '英语' } } });
  await settle();
  await bg.send({ type: 'lookup', term: '猫' });
  await bg.send({ type: 'mine', fields: { expression: '猫' }, sentence: '猫' });
  await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  await bg.send({ type: 'lookupAudio', expression: '猫', reading: 'ねこ' });
  await bg.send({ type: 'lookupAudioList', expression: '猫', reading: 'ねこ' });
  await bg.send({ type: 'openInAnki', expression: '猫', reading: 'ねこ' });
  await bg.send({ type: 'srsTermStatus', expression: '猫', reading: 'ねこ' });
  for (const p of ['/api/lookup/dictionary', '/api/mine', '/api/duplicate', '/api/lookup/audio',
    '/api/lookup/audio/list', '/api/anki/open']) {
    assert.deepEqual(bg.api(p).map((c) => c.profile), [2], p);
  }
  assert.deepEqual(bg.api('/api/srs/term-status').map((c) => c.profile), [null], '与配置无关的端点不带头');
});

test('选择即时生效：fushiSelectProfile 后下一条请求就带新配置；选回跟随 Fushi 即不带', async () => {
  const bg = loadBackground();
  await settle();
  const r = await bg.send({ type: 'fushiSelectProfile', profile: { id: 2, name: '英语' } });
  assert.equal(r.ok, true);
  assert.deepEqual(plain(bg.store.fushiProfileSelection), { id: 2, name: '英语' });
  await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  // 只影响扩展：带所选配置的请求之后，app 报的激活配置仍是原来那份，选择也不被「校正」掉。
  const listed = await bg.send({ type: 'fushiProfiles' });
  assert.equal(listed.activeProfileId, 1);
  assert.deepEqual(plain(listed.selection), { id: 2, name: '英语' });
  await bg.send({ type: 'fushiSelectProfile', profile: null });
  assert.equal('fushiProfileSelection' in bg.store, false);
  await bg.send({ type: 'duplicate', expression: '犬', reading: 'いぬ' });
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.profile), [2, null]);
});

test('所选配置在 app 里被删：响应头 missing → 回退跟随 Fushi 并留提示，之后不再带旧 id', async () => {
  const bg = loadBackground({ saved: { fushiProfileSelection: { id: 9, name: '已删' } } });
  await settle();
  await bg.send({ type: 'duplicate', expression: '猫', reading: 'ねこ' });
  await settle();
  assert.equal('fushiProfileSelection' in bg.store, false);
  assert.equal(bg.store.fushiProfileNotice.kind, 'removed');
  assert.equal(bg.store.fushiProfileNotice.name, '已删');
  await bg.send({ type: 'duplicate', expression: '犬', reading: 'いぬ' });
  assert.deepEqual(bg.api('/api/duplicate').map((c) => c.profile), [9, null]);
});

test('列配置：返回列表 + 激活配置；发现改名则更新保存的名字并提示', async () => {
  const bg = loadBackground({
    saved: { fushiProfileSelection: { id: 2, name: 'EN' } },
    profiles: [{ id: 1, name: '默认' }, { id: 2, name: 'English' }],
  });
  await settle();
  const r = await bg.send({ type: 'fushiProfiles' });
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.profiles.map((p) => p.id)), [1, 2]);
  assert.equal(r.activeProfileId, 1);
  assert.deepEqual(plain(r.selection), { id: 2, name: 'English' });
  assert.deepEqual(plain(bg.store.fushiProfileSelection), { id: 2, name: 'English' });
  assert.equal(bg.store.fushiProfileNotice.kind, 'renamed');
});

test('列配置：所选配置已不在列表 → 回退跟随 Fushi 并提示', async () => {
  const bg = loadBackground({ saved: { fushiProfileSelection: { id: 5, name: '旧' } } });
  await settle();
  const r = await bg.send({ type: 'fushiProfiles' });
  assert.equal(r.ok, true);
  assert.equal(r.selection, null);
  assert.equal('fushiProfileSelection' in bg.store, false);
  assert.equal(bg.store.fushiProfileNotice.kind, 'removed');
});

// ── 工具栏菜单接线 ──

test('工具栏菜单装入配置模块与下拉，并经 background 列出 / 选择配置', () => {
  const html = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.html'), 'utf8');
  const js = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.js'), 'utf8');
  assert.match(html, /<script src="\.\.\/profile-selection\.js"><\/script>/);
  assert.ok(html.indexOf('profile-selection.js') < html.indexOf('action-popup.js'));
  assert.match(html, /id="hp-profile-select"/);
  assert.match(html, /id="hp-profile-notice"/);
  assert.match(js, /type: 'fushiProfiles'/);
  assert.match(js, /type: 'fushiSelectProfile'/);
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.match(bg, /'profile-selection\.js'\); \}/, 'SW importScripts 装入配置模块');
});
