// 反馈 KGC1ifR1a3：看网页视频时用 Fushi App 本体的「收藏」——收藏当前句（字幕 + 时间点）与视频本身，
// 与 App 收藏夹是同一份数据。本文件钉住扩展这一侧的整条链：
//   入口（播放器菜单 / 快捷键 Ctrl+Shift+F / 侧边栏 ☆）→ video-favorite.js 执行端
//   → background 'videoFavorite' → POST /api/extension/video-favorite {op,kind,url,title,text,startMs,endMs}
//   → {favorite?, video, sentences:[{text,startMs}]} → 已收藏状态（★ / 开关开态）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const VF = require('./video-favorite.js');
const VS = require('./video-shortcuts.js');

const flush = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };
const plain = (o) => JSON.parse(JSON.stringify(o));

// ── 纯函数：消息格式与回包解析 ────────────────────────────────────────────────

test('cueKey：起点毫秒取整 + 去首尾空白的文本（与 App 匹配口径同）', () => {
  assert.strictEqual(VF.cueKey(' 夏が来た ', 83000.4), '83000|夏が来た');
  assert.strictEqual(VF.cueKey('a', undefined), '|a');
});

test('toggleMessage：句子收藏带文本与时间点；视频收藏不带句子字段；非网页 / 无句子 → null', () => {
  assert.deepStrictEqual(
    VF.toggleMessage('sentence', 'https://youtu.be/abc?t=3', '歌 - YouTube', { text: ' 夏 ', startMs: 1200.6, endMs: 1800 }),
    { type: 'videoFavorite', op: 'toggle', kind: 'sentence', url: 'https://youtu.be/abc?t=3', title: '歌 - YouTube', text: '夏', startMs: 1201, endMs: 1800 },
  );
  assert.deepStrictEqual(
    VF.toggleMessage('video', 'https://www.netflix.com/watch/1', 'N', { text: 'ignored' }),
    { type: 'videoFavorite', op: 'toggle', kind: 'video', url: 'https://www.netflix.com/watch/1', title: 'N' },
  );
  assert.strictEqual(VF.toggleMessage('sentence', 'https://a.jp/v', '', { text: '  ' }), null);
  assert.strictEqual(VF.toggleMessage('sentence', 'https://a.jp/v', '', null), null);
  assert.strictEqual(VF.toggleMessage('video', 'chrome-extension://x/p.html', '', null), null);
  assert.deepStrictEqual(VF.stateMessage('https://a.jp/v'), { type: 'videoFavorite', op: 'state', url: 'https://a.jp/v' });
  assert.strictEqual(VF.stateMessage('about:blank'), null);
});

test('parseResponse：只认合契约的回包，坏回包一律 ok:false（不当成「没收藏」写进状态）', () => {
  const good = VF.parseResponse({ ok: true, status: 200, data: { favorite: true, video: false, sentences: [{ text: '夏', startMs: 1200 }] } });
  assert.strictEqual(good.ok, true);
  assert.strictEqual(good.favorite, true);
  assert.strictEqual(good.video, false);
  assert.deepStrictEqual(Object.keys(good.keys), ['1200|夏']);
  for (const bad of [null, { ok: false, status: 404 }, { ok: true, data: {} }, { ok: true, data: { video: true } }]) {
    assert.strictEqual(VF.parseResponse(bad).ok, false);
  }
  assert.strictEqual(VF.parseResponse({ ok: false, status: 404 }).status, 404);
});

test('toastKey：加 / 取消分句子与视频；404 = 旧 App 提示更新，其余失败 = 连不上', () => {
  assert.strictEqual(VF.toastKey('sentence', { ok: true, favorite: true }), 'vfav_line_added');
  assert.strictEqual(VF.toastKey('sentence', { ok: true, favorite: false }), 'vfav_line_removed');
  assert.strictEqual(VF.toastKey('video', { ok: true, favorite: true }), 'vfav_video_added');
  assert.strictEqual(VF.toastKey('video', { ok: true, favorite: false }), 'vfav_video_removed');
  assert.strictEqual(VF.toastKey('video', { ok: false, status: 404 }), 'favorite_failed_old_app');
  assert.strictEqual(VF.toastKey('sentence', { ok: false, status: 0 }), 'favorite_failed');
});

// ── 运行时：执行端 + 已收藏状态 + 侧边栏 tab 消息 ──────────────────────────────

