const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 扩展「材质」设置（用户 2026-10-04：「浏览器插件可以造一套液态玻璃的主题」）。
// 材质与配色正交（同 app 设计系统 glass_material 独立于颜色主题）：
//   extensionMaterial = 'auto'（跟随 Fushi：app 设计系统选了玻璃 → 玻璃）| 'solid' | 'glass'。
// 本测试钉住：
//  ① theme.js resolveGlass 真值表 + 扩展页面根 data-material 随设置 / app 镜像即时切换，
//     宿主网页的 <html> 绝不写；
//  ② content.js 查词弹窗的玻璃钩子经 resolveGlass 决议（显式设置压过 app 下发的 --fushi-glass）；
//  ③ background 把 app 下发的 --fushi-glass 镜像进 appGlassMirror；
//  ④ glass.css：全部规则挂在 :root[data-material="glass"] 下（实心时零影响），带 -webkit- 前缀，
//     有不支持 backdrop-filter / 减少透明度 / 减少动态效果三条回退；三个扩展页面在页面 CSS 之后引入；
//  ⑤ options 页的材质下拉 + 节导航锚点都指向真实存在的节。

const THEME_SRC = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');
const GLASS_CSS = fs.readFileSync(path.join(__dirname, 'glass.css'), 'utf8');

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

