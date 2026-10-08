// 扩展配色主题（用户 2026-09-19：「一套和 Fushi 本体一样的主题管理，不只是浅色暗色还能自定义」）。
//  ① theme-palette.js：预设与 app theme_notifier.dart 的 M3 经典预设（m3-*）同名同种子同变体；种子色
//     经 material-color.js（material_color_utilities 0.13.0 移植）→ M3 动态方案 → Fushi 表面阶梯 →
//     --fushi-* token；纯黑深色底 #000；旧扩展预设 id 只读映射；自定义条目规范化。
//  ② theme.js：extensionPalette / extensionCustomThemes / appThemeMirror / extensionPureBlack 决议；
//     缺省跟随 Fushi；预设/自定义在扩展页面写 :root 两块、在宿主页只写 #fushi-* 宿主；'app' 用镜像色；
//     popupVars 在预设/自定义下覆盖弹窗 --md-*，跟随 Fushi 时为 null。
//  ③ background.js 把查词响应的 app 配色按明暗镜像进 appThemeMirror；三处弹窗壳都调
//     applyPopupPalette。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const MC_SRC = fs.readFileSync(path.join(__dirname, 'material-color.js'), 'utf8');
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
  vm.runInContext(MC_SRC, sandbox, { filename: 'material-color.js' });
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
  vm.runInContext(MC_SRC, sandbox, { filename: 'material-color.js' });
  vm.runInContext(PALETTE_SRC, sandbox, { filename: 'theme-palette.js' });
  vm.runInContext(THEME_SRC, sandbox, { filename: 'theme.js' });
  return { theme: sandbox.fushiTheme, doc, sandbox, set: (p) => sandbox.chrome.storage.local.set(p) };
}

const HEX = /^#[0-9a-f]{6}$/;

// ───────── ① theme-palette.js ─────────

test('预设与 app theme_notifier.dart themePresets 同名同种子同变体（逐条从 Dart 源码读出比对）', () => {
  const P = loadPalette();
  const dart = fs.readFileSync(path.join(__dirname, '..', '..', 'fushi', 'lib', 'src', 'models', 'theme_notifier.dart'), 'utf8');
  const block = /static const Map<String, ThemePreset> themePresets = \{([\s\S]*?)\n  \};/.exec(dart)[1];
  const app = [...block.matchAll(/'(m3-[a-z]+)': \(\s*seed: Color\(0xFF([0-9A-F]{6})\),\s*variant: ([A-Za-z.]+),/g)]
    .map((m) => ({ key: m[1], seed: '#' + m[2].toLowerCase(), variant: m[3] === 'kFushiDefaultSchemeVariant' ? 'vibrant' : m[3].split('.').pop() }));
  assert.ok(app.length >= 10, 'Dart 预设表解析失败');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(P.PRESETS.map((p) => ({ key: p.key, seed: p.seed, variant: p.variant })))), app);
  assert.match(dart, /kFushiDefaultSchemeVariant =\s*DynamicSchemeVariant\.vibrant;/, 'app 默认变体变了要同步 DEFAULT_VARIANT');
  assert.strictEqual(P.DEFAULT_VARIANT, 'vibrant');
});

