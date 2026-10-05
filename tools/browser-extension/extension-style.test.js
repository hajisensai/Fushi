const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 扩展的外观风格（用户 2026-10-05：「浏览器插件重写样式两套样式 M3E 和液态玻璃，而且配置项现在很多
// 信息过载，重新设计」）。取代 2026-10-04「液态玻璃是唯一材质」的守卫。本测试钉住：
//  ① theme.js：extensionStyle（glass 缺省 / m3e）是唯一决议点，扩展页面根写 data-style，与明暗 /
//     调色板正交；宿主网页的 <html> 不碰；退役的 extensionMaterial / appGlassMirror 照旧只清理；
//  ② 页内查词弹窗：玻璃风格挂玻璃钩子，M3E 不挂、宿主 data-style=m3e（实色卡），墨水屏两者都不透；
//     嵌套子层与第一层同一套 M3E 圆角 / 投影；toast / 拖放提示随风格；
//  ③ token 只在 theme.css（形状 / 材质 / 动效），material.css 只消费；兼容层与 M3E 块的层叠顺序；
//  ④ 设置页：风格单选卡；六组信息架构、一项一行说明、常显项上限、「更多」条数角标、控件一个不丢；
//  ⑤ 工具栏菜单只放三个最高频开关，缺省值与设置页一致。

const THEME_SRC = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');

function storageMock(stored, removed) {
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
      remove: (keys) => {
        for (const k of [].concat(keys)) { removed.push(k); delete stored[k]; }
        return Promise.resolve();
      },
    },
    onChanged: { addListener: (fn) => changeListeners.push(fn) },
  };
}

function loadTheme(opts) {
  opts = opts || {};
  const stored = Object.assign({}, opts.stored);
  const removed = [];
  const rootAttrs = {};
  const sandbox = {
    console,
    location: { protocol: opts.protocol || 'chrome-extension:' },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    chrome: { storage: storageMock(stored, removed) },
    document: {
      documentElement: { setAttribute: (k, v) => { rootAttrs[k] = v; }, removeAttribute: (k) => { delete rootAttrs[k]; } },
      createElement: () => ({}),
    },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(THEME_SRC, sandbox, { filename: 'theme.js' });
  return { theme: sandbox.fushiTheme, rootAttrs, stored, removed, set: (p) => sandbox.chrome.storage.local.set(p) };
}



// ───────── ① theme.js：风格决议 ─────────

test('theme.js：extensionStyle 缺省 = 玻璃，m3e 生效，非法值回落玻璃；扩展页面根写 data-style', () => {
  const def = loadTheme({});
  assert.strictEqual(def.theme.style, 'glass');
  assert.strictEqual(def.theme.usesGlass(), true);
  assert.strictEqual(def.rootAttrs['data-style'], 'glass');
  const m3e = loadTheme({ stored: { extensionStyle: 'm3e' } });
  assert.strictEqual(m3e.theme.style, 'm3e');
  assert.strictEqual(m3e.theme.usesGlass(), false);
  assert.strictEqual(m3e.rootAttrs['data-style'], 'm3e');
  const bad = loadTheme({ stored: { extensionStyle: 'solid' } });
  assert.strictEqual(bad.theme.style, 'glass', '旧「实心」等未知值回落玻璃');
});

test('theme.js：改设置即切风格，与明暗 / 调色板互不影响', () => {
  const h = loadTheme({ stored: { extensionTheme: 'dark' } });
  h.set({ extensionStyle: 'm3e' });
  assert.strictEqual(h.rootAttrs['data-style'], 'm3e');
  assert.strictEqual(h.rootAttrs['data-theme'], 'dark', '风格不动明暗');
  h.set({ extensionTheme: 'light' });
  assert.strictEqual(h.rootAttrs['data-style'], 'm3e', '明暗不动风格');
  h.set({ extensionStyle: 'glass' });
  assert.strictEqual(h.rootAttrs['data-style'], 'glass');
});

test('theme.js：宿主网页的 <html> 不写 data-style；旧「材质」键只在扩展页面清', () => {
  const host = loadTheme({ protocol: 'https:', stored: { extensionStyle: 'm3e', extensionMaterial: 'solid' } });
  assert.strictEqual(host.rootAttrs['data-style'], undefined);
  assert.strictEqual(host.theme.style, 'm3e', '宿主页里浮层仍能问到风格');
  assert.deepStrictEqual(host.removed, []);
  const page = loadTheme({ stored: { extensionMaterial: 'solid', appGlassMirror: true, extensionStyle: 'm3e' } });
  assert.deepStrictEqual([...page.removed].sort(), ['appGlassMirror', 'extensionMaterial']);
  assert.strictEqual(page.stored.extensionStyle, 'm3e', '只清退役键');
});

// ───────── ② 页内查词弹窗（content.js / nested-popup-host.js） ─────────
function loadContent(fushiTheme) {
  const noop = () => {};
  const el = () => ({
    style: { cssText: '', setProperty: noop, getPropertyValue: () => '' },
    dataset: {}, classList: { add: noop, remove: noop }, children: [],
    setAttribute: noop, getAttribute: () => null, appendChild: (c) => c,
    insertBefore: (c) => c, remove: noop, contains: () => false, addEventListener: noop,
    attachShadow: () => ({ appendChild: noop, getElementById: () => null }),
    getBoundingClientRect: () => ({ x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }),
  });
  const sandbox = {
    console: { log: noop, warn: noop, error: noop },
    setTimeout: () => 0, clearTimeout: noop, requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'example.com', href: 'https://example.com/p', pathname: '/p' },
    navigator: { userAgent: 'node-test' },
  };
  sandbox.document = {
    documentElement: el(), body: el(), fullscreenElement: null,
    addEventListener: noop, removeEventListener: noop,
    getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    createElement: () => el(), createTextNode: () => ({}),
    createRange: () => ({ setStart: noop, setEnd: noop, getClientRects: () => [] }),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: { id: 'test-ext-id', lastError: null, onMessage: { addListener: noop }, sendMessage: noop },
    storage: { local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener: noop } },
  };
  sandbox.window = {
    addEventListener: noop, innerWidth: 1200, innerHeight: 800,
    matchMedia: () => ({ matches: false, addEventListener: noop }),
    flutter_inappwebview: { callHandler: noop },
  };
  if (fushiTheme) sandbox.window.fushiTheme = fushiTheme;
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'vendor', 'dict-media.js'), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8'), sandbox, { filename: 'content.js' });
  return sandbox;
}

