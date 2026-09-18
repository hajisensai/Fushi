// 用户 2026-09-18：
//  ① 「扩展支持主题配置、统一颜色」——theme.js 是明暗唯一决议点（extensionTheme：auto 跟系统 /
//     light / dark），扩展页面写根 data-theme，页内浮层按 resolve(fallback)；显式明暗随查词请求
//     colorScheme 提示交给 app 生成同明暗的 --md-*；调色板只在 theme.css，各页 CSS 只别名。
//  ② 「沉浸时间先支持视频」——study-tracker.js 把正片 <video> 的位置样本每秒交给 background，
//     background 原样 POST /api/extension/study；app 侧 VideoWatchTracker 按首次覆盖记账。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const THEME_SRC = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');
const STUDY_SRC = fs.readFileSync(path.join(__dirname, 'study-tracker.js'), 'utf8');
const BG_SRC = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');

function storageMock(stored) {
  const changeListeners = [];
  return {
    local: {
      get: (keys, cb) => {
        const out = {};
        for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
        if (cb) { cb(out); return undefined; }
        return Promise.resolve(out);
      },
      set: (patch) => {
        const changes = {};
        for (const k of Object.keys(patch)) { changes[k] = { newValue: patch[k] }; stored[k] = patch[k]; }
        for (const fn of changeListeners) fn(changes, 'local');
        return Promise.resolve();
      },
    },
    onChanged: { addListener: (fn) => changeListeners.push(fn) },
  };
}

// ───────── ① 主题 ─────────

function loadTheme(opts) {
  opts = opts || {};
  const stored = Object.assign({}, opts.stored);
  const rootAttrs = {};
  const sandbox = {
    console,
    location: { protocol: opts.protocol || 'https:' },
    matchMedia: () => ({ matches: !!opts.systemDark, addEventListener() {} }),
    chrome: { storage: storageMock(stored) },
    document: { documentElement: { setAttribute: (k, v) => { rootAttrs[k] = v; }, removeAttribute: (k) => { delete rootAttrs[k]; } } },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(THEME_SRC, sandbox, { filename: 'theme.js' });
  return { theme: sandbox.fushiTheme, rootAttrs, set: (p) => sandbox.chrome.storage.local.set(p) };
}

test('auto：跟系统；有 fallback（app 的 --fushi-color-scheme）时优先 fallback；显式值压过一切', () => {
  const h = loadTheme({ systemDark: true });
  assert.strictEqual(h.theme.resolve(), 'dark');
  assert.strictEqual(h.theme.resolve('light'), 'light', 'auto 下查词弹窗跟 app');
  assert.strictEqual(h.theme.explicit(), null);
  h.set({ extensionTheme: 'light' });
  assert.strictEqual(h.theme.resolve('dark'), 'light', '显式浅色压过 app 的深色');
  assert.strictEqual(h.theme.explicit(), 'light');
  h.set({ extensionTheme: 'garbage' });
  assert.strictEqual(h.theme.preference, 'auto', '坏值当 auto');
});

test('扩展页面自动把显式值写成根 data-theme；auto 摘掉属性交给 prefers-color-scheme', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionTheme: 'dark' } });
  assert.strictEqual(h.rootAttrs['data-theme'], 'dark');
  h.set({ extensionTheme: 'auto' });
  assert.strictEqual(h.rootAttrs['data-theme'], undefined);
  const host = loadTheme({ protocol: 'https:', stored: { extensionTheme: 'dark' } });
  assert.strictEqual(host.rootAttrs['data-theme'], undefined, '宿主网页的 <html> 绝不能被改');
});