test('旧扩展预设 id 只读映射到最接近的新预设（与 app legacyPresetReplacement 同一规则）', () => {
  const P = loadPalette();
  for (const [key, legacy] of Object.entries(P.LEGACY_PRESETS)) {
    const want = legacy.neutral ? 'm3-neutral' : P.nearestPresetForSeed(legacy.seed);
    assert.strictEqual(P.legacyReplacement(key), want, key + ' 的映射表与色相最近规则不一致');
    assert.strictEqual(P.normalizePaletteId(key), want);
  }
  // app 侧旧预设表的种子 / 中性 / 纯黑与这里一致（同名七款）。
  const dart = fs.readFileSync(path.join(__dirname, '..', '..', 'fushi', 'lib', 'src', 'models', 'theme_notifier.dart'), 'utf8');
  let n = 0;
  for (const m of dart.matchAll(/'([a-z]+-theme)': \(\s*seed: Color\(0xFF([0-9A-F]{6})\),\s*neutral: (true|false),\s*dark: (?:true|false),\s*pureBlack: (true|false),/g)) {
    n++;
    assert.deepStrictEqual(JSON.parse(JSON.stringify(P.LEGACY_PRESETS[m[1]])), { seed: '#' + m[2].toLowerCase(), neutral: m[3] === 'true', pureBlack: m[4] === 'true' }, m[1]);
  }
  assert.strictEqual(n, 7, 'Dart 旧预设表解析失败');
  assert.strictEqual(P.normalizePaletteId('custom:abc'), 'custom:abc');
});

test('种子色派生明暗两套 token：全 hex、浅色浅底深字、深色深底浅字', () => {
  const P = loadPalette();
  for (const key of ['m3-orange', 'm3-blue', 'm3-teal', 'm3-neutral']) {
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
  }
});

test('纯黑深色背景：深色页面底 #000000、容器阶梯仍可辨；浅色不受影响', () => {
  const P = loadPalette();
  const spec = P.specFor('m3-indigo');
  const black = P.derive(spec, 'dark', { pureBlack: true });
  assert.strictEqual(black['--fushi-bg'], '#000000');
  const L = (hex) => P.rgbToOklch(P.parseHex(hex)).L;
  assert.ok(L(black['--fushi-surface-muted']) > L(black['--fushi-bg']) + 0.05, '容器层不能和纯黑底糊成一片');
  assert.notStrictEqual(P.derive(spec, 'dark')['--fushi-bg'], '#000000');
  assert.deepStrictEqual(P.derive(spec, 'light', { pureBlack: true }), P.derive(spec, 'light'));
  const gray = P.derive(P.specFor('m3-neutral'), 'dark');
  const c = P.parseHex(gray['--fushi-bg']);
  assert.ok(Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b) <= 3, '中性预设的底应近灰阶');
});

test('自定义条目规范化：坏 hex 回默认种子、id 去重、id 只留安全字符；palette id 坏值回 app（跟随 Fushi）', () => {
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
  assert.strictEqual(P.normalizePaletteId('custom:../x'), 'app');
  assert.strictEqual(P.normalizePaletteId('fushi'), P.legacyReplacement('fushi'), '旧扩展绿映射到新预设');
  assert.strictEqual(P.normalizePaletteId('nope'), 'app');
  assert.strictEqual(P.normalizePaletteId(undefined), 'app', '缺省跟随 Fushi，与查词弹窗同源');
  assert.strictEqual(P.normalizePaletteId('app'), 'app');
  assert.strictEqual(P.specFor('custom:missing', list), null, '找不到的自定义 id 回 null（调用方按 fushi 兜底）');
  const spec = P.specFor('custom:a1', list);
  assert.strictEqual(spec.surface, '#ffffff');
});

