const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 扩展的材质：液态玻璃是唯一材质（用户 2026-10-04：「浏览器插件的材质默认液态玻璃，然后砍掉
// 之前的样式」）。原先的「材质」设置（extensionMaterial = 跟随 Fushi / 实心 / 玻璃）与 app
// 设计系统镜像（appGlassMirror）一并删除；配色主题（extensionPalette）与材质正交，保留。
// 本测试钉住：
//  ① theme.js 不再有材质决议：扩展页面根不写 data-material，旧存储里的 extensionMaterial /
//     appGlassMirror 读到也忽略，扩展页面启动时清掉（宿主网页不清）；
//  ② content.js 查词弹窗恒上玻璃，只有 app 墨水屏下发 --fushi-glass: '0' 时关；
//  ③ background 不再镜像 app 的玻璃开关；options 页没有材质下拉，17 份文案都已删；
//  ④ glass.css 无条件生效（不挂任何属性开关），带 -webkit- 前缀，保留不支持 backdrop-filter /
//     减少透明度 / 减少动态效果三条兼容回退，且回退压得过暗色块；三个扩展页面在页面 CSS 之后引入；
//  ⑤ options 页的节导航锚点都指向真实存在的节。

const THEME_SRC = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');
const GLASS_CSS = fs.readFileSync(path.join(__dirname, 'glass.css'), 'utf8');

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

// ───────── ① theme.js ─────────

test('theme.js 没有材质决议：不导出 material / resolveGlass，扩展页面根不写 data-material', () => {
  const h = loadTheme({ stored: { extensionMaterial: 'solid', appGlassMirror: false } });
  assert.strictEqual(h.theme.material, undefined);
  assert.strictEqual(h.theme.resolveGlass, undefined);
  assert.strictEqual(h.theme.setMaterial, undefined);
  assert.strictEqual(h.rootAttrs['data-material'], undefined, '旧存储的「实心」读到也忽略');
  h.set({ extensionMaterial: 'glass', extensionTheme: 'dark' });
  assert.strictEqual(h.rootAttrs['data-material'], undefined);
  assert.strictEqual(h.rootAttrs['data-theme'], 'dark', '明暗照旧生效');
  assert.doesNotMatch(THEME_SRC, /data-material/);
});

test('扩展页面启动时清掉旧材质键；宿主网页不清', () => {
  const page = loadTheme({ stored: { extensionMaterial: 'solid', appGlassMirror: true, extensionTheme: 'dark' } });
  assert.deepStrictEqual([...page.removed].sort(), ['appGlassMirror', 'extensionMaterial']);
  assert.ok(!('extensionMaterial' in page.stored));
  assert.strictEqual(page.stored.extensionTheme, 'dark', '只清退役键');
  const host = loadTheme({ protocol: 'https:', stored: { extensionMaterial: 'solid' } });
  assert.deepStrictEqual(host.removed, []);
});

// ───────── ② content.js 查词弹窗 ─────────

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

test('查词弹窗：恒上玻璃，与 theme.js / 旧材质设置无关', () => {
  // theme.js 缺席，以及旧 theme.js 仍带 resolveGlass（返回实心）时都不影响。
  for (const theme of [null, { resolve: (f) => f || 'light', resolveGlass: () => false }]) {
    const s = loadContent(theme);
    const p = fakePopup();
    s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'dark', '--fushi-glass': '1' }, false);
    assert.ok(p.classes.has('fushi-glass'));
    assert.strictEqual(p.hostAttrs['data-fushi-glass'], 'dark');
    const q = fakePopup();
    s.fushiApplyTheme(q.c, { '--fushi-color-scheme': 'light' }, false);
    assert.ok(q.classes.has('fushi-glass'), '缺 key（旧 app）同样是玻璃');
    assert.strictEqual(q.hostAttrs['data-fushi-glass'], 'light');
  }
  const src = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
  assert.doesNotMatch(src, /resolveGlass/);
});

test('查词弹窗：只有墨水屏（--fushi-glass: 0）关玻璃，同一弹窗上即时摘钩子', () => {
  const s = loadContent(null);
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '0' }, false);
  assert.ok(!p.classes.has('fushi-glass'));
  assert.ok(!('data-fushi-glass' in p.hostAttrs));
});

// ───────── ③ background / options / 文案 ─────────

test('background 不再镜像 app 的玻璃开关', () => {
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.doesNotMatch(bg, /appGlassMirror|rememberAppGlass|--fushi-glass/);
});

test('options 页没有材质下拉；17 份文案都没有材质 key', () => {
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  const js = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  assert.doesNotMatch(html, /extensionMaterial/);
  assert.doesNotMatch(js, /extensionMaterial/);
  const dir = path.join(__dirname, 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json') || f === 'en.js');
  assert.strictEqual(files.length, 17);
  for (const f of files) {
    assert.doesNotMatch(fs.readFileSync(path.join(dir, f), 'utf8'), /opt_extensionMaterial_/, f);
  }
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

test('glass.css：无条件生效，不挂任何材质属性开关', () => {
  const css = stripComments(GLASS_CSS);
  const selectors = [];
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
      assert.match(part.trim(), /^:root/, '页面级玻璃规则都从 :root 起：' + part.trim());
    }
  }
  assert.doesNotMatch(css, /data-material/);
});

test('glass.css：模糊带 -webkit- 前缀，明暗两套，三条兼容回退齐全且压得过暗色块', () => {
  const css = stripComments(GLASS_CSS);
  assert.match(css, /-webkit-backdrop-filter:\s*var\(--fushi-glass-filter\)/);
  assert.match(css, /[^-]backdrop-filter:\s*var\(--fushi-glass-filter\)/);
  assert.match(css, /--fushi-glass-filter:\s*blur\(\d+px\) saturate\([\d.]+\)/);
  assert.match(css, /@media \(prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)/);
  assert.match(css, /:root\[data-theme="dark"\]\s*\{/);
  const supportsNot = /@supports not \(\(backdrop-filter: blur\(1px\)\) or \(-webkit-backdrop-filter: blur\(1px\)\)\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(supportsNot, '缺不支持 backdrop-filter 的实心回退');
  assert.match(supportsNot[1], /--fushi-glass-fill:\s*var\(--fushi-surface\)/);
  const reduced = /@media \(prefers-reduced-transparency: reduce\)\s*\{([\s\S]*?)\n\}/.exec(css);
  assert.ok(reduced, '缺减少透明度回退');
  assert.match(reduced[1], /--fushi-glass-fill:\s*var\(--fushi-surface\)/);
  assert.match(reduced[1], /--fushi-glass-filter:\s*none/);
  // 回退的特异性 (0,2,0) 且排在暗色块之后：暗色下实心填充不会被暗色块（同为 (0,2,0)）盖回半透明。
  for (const block of [supportsNot[1], reduced[1]]) {
    assert.match(block, /^\s*:root:is\(\[data-theme\], :not\(\[data-theme\]\)\)\s*\{/);
  }
  assert.ok(css.indexOf('@supports not') > css.lastIndexOf(':root[data-theme="dark"]'));
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

test('options：节导航锚点都指向真实的节', () => {
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  const nav = /<nav class="section-nav" id="sectionNav"[\s\S]*?<\/nav>/.exec(html)[0];
  const targets = [...nav.matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
  assert.ok(targets.length >= 8);
  for (const id of targets) {
    assert.match(html, new RegExp('<section class="section[^"]*" id="' + id + '"'), '节导航指向不存在的节 #' + id);
  }
  const sections = [...html.matchAll(/<section class="section[^"]*" id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(targets, sections, '每个节都要有导航项，顺序一致');
});
