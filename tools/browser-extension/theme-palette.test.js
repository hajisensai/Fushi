// 扩展配色主题（用户 2026-09-19：「一套和 Fushi 本体一样的主题管理，不只是浅色暗色还能自定义」）。
//  ① theme-palette.js：预设与 app theme_notifier.dart 七款同名同种子；种子色 → 明暗两套 --fushi-*
//     token（hex），纯黑预设底为 #000、卡片可辨；自定义条目规范化（坏值回默认、id 去重）。
//  ② theme.js：extensionPalette / extensionCustomThemes / appThemeMirror 三键决议；默认 'fushi'
//     不注入 style（theme.css 原样）；预设/自定义在扩展页面写 :root 两块、在宿主页只写 #fushi-*
//     宿主；'app' 用镜像色；popupVars 在预设/自定义下覆盖弹窗 --md-*，跟随 Fushi 时为 null。
//  ③ background.js 把查词响应的 app 配色按明暗镜像进 appThemeMirror；三处弹窗壳都调
//     applyPopupPalette。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const PALETTE_SRC = fs.readFileSync(path.join(__dirname, 'theme-palette.js'), 'utf8');
const THEME_SRC = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');

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

function fakeDoc() {
  const nodes = {};
  const head = { children: [], appendChild(el) { this.children.push(el); el.parentNode = this; } };
  const html = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; } };
  return {
    head,
    documentElement: html,
    getElementById: (id) => nodes[id] || null,
    createElement: (tag) => {
      const el = { tag, id: '', textContent: '', parentNode: null };
      Object.defineProperty(el, 'id', { set(v) { nodes[v] = el; el._id = v; }, get() { return el._id; } });
      return el;
    },
    _nodes: nodes,
    _removeChild(el) { head.children = head.children.filter((c) => c !== el); el.parentNode = null; delete nodes[el._id]; },
  };
}

function loadPalette() {
  const sandbox = { console };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(PALETTE_SRC, sandbox, { filename: 'theme-palette.js' });
  return sandbox.fushiThemePalette;
}