test('调色板单一真相源：options.css / side-panel.css 只别名 --fushi-*，不再各自定义颜色', () => {
  const themeCss = fs.readFileSync(path.join(__dirname, 'theme.css'), 'utf8');
  assert.match(themeCss, /:root\[data-theme="dark"\]/);
  assert.match(themeCss, /@media \(prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)/);
  for (const f of ['options.css', 'side-panel.css']) {
    const css = fs.readFileSync(path.join(__dirname, f), 'utf8');
    assert.doesNotMatch(css, /@media \(prefers-color-scheme: dark\)/, f + ' 不得再自带一套深色值');
    const root = /:root\s*\{([\s\S]*?)\}/.exec(css)[1];
    for (const line of root.split('\n')) {
      const m = /^\s*(--[a-z-]+):\s*(.+);/.exec(line);
      if (!m || m[1] === '--radius' || m[1] === '--ease' || m[1] === '--subtitle-scale') continue;
      assert.match(m[2], /^var\(--fushi-/, f + ' 的 ' + m[1] + ' 必须别名到 theme.css');
    }
  }
  // 页内浮层：生成的 content.css 里 theme.css 重根到 #fushi-* 宿主，绝不落到宿主页 :root。
  const content = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.match(content, /:where\(#fushi-drawer, #fushi-subtitle-overlay[^)]*\)\s*\{[^}]*--fushi-bg/);
  assert.doesNotMatch(content, /^:root/m, 'content.css 不得含裸 :root 规则');
  for (const page of ['options.html', 'side-panel.html', 'vendor/action-popup.html', 'nested-popup.html']) {
    assert.match(fs.readFileSync(path.join(__dirname, page), 'utf8'), /theme\.css/, page + ' 要引入 theme.css');
  }
});

test('background：显式明暗随查词请求带 colorScheme；auto 不带', async () => {
  const stored = { extensionTheme: 'dark' };
  const fetches = [];
  const sandbox = {
    console, URL, btoa: (s) => Buffer.from(s).toString('base64'),
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval,
    performance: { now: () => 1, timeOrigin: 0 },
    AbortSignal: { timeout: () => null },
    fetch: (url, init) => {
      fetches.push({ url, body: init && init.body ? JSON.parse(init.body) : null });
      return Promise.resolve({ ok: true, status: 200, headers: { get: () => null }, text: () => Promise.resolve('{"popupJson":"[]"}') });
    },
    importScripts() {},
    chrome: {
      storage: storageMock(stored),
      runtime: { onMessage: { addListener: (fn) => { sandbox._onMessage = fn; } }, onStartup: { addListener() {} }, onInstalled: { addListener() {} }, getURL: (r) => r, id: 'x' },
      alarms: { create() {}, onAlarm: { addListener() {} } },
      action: { setBadgeText() {}, setBadgeBackgroundColor() {}, setTitle() {}, onClicked: { addListener() {} } },
      tabs: { onUpdated: { addListener() {} }, onRemoved: { addListener() {} }, query: () => Promise.resolve([]) },
      webNavigation: { onCompleted: { addListener() {} } },
      sidePanel: { setPanelBehavior: () => Promise.resolve(), setOptions() {} },
      offscreen: { hasDocument: () => Promise.resolve(false) },
      cookies: { getAll: () => Promise.resolve([]) },
    },
  };
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(BG_SRC, sandbox, { filename: 'background.js' });
  const ask = (msg) => new Promise((resolve) => { sandbox._onMessage(msg, { tab: { id: 1 } }, resolve); });
  await ask({ type: 'lookup', term: '世界' });
  const lookup = fetches.find((f) => /\/api\/lookup\/dictionary$/.test(f.url));
  assert.strictEqual(lookup.body.colorScheme, 'dark', '显式深色要作为 colorScheme 提示交给 app');
  fetches.length = 0;
  await sandbox.chrome.storage.local.set({ extensionTheme: 'auto' });
  await ask({ type: 'lookup', term: '世界' });
  const lookup2 = fetches.find((f) => /\/api\/lookup\/dictionary$/.test(f.url));
  assert.ok(!('colorScheme' in lookup2.body), 'auto 不带提示（app 按自己当前明暗）');
  // ② 样本转发 + app 语言记录
  const r = await ask({ type: 'studySample', sample: { mediaKind: 'video', mediaKey: 'web:yt-a', positionMs: 1000, playing: true, speed: 1 } });
  const study = fetches.find((f) => /\/api\/extension\/study$/.test(f.url));
  assert.ok(study && study.body.mediaKey === 'web:yt-a', '样本必须原样 POST /api/extension/study');
  assert.strictEqual(r.ok, true);
});

test('background：app 在 status / 查词响应里下发的语言写进 storage.appLocale（i18n.js 据此跟随）', () => {
  assert.match(BG_SRC, /rememberAppLocale\(data && data\.locale\)/);
  assert.match(BG_SRC, /rememberAppLocale\(data && data\.appLocale\)/);
  assert.match(BG_SRC, /chrome\.storage\.local\.set\(\{ appLocale: tag \}\)/);
});

// ───────── ② 视频沉浸时间 ─────────

function loadStudy(opts) {
  opts = opts || {};
  const stored = Object.assign({ studyTrackVideo: true }, opts.stored);
  const docListeners = Object.create(null);
  const sent = [];
  const intervals = [];
  const videos = [];
  const sandbox = {
    console,
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval: (id) => { if (intervals[id - 1]) intervals[id - 1].fn = null; },
    location: { hostname: 'www.youtube.com', pathname: '/watch', search: '?v=abc' },
    chrome: {
      storage: storageMock(stored),
      runtime: { sendMessage: (msg, cb) => { sent.push(msg); if (cb) cb({ ok: true }); }, lastError: null },
    },
    document: {
      title: '無職転生 第1話 - YouTube',
      addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
      querySelectorAll: () => videos,
    },
  };
  sandbox.window = sandbox;
  sandbox.window.fushiVideoKey = () => 'yt-abc';
  vm.createContext(sandbox);
  vm.runInContext(STUDY_SRC, sandbox, { filename: 'study-tracker.js' });
  const makeVideo = (over) => {
    const listeners = Object.create(null);
    const v = Object.assign({
      tagName: 'VIDEO', isConnected: true, paused: false, ended: false, currentTime: 12.3, duration: 1400, playbackRate: 1,
      getBoundingClientRect: () => ({ width: 1280, height: 720 }),
      addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); },
      removeEventListener: (t, fn) => { const l = listeners[t] || []; const i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); },
      fire: (t) => { for (const fn of (listeners[t] || []).slice()) fn({ target: v }); },
      listeners,
    }, over);
    return v;
  };
  const dispatch = (t, target) => { for (const fn of docListeners[t] || []) fn({ target }); };
  const tick = () => { for (const it of intervals) if (it.fn && it.ms === 1000) it.fn(); };
  return { sandbox, sent, makeVideo, dispatch, tick, docListeners, samples: () => sent.filter((m) => m.type === 'studySample').map((m) => m.sample) };
}