test('surface / text 覆盖生效：底色就是钉的色；明暗冲突时折到本明暗；文字覆盖不会白底白字', () => {
  const P = loadPalette();
  const spec = { seed: '#1f4959', surface: '#fff4e6', text: '#ffffff', neutral: false };
  const light = P.derive(spec, 'light');
  assert.strictEqual(light['--fushi-bg'], '#fff4e6', '浅色下钉的浅底原样采用（app deriveSurfaceRolesFrom）');
  const text = P.rgbToOklch(P.parseHex(light['--fushi-text']));
  assert.ok(text.L < 0.45, '浅色模式下白色文字覆盖会被折成深字');
  const dark = P.derive(spec, 'dark');
  assert.ok(P.rgbToOklch(P.parseHex(dark['--fushi-bg'])).L < 0.4, '深色下浅底覆盖折成深底');
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
    '--background-color', '--fushi-card-bg-rgb', '--fushi-primary-highlight', '--md-error',
    '--md-inverse-on-surface', '--md-inverse-surface', '--md-on-primary', '--md-on-primary-container',
    '--md-on-secondary-container', '--md-on-surface', '--md-on-surface-variant', '--md-on-tertiary',
    '--md-on-tertiary-container', '--md-outline', '--md-outline-variant', '--md-primary',
    '--md-primary-container', '--md-secondary-container', '--md-surface-container',
    '--md-surface-container-high', '--md-surface-container-highest', '--md-surface-container-low',
    '--md-tertiary', '--md-tertiary-container', '--text-color',
  ]);
  // 新增的 M3 容器 / tertiary 角色键必须是 app 真会下发的键（popup_theme_css.dart），否则弹窗读不到。
  const dartVars = fs.readFileSync(path.join(__dirname, '..', '..', 'fushi', 'lib', 'src', 'utils', 'popup_theme_css.dart'), 'utf8');
  for (const k of Object.keys(pv)) {
    if (k.startsWith('--md-')) assert.ok(dartVars.includes("'" + k + "'"), k + ' 不是 app 下发的键');
  }
  // 跟随 Fushi：app 下发了容器角色就原样采用（与 app 同色），缺了按主色派生。
  const withRoles = P.tokensFromAppTheme(Object.assign({}, mirror, {
    '--md-primary-container': 'rgb(187, 236, 216)', '--md-tertiary': 'rgb(61, 99, 115)',
  }));
  assert.strictEqual(withRoles['--fushi-primary-soft'], '#bbecd8');
  assert.strictEqual(withRoles['--fushi-tertiary'], '#3d6373');
  assert.match(t['--fushi-tertiary'], HEX, '旧 app 缺 tertiary 时派生');
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

test('缺省调色板 = 跟随 Fushi：还没镜像到 app 配色时不注入 style（theme.css 接管）、弹窗不覆盖', () => {
  const h = loadTheme({ protocol: 'chrome-extension:' });
  assert.strictEqual(h.theme.palette, 'app');
  assert.strictEqual(h.theme.tokens('light'), null);
  assert.strictEqual(h.theme.popupVars('dark'), null);
  assert.strictEqual(h.doc.getElementById('fushi-theme-palette'), null);
});

test('旧扩展绿（fushi）存储：映射到新预设，页面注入派生 style、查词弹窗同色覆盖', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'fushi' } });
  const P = h.sandbox.fushiThemePalette;
  assert.strictEqual(h.theme.palette, P.legacyReplacement('fushi'));
  assert.ok(h.doc.getElementById('fushi-theme-palette'));
  const pv = h.theme.popupVars('light');
  assert.strictEqual(pv['--md-primary'], P.derive(P.specFor(h.theme.palette), 'light')['--fushi-primary']);
});

test('扩展页面选预设：写 :root 明暗两块（显式属性 + prefers-color-scheme）；切到跟随 Fushi 且无镜像时摘掉 style', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'm3-orange' } });
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.ok(style, '应注入调色板 style');
  assert.match(style.textContent, /^:root:not\(\[data-theme="dark"\]\) \{ --fushi-bg: #[0-9a-f]{6};/m);
  assert.match(style.textContent, /:root\[data-theme="dark"\] \{ --fushi-bg: #[0-9a-f]{6};/);
  assert.match(style.textContent, /@media \(prefers-color-scheme: dark\) \{ :root:not\(\[data-theme="light"\]\)/);
  assert.doesNotMatch(style.textContent, /#fushi-drawer/, '扩展页面不用宿主清单');
  h.set({ extensionPalette: 'app' });
  assert.strictEqual(h.doc.getElementById('fushi-theme-palette'), null, '没有 app 镜像时交给 theme.css');
});

test('纯黑开关：预设下深色底变 #000；没写过时旧 black-theme 用户缺省开（不改写存储）', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'm3-blue' } });
  assert.strictEqual(h.theme.pureBlack, false);
  assert.notStrictEqual(h.theme.tokens('dark')['--fushi-bg'], '#000000');
  h.set({ extensionPureBlack: true });
  assert.strictEqual(h.theme.tokens('dark')['--fushi-bg'], '#000000');
  assert.notStrictEqual(h.theme.tokens('light')['--fushi-bg'], '#000000');
  const legacy = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'black-theme' } });
  assert.strictEqual(legacy.theme.pureBlack, true);
  assert.strictEqual(legacy.theme.palette, legacy.sandbox.fushiThemePalette.legacyReplacement('black-theme'));
  assert.strictEqual(legacy.theme.tokens('dark')['--fushi-bg'], '#000000');
  const off = loadTheme({ protocol: 'chrome-extension:', stored: { extensionPalette: 'black-theme', extensionPureBlack: false } });
  assert.strictEqual(off.theme.pureBlack, false, '显式关过就尊重');
});