function loadTheme(opts) {
  opts = opts || {};
  const stored = Object.assign({}, opts.stored);
  const doc = fakeDoc();
  doc.head.removeChild = (el) => doc._removeChild(el);
  const sandbox = {
    console,
    location: { protocol: opts.protocol || 'https:' },
    matchMedia: () => ({ matches: !!opts.systemDark, addEventListener() {} }),
    chrome: { storage: storageMock(stored) },
    document: doc,
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(PALETTE_SRC, sandbox, { filename: 'theme-palette.js' });
  vm.runInContext(THEME_SRC, sandbox, { filename: 'theme.js' });
  return { theme: sandbox.fushiTheme, doc, set: (p) => sandbox.chrome.storage.local.set(p) };
}

const HEX = /^#[0-9a-f]{6}$/;

// ───────── ① theme-palette.js ─────────

test('预设与 app theme_notifier.dart 的七款同名同种子；fushi 默认无出厂明暗', () => {
  const P = loadPalette();
  const byKey = Object.fromEntries(P.PRESETS.map((p) => [p.key, p]));
  assert.deepStrictEqual(Object.keys(byKey), ['fushi', 'light-theme', 'ecru-theme', 'water-theme', 'eyecare-theme', 'gray-theme', 'dark-theme', 'black-theme']);
  assert.strictEqual(byKey['light-theme'].seed, '#1f4959');
  assert.strictEqual(byKey['ecru-theme'].seed, '#8b7355');
  assert.strictEqual(byKey['water-theme'].seed, '#4a7c8f');
  assert.strictEqual(byKey['eyecare-theme'].seed, '#5e8c63');
  assert.strictEqual(byKey['gray-theme'].seed, '#5c6b73');
  assert.strictEqual(byKey['dark-theme'].seed, '#1f4959');
  assert.strictEqual(byKey['black-theme'].seed, '#3f51b5');
  assert.strictEqual(byKey.fushi.brightness, null);
  assert.strictEqual(byKey['ecru-theme'].brightness, 'light');
  assert.strictEqual(byKey['black-theme'].brightness, 'dark');
  assert.strictEqual(byKey['gray-theme'].neutral, true, '灰色系预设 = app 的 neutral variant');
});

test('种子色派生明暗两套 token：全 hex、浅色浅底深字、深色深底浅字、色相跟种子', () => {
  const P = loadPalette();
  for (const key of ['ecru-theme', 'water-theme', 'dark-theme']) {
    const spec = P.specFor(key);
    const light = P.derive(spec, 'light');
    const dark = P.derive(spec, 'dark');
    assert.deepStrictEqual(Object.keys(light), Array.from(P.TOKEN_NAMES));
    for (const k of P.TOKEN_NAMES) {
      assert.match(light[k], HEX, key + ' light ' + k);
      assert.match(dark[k], HEX, key + ' dark ' + k);
    }
    const L = (hex) => P.rgbToOklch(P.parseHex(hex)).L;
    assert.ok(L(light['--fushi-bg']) > 0.9 && L(light['--fushi-text']) < 0.35, key + ' 浅色应浅底深字');
    assert.ok(L(dark['--fushi-bg']) < 0.3 && L(dark['--fushi-text']) > 0.8, key + ' 深色应深底浅字');
    const seedHue = P.rgbToOklch(P.parseHex(spec.seed)).h;
    const primaryHue = P.rgbToOklch(P.parseHex(light['--fushi-primary'])).h;
    const dh = Math.abs(((primaryHue - seedHue + 540) % 360) - 180);
    assert.ok(dh < 12, key + ' 主色色相应跟种子（差 ' + dh.toFixed(1) + '°）');
  }
});

test('纯黑预设：深色底 #000000，卡片阶梯仍与底可辨；neutral 预设的表面无色相偏移', () => {
  const P = loadPalette();
  const black = P.derive(P.specFor('black-theme'), 'dark');
  assert.strictEqual(black['--fushi-bg'], '#000000');
  const L = (hex) => P.rgbToOklch(P.parseHex(hex)).L;
  assert.ok(L(black['--fushi-surface']) > 0.12, '卡片不能和纯黑底糊成一片');
  const gray = P.derive(P.specFor('gray-theme'), 'dark');
  const c = P.parseHex(gray['--fushi-bg']);
  assert.ok(Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b) <= 2, 'neutral 的底应是灰阶');
});

test('自定义条目规范化：坏 hex 回默认种子、id 去重、id 只留安全字符；palette id 坏值回 fushi', () => {
  const P = loadPalette();
  const list = P.normalizeCustomThemes([
    { id: 'a1', name: '  My theme  ', seed: 'not-a-color', surface: '#FFF', text: null, neutral: 'yes' },
    { id: 'a1', name: 'dup' },
    { id: '../evil', seed: '#123456' },
    null,
  ]);
  assert.strictEqual(list.length, 2);
  assert.deepEqual(list[0], { id: 'a1', name: 'My theme', seed: P.DEFAULT_SEED, surface: '#ffffff', text: null, neutral: false });
  assert.strictEqual(list[1].id, 'evil', 'id 里的路径字符被剥掉');
  assert.strictEqual(P.normalizePaletteId('custom:a1'), 'custom:a1');
  assert.strictEqual(P.normalizePaletteId('custom:../x'), 'fushi');
  assert.strictEqual(P.normalizePaletteId('nope'), 'fushi');
  assert.strictEqual(P.normalizePaletteId('app'), 'app');
  assert.strictEqual(P.specFor('custom:missing', list), null, '找不到的自定义 id 回 null（调用方按 fushi 兜底）');
  const spec = P.specFor('custom:a1', list);
  assert.strictEqual(spec.surface, '#ffffff');
});