function fakePopup() {
  const hostAttrs = {};
  const classes = new Set();
  const host = {
    setAttribute: (k, v) => { hostAttrs[k] = String(v); },
    removeAttribute: (k) => { delete hostAttrs[k]; },
    style: { setProperty: () => {} },
  };
  const attrs = {};
  const c = {
    style: { setProperty: () => {} },
    classList: { add: (n) => classes.add(n), remove: (n) => classes.delete(n) },
    setAttribute: (k, v) => { attrs[k] = String(v); },
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    getRootNode: () => ({ host }),
  };
  return { c, classes, hostAttrs };
}


test('查词弹窗：玻璃风格上玻璃钩子 + 宿主 data-style=glass', () => {
  for (const theme of [null, { style: 'glass', resolve: (f) => f || 'light' }]) {
    const s = loadContent(theme);
    const p = fakePopup();
    s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'dark', '--fushi-glass': '1' }, false);
    assert.ok(p.classes.has('fushi-glass'));
    assert.strictEqual(p.hostAttrs['data-fushi-glass'], 'dark');
    assert.strictEqual(p.hostAttrs['data-style'], 'glass');
  }
});

test('查词弹窗：M3E 风格不挂玻璃钩子，宿主 data-style=m3e；同一弹窗切回玻璃即时恢复', () => {
  const theme = { style: 'm3e', resolve: (f) => f || 'light' };
  const s = loadContent(theme);
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  assert.ok(!p.classes.has('fushi-glass'));
  assert.ok(!('data-fushi-glass' in p.hostAttrs));
  assert.strictEqual(p.hostAttrs['data-style'], 'm3e');
  theme.style = 'glass';
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  assert.ok(p.classes.has('fushi-glass'));
  assert.strictEqual(p.hostAttrs['data-style'], 'glass');
});

