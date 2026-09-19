// 视频上字幕的外观设置（用户 2026-09-19：「浏览器字幕字体加入字体管理，比如大小、字重、间距、
// 行高、字体、对齐还有背景管理」）。
//  ① subtitle-style.js：normalize 夹值/回默认、字体串消毒；toCssVars 只给「与默认不同」的变量，
//     默认项为 null（覆盖层 removeProperty 交还 CSS）；底板颜色+不透明度合成 rgba。
//  ② content-css-overlay.css 的 #fushi-subtitle-overlay 每一项外观都读 --fushi-sub-* 且给默认值；
//     options.css 的预览节点默认值与之逐项一致（否则设置页预览和视频上不一样）。
//  ③ subtitle-panel.js 首读 + storage.onChanged 都把 subtitleStyle 落到覆盖层根；同一份设置在
//     200ms tick 里不重复写；删键回默认（全部 removeProperty）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT();

const STYLE_SRC = fs.readFileSync(path.join(__dirname, 'subtitle-style.js'), 'utf8');

function loadStyle() {
  const sandbox = { console };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(STYLE_SRC, sandbox, { filename: 'subtitle-style.js' });
  return sandbox.fushiSubtitleStyle;
}

// ───────── ① 纯函数 ─────────

test('normalize：缺省全默认；越界夹住；字重取整到百位；坏枚举回默认；字体串剥掉分号花括号', () => {
  const S = loadStyle();
  assert.deepEqual(S.normalize(undefined), S.DEFAULTS);
  assert.strictEqual(S.isDefault(null), true);
  const n = S.normalize({
    fontScale: 999, fontWeight: 650, letterSpacing: -40, lineHeight: '180', textAlign: 'justify',
    textColor: 'FFF', shadow: 'blurry', backgroundColor: '#12ab', backgroundOpacity: 101, borderRadius: -3,
    padding: 'x', fontFamily: '"Noto Sans JP"; } body { display:none',
  });
  assert.strictEqual(n.fontScale, 300);
  assert.strictEqual(n.fontWeight, 700);
  assert.strictEqual(n.letterSpacing, -5);
  assert.strictEqual(n.lineHeight, 180);
  assert.strictEqual(n.textAlign, 'center');
  assert.strictEqual(n.textColor, '#ffffff');
  assert.strictEqual(n.shadow, 'soft');
  assert.strictEqual(n.backgroundColor, '', '坏 hex 当没设');
  assert.strictEqual(n.backgroundOpacity, 100);
  assert.strictEqual(n.borderRadius, 0);
  assert.strictEqual(n.padding, 100);
  assert.strictEqual(n.fontFamily, '"Noto Sans JP" body displaynone');
  assert.doesNotMatch(n.fontFamily, /[;{}:]/);
});

test('toCssVars：默认设置全 null；改过的项给出变量；底板颜色 + 不透明度合成 rgba', () => {
  const S = loadStyle();
  const def = S.toCssVars(null);
  for (const k of Object.keys(def)) assert.strictEqual(def[k], null, k + ' 默认应交还 CSS');
  assert.deepEqual(Object.keys(def).sort(), [
    '--fushi-sub-align', '--fushi-sub-bg', '--fushi-sub-color', '--fushi-sub-family', '--fushi-sub-line-height',
    '--fushi-sub-padding', '--fushi-sub-radius', '--fushi-sub-scale', '--fushi-sub-shadow', '--fushi-sub-spacing',
    '--fushi-sub-weight',
  ]);
  const v = S.toCssVars({
    fontFamily: 'serif', fontScale: 150, fontWeight: 400, letterSpacing: 10, lineHeight: 200, textAlign: 'left',
    textColor: '#ffee00', shadow: 'none', backgroundColor: '#112233', backgroundOpacity: 50, borderRadius: 0, padding: 50,
  });
  assert.strictEqual(v['--fushi-sub-family'], 'serif');
  assert.strictEqual(v['--fushi-sub-scale'], '1.5');
  assert.strictEqual(v['--fushi-sub-weight'], '400');
  assert.strictEqual(v['--fushi-sub-spacing'], '0.1em');
  assert.strictEqual(v['--fushi-sub-line-height'], '2');
  assert.strictEqual(v['--fushi-sub-align'], 'left');
  assert.strictEqual(v['--fushi-sub-color'], '#ffee00');
  assert.strictEqual(v['--fushi-sub-shadow'], 'none');
  assert.strictEqual(v['--fushi-sub-bg'], 'rgba(17, 34, 51, 0.5)');
  assert.strictEqual(v['--fushi-sub-radius'], '0px');
  assert.strictEqual(v['--fushi-sub-padding'], '3.0px 6.0px 3.5px');
  // 只改不透明度：颜色用主题 scrim 的 rgb（#0c0f0d），不透明度用用户的。
  assert.strictEqual(S.toCssVars({ backgroundOpacity: 20 })['--fushi-sub-bg'], 'rgba(12, 15, 13, 0.2)');
  // 只改颜色：不透明度用默认 72%。
  assert.strictEqual(S.toCssVars({ backgroundColor: '#000000' })['--fushi-sub-bg'], 'rgba(0, 0, 0, 0.72)');
  // strong 描边是多层 text-shadow。
  assert.ok(S.toCssVars({ shadow: 'strong' })['--fushi-sub-shadow'].split(',').length >= 4);
});