test('surface / text 覆盖生效：浅色底取覆盖色相与明度；文字覆盖明度被夹到可读区', () => {
  const P = loadPalette();
  const spec = { seed: '#1f4959', surface: '#fff4e6', text: '#ffffff', neutral: false };
  const light = P.derive(spec, 'light');
  const bg = P.rgbToOklch(P.parseHex(light['--fushi-bg']));
  const want = P.rgbToOklch(P.parseHex('#fff4e6'));
  assert.ok(Math.abs(bg.h - want.h) < 5, '底色相跟覆盖');
  const text = P.rgbToOklch(P.parseHex(light['--fushi-text']));
  assert.ok(text.L < 0.4, '浅色模式下白色文字覆盖会被折成深字，不能变成白底白字');
});

test('跟随 Fushi：app 镜像色（cssRgb 的 rgb() 串）映射到 --fushi-*，缺核心键回 null；popupVars 键名与 app 下发一致', () => {
  const P = loadPalette();
  // 夹具用 app 真实下发格式：popup_theme_css.dart cssRgb() → `rgb(r, g, b)`，不是 hex。
  // 曾因夹具全写 hex 而漏掉「解析只认 hex → 真 app 下永远回 null、退成默认绿」。
  const mirror = {
    '--text-color': 'rgb(25, 28, 26)', '--background-color': 'rgb(247, 249, 244)', '--md-primary': 'rgb(56, 106, 88)',
    '--md-on-primary': 'rgb(255, 255, 255)', '--md-surface-container': 'rgb(236, 238, 233)',
    '--md-surface-container-high': 'rgb(230, 232, 227)', '--md-on-surface': 'rgb(25, 28, 26)',
    '--md-on-surface-variant': 'rgb(68, 72, 63)', '--md-outline-variant': 'rgb(196, 200, 190)',
  };
  const t = P.tokensFromAppTheme(mirror);
  assert.strictEqual(t['--fushi-surface'], '#f7f9f4');
  assert.strictEqual(t['--fushi-primary'], '#386a58');
  assert.strictEqual(t['--fushi-text'], '#191c1a');
  assert.strictEqual(t['--fushi-outline'], '#c4c8be');
  assert.strictEqual(P.tokensFromAppTheme({ '--md-primary': '#386a58' }), null);
  // hex 形态仍收（自定义主题条目 / 旧镜像），rgba 忽略 alpha，坏串回 null。
  assert.strictEqual(P.toHex(P.parseCssColor('#386a58')), P.toHex({ r: 56, g: 106, b: 88 }));
  assert.strictEqual(P.toHex(P.parseCssColor('rgba(56, 106, 88, 0.5)')), P.toHex({ r: 56, g: 106, b: 88 }));
  assert.strictEqual(P.parseCssColor('rgb(300, 0, 0)'), null);
  assert.strictEqual(P.parseCssColor('hsl(1, 2%, 3%)'), null);
  assert.strictEqual(P.tokensFromAppTheme({ '--text-color': '#191c1a', '--background-color': '#f7f9f4', '--md-primary': '#386a58' })['--fushi-primary'], '#386a58');
  const pv = P.popupVarsFromTokens(P.derive(P.specFor('ecru-theme'), 'dark'));
  assert.deepStrictEqual(Object.keys(pv).sort(), [
    '--background-color', '--fushi-card-bg-rgb', '--fushi-primary-highlight', '--md-on-primary',
    '--md-on-surface', '--md-on-surface-variant', '--md-outline-variant', '--md-primary',
    '--md-surface-container', '--md-surface-container-high', '--text-color',
  ]);
  assert.match(pv['--fushi-card-bg-rgb'], /^\d+, \d+, \d+$/, 'popup.css 的 rgba(var(--fushi-card-bg-rgb), a) 需要裸三元组');
  assert.match(pv['--fushi-primary-highlight'], /^rgba\(\d+, \d+, \d+, 0\.35\)$/);
});