function loadRuntime(responder, opts = {}) {
  const sent = [];
  const toasts = [];
  const tabListeners = [];
  let interval = null;
  const location = { href: opts.href || 'https://www.youtube.com/watch?v=abc&t=5', protocol: 'https:' };
  const windowObj = {
    fushiT: (k) => k,
    fushiToast: (t) => toasts.push(t),
    fushiSubtitleCurrentCue: () => (opts.cue === undefined ? { text: '夏が来た', startMs: 83000, endMs: 85000 } : opts.cue),
  };
  const sandbox = {
    window: windowObj,
    document: { title: '(2) 歌 - YouTube', querySelector: (s) => (s === 'video' ? {} : null) },
    location,
    setInterval: (fn) => { interval = fn; return 1; },
    Date, Promise, Object, Array, String, Math, isFinite,
    chrome: {
      runtime: {
        lastError: null,
        sendMessage(msg, cb) {
          sent.push(msg);
          Promise.resolve().then(() => cb(responder(msg)));
        },
        onMessage: { addListener: (fn) => tabListeners.push(fn) },
      },
    },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'video-favorite.js'), 'utf8'), sandbox, { filename: 'video-favorite.js' });
  return {
    vf: windowObj.fushiVideoFavorite, sent, toasts, location,
    tick: () => interval && interval(),
    tab(msg) {
      return new Promise((resolve) => {
        for (const fn of tabListeners) if (fn(msg, {}, resolve) === true) return;
        resolve(undefined);
      });
    },
  };
}

function appState(store) {
  // 模拟 App：按 kind + text + startMs 切换，回整份状态（同 /api/extension/video-favorite）。
  return (msg) => {
    if (msg.type !== 'videoFavorite') return null;
    let favorite;
    if (msg.op === 'toggle') {
      const key = msg.kind === 'video' ? 'video' : msg.startMs + '|' + msg.text;
      favorite = !store.has(key);
      if (favorite) store.add(key); else store.delete(key);
    }
    const sentences = [...store].filter((k) => k !== 'video').map((k) => {
      const i = k.indexOf('|');
      return { text: k.slice(i + 1), startMs: Number(k.slice(0, i)) };
    });
    return { ok: true, status: 200, data: Object.assign(favorite === undefined ? {} : { favorite }, { video: store.has('video'), sentences }) };
  };
}

test('快捷键 / 菜单「收藏当前句」：发页面原地址 + 标题 + 当前句，toast 成功，状态变 ★；再按取消', async () => {
  const r = loadRuntime(appState(new Set()));
  assert.strictEqual(r.vf.toggleCurrentCue(), true, '有当前句 = 接管按键');
  await flush();
  const toggle = r.sent.find((m) => m.op === 'toggle');
  assert.deepStrictEqual(plain(toggle), {
    type: 'videoFavorite', op: 'toggle', kind: 'sentence',
    url: 'https://www.youtube.com/watch?v=abc&t=5', title: '(2) 歌 - YouTube',
    text: '夏が来た', startMs: 83000, endMs: 85000,
  });
  assert.deepStrictEqual(r.toasts, ['vfav_line_added']);
  assert.strictEqual(r.vf.isCueFavorited({ text: '夏が来た', startMs: 83000 }), true);
  assert.strictEqual(r.vf.isCueFavorited({ text: '夏が来た', startMs: 90000 }), false, '同文本不同时间点是另一句');

  r.vf.toggleCurrentCue();
  await flush();
  assert.strictEqual(r.toasts.pop(), 'vfav_line_removed');
  assert.strictEqual(r.vf.isCueFavorited({ text: '夏が来た', startMs: 83000 }), false);
});

test('没有当前句：不发请求、不吞按键，toast 说明', async () => {
  const r = loadRuntime(appState(new Set()), { cue: null });
  assert.strictEqual(r.vf.toggleCurrentCue(), false);
  await flush();
  assert.ok(!r.sent.some((m) => m.op === 'toggle'));
  assert.deepStrictEqual(r.toasts, ['vfav_no_line']);
});

test('收藏视频本身：开关态来自 App 回包；失败如实提示且状态不变', async () => {
  const r = loadRuntime(appState(new Set()));
  assert.strictEqual(await r.vf.toggleVideo(), true);
  assert.strictEqual(r.vf.isVideoFavorited(), true);
  assert.strictEqual(r.toasts.pop(), 'vfav_video_added');

  const old = loadRuntime(() => ({ ok: false, status: 404, data: null }));
  assert.strictEqual(await old.vf.toggleVideo(), null);
  assert.strictEqual(old.vf.isVideoFavorited(), false);
  assert.deepStrictEqual(old.toasts, ['✗ favorite_failed_old_app'], '旧 App 没这个端点：让用户更新 Fushi');
});