function loadTheme(opts) {
  opts = opts || {};
  const stored = Object.assign({}, opts.stored);
  const rootAttrs = {};
  const sandbox = {
    console,
    location: { protocol: opts.protocol || 'chrome-extension:' },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    chrome: { storage: storageMock(stored) },
    document: {
      documentElement: { setAttribute: (k, v) => { rootAttrs[k] = v; }, removeAttribute: (k) => { delete rootAttrs[k]; } },
      createElement: () => ({}),
    },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(THEME_SRC, sandbox, { filename: 'theme.js' });
  return { theme: sandbox.fushiTheme, rootAttrs, set: (p) => sandbox.chrome.storage.local.set(p) };
}

// ───────── ① theme.js ─────────

test('resolveGlass 真值表：显式 glass / solid 压过 app；auto 跟本次 app 开关，缺省跟镜像', () => {
  const h = loadTheme();
  assert.strictEqual(h.theme.material, 'auto', '缺省 = 跟随 Fushi');
  assert.strictEqual(h.theme.resolveGlass(), false, '从未查过词（无镜像）= 实心');
  assert.strictEqual(h.theme.resolveGlass(true), true, 'auto 下查词弹窗跟本次响应');
  assert.strictEqual(h.theme.resolveGlass(false), false);
  h.set({ appGlassMirror: true });
  assert.strictEqual(h.theme.resolveGlass(), true, 'auto 下扩展页面跟 app 设计系统镜像');
  h.set({ extensionMaterial: 'solid' });
  assert.strictEqual(h.theme.resolveGlass(true), false, '显式实心压过 app 的玻璃');
  assert.strictEqual(h.theme.resolveGlass(), false);
  h.set({ extensionMaterial: 'glass', appGlassMirror: false });
  assert.strictEqual(h.theme.resolveGlass(false), true, '显式液态玻璃压过 app 的实心');
  h.set({ extensionMaterial: 'bogus' });
  assert.strictEqual(h.theme.material, 'auto', '坏值当 auto');
});

test('扩展页面：根 data-material 随设置与 app 镜像即时切换', () => {
  const h = loadTheme({ stored: { extensionMaterial: 'glass' } });
  assert.strictEqual(h.rootAttrs['data-material'], 'glass');
  h.set({ extensionMaterial: 'solid' });
  assert.strictEqual(h.rootAttrs['data-material'], undefined);
  h.set({ extensionMaterial: 'auto' });
  assert.strictEqual(h.rootAttrs['data-material'], undefined, 'auto + 无镜像 = 实心');
  h.set({ appGlassMirror: true });
  assert.strictEqual(h.rootAttrs['data-material'], 'glass', '「跟随 Fushi」：app 选了玻璃即玻璃');
  h.set({ appGlassMirror: false });
  assert.strictEqual(h.rootAttrs['data-material'], undefined);
});

test('宿主网页：绝不往 <html> 写 data-material', () => {
  const h = loadTheme({ protocol: 'https:', stored: { extensionMaterial: 'glass', appGlassMirror: true } });
  assert.strictEqual(h.rootAttrs['data-material'], undefined);
  assert.strictEqual(h.theme.resolveGlass(false), true, '但查词弹窗仍按设置决议');
});

// ───────── ② content.js 查词弹窗 ─────────

function loadContent(resolveGlass) {
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
  if (resolveGlass) {
    sandbox.window.fushiTheme = { resolve: (f) => f || 'light', resolveGlass };
  }
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

test('查词弹窗：玻璃开关经 theme.js resolveGlass 决议（显式设置压过 app 下发）', () => {
  const seen = [];
  // 设置 = 液态玻璃：app 下发实心也上玻璃。
  const forced = loadContent((app) => { seen.push(app); return true; });
  const p = fakePopup();
  forced.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'dark', '--fushi-glass': '0' }, false);
  assert.deepStrictEqual(seen, [false], 'resolveGlass 收到的是本次响应的 app 开关');
  assert.ok(p.classes.has('fushi-glass'));
  assert.strictEqual(p.hostAttrs['data-fushi-glass'], 'dark');
  // 设置 = 实心：app 下发玻璃也不上。
  const off = loadContent(() => false);
  const q = fakePopup();
  off.fushiApplyTheme(q.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  assert.ok(!q.classes.has('fushi-glass'));
  assert.ok(!('data-fushi-glass' in q.hostAttrs));
});

test('查词弹窗：theme.js 缺席时退回 app 开关（与加设置前一致）', () => {
  const s = loadContent(null);
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  assert.ok(p.classes.has('fushi-glass'));
});

// ───────── ③ background 镜像 ─────────

test('background：app 下发的 --fushi-glass 镜像进 appGlassMirror（缺 key 不写、同值不重写）', () => {
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  const start = bg.indexOf('function rememberAppGlass(');
  assert.ok(start >= 0);
  const body = bg.slice(start, bg.indexOf('\n}\n', start));
  assert.match(body, /if \(v !== '1' && v !== '0'\) return;/);
  assert.match(body, /if \(glass === appGlassMirror\) return;/);
  assert.match(body, /chrome\.storage\.local\.set\(\{ appGlassMirror: glass \}\)/);
  const remember = bg.slice(bg.indexOf('function rememberAppTheme('));
  assert.match(remember.slice(0, 200), /rememberAppGlass\(theme\);/, '颜色键不全时也要先镜像玻璃开关');
});

// ───────── ④ glass.css ─────────

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

test('glass.css：每条规则都挂在 :root[data-material="glass"] 下（实心时一条不生效）', () => {
  const css = stripComments(GLASS_CSS);
  const selectors = [];
  // 取出每个规则块的选择器（跳过 @supports / @media 包裹行本身）。
  const re = /([^{}]+)\{/g;
  let m;
  while ((m = re.exec(css))) {
    const sel = m[1].trim();
    if (!sel || sel.startsWith('@')) continue;
    selectors.push(sel);
  }
  assert.ok(selectors.length > 10);
  for (const sel of selectors) {
    for (const part of splitTopLevel(sel)) {
      assert.match(part.trim(), /^:root\[data-material="glass"\]/, '未挂材质属性的选择器：' + part.trim());
    }
  }
});

test('glass.css：模糊带 -webkit- 前缀，明暗两套，三条回退齐全', () => {
  const css = stripComments(GLASS_CSS);
  assert.match(css, /-webkit-backdrop-filter:\s*var\(--fushi-glass-filter\)/);
  assert.match(css, /[^-]backdrop-filter:\s*var\(--fushi-glass-filter\)/);
  assert.match(css, /--fushi-glass-filter:\s*blur\(\d+px\) saturate\([\d.]+\)/);
  assert.match(css, /@media \(prefers-color-scheme: dark\)\s*\{\s*:root\[data-material="glass"\]:not\(\[data-theme="light"\]\)/);
  assert.match(css, /:root\[data-material="glass"\]\[data-theme="dark"\]\s*\{/);
  const supportsNot = /@supports not \(\(backdrop-filter: blur\(1px\)\) or \(-webkit-backdrop-filter: blur\(1px\)\)\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(supportsNot, '缺不支持 backdrop-filter 的实心回退');
  assert.match(supportsNot[1], /--fushi-glass-fill:\s*var\(--fushi-surface\)/);
  const reduced = /@media \(prefers-reduced-transparency: reduce\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(reduced, '缺减少透明度回退');
  assert.match(reduced[1], /--fushi-glass-fill:\s*var\(--fushi-surface\)/);
  assert.match(reduced[1], /--fushi-glass-filter:\s*none/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  // 颜色来自调色板：表面填充都是 --fushi-surface 的半透明混合，不另起一套底色。
  assert.match(css, /--fushi-glass-fill:\s*color-mix\(in oklch, var\(--fushi-surface\) \d+%, transparent\)/);
});

test('三个扩展页面在页面样式之后引入 glass.css；侧栏被抽屉 iframe 嵌入时可取到', () => {
  for (const [page, href, after] of [
    ['options.html', 'glass.css', 'options.css'],
    ['side-panel.html', 'glass.css', 'side-panel.css'],
    ['vendor/action-popup.html', '../glass.css', '</style>'],
  ]) {
    const html = fs.readFileSync(path.join(__dirname, page), 'utf8');
    const at = html.indexOf('href="' + href + '"');
    assert.ok(at >= 0, page + ' 未引入 glass.css');
    assert.ok(html.indexOf(after) < at, page + ' 要在页面样式之后引入 glass.css（同特异性时后者赢）');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  assert.ok(manifest.web_accessible_resources.some((r) => r.resources.includes('glass.css')));
});

// ───────── ⑤ options 页 ─────────

test('options：材质下拉三档并持久化到 extensionMaterial；节导航锚点都指向真实的节', () => {
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  const js = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  const select = /<select class="select-input" id="extensionMaterial">([\s\S]*?)<\/select>/.exec(html);
  assert.ok(select, 'options.html 缺材质下拉');
  const values = [...select[1].matchAll(/value="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(values, ['auto', 'solid', 'glass']);
  assert.match(js, /extensionMaterial: \{ key: 'extensionMaterial', fallback: 'auto' \}/);
  const nav = /<nav class="section-nav" id="sectionNav"[\s\S]*?<\/nav>/.exec(html)[0];
  const targets = [...nav.matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
  assert.ok(targets.length >= 8);
  for (const id of targets) {
    assert.match(html, new RegExp('<section class="section[^"]*" id="' + id + '"'), '节导航指向不存在的节 #' + id);
  }
  const sections = [...html.matchAll(/<section class="section[^"]*" id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(targets, sections, '每个节都要有导航项，顺序一致');
});