test('格式契约：app 侧 popup_theme_css.dart 的 cssRgb 仍产出 rgb(r, g, b)，与 parseCssColor 同口径', () => {
  const dart = fs.readFileSync(path.join(__dirname, '..', '..', 'fushi', 'lib', 'src', 'utils', 'popup_theme_css.dart'), 'utf8');
  assert.match(dart, /String cssRgb\(Color c\) => 'rgb\(/, 'app 下发格式变了就要同步 theme-palette.js parseCssColor');
  const P = loadPalette();
  assert.strictEqual(P.toHex(P.parseCssColor('rgb(1, 2, 3)')), P.toHex({ r: 1, g: 2, b: 3 }));
});

// ───────── ② theme.js ─────────

test('默认 fushi 调色板：不注入 style、tokens/popupVars 为 null，theme.css 原样接管', () => {
  const h = loadTheme({ protocol: 'chrome-extension:' });
  assert.strictEqual(h.theme.palette, 'fushi');
  assert.strictEqual(h.theme.tokens('light'), null);
  assert.strictEqual(h.theme.popupVars('dark'), null);
  assert.strictEqual(h.doc.getElementById('fushi-theme-palette'), null);
});

test('扩展页面选预设：写 :root 明暗两块（显式属性 + prefers-color-scheme）；切回 fushi 摘掉 style', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'ecru-theme' } });
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.ok(style, '应注入调色板 style');
  assert.match(style.textContent, /^:root:not\(\[data-theme="dark"\]\) \{ --fushi-bg: #[0-9a-f]{6};/m);
  assert.match(style.textContent, /:root\[data-theme="dark"\] \{ --fushi-bg: #[0-9a-f]{6};/);
  assert.match(style.textContent, /@media \(prefers-color-scheme: dark\) \{ :root:not\(\[data-theme="light"\]\)/);
  assert.doesNotMatch(style.textContent, /#fushi-drawer/, '扩展页面不用宿主清单');
  h.set({ extensionPalette: 'fushi' });
  assert.strictEqual(h.doc.getElementById('fushi-theme-palette'), null, '默认调色板要把 style 摘掉');
});

test('宿主网页：只写 #fushi-* 浮层宿主，绝不写 :root，也不动宿主 <html> 的 data-theme', () => {
  const h = loadTheme({ protocol: 'https:', stored: { extensionPalette: 'water-theme', extensionTheme: 'dark' } });
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.ok(style);
  assert.match(style.textContent, /:where\(#fushi-drawer, #fushi-subtitle-overlay, #fushi-subtitle-drop-hint, #fushi-queue-chip, #fushi-toast, #fushi-player-btn, #fushi-player-controls\)\[data-theme="dark"\]/);
  assert.doesNotMatch(style.textContent, /(^|[^-\w]):root/m, '宿主页 :root 一个变量都不能碰');
  assert.deepStrictEqual(h.doc.documentElement.attrs, {}, '宿主 <html> 不改');
});

test('自定义主题：列表变化 / 选中变化都即时重算；删掉正在用的自定义 id 后回 theme.css 默认', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: {
    extensionPalette: 'custom:t1',
    extensionCustomThemes: [{ id: 't1', name: 'Sakura', seed: '#d6336c' }],
  } });
  const before = h.theme.tokens('light')['--fushi-primary'];
  assert.match(before, HEX);
  h.set({ extensionCustomThemes: [{ id: 't1', name: 'Sakura', seed: '#1c7ed6' }] });
  const after = h.theme.tokens('light')['--fushi-primary'];
  assert.notStrictEqual(after, before, '改种子色要立刻反映');
  h.set({ extensionCustomThemes: [] });
  assert.strictEqual(h.theme.tokens('light'), null);
  assert.strictEqual(h.doc.getElementById('fushi-theme-palette'), null);
});

test('跟随 Fushi：有哪一侧镜像就给哪一侧；popupVars 为 null（弹窗照旧吃 app 自己的配色）', () => {
  const mirrorLight = {
    '--text-color': '#191c1a', '--background-color': '#f7f9f4', '--md-primary': '#386a58',
    '--md-on-primary': '#ffffff', '--md-surface-container': '#eceee9', '--md-surface-container-high': '#e6e8e3',
    '--md-on-surface': '#191c1a', '--md-on-surface-variant': '#44483f', '--md-outline-variant': '#c4c8be',
  };
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'app' } });
  assert.strictEqual(h.theme.tokens('light'), null, '还没镜像到 app 配色时回默认');
  h.set({ appThemeMirror: { light: mirrorLight } });
  assert.strictEqual(h.theme.tokens('light')['--fushi-surface'], '#f7f9f4');
  assert.strictEqual(h.theme.tokens('dark'), null, '深色侧还没镜像');
  assert.strictEqual(h.theme.popupVars('light'), null);
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.match(style.textContent, /:root:not\(\[data-theme="dark"\]\) \{ --fushi-bg: #eceee9;/);
  assert.doesNotMatch(style.textContent, /data-theme="dark"\] \{/, '没有深色镜像就不写深色块');
});

test('applyPopupPalette：预设/自定义下把 --md-* 等覆盖到弹窗容器；fushi/app 下不动', () => {
  const h = loadTheme({ protocol: 'https:', stored: { extensionPalette: 'dark-theme' } });
  const c = { style: { props: {}, setProperty(k, v) { this.props[k] = v; } } };
  assert.strictEqual(h.theme.applyPopupPalette(c, 'dark'), true);
  assert.match(c.style.props['--md-primary'], HEX);
  assert.match(c.style.props['--background-color'], HEX);
  assert.match(c.style.props['--fushi-card-bg-rgb'], /^\d+, \d+, \d+$/);
  h.set({ extensionPalette: 'fushi' });
  const c2 = { style: { props: {}, setProperty(k, v) { this.props[k] = v; } } };
  assert.strictEqual(h.theme.applyPopupPalette(c2, 'dark'), false);
  assert.deepStrictEqual(c2.style.props, {});
});

// ───────── ③ 接线守卫 ─────────

test('三处弹窗壳都在设 data-theme 之后调 applyPopupPalette；background 镜像 app 配色到 appThemeMirror', () => {
  for (const f of ['content.js', 'side-panel.js', 'nested-popup.js']) {
    const src = fs.readFileSync(path.join(__dirname, f), 'utf8');
    assert.match(src, /fushiTheme\.applyPopupPalette\(/, f + ' 应套扩展调色板到弹窗');
  }
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.match(bg, /rememberAppTheme\(data && data\.theme\)/);
  assert.match(bg, /chrome\.storage\.local\.set\(\{ appThemeMirror \}\)/);
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  assert.ok(js.indexOf('theme-palette.js') < js.indexOf('theme.js'), 'theme-palette.js 必须先于 theme.js 装入');
  assert.ok(js.indexOf('subtitle-style.js') < js.indexOf('subtitle-panel.js'), 'subtitle-style.js 必须先于 subtitle-panel.js 装入');
  for (const page of ['options.html', 'side-panel.html', 'nested-popup.html', 'vendor/action-popup.html']) {
    const html = fs.readFileSync(path.join(__dirname, page), 'utf8');
    const scripts = [...html.matchAll(/<script src="([^"]+)"/g)].map((m) => m[1].replace(/^\.\.\//, ''));
    assert.ok(scripts.indexOf('theme-palette.js') >= 0 && scripts.indexOf('theme-palette.js') < scripts.indexOf('theme.js'), page + ' 要在 theme.js 前装 theme-palette.js');
  }
  const wa = manifest.web_accessible_resources.some((r) => r.resources.includes('theme-palette.js'));
  assert.ok(wa, '抽屉 iframe 的 side-panel.html 要能取到 theme-palette.js');
});

test('IN_PAGE_HOSTS 与 generate-content-css.mjs 的重根宿主清单一致', () => {
  const gen = fs.readFileSync(path.join(__dirname, 'scripts', 'generate-content-css.mjs'), 'utf8');
  const a = /IN_PAGE_THEME_HOSTS =\s*'([^']+)'/.exec(gen)[1];
  const b = /IN_PAGE_HOSTS = '([^']+)'/.exec(THEME_SRC)[1];
  assert.strictEqual(b, a);
});