test('查词弹窗：墨水屏（--fushi-glass: 0）两种风格都不上玻璃', () => {
  const s = loadContent(null);
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '0' }, false);
  assert.ok(!p.classes.has('fushi-glass'));
  assert.ok(!('data-fushi-glass' in p.hostAttrs));
});

test('M3E 查词卡：嵌套子层外框的圆角 / 投影与第一层 content.css 逐字相同', () => {
  const host = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
  const radius = /FUSHI_M3E_LAYER_RADIUS = '([^']+)'/.exec(host)[1];
  const shadow = /FUSHI_M3E_LAYER_SHADOW = '([^']+)'/.exec(host)[1];
  const overlay = fs.readFileSync(path.join(__dirname, 'scripts', 'content-css-overlay.css'), 'utf8');
  const rule = /:host\(\[data-style="m3e"\]\)\s*\{([^}]*)\}/.exec(overlay);
  assert.ok(rule, 'content-css-overlay.css 缺 M3E 宿主规则');
  assert.match(rule[1], new RegExp('border-radius:\\s*' + radius.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ';'));
  assert.strictEqual(/box-shadow:\s*([^;]+);/.exec(rule[1])[1].trim(), shadow);
  // 子层也按风格决定玻璃：M3E 下 fushiNestedGlass 直接 false。
  assert.match(host, /function fushiNestedGlass\(theme\) \{\s*if \(fushiNestedStyle\(\) !== 'glass'\) return false;/);
  // toast / 拖放提示：创建它们的脚本写 data-style，玻璃段只认非 M3E。
  assert.match(fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8'), /t\.setAttribute\('data-style', fushiExtensionStyle\(\)\)/);
  assert.match(fs.readFileSync(path.join(__dirname, 'subtitle-panel.js'), 'utf8'), /st\.dropHint\.setAttribute\('data-style'/);
  assert.match(overlay, /html #fushi-toast:not\(\[data-style="m3e"\]\)/);
  assert.match(overlay, /html #fushi-toast\[data-style="m3e"\]\s*\{/);
});

// ───────── ③ token：theme.css 是唯一来源 ─────────
function stripComments(css) { return css.replace(/\/\*[\s\S]*?\*\//g, ''); }

// 只按顶层逗号拆选择器列表（:is(...) / :not(...) 里的逗号不拆）。
function splitTopLevel(sel) {
  const parts = [];
  let depth = 0;
  let cur = '';
  for (const ch of sel) {
    if (ch === '(') depth++;
    else if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { parts.push(cur); cur = ''; } else cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  return parts;
}

const THEME_CSS = fs.readFileSync(path.join(__dirname, 'theme.css'), 'utf8');

function block(css, selector) {
  const at = css.lastIndexOf(selector + ' {');
  assert.ok(at >= 0, '缺块 ' + selector);
  return css.slice(at, css.indexOf('}', at));
}

test('theme.css：两套风格的形状 / 材质 / 动效 token 都在这里；M3E 块排在玻璃明暗块与兼容层之后', () => {
  const css = stripComments(THEME_CSS);
  for (const t of ['--fushi-shape-card', '--fushi-shape-control', '--fushi-shape-control-pressed', '--fushi-shape-field',
    '--fushi-shape-menu', '--fushi-ease', '--fushi-ease-spatial', '--fushi-dur-medium', '--fushi-mat-fill', '--fushi-mat-filter']) {
    assert.match(css, new RegExp(t + ':'), '缺 token ' + t);
  }
  assert.match(css, /--fushi-mat-filter:\s*blur\(20px\) saturate\([\d.]+\)/, '玻璃模糊与 app kFushiGlassBlurSigma 同源');
  const m3e = block(css, ':root[data-style="m3e"]');
  assert.match(m3e, /--fushi-mat-filter:\s*none/);
  assert.match(m3e, /--fushi-mat-fill:\s*var\(--fushi-surface\)/);
  assert.match(m3e, /--fushi-mat-orb-strength:\s*0%/);
  assert.match(m3e, /--fushi-shape-control-pressed:\s*\d+px/, 'M3E 按压形变');
  assert.match(m3e, /--fushi-ease-spatial:\s*cubic-bezier\(/);
  const at = css.indexOf(':root[data-style="m3e"]');
  assert.ok(at > css.lastIndexOf(':root[data-theme="dark"]'), 'M3E 块要压得过玻璃暗色块');
  assert.ok(at > css.lastIndexOf('@media (prefers-reduced-transparency: reduce)'), 'M3E 块要压得过玻璃兼容层');
  // 兼容层：不支持 backdrop-filter / 减少透明度 → 玻璃填充回实心。
  const supportsNot = /@supports not \(\(backdrop-filter: blur\(1px\)\) or \(-webkit-backdrop-filter: blur\(1px\)\)\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(supportsNot);
  assert.match(supportsNot[1], /--fushi-mat-fill:\s*var\(--fushi-surface\)/);
  const reduced = /@media \(prefers-reduced-transparency: reduce\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(reduced);
  assert.match(reduced[1], /--fushi-mat-filter:\s*none/);
});

test('material.css：全部从 :root 起、只消费 token（不写风格数值），模糊带 -webkit-，有减少动态效果归零', () => {
  const css = stripComments(fs.readFileSync(path.join(__dirname, 'material.css'), 'utf8'));
  const re = /([^{}]+)\{/g;
  let m;
  let n = 0;
  while ((m = re.exec(css))) {
    const sel = m[1].trim();
    if (!sel || sel.startsWith('@')) continue;
    n++;
    for (const part of splitTopLevel(sel)) assert.match(part.trim(), /^:root/, '页面级材质规则都从 :root 起：' + part.trim());
  }
  assert.ok(n > 30);
  assert.doesNotMatch(css, /--fushi-mat-[a-z-]+\s*:/, 'material.css 不定义材质 token（只在 theme.css）');
  assert.doesNotMatch(css, /backdrop-filter:\s*blur\(/, '模糊数值只在 theme.css');
  assert.match(css, /-webkit-backdrop-filter:\s*var\(--fushi-mat-filter\)/);
  assert.match(css, /[^-]backdrop-filter:\s*var\(--fushi-mat-filter\)/);
  assert.match(css, /:root\[data-style="m3e"\] :is\(\.setting-list > \.setting-row, \.hp-group > \.hp-toggle\)/, 'M3E 分段列表');
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
});

test('三个扩展页面在页面样式之后引入 material.css；侧栏被抽屉 iframe 嵌入时可取到；旧 glass.css 已删', () => {
  for (const [page, href, after] of [
    ['options.html', 'material.css', 'options.css'],
    ['side-panel.html', 'material.css', 'side-panel.css'],
    ['vendor/action-popup.html', '../material.css', '</style>'],
  ]) {
    const html = fs.readFileSync(path.join(__dirname, page), 'utf8');
    const at = html.indexOf('href="' + href + '"');
    assert.ok(at >= 0, page + ' 未引入 material.css');
    assert.ok(html.indexOf(after) < at, page + ' 要在页面样式之后引入 material.css（同特异性时后者赢）');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  assert.ok(manifest.web_accessible_resources.some((r) => r.resources.includes('material.css')));
  assert.ok(!fs.existsSync(path.join(__dirname, 'glass.css')));
});

// ───────── ④ 设置页：风格选择 + 信息架构 ─────────

const OPTIONS_HTML = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
const OPTIONS_JS = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');

test('options：外观组有两张风格单选卡（glass / m3e），options.js 写 extensionStyle；文案在 en.js', () => {
  const values = [...OPTIONS_HTML.matchAll(/<input type="radio" name="extensionStyle" value="([^"]+)">/g)].map((m) => m[1]);
  assert.deepStrictEqual(values, ['glass', 'm3e']);
  assert.match(OPTIONS_JS, /chrome\.storage\.local\.set\(\{ extensionStyle: r\.value \}\)/);
  assert.doesNotMatch(OPTIONS_HTML + OPTIONS_JS, /extensionMaterial/);
  const en = fs.readFileSync(path.join(__dirname, 'locales', 'en.js'), 'utf8');
  for (const k of ['opt_extensionStyle_title', 'opt_extensionStyle_option_glass', 'opt_extensionStyle_option_m3e']) {
    assert.match(en, new RegExp('^  ' + k + ': ', 'm'));
  }
});

test('options：节导航锚点与六个任务组一一对应，顺序一致', () => {
  const nav = /<nav class="section-nav" id="sectionNav"[\s\S]*?<\/nav>/.exec(OPTIONS_HTML)[0];
  const targets = [...nav.matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
  const sections = [...OPTIONS_HTML.matchAll(/<section class="section[^"]*" id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(targets, sections);
  assert.deepStrictEqual(sections, ['sec-lookup', 'sec-subtitle', 'sec-subtitle-style', 'sec-appearance', 'sec-shortcut', 'sec-advanced']);
});

test('options 信息架构：每项最多一行说明；查词 / 字幕 / 字幕外观常显项 ≤ 5，其余进「更多选项」', () => {
  for (const part of OPTIONS_HTML.split('class="setting-row').slice(1)) {
    const at = part.indexOf('class="setting-copy"');
    const row = at >= 0 ? part.slice(at, part.indexOf('</span>', at)) : '';
    const smalls = (row.match(/<small(?! class="font-library-note")/g) || []).length;
    assert.ok(smalls <= 1, '一项只留一行说明：' + row.slice(0, 160));
  }
  for (const id of ['sec-lookup', 'sec-subtitle', 'sec-subtitle-style']) {
    const sec = new RegExp('<section class="section" id="' + id + '"[\\s\\S]*?</section>').exec(OPTIONS_HTML)[0];
    const visible = sec.slice(0, sec.indexOf('<details class="more"'));
    const rows = (visible.match(/class="setting-row/g) || []).length;
    assert.ok(rows >= 3 && rows <= 5, id + ' 常显 ' + rows + ' 项');
    const count = Number(/<span class="more-count">(\d+)<\/span>/.exec(sec)[1]);
    const hidden = sec.slice(sec.indexOf('<details class="more"'));
    assert.strictEqual(count, (hidden.match(/class="setting-row/g) || []).length, id + ' 「更多选项」条数角标要与实际一致');
  }
});

test('options：重组不丢功能——options.js 绑定的每个开关 / 下拉 / 字幕外观控件在页面上都还在', () => {
  const ids = new Set();
  for (const block of [/const toggleIds = Object\.freeze\(\{([\s\S]*?)\}\);/, /const selectSettings = Object\.freeze\(\{([\s\S]*?)\}\);/,
    /const subtitleStyleFields = Object\.freeze\(\{([\s\S]*?)\}\);/]) {
    const body = block.exec(OPTIONS_JS)[1];
    for (const m of body.matchAll(/^\s*(\w+):/gm)) ids.add(m[1]);
  }
  for (const id of ['popupSizeWidth', 'popupSizeHeight', 'resetSubtitleOverlayPosition', 'resetSubtitleStyle', 'paletteGrid',
    'host', 'port', 'token', 'lookupPerfOutput', 'updateCard']) ids.add(id);
  assert.ok(ids.size > 50);
  for (const id of ids) assert.match(OPTIONS_HTML, new RegExp('id="' + id + '"'), 'options.html 丢了控件 #' + id);
});

// ───────── ⑤ 工具栏菜单：只放最高频的开关 ─────────

test('工具栏菜单：快捷开关缺省值与设置页 settingDefaults 逐项一致', () => {
  const ap = require('./vendor/action-popup.js');
  const defaults = /const settingDefaults = Object\.freeze\(\{([\s\S]*?)\}\);/.exec(OPTIONS_JS)[1];
  for (const [key, value] of Object.entries(ap.FUSHI_AP_QUICK_DEFAULTS)) {
    const m = new RegExp('^\\s*' + key + ':\\s*(true|false),', 'm').exec(defaults);
    assert.ok(m, 'settingDefaults 缺 ' + key);
    assert.strictEqual(String(value), m[1], key + ' 缺省值与设置页不一致');
    assert.strictEqual(ap.fushiQuickToggleOn(key, {}), value);
    assert.strictEqual(ap.fushiQuickToggleOn(key, { [key]: !value }), !value);
  }
  const html = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.html'), 'utf8');
  const keys = [...html.matchAll(/class="hp-toggle hp-quick-toggle"[^>]*data-key="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(keys.sort(), Object.keys(ap.FUSHI_AP_QUICK_DEFAULTS).sort());
  // 菜单里的开关总数控制在三个（含「Fushi 字幕」）。
  assert.strictEqual((html.match(/class="hp-toggle /g) || []).length, 3);
});