test('applyTo：非默认 setProperty、默认 removeProperty；坏元素不抛', () => {
  const S = loadStyle();
  const set = {}, removed = [];
  const el = { style: { setProperty: (k, v) => { set[k] = v; }, removeProperty: (k) => removed.push(k) } };
  S.applyTo(el, { fontScale: 120 });
  assert.strictEqual(set['--fushi-sub-scale'], '1.2');
  assert.ok(removed.includes('--fushi-sub-weight') && removed.includes('--fushi-sub-bg'));
  assert.doesNotThrow(() => S.applyTo(null, {}));
});

// 用户 2026-09-20：「字体不要手填而是下拉框并且可以下载字体」——下拉两组：本机字体栈
// （FONT_SUGGESTIONS）+ Fushi 字体库（app /api/extension/fonts）；库字体经 @font-face 挂进页面。
test('字体库辅助：栈标签取前两个 family；库条目值带引号且剥引号反斜杠；命中判据与存值同形', () => {
  const S = loadStyle();
  assert.strictEqual(S.fontStackLabel('"Hiragino Sans", "Yu Gothic UI", sans-serif'), 'Hiragino Sans / Yu Gothic UI');
  assert.strictEqual(S.fontStackLabel('monospace'), 'monospace');
  assert.strictEqual(S.fontFamilyValueOf('Klee "One" ' + String.fromCharCode(92) + 'x'), '"Klee One x"');
  assert.strictEqual(S.fontFamilyValueOf('   '), '');
  assert.strictEqual(S.matchesFushiFont('"Klee One"', 'Klee One'), true);
  assert.strictEqual(S.matchesFushiFont('Klee One', 'Klee One'), false, '未加引号的手填值不当作库条目');
  assert.strictEqual(S.matchesFushiFont('"Klee One"', ''), false);
});