test('正片开播：立刻发一个样本，之后每秒一个；mediaKey 带 web: 前缀、身份与字幕轨同一把 key', () => {
  const h = loadStudy();
  const v = h.makeVideo();
  h.dispatch('play', v);
  assert.strictEqual(h.samples().length, 1);
  const s = h.samples()[0];
  assert.strictEqual(s.mediaKind, 'video');
  assert.strictEqual(s.mediaKey, 'web:yt-abc');
  assert.strictEqual(s.title, '無職転生 第1話 - YouTube');
  assert.strictEqual(s.positionMs, 12300);
  assert.strictEqual(s.durationMs, 1400000);
  assert.strictEqual(s.playing, true);
  assert.strictEqual(s.speed, 1);
  assert.strictEqual(s.ended, false);
  v.currentTime = 13.3;
  h.tick();
  assert.strictEqual(h.samples().length, 2);
  assert.strictEqual(h.samples()[1].positionMs, 13300);
});

test('悬停预览 / 小窗 / 短片不追踪；直播（duration=Infinity）追踪且 durationMs=null', () => {
  const h = loadStudy();
  h.dispatch('play', h.makeVideo({ duration: 12 }));
  assert.strictEqual(h.samples().length, 0, '30s 以下的短片不算看片');
  h.dispatch('play', h.makeVideo({ getBoundingClientRect: () => ({ width: 160, height: 90 }) }));
  assert.strictEqual(h.samples().length, 0, '小窗预览不算');
  h.dispatch('play', h.makeVideo({ duration: Infinity }));
  assert.strictEqual(h.samples().length, 1);
  assert.strictEqual(h.samples()[0].durationMs, null);
});

test('暂停发 playing=false 且停心跳；ended / 页面卸载发 ended=true；关掉设置即停', () => {
  const h = loadStudy();
  const v = h.makeVideo();
  h.dispatch('play', v);
  v.paused = true;
  v.fire('pause');
  assert.strictEqual(h.samples().at(-1).playing, false);
  h.tick();
  assert.strictEqual(h.samples().length, 2, '暂停态不刷心跳');
  v.paused = false;
  v.fire('seeked');
  assert.strictEqual(h.samples().length, 3, 'seek 后立刻补一个样本');
  h.dispatch('pagehide');
  assert.strictEqual(h.samples().at(-1).ended, true, '卸载要给 app 一个停表信号');
  h.tick();
  assert.strictEqual(h.samples().length, 4, '卸载后不再发');
  const h2 = loadStudy();
  const v2 = h2.makeVideo();
  h2.dispatch('play', v2);
  h2.sandbox.chrome.storage.local.set({ studyTrackVideo: false });
  assert.strictEqual(h2.samples().at(-1).ended, true, '关掉设置 = 立刻停表');
  h2.dispatch('play', h2.makeVideo());
  assert.strictEqual(h2.samples().length, 2, '关掉后不再追踪');
});

test('同页换视频（key 变）：先给旧视频 ended，再以新 key 开始', () => {
  const h = loadStudy();
  const v = h.makeVideo();
  h.dispatch('play', v);
  h.sandbox.window.fushiVideoKey = () => 'yt-next';
  h.tick();
  const s = h.samples();
  assert.strictEqual(s[1].mediaKey, 'web:yt-abc');
  assert.strictEqual(s[1].ended, true);
  assert.strictEqual(s[2].mediaKey, 'web:yt-next');
  assert.strictEqual(s[2].ended, false);
});

test('manifest 装入顺序：locales/en.js → i18n.js → theme.js 在 content.js 之前，study-tracker.js 在最后', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  const idx = (f) => js.indexOf(f);
  assert.ok(idx('locales/en.js') >= 0 && idx('locales/en.js') < idx('i18n.js'));
  assert.ok(idx('i18n.js') < idx('theme.js') && idx('theme.js') < idx('content.js'));
  assert.ok(idx('study-tracker.js') > idx('subtitle-providers.js'), 'study-tracker 依赖 fushiVideoKey');
  const war = manifest.web_accessible_resources.flatMap((r) => r.resources);
  assert.ok(war.includes('locales/*.json'), '各语言字典要能被 content script fetch');
  assert.ok(war.includes('theme.css') && war.includes('i18n.js'), '侧栏被抽屉 iframe 嵌入时要能取到主题/文案脚本');
});