test('有 <video> 的页面自动拉一次状态；换视频（地址变）清空重拉；拉失败 30 秒内不重试', async () => {
  const store = new Set(['83000|夏が来た', 'video']);
  const r = loadRuntime(appState(store));
  r.tick();
  await flush();
  assert.deepStrictEqual(plain(r.sent.filter((m) => m.op === 'state')), [
    { type: 'videoFavorite', op: 'state', url: 'https://www.youtube.com/watch?v=abc&t=5' },
  ]);
  assert.strictEqual(r.vf.isVideoFavorited(), true);
  assert.deepStrictEqual(plain(r.vf.snapshot().keys), ['83000|夏が来た']);
  r.tick();
  await flush();
  assert.strictEqual(r.sent.filter((m) => m.op === 'state').length, 1, '已加载不重复拉');

  r.location.href = 'https://www.youtube.com/watch?v=other';
  assert.strictEqual(r.vf.isVideoFavorited(), false, '换视频后旧状态不串');
  r.tick();
  await flush();
  assert.strictEqual(r.sent.filter((m) => m.op === 'state').length, 2);

  const off = loadRuntime(() => null);
  off.tick(); await flush();
  off.tick(); await flush();
  assert.strictEqual(off.sent.length, 1, 'App 没开：不每 2 秒打一次');
});

test('侧边栏 tab 消息：切换某一句 / 视频，回最新快照（侧边栏据此画 ☆/★）', async () => {
  const r = loadRuntime(appState(new Set()));
  const res = await r.tab({ type: 'fushiVideoFavoriteToggleCue', cue: { text: 'ただいま', startMs: 1000, endMs: 2000 } });
  assert.strictEqual(res.ok, true);
  assert.deepStrictEqual(plain(res.favorites.keys), ['1000|ただいま']);
  const v = await r.tab({ type: 'fushiVideoFavoriteToggleVideo' });
  assert.strictEqual(v.favorites.video, true);
  assert.strictEqual(await r.tab({ type: 'somethingElse' }), undefined, '别的消息不接');
});

// ── background.js：转发到 App ────────────────────────────────────────────────

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
      posts.push({ url: String(url), headers: (init && init.headers) || {}, body: init && init.body ? JSON.parse(init.body) : null });
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
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'), sandbox, { filename: 'background.js' });
  return {
    posts,
    send(msg) {
      const responses = [];
      for (const fn of messageListeners) fn(msg, {}, (r) => responses.push(r));
      return responses;
    },
  };
}

test('background videoFavorite：POST /api/extension/video-favorite 带鉴权与契约字段，回 {ok,status,data}', async () => {
  const data = { favorite: true, video: false, sentences: [{ text: '夏', startMs: 1200 }] };
  const bg = loadBackground({ ok: true, status: 200, json: () => Promise.resolve(data) });
  const responses = bg.send({
    type: 'videoFavorite', op: 'toggle', kind: 'sentence', url: 'https://youtu.be/abc',
    title: 't', text: '夏', startMs: 1200, endMs: 1800, extra: 'drop',
  });
  await flush();
  const hits = bg.posts.filter((p) => p.url.endsWith('/api/extension/video-favorite'));
  assert.strictEqual(hits.length, 1);
  assert.deepStrictEqual(hits[0].body, {
    op: 'toggle', kind: 'sentence', url: 'https://youtu.be/abc', title: 't', text: '夏', startMs: 1200, endMs: 1800,
  });
  assert.ok(/^Basic /.test(String(hits[0].headers.Authorization || '')));
  const reply = responses.find((r) => r && typeof r === 'object' && 'data' in r);
  assert.ok(reply, '回了 sendResponse');
  assert.strictEqual(reply.ok, true);
  assert.deepStrictEqual(plain(reply.data), data);
});

test('background videoFavorite：旧 App（404）→ ok:false + status 404', async () => {
  const bg = loadBackground({ ok: false, status: 404, json: () => Promise.resolve(null) });
  const responses = bg.send({ type: 'videoFavorite', op: 'state', url: 'https://a.jp/v' });
  await flush();
  const reply = responses.find((r) => r && typeof r === 'object' && 'status' in r);
  assert.strictEqual(reply.ok, false);
  assert.strictEqual(reply.status, 404);
});

// ── 入口：快捷键 / 字幕执行端 / 设置页 / 侧边栏 / 清单 ─────────────────────────