test('fontFaceCss：每条库字体一条 @font-face（src 为 app 文件端点、按扩展名给 format）；非 http(s)/含引号空白的 url 与空 family 一律丢弃', () => {
  const S = loadStyle();
  const css = S.fontFaceCss([
    { family: 'Klee One', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=abc', ext: 'ttf' },
    { family: 'Noto Sans JP', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_2&token=abc', ext: 'woff2' },
    { family: 'Bad', url: 'javascript:alert(1)', ext: 'ttf' },
    { family: 'Bad2', url: 'http://127.0.0.1/a") } body { display:none', ext: 'ttf' },
    { family: '', url: 'http://127.0.0.1/x', ext: 'ttf' },
    { family: 'NoFmt', url: 'http://127.0.0.1/y', ext: 'bin' },
  ]);
  const lines = css.split('\n');
  assert.strictEqual(lines.length, 3);
  assert.strictEqual(lines[0],
    '@font-face{font-family:"Klee One";src:url("http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=abc") format("truetype");font-display:swap;}');
  assert.match(lines[1], /format\("woff2"\)/);
  assert.strictEqual(lines[2], '@font-face{font-family:"NoFmt";src:url("http://127.0.0.1/y");font-display:swap;}');
  assert.doesNotMatch(css, /javascript:|display:none/);
  assert.strictEqual(S.fontFaceCss(null), '');
});

// ───────── ② CSS 契约 ─────────

function subVarDefaults(block) {
  const out = {};
  for (const m of block.matchAll(/(--fushi-sub-[a-z-]+):\s*([^;]+);/g)) out[m[1]] = m[2].trim();
  return out;
}

test('覆盖层 CSS：每项外观读 --fushi-sub-* 并有默认值；options.css 预览默认值逐项一致；生成的 content.css 已含', () => {
  const overlay = fs.readFileSync(path.join(__dirname, 'scripts', 'content-css-overlay.css'), 'utf8');
  const block = /#fushi-subtitle-overlay \{([\s\S]*?)\n\}/.exec(overlay)[1];
  const defaults = subVarDefaults(block);
  const S = loadStyle();
  assert.deepEqual(Object.keys(defaults).sort(), Object.keys(S.toCssVars(null)).sort(), 'CSS 默认变量集 = toCssVars 输出集');
  for (const [prop, v] of [
    ['font-family', 'var(--fushi-sub-family)'], ['font-weight', 'var(--fushi-sub-weight)'],
    ['line-height', 'var(--fushi-sub-line-height)'], ['letter-spacing', 'var(--fushi-sub-spacing)'],
    ['text-align', 'var(--fushi-sub-align)'], ['text-shadow', 'var(--fushi-sub-shadow)'],
    ['color', 'var(--fushi-sub-color)'], ['background', 'var(--fushi-sub-bg)'],
    ['border-radius', 'var(--fushi-sub-radius)'], ['padding', 'var(--fushi-sub-padding)'],
  ]) {
    assert.ok(block.includes('\n    ' + prop + ': ' + v + ';'), prop + ' 应读 ' + v);
  }
  assert.match(block, /font-size: calc\(clamp\(18px, 2\.2vw, 32px\) \* var\(--fushi-sub-scale\)\);/);
  assert.match(overlay, /#fushi-subtitle-overlay:has\(ruby\) \{\s*line-height: max\(2, var\(--fushi-sub-line-height\)\);/);
  // 默认值与旧观感一字不差（老用户零变化）。
  assert.strictEqual(defaults['--fushi-sub-family'], '"Hiragino Sans", "Yu Gothic UI", sans-serif');
  assert.strictEqual(defaults['--fushi-sub-weight'], '600');
  assert.strictEqual(defaults['--fushi-sub-line-height'], '1.45');
  assert.strictEqual(defaults['--fushi-sub-spacing'], '0.01em');
  assert.strictEqual(defaults['--fushi-sub-shadow'], '0 1px 3px #000, 1px 0 2px #000, -1px 0 2px #000');
  assert.strictEqual(defaults['--fushi-sub-padding'], '6px 12px 7px');
  // 设置页预览与覆盖层同一组默认值。
  const options = fs.readFileSync(path.join(__dirname, 'options.css'), 'utf8');
  const previewBlock = /\.subtitle-preview-cue \{([\s\S]*?)\n\}/.exec(options)[1];
  assert.deepEqual(subVarDefaults(previewBlock), defaults, 'options.css 预览默认值必须与覆盖层一致');
  const content = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.match(content, /#fushi-subtitle-overlay \{[\s\S]*?--fushi-sub-scale: 1;/);
});

// ───────── ③ subtitle-panel.js 接线 ─────────

const CONTENT = path.join(__dirname, 'content.js');
const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');

function makeEl(tag) {
  const listeners = Object.create(null);
  const attrs = Object.create(null);
  const props = {};
  const el = {
    tagName: (tag || 'div').toUpperCase(), _id: '', className: '', textContent: '',
    style: {
      cssText: '', props, writes: 0,
      setProperty(k, v) { props[k] = v; this.writes++; },
      removeProperty(k) { delete props[k]; this.writes++; },
      getPropertyValue: (k) => props[k] || '',
    },
    dataset: {}, children: [], parentNode: null, offsetHeight: 40,
    setAttribute(k, v) { if (k === 'id') el._id = v; attrs[k] = String(v); },
    removeAttribute(k) { delete attrs[k]; },
    getAttribute(k) { return k in attrs ? attrs[k] : null; },
    hasAttribute(k) { return k in attrs; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    setPointerCapture() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) { const i = el.children.indexOf(child); if (i >= 0) el.children.splice(i, 1); child.parentNode = null; return child; },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findById(root, id) {
  if (root._id === id) return root;
  for (const c of root.children) { const hit = findById(c, id); if (hit) return hit; }
  return null;
}

function loadWorld(prefs) {
  const head = makeEl('head'), body = makeEl('body'), html = makeEl('html');
  html.appendChild(head); html.appendChild(body);
  const stored = Object.assign({ netflixSubtitlePanel: true, subtitleOverlayAllTracks: true }, prefs || {});
  const changeListeners = [];
  const intervals = [];
  const rect = { x: 100, y: 50, left: 100, top: 50, right: 1380, bottom: 770, width: 1280, height: 720 };
  const video = { currentTime: 0, paused: false, playbackRate: 1, textTracks: [], getBoundingClientRect: () => rect };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {}, requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'www.youtube.com', href: 'https://www.youtube.com/watch?v=abc123', pathname: '/watch', search: '?v=abc123', protocol: 'https:' },
  };
  sandbox.document = {
    documentElement: html, head, body, fullscreenElement: null,
    addEventListener() {},
    getElementById: (id) => findById(html, id),
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: { id: 'test-ext-id', getURL: (rel) => 'chrome-extension://test-ext-id/' + rel, lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
    storage: {
      local: {
        get: (keys, cb) => {
          const out = {};
          for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
          if (cb) { cb(out); return undefined; }
          return { then: (fn) => { fn(out); return { catch() {} }; }, catch() {} };
        },
        set: (patch, cb) => {
          const changes = {};
          for (const k of Object.keys(patch)) { changes[k] = { oldValue: stored[k], newValue: patch[k] }; stored[k] = patch[k]; }
          for (const fn of changeListeners) fn(changes, 'local');
          if (cb) cb();
          return Promise.resolve();
        },
        remove: (keys) => {
          const changes = {};
          for (const k of [].concat(keys)) { changes[k] = { oldValue: stored[k] }; delete stored[k]; }
          for (const fn of changeListeners) fn(changes, 'local');
          return Promise.resolve();
        },
      },
      onChanged: { addListener: (fn) => changeListeners.push(fn) },
    },
  };
  sandbox.window = {
    fushiT: FUSHI_T,
    addEventListener() {}, removeEventListener() {}, postMessage() {},
    innerWidth: 1600, innerHeight: 900,
    matchMedia: () => ({ matches: false }),
    getSelection: () => ({ removeAllRanges() {} }),
    fushiSelection: { getCharacterAtPoint: () => null, selectFromPosition: () => '', clearSelection() {} },
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  sandbox.globalThis = sandbox;
  sandbox.navigator = { clipboard: { writeText: () => Promise.resolve() } };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(STYLE_SRC, sandbox, { filename: 'subtitle-style.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  vm.runInContext(fs.readFileSync(PANEL, 'utf8'), sandbox, { filename: 'subtitle-panel.js' });
  sandbox.window.fushiLookupAtPoint = () => {};
  const tick = () => { for (const it of intervals) if (it.ms === 200) it.fn(); };
  const overlayEl = () => findById(html, 'fushi-subtitle-overlay');
  const setTrack = (lang, cues) => {
    const key = 'yt-abc123|' + lang;
    sandbox.window.fushiEpisodeCues[key] = cues;
    sandbox.window.fushiSubtitlePanelOnCues(key);
  };
  return { sandbox, stored, tick, overlayEl, setTrack, storage: sandbox.chrome.storage.local };
}

const CUES = [{ startMs: 0, endMs: 3000, text: '君の名は' }, { startMs: 3000, endMs: 6000, text: '大丈夫だ' }];

test('首读 subtitleStyle 落到覆盖层根；同一份设置在 tick 里不重复写 style', () => {
  const w = loadWorld({ subtitleStyle: { fontScale: 130, fontWeight: 700, textAlign: 'left' } });
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.ok(el, '覆盖层应已挂出');
  assert.strictEqual(el.style.props['--fushi-sub-scale'], '1.3');
  assert.strictEqual(el.style.props['--fushi-sub-weight'], '700');
  assert.strictEqual(el.style.props['--fushi-sub-align'], 'left');
  assert.strictEqual(el.style.props['--fushi-sub-color'], undefined, '默认项不写');
  const writes = el.style.writes;
  w.tick(); w.tick(); w.tick();
  assert.strictEqual(el.style.writes, writes, 'tick 不该反复重写 style');
});

test('设置页改动经 storage.onChanged 立刻生效；删键回默认（全部 removeProperty）；旧布尔底板开关照旧', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.strictEqual(el.style.props['--fushi-sub-scale'], undefined);
  w.storage.set({ subtitleStyle: { fontFamily: 'serif', backgroundColor: '#000000', backgroundOpacity: 30 } });
  assert.strictEqual(el.style.props['--fushi-sub-family'], 'serif');
  assert.strictEqual(el.style.props['--fushi-sub-bg'], 'rgba(0, 0, 0, 0.3)');
  w.storage.set({ subtitleOverlayBackground: false });
  assert.strictEqual(el.hasAttribute('data-bare'), true, '底板开关仍是 data-bare');
  assert.strictEqual(el.style.props['--fushi-sub-family'], 'serif', '改别的键不能把外观刷掉');
  w.storage.remove('subtitleStyle');
  assert.deepEqual(el.style.props, {}, '删键后全部变量交还 CSS');
});

// ───────── ④ Fushi 字体库 @font-face ─────────

function withFontMessages(w, fonts) {
  const calls = [];
  w.sandbox.chrome.runtime.sendMessage = (msg, cb) => {
    calls.push(msg);
    if (msg && msg.type === 'subtitleFonts' && cb) cb(fonts ? { ok: true, fonts } : { ok: false });
  };
  return calls;
}

test('外观选了字体 → 向 background 要一次字体清单并把 @font-face 挂进 <head>；没选字体不请求；app 没开不挂且允许重试', () => {
  const FONTS = [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'ttf', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=t' }];
  // ① 没选字体：不请求。
  const w0 = loadWorld({ subtitleStyle: { fontScale: 120 } });
  const calls0 = withFontMessages(w0, FONTS);
  w0.setTrack('ja', CUES); w0.tick();
  assert.strictEqual(calls0.filter((m) => m.type === 'subtitleFonts').length, 0);
  // ② 选了库字体：请求一次，<head> 里出现 @font-face；再 tick 不重复请求。
  const w = loadWorld({ subtitleStyle: { fontFamily: '"Klee One"' } });
  const calls = withFontMessages(w, FONTS);
  w.setTrack('ja', CUES); w.tick(); w.tick();
  assert.strictEqual(calls.filter((m) => m.type === 'subtitleFonts').length, 1);
  const styleEl = w.sandbox.document.getElementById('fushi-subtitle-fontfaces');
  assert.ok(styleEl, '应注入 <style id=fushi-subtitle-fontfaces>');
  assert.strictEqual(styleEl.parentNode, w.sandbox.document.head);
  assert.match(styleEl.textContent, /@font-face\{font-family:"Klee One";src:url\("http:\/\/127\.0\.0\.1:19633\/api\/extension\/fonts\/file\?id=font_1&token=t"\) format\("truetype"\)/);
  assert.strictEqual(w.overlayEl().style.props['--fushi-sub-family'], '"Klee One"');
  // ③ 设置页又改了外观：允许再拉一次清单（可能刚下载了新字体），清单没变不重写。
  const text = styleEl.textContent;
  w.storage.set({ subtitleStyle: { fontFamily: '"Klee One"', fontScale: 150 } });
  assert.strictEqual(calls.filter((m) => m.type === 'subtitleFonts').length, 2);
  assert.strictEqual(styleEl.textContent, text);
  // ④ app 没开：不挂，且下次外观变化会重试。
  const w2 = loadWorld({ subtitleStyle: { fontFamily: '"Klee One"' } });
  const calls2 = withFontMessages(w2, null);
  w2.setTrack('ja', CUES); w2.tick();
  assert.strictEqual(calls2.filter((m) => m.type === 'subtitleFonts').length, 1);
  assert.strictEqual(w2.sandbox.document.getElementById('fushi-subtitle-fontfaces'), null);
  w2.storage.set({ subtitleStyle: { fontFamily: '"Klee One"', fontScale: 110 } });
  assert.strictEqual(calls2.filter((m) => m.type === 'subtitleFonts').length, 2, '失败后允许重试');
});

// ───────── ⑤ background：subtitleFonts / subtitleFontDownload ─────────

function loadBackground(routes) {
  const stored = { host: '127.0.0.1', port: 19733, token: 'tk' };
  const fetches = [];
  const sandbox = {
    console, URL, btoa: (s) => Buffer.from(s).toString('base64'),
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval,
    performance: { now: () => 1, timeOrigin: 0 },
    AbortSignal: { timeout: () => null },
    fetch: (url, init) => {
      const u = new URL(url);
      fetches.push({ path: u.pathname, method: init && init.method, auth: init && init.headers && init.headers.Authorization, body: init && init.body ? JSON.parse(init.body) : null });
      const r = routes[u.pathname];
      if (!r) return Promise.reject(new Error('ECONNREFUSED'));
      return Promise.resolve({ ok: r.status === 200, status: r.status, headers: { get: () => null }, json: () => Promise.resolve(r.body), text: () => Promise.resolve(JSON.stringify(r.body)) });
    },
    importScripts() {},
    chrome: {
      storage: { local: { get: (keys) => Promise.resolve(Object.fromEntries([].concat(keys).filter((k) => k in stored).map((k) => [k, stored[k]]))), set: () => Promise.resolve() }, onChanged: { addListener() {} } },
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
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'), sandbox, { filename: 'background.js' });
  const ask = (msg) => new Promise((resolve) => { sandbox._onMessage(msg, { tab: { id: 1 } }, resolve); });
  return { ask, fetches };
}

test('background subtitleFonts：POST /api/extension/fonts 带 Basic 鉴权；每条字体拼上带 token 的文件 URL；坏条目丢弃；app 没开 ok:false', async () => {
  const status = { status: 200, body: { app: 'fushi' } };
  const bg = loadBackground({
    '/api/extension/status': status,
    '/api/extension/fonts': { status: 200, body: {
      fonts: [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'TTF' }, { id: '', family: 'x' }, { id: 'font_3' }],
      recommended: [{ name: 'Klee One', nameJa: 'クレー One', installed: true }],
    } },
  });
  const r = await bg.ask({ type: 'subtitleFonts' });
  assert.strictEqual(r.ok, true);
  const call = bg.fetches.find((f) => f.path === '/api/extension/fonts');
  assert.strictEqual(call.method, 'POST');
  assert.strictEqual(call.auth, 'Basic ' + Buffer.from('fushi:tk').toString('base64'));
  assert.deepEqual(r.fonts, [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'ttf', url: 'http://127.0.0.1:19733/api/extension/fonts/file?id=font_1&token=tk' }]);
  assert.deepEqual(r.recommended, [{ name: 'Klee One', nameJa: 'クレー One', installed: true }]);
  const off = loadBackground({});
  const r2 = await off.ask({ type: 'subtitleFonts' });
  assert.strictEqual(r2.ok, false);
});

test('background subtitleFontDownload：POST /api/extension/fonts/download {name}；app 的 ok/error 原样透传，新字体同样拼 URL', async () => {
  const bg = loadBackground({
    '/api/extension/status': { status: 200, body: { app: 'fushi' } },
    '/api/extension/fonts/download': { status: 200, body: { ok: true, fonts: [{ id: 'font_9', name: 'Noto Sans JP', family: 'Noto Sans JP', ext: 'ttf' }] } },
  });
  const r = await bg.ask({ type: 'subtitleFontDownload', name: 'Noto Sans JP' });
  const call = bg.fetches.find((f) => f.path === '/api/extension/fonts/download');
  assert.deepEqual(call.body, { name: 'Noto Sans JP' });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.fonts[0].url, 'http://127.0.0.1:19733/api/extension/fonts/file?id=font_9&token=tk');
  const bad = loadBackground({
    '/api/extension/status': { status: 200, body: { app: 'fushi' } },
    '/api/extension/fonts/download': { status: 404, body: { ok: false, error: 'unknown_font' } },
  });
  const r2 = await bad.ask({ type: 'subtitleFontDownload', name: 'Nope' });
  assert.strictEqual(r2.ok, false);
  assert.strictEqual(r2.error, 'unknown_font');
  assert.strictEqual(r2.status, 404);
});