test('宿主网页：只写 #fushi-* 浮层宿主，绝不写 :root，也不动宿主 <html> 的 data-theme', () => {
  const h = loadTheme({ protocol: 'https:', stored: { extensionPalette: 'm3-blue', extensionTheme: 'dark' } });
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.ok(style);
  assert.match(style.textContent, /:where\(#fushi-drawer, #fushi-subtitle-overlay, #fushi-subtitle-drop-hint, #fushi-queue-chip, #fushi-toast, #fushi-player-btn, #fushi-player-controls, #fushi-ctx-modal-host\)\[data-theme="dark"\]/);
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
  const dark = h.theme.tokens('dark');
  assert.ok(dark, '深色侧还没镜像时按 app 主色派生，不退回 theme.css');
  const P = h.sandbox.fushiThemePalette;
  const hue = (hex) => P.rgbToOklch(P.parseHex(hex)).h;
  assert.ok(Math.abs(hue(dark['--fushi-primary']) - hue('#386a58')) < 15);
  // 新 app 随 theme 下发种子 / 变体 / 纯黑：另一明暗与 app 自己切过去的算法一致。
  h.set({ appThemeMirror: { light: Object.assign({}, mirrorLight, {
    '--fushi-theme-seed': 'rgb(233, 30, 99)', '--fushi-theme-variant': 'vibrant', '--fushi-pure-black': '1',
  }) } });
  assert.deepStrictEqual(h.theme.tokens('dark'), P.derive(P.specFor('m3-pink'), 'dark', { pureBlack: true }));
  assert.strictEqual(h.theme.popupVars('light'), null);
  const style = h.doc.getElementById('fushi-theme-palette');
  assert.match(style.textContent, /:root:not\(\[data-theme="dark"\]\) \{ --fushi-bg: #f7f9f4;/);
});

test('applyPopupPalette：预设/自定义/扩展绿下把 --md-* 等覆盖到弹窗容器；跟随 Fushi 下不动', () => {
  const h = loadTheme({ protocol: 'https:', stored: { extensionPalette: 'm3-teal' } });
  const c = { style: { props: {}, setProperty(k, v) { this.props[k] = v; } } };
  assert.strictEqual(h.theme.applyPopupPalette(c, 'dark'), true);
  assert.match(c.style.props['--md-primary'], HEX);
  assert.match(c.style.props['--background-color'], HEX);
  assert.match(c.style.props['--fushi-card-bg-rgb'], /^\d+, \d+, \d+$/);
  h.set({ extensionPalette: 'app' });
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

// 用户 2026-10-06「切换主题时如果我是深色就要继续保持深色」：调色板只决定配色家族，不决定明暗。
test('切调色板不改明暗：options 选主题只写 extensionPalette；预览按当前明暗；预设都能派生亮暗两套', () => {
  const opts = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  const select = /async function selectPalette\(id\) \{([\s\S]*?)\n\}/.exec(opts)[1];
  assert.doesNotMatch(select, /extensionTheme/, '选主题绝不能顺手改明暗');
  assert.doesNotMatch(opts, /preset\.brightness/, '预设的名义明暗不参与任何决议');
  const P = loadPalette();
  const L = (hex) => P.rgbToOklch(P.parseHex(hex)).L;
  for (const p of P.PRESETS) {
    assert.ok(L(P.derive(P.specFor(p.key), 'light')['--fushi-bg']) > 0.8, p.key + ' 浅色要是浅底');
    assert.ok(L(P.derive(P.specFor(p.key), 'dark')['--fushi-bg']) < 0.35, p.key + ' 深色要是深底');
  }
});

test('明暗决议：跟随 Fushi + 自动 → 跟 app 的明暗（弹窗与扩展页面一致）；其它调色板 + 自动 → 跟系统、不吃 app 的明暗', () => {
  const h = loadTheme({ protocol: 'chrome-extension:', stored: { appThemeMirror: { current: 'dark' } } });
  assert.strictEqual(h.theme.palette, 'app');
  assert.strictEqual(h.theme.resolve(), 'dark', '扩展页面跟 app 当前明暗');
  assert.strictEqual(h.theme.resolve('light'), 'light', '查词弹窗传入的 app 明暗优先');
  assert.strictEqual(h.theme.documentScheme(), 'dark');
  h.set({ extensionPalette: 'm3-red' });
  assert.strictEqual(h.theme.resolve('dark'), 'light', '非跟随 Fushi 时自动 = 系统（测试壳系统为浅色）');
  assert.strictEqual(h.theme.documentScheme(), null);
  h.set({ extensionTheme: 'dark' });
  h.set({ extensionPalette: 'ecru-theme' });
  assert.strictEqual(h.theme.preference, 'dark', '切到旧「浅色出厂」预设 id 也保持深色');
  assert.strictEqual(h.theme.resolve(), 'dark');
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.match(bg, /\[scheme\]: colors, current: scheme/, 'background 镜像 app 当前明暗');
});

// ───────── 与 app 逐位一致 ─────────
// 真值：material_color_utilities 0.13.0（Flutter 钉的版本）+ app buildFushiColorScheme 的表面阶梯 / 纯黑阶梯 /
// 无彩度中性派生逐行复刻（Dart 跑出，见提交说明）。行 = 预设/明暗(light|dark|black=纯黑深色)，列 = ROLE_KEYS。
const ROLE_KEYS = ["primary","onPrimary","primaryContainer","onPrimaryContainer","secondary","onSecondary","secondaryContainer","onSecondaryContainer","tertiary","onTertiary","tertiaryContainer","onTertiaryContainer","error","onError","errorContainer","onErrorContainer","outline","outlineVariant","surface","surfaceContainerLowest","surfaceContainerLow","surfaceContainer","surfaceContainerHigh","surfaceContainerHighest","onSurface","onSurfaceVariant","inverseSurface","onInverseSurface","inversePrimary"];
const APP_TRUTH = {
  "m3-baseline/light": "6f19ff ffffff e9ddff 5400cc 6b5778 ffffff f3daff 523f5f 79507a ffffff ffd6fc 5f3961 ba1a1a ffffff ffdad6 93000a 7a7484 cbc3d5 fefefe ffffff f9f3ff f1eaf9 e8e1f0 ded7e6 1d1a24 494453 322f3a f5eefd cfbcff",
  "m3-baseline/dark": "cfbcff 3a0092 5400cc e9ddff d7bee4 3b2948 523f5f f3daff e8b7e7 462349 5f3961 ffd6fc ffb4ab 690005 93000a ffdad6 948e9f 494453 120f19 0c0a13 1c1923 25222c 302d37 3b3742 e7e0ef cbc3d5 e7e0ef 322f3a 6f19ff",
  "m3-baseline/black": "cfbcff 3a0092 5400cc e9ddff d7bee4 3b2948 523f5f f3daff e8b7e7 462349 5f3961 ffd6fc ffb4ab 690005 93000a ffdad6 948e9f 494453 000000 000000 110e18 1b1822 25222c 302d37 e7e0ef cbc3d5 e7e0ef 322f3a 6f19ff",
  "m3-indigo/light": "1242ff ffffff dee0ff 002eca 605a7d ffffff e6deff 484264 6b5485 ffffff efdbff 533d6c ba1a1a ffffff ffdad6 93000a 757685 c5c5d6 fefefe ffffff f6f3ff edebfa e4e2f1 dad8e7 1a1b25 444654 2f303a f0effe bac3ff",
  "m3-indigo/dark": "bac3ff 001e91 002eca dee0ff c9c1ea 312c4c 484264 e6deff d7bbf3 3b2654 533d6c efdbff ffb4ab 690005 93000a ffdad6 8f8f9f 444654 0f101a 090a14 191a24 22232d 2d2d38 383843 e2e1ef c5c5d6 e2e1ef 2f303a 1242ff",
  "m3-indigo/black": "bac3ff 001e91 002eca dee0ff c9c1ea 312c4c 484264 e6deff d7bbf3 3b2654 533d6c efdbff ffb4ab 690005 93000a ffdad6 8f8f9f 444654 000000 000000 0e0f18 181923 22232d 2d2d38 e2e1ef c5c5d6 e2e1ef 2f303a 1242ff",
  "m3-blue/light": "0056d2 ffffff dae2ff 0040a1 5b5b7e ffffff e1dfff 434465 655688 ffffff e9ddff 4d3f6f ba1a1a ffffff ffdad6 93000a 737785 c3c6d6 fefefe ffffff f4f4ff eaebf9 e2e3f1 d8d9e7 181b25 434654 2d303a eff0fe b2c5ff",
  "m3-blue/dark": "b2c5ff 002b72 0040a1 dae2ff c4c3eb 2d2d4d 434465 e1dfff d0bef6 362856 4d3f6f e9ddff ffb4ab 690005 93000a ffdad6 8d909f 434654 0e111a 080b14 171a24 20232e 2b2e38 363944 e0e2ef c3c6d6 e0e2ef 2d303a 0056d2",
  "m3-blue/black": "b2c5ff 002b72 0040a1 dae2ff c4c3eb 2d2d4d 434465 e1dfff d0bef6 362856 4d3f6f e9ddff ffb4ab 690005 93000a ffdad6 8d909f 434654 000000 000000 0c0f19 161923 20232e 2b2e38 e0e2ef c3c6d6 e0e2ef 2d303a 0056d2",
  "m3-teal/light": "006b5e ffffff 00fee2 005047 386668 ffffff bcebee 1e4e50 206777 ffffff aeecff 004e5d ba1a1a ffffff ffdad6 93000a 697b76 b8cac5 f9fffc ffffff eaf8f3 e2f0eb d9e7e2 cfddd8 111e1b 394a46 263330 e5f4ef 00dfc6",
  "m3-teal/dark": "00dfc6 003730 005047 00fee2 a0cfd1 003739 1e4e50 bcebee 90d0e3 003641 004e5d aeecff ffb4ab 690005 93000a ffdad6 839490 394a46 061311 020d0b 101d1a 192623 24312e 2f3c38 d7e6e1 b8cac5 d7e6e1 263330 006b5e",
  "m3-teal/black": "00dfc6 003730 005047 00fee2 a0cfd1 003739 1e4e50 bcebee 90d0e3 003641 004e5d aeecff ffb4ab 690005 93000a ffdad6 839490 394a46 000000 000000 05120f 0f1c19 192623 24312e d7e6e1 b8cac5 d7e6e1 263330 006b5e",
  "m3-green/light": "006e2b ffffff 69ff88 00531e 406653 ffffff c2ecd3 284e3c 22695b ffffff abf0de 005144 ba1a1a ffffff ffdad6 93000a 6e7a6c bdcaba fbfff6 ffffff eef8e9 e5efe0 dde7d8 d3ddce 151e15 3e4a3d 2a3329 eaf4e5 00e561",
  "m3-green/dark": "00e561 003913 00531e 69ff88 a6d0b8 103726 284e3c c2ecd3 8fd4c2 00382e 005144 abf0de ffb4ab 690005 93000a ffdad6 879485 3e4a3d 0a130b 050d06 141d14 1d261d 273127 323c32 dbe5d7 bdcaba dbe5d7 2a3329 006e2b",
  "m3-green/black": "00e561 003913 00531e 69ff88 a6d0b8 103726 284e3c c2ecd3 8fd4c2 00382e 005144 abf0de ffb4ab 690005 93000a ffdad6 879485 3e4a3d 000000 000000 091209 131c13 1d261d 273127 dbe5d7 bdcaba dbe5d7 2a3329 006e2b",
  "m3-yellow/light": "795900 ffffff ffdfa0 5c4300 6b5e2f ffffff f5e2a7 524619 66601f ffffff eee595 4e4807 ba1a1a ffffff ffdad6 93000a 82755f d4c5aa fefefe ffffff fff3e4 f9ebd4 f1e2cb e7d8c2 211b0d 504531 372f20 feefd8 fcbc00",
  "m3-yellow/dark": "fcbc00 402d00 5c4300 ffdfa0 d8c68d 3a2f05 524619 f5e2a7 d2c97c 363100 4e4807 eee595 ffb4ab 690005 93000a ffdad6 9d8f77 504531 161004 100a02 201a0c 2a2314 352d1e 403828 efe1ca d4c5aa efe1ca 372f20 795900",
  "m3-yellow/black": "fcbc00 402d00 5c4300 ffdfa0 d8c68d 3a2f05 524619 f5e2a7 d2c97c 363100 4e4807 eee595 ffb4ab 690005 93000a ffdad6 9d8f77 504531 000000 000000 150f04 1f190b 2a2314 352d1e efe1ca d4c5aa efe1ca 372f20 795900",
  "m3-orange/light": "9f4200 ffffff ffdbcb 7a3000 7c5635 ffffff ffdcc2 623f20 7c571c ffffff ffddb2 614004 ba1a1a ffffff ffdad6 93000a 8b7266 dfc0b3 fefefe ffffff fff2ee fde8df f4e0d7 ead6cd 261811 584238 3d2d25 ffede6 ffb692",
  "m3-orange/dark": "ffb692 562000 7a3000 ffdbcb efbd94 48290c 623f20 ffdcc2 f0be79 452b00 614004 ffddb2 ffb4ab 690005 93000a ffdad6 a68b7f 584238 1b0e08 140804 261710 302019 3b2b23 47352d f8ddd1 dfc0b3 f8ddd1 3d2d25 9f4200",
  "m3-orange/black": "ffb692 562000 7a3000 ffdbcb efbd94 48290c 623f20 ffdcc2 f0be79 452b00 614004 ffddb2 ffb4ab 690005 93000a ffdad6 a68b7f 584238 000000 000000 190c07 25160f 302019 3b2b23 f8ddd1 dfc0b3 f8ddd1 3d2d25 9f4200",
  "m3-red/light": "c0000a ffffff ffdad5 930005 80543e ffffff ffdbcc 653d29 845324 ffffff ffdcc1 683c0e ba1a1a ffffff ffdad6 93000a 8c716d dfbfbb fefefe ffffff fff2f0 fee8e5 f5dfdc ebd5d2 271816 58413e 3d2c2a ffedea ffb4aa",
  "m3-red/dark": "ffb4aa 690003 930005 ffdad5 f4ba9f 4b2715 653d29 ffdbcc fab981 4c2700 683c0e ffdcc1 ffb4ab 690005 93000a ffdad6 a78a86 58413e 1b0d0c 140806 251715 2f201e 3b2a28 463533 f9dcd8 dfbfbb f9dcd8 3d2c2a c0000a",
  "m3-red/black": "ffb4aa 690003 930005 ffdad5 f4ba9f 4b2715 653d29 ffdbcc fab981 4c2700 683c0e ffdcc1 ffb4ab 690005 93000a ffdad6 a78a86 58413e 000000 000000 190c0a 241614 2f201e 3b2a28 f9dcd8 dfbfbb f9dcd8 3d2c2a c0000a",
  "m3-pink/light": "bc004b ffffff ffd9de 900038 82524b ffffff ffdad5 673b35 894f33 ffffff ffdbcc 6d391e ba1a1a ffffff ffdad6 93000a 8a7174 debfc2 fefefe ffffff fff2f2 fde7e8 f4dfe0 ead5d6 26181a 574144 3d2c2e ffecee ffb2be",
  "m3-pink/dark": "ffb2be 660025 900038 ffd9de f6b8af 4c2520 673b35 ffdad5 ffb694 51230a 6d391e ffdbcc ffb4ab 690005 93000a ffdad6 a58a8d 574144 1a0d0f 13080a 241719 2e2022 3a2a2c 453537 f7dcdf debfc2 f7dcdf 3d2c2e bc004b",
  "m3-pink/black": "ffb2be 660025 900038 ffd9de f6b8af 4c2520 673b35 ffdad5 ffb694 51230a 6d391e ffdbcc ffb4ab 690005 93000a ffdad6 a58a8d 574144 000000 000000 180c0e 231618 2e2022 3a2a2c f7dcdf debfc2 f7dcdf 3d2c2e bc004b",
  "m3-neutral/light": "55606a ffffff d9e4f0 3e4852 595f65 ffffff dee3eb 42474e 50606f ffffff d4e4f6 394856 ba1a1a ffffff ffdad6 93000a 777778 c8c6c7 fefdff ffffff f6f4f5 eeeced e5e3e4 dbd9da 1b1c1d 464748 303031 f2f0f1 bdc8d4",
  "m3-neutral/dark": "bdc8d4 27313b 3e4852 d9e4f0 c2c7ce 2b3137 42474e dee3eb b8c8d9 23323f 394856 d4e4f6 ffb4ab 690005 93000a ffdad6 919091 464748 101112 0a0b0c 1a1b1c 232425 2d2e2f 38393a e4e2e3 c8c6c7 e4e2e3 303031 55606a",
  "m3-neutral/black": "bdc8d4 27313b 3e4852 d9e4f0 c2c7ce 2b3137 42474e dee3eb b8c8d9 23323f 394856 d4e4f6 ffb4ab 690005 93000a ffdad6 919091 464748 000000 000000 0f1011 191a1b 232425 2d2e2f e4e2e3 c8c6c7 e4e2e3 303031 55606a",
};

test('十款预设 × 浅 / 深 / 纯黑：ColorScheme 角色与 app buildFushiColorScheme 逐位相同', () => {
  const P = loadPalette();
  for (const [k, row] of Object.entries(APP_TRUTH)) {
    const [key, mode] = k.split('/');
    const s = P.schemeFor(P.specFor(key), mode === 'light' ? 'light' : 'dark', { pureBlack: mode === 'black' });
    const want = row.split(' ');
    ROLE_KEYS.forEach((r, i) => {
      // 中性路径的 on-主色由 app 的 _readableOnColor 决定（真值脚本未复刻），只比其余角色。
      if (key === 'm3-neutral' && /^(onPrimary|onPrimaryContainer|inversePrimary)$/.test(r)) return;
      assert.strictEqual((s[r] & 0xffffff).toString(16).padStart(6, '0'), want[i], k + ' ' + r);
    });
  }
});

test('theme.css ① 缺省调色板 = app 缺省种子（kFushiDefaultSeed）按同一算法派生的值（浅 / 深两块）', () => {
  const P = loadPalette();
  const css = fs.readFileSync(path.join(__dirname, 'theme.css'), 'utf8');
  const lightBlock = /:root \{\n  color-scheme: light dark;\n([\s\S]*?)\n  \/\*/.exec(css)[1];
  const darkBlock = /:root\[data-theme="dark"\] \{\n  color-scheme: dark;\n([\s\S]*?)\n\}/.exec(css)[1];
  const parse = (b) => Object.fromEntries([...b.matchAll(/(--fushi-[a-z-]+): (#[0-9a-f]{6});/g)].map((m) => [m[1], m[2]]));
  assert.deepStrictEqual(parse(lightBlock), JSON.parse(JSON.stringify(P.derive({ seed: P.DEFAULT_SEED }, 'light'))));
  assert.deepStrictEqual(parse(darkBlock), JSON.parse(JSON.stringify(P.derive({ seed: P.DEFAULT_SEED }, 'dark'))));
  const media = /@media \(prefers-color-scheme: dark\) \{\n  :root:not\(\[data-theme="light"\]\) \{\n([\s\S]*?)\n  \}\n\}/.exec(css)[1];
  assert.deepStrictEqual(parse(media), parse(darkBlock));
});