test('快捷键：Ctrl+Shift+F = favorite-cue（需有字幕轨；可在设置页改键 / 关掉）', () => {
  assert.strictEqual(VS.DEFAULT_COMBOS['favorite-cue'], 'Ctrl+Shift+KeyF');
  const ev = { code: 'KeyF', ctrl: true, shift: true };
  assert.deepStrictEqual(plain(VS.decide(ev, { enabled: true, hasVideo: true, hasTrack: true })), { action: 'favorite-cue' });
  assert.strictEqual(VS.decide(ev, { enabled: true, hasVideo: true, hasTrack: false }), null, '没字幕轨放行给站点');
  assert.strictEqual(VS.decide(ev, { enabled: true, hasVideo: true, hasTrack: true, bindings: { 'favorite-cue': false } }), null);
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  assert.match(html, /data-shortcut-action="favorite-cue"/);
  assert.match(html, /id="videoShortcutFavoriteCue"/);
  const opts = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  assert.match(opts, /videoShortcutFavoriteCue: true/);
});

function loadPanel(favoriteCalls) {
  const listeners = [];
  const video = { currentTime: 1.5, getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 450 }) };
  const el = () => ({
    style: {}, children: [], setAttribute() {}, getAttribute: () => null, appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}, removeChild() {}, classList: { add() {}, remove() {}, toggle() {} },
  });
  const html = el();
  const windowObj = {
    fushiT: (k) => k,
    fushiToast() {},
    fushiEpisodeCues: { 'example.com/v|ja': [{ startMs: 1000, endMs: 2000, text: 'あ' }, { startMs: 3000, endMs: 4000, text: 'い' }] },
    fushiVideoFavorite: {
      toggleCurrentCue() { favoriteCalls.push('current'); return true; },
      snapshot() { return { href: 'x', loaded: true, video: true, keys: ['1000|あ'], rev: 3 }; },
    },
    addEventListener() {},
  };
  const sandbox = {
    window: windowObj,
    document: {
      documentElement: html, body: html, fullscreenElement: null,
      addEventListener() {}, getElementById: () => null,
      querySelector: (s) => (s === 'video' ? video : null), querySelectorAll: () => [],
      createElement: el,
    },
    location: { hostname: 'example.com', pathname: '/v' },
    setInterval: () => 1, clearInterval() {},
    chrome: {
      storage: {
        local: { get: (_k, cb) => { if (cb) cb({ netflixSubtitlePanel: true }); }, set() {} },
        onChanged: { addListener() {} },
      },
      runtime: { lastError: null, sendMessage() {}, onMessage: { addListener: (fn) => listeners.push(fn) } },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'subtitle-adapters.js'), 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8'), sandbox);
  return {
    windowObj,
    send(msg) {
      let out;
      for (const fn of listeners) { fn(msg, {}, (v) => { out = v; }); if (out !== undefined) break; }
      return out;
    },
  };
}

test('subtitle-panel：当前句（已应用偏移）+ favorite-cue 快捷键转给执行端 + 侧边栏状态带收藏快照', () => {
  const calls = [];
  const p = loadPanel(calls);
  assert.deepStrictEqual(plain(p.windowObj.fushiSubtitleCurrentCue()), { text: 'あ', startMs: 1000, endMs: 2000 });
  assert.strictEqual(p.windowObj.fushiSubtitleShortcut('favorite-cue'), true);
  assert.deepStrictEqual(calls, ['current']);
  const state = p.send({ type: 'fushiSubtitleSidePanelState', includeCues: false });
  assert.deepStrictEqual(plain(state.favorites), { href: 'x', loaded: true, video: true, keys: ['1000|あ'], rev: 3 });
});

test('侧边栏：每行 ☆/★ 与顶栏「收藏这个视频」经 tab 消息转发；页面装了同一份 cueKey', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  assert.match(src, /type: 'fushiVideoFavoriteToggleCue'/);
  assert.match(src, /type: 'fushiVideoFavoriteToggleVideo'/);
  assert.match(src, /row\.appendChild\(cueFavoriteButton\(cue\)\)/);
  const html = fs.readFileSync(path.join(__dirname, 'side-panel.html'), 'utf8');
  assert.match(html, /<button id="fav-video"[^>]*data-i18n-title="sp_fav_video_title"/);
  assert.ok(html.indexOf('video-favorite.js') < html.indexOf('side-panel.js'), 'cueKey 先于侧边栏脚本装入');
});

test('manifest：video-favorite.js 在 subtitle-panel.js 之后、快捷键 / 播放器菜单之前；侧边栏可取', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  const at = js.indexOf('video-favorite.js');
  assert.ok(at > js.indexOf('subtitle-panel.js'));
  assert.ok(at < js.indexOf('video-shortcuts.js'));
  assert.ok(at < js.indexOf('player-controls.js'));
  assert.ok(manifest.web_accessible_resources.some((r) => r.resources.includes('video-favorite.js')));
});
