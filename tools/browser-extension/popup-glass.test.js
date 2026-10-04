const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 查词弹窗「玻璃」材质（扩展唯一的材质；只有 app 开墨水屏时随查词响应 theme 下发 --fushi-glass: '0' 关掉）。
// 只有扩展这一宿主里 backdrop-filter 能真模糊：弹窗挂在网页文档的 shadow root 里，背后就是网页；
// app 内弹窗是独立 WebView，文档里卡片背后没有 Flutter 画面可采样，故样式只写在
// scripts/content-css-overlay.css（生成进 vendor/content.css），不进共享 popup.css。
// 本测试钉住：① content.js 给弹窗根 / shadow 宿主挂玻璃钩子（缺 key = 旧 app = 玻璃；'0' = 墨水屏 = 摘）；
// ② 生成的 content.css 里玻璃段整段在 @supports 里、数值与 Flutter 侧同源，减少透明度时回落不透明；
// ③ 玻璃段不碰 popup.css 共享段（app 内弹窗不受影响）。

const CONTENT = path.join(__dirname, 'content.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const CONTENT_CSS = path.join(__dirname, 'vendor', 'content.css');
const POPUP_CSS = path.join(__dirname, 'vendor', 'popup.css');

function loadSandbox() {
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
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  return sandbox;
}

// 弹窗根 #entries-container 与其 shadow 宿主 #hibiki-popup-host 的最小替身。
function fakePopup() {
  const attrs = {};
  const hostAttrs = {};
  const hostVars = {};
  const classes = new Set();
  const host = {
    setAttribute: (k, v) => { hostAttrs[k] = String(v); },
    removeAttribute: (k) => { delete hostAttrs[k]; },
    style: { setProperty: (k, v) => { hostVars[k] = v; } },
  };
  const c = {
    style: { setProperty: () => {} },
    classList: { add: (n) => classes.add(n), remove: (n) => classes.delete(n) },
    setAttribute: (k, v) => { attrs[k] = String(v); },
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    getRootNode: () => ({ host }),
  };
  return { c, classes, hostAttrs, hostVars };
}

test('theme --fushi-glass=1：弹窗根挂 .fushi-glass，宿主挂 data-fushi-glass 与圆角变量', () => {
  const s = loadSandbox();
  const p = fakePopup();
  s.fushiApplyTheme(p.c, {
    '--fushi-color-scheme': 'light', '--fushi-glass': '1', '--fushi-radius-card': '16px',
  }, false);
  assert.ok(p.classes.has('fushi-glass'));
  assert.strictEqual(p.hostAttrs['data-fushi-glass'], 'light');
  assert.strictEqual(p.hostVars['--fushi-radius-card'], '16px',
    '宿主读不到只设在子级 #entries-container 上的圆角变量，必须同值补到宿主');
});

test('暗色主题下宿主标 dark（描边改白 8%）', () => {
  const s = loadSandbox();
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'dark', '--fushi-glass': '1' }, false);
  assert.strictEqual(p.c.getAttribute('data-theme'), 'dark');
  assert.strictEqual(p.hostAttrs['data-fushi-glass'], 'dark');
});

test('墨水屏（--fushi-glass: 0）两个钩子都不在（同一弹窗上切换即时摘掉）；旧 app 不下发该 key 仍是玻璃', () => {
  const s = loadSandbox();
  const p = fakePopup();
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '1' }, false);
  s.fushiApplyTheme(p.c, { '--fushi-color-scheme': 'light', '--fushi-glass': '0' }, false);
  assert.ok(!p.classes.has('fushi-glass'));
  assert.ok(!('data-fushi-glass' in p.hostAttrs));

  const q = fakePopup();
  s.fushiApplyTheme(q.c, { '--fushi-color-scheme': 'light' }, false);
  assert.ok(q.classes.has('fushi-glass'));
  assert.strictEqual(q.hostAttrs['data-fushi-glass'], 'light');
});

// 取出 content.css 里玻璃 @supports 段（花括号配平）。
function glassSupportsBlock(css) {
  const start = css.indexOf('@supports ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px)))');
  assert.ok(start >= 0, 'content.css 缺玻璃 @supports 段——改了 content-css-overlay.css 后要重跑 generate-content-css.mjs');
  let depth = 0;
  for (let i = css.indexOf('{', start); i < css.length; i++) {
    if (css[i] === '{') depth++;
    else if (css[i] === '}' && --depth === 0) return css.slice(start, i + 1);
  }
  throw new Error('unbalanced @supports block');
}

test('content.css：玻璃样式整段在 @supports 内，数值与 Flutter 侧同源', () => {
  const css = fs.readFileSync(CONTENT_CSS, 'utf8');
  const block = glassSupportsBlock(css);
  // 半透明填充：亮 0.72 / 暗 0.62（fushiGlassFillOpacity），用主题下发的卡底 RGB 三元组合成。
  assert.match(block, /#entries-container\.fushi-glass:not\(\.eink\)\s*\{[^}]*rgba\(var\(--fushi-card-bg-rgb[^)]*\),\s*0\.72\)/);
  assert.match(block, /#entries-container\.fushi-glass:not\(\.eink\)\[data-theme="dark"\]\s*\{[^}]*rgba\(var\(--fushi-card-bg-rgb[^)]*\),\s*0\.62\)/);
  // 模糊落在 shadow 宿主上，带 -webkit- 前缀（sigma 20 = kFushiGlassBlurSigma）。
  assert.match(block, /:host\(\[data-fushi-glass\]\)\s*\{[^}]*-webkit-backdrop-filter:\s*blur\(20px\) saturate\(1\.4\)/);
  assert.match(block, /:host\(\[data-fushi-glass\]\)\s*\{[^}]*[^-]backdrop-filter:\s*blur\(20px\) saturate\(1\.4\)/);
  // 细描边（黑/白 8%），用 outline 不占布局。
  assert.match(block, /outline:\s*1px solid rgba\(0, 0, 0, 0\.08\)/);
  assert.match(block, /:host\(\[data-fushi-glass="dark"\]\)\s*\{[^}]*rgba\(255, 255, 255, 0\.08\)/);
  // 减少透明度（兼容层）：宿主不模糊、填充回不透明卡底。
  const reduced = /@media \(prefers-reduced-transparency: reduce\)\s*\{([\s\S]*?)\n    \}/.exec(block);
  assert.ok(reduced, '玻璃段缺减少透明度回退');
  assert.match(reduced[1], /:host\(\[data-fushi-glass\]\)\s*\{[^}]*backdrop-filter:\s*none/);
  assert.match(reduced[1], /background-color:\s*rgb\(var\(--fushi-card-bg-rgb/);
  // @supports 段之外不得再出现任何**材质**（backdrop-filter / 半透明卡底）——不支持时保持不透明。
  // 例外两类：「选择音频源」菜单（.fushi-audio-menu.is-glass / .is-eink）自带材质；共享 popup.css 的
  // 强调色段 `:where(html.fushi-glass-host, .fushi-glass) …` 只给标签 / 按钮上主题主色，不碰材质。
  const outside = css.replace(block, '').replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\.fushi-audio-menu[^{]*\{[^}]*\}/g, '');
  assert.ok(!/backdrop-filter/.test(outside), 'backdrop-filter 漏到 @supports 段外');
  assertGlassHooksAreAccentOnly(outside, '@supports 段外');
});

// 共享 popup.css / content.css 里 @supports 段之外挂着 fushi-glass 钩子的规则，只能是强调色段：
// 选择器以 :where(html.fushi-glass-host, .fushi-glass) 开头，声明里不得有材质（模糊 / 卡片底色）。
// app 内专用的 `html.fushi-glass-host` 透明文档宿主（Flutter 画玻璃卡面）由生成器丢弃，不得进扩展。
function assertGlassHooksAreAccentOnly(css, where) {
  const rule = /([^{}]+)\{([^}]*)\}/g;
  let m;
  while ((m = rule.exec(css))) {
    const sel = m[1].trim();
    if (!/fushi-glass/.test(sel)) continue;
    assert.ok(!/backdrop-filter/.test(m[2]), `${where}的玻璃钩子规则带了模糊：${sel}`);
    if (/^html\.fushi-glass-host/.test(sel)) continue; // app 内透明宿主，只在 popup.css
    for (const part of sel.split(/,(?![^(]*\))/)) {
      assert.match(part.trim(), /^:where\(html\.fushi-glass-host, \.fushi-glass\) /,
        `${where}出现强调色段以外的玻璃钩子：${part.trim()}`);
    }
  }
}

test('共享 popup.css 不含卡片材质（app 内弹窗的玻璃由 Flutter 画，文档里无可模糊的内容）', () => {
  const popupCss = fs.readFileSync(POPUP_CSS, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
    // 音频源菜单浮在同一文档的词条之上，背后有真内容可模糊，是本条的有意例外。
    .replace(/\.fushi-audio-menu[^{]*\{[^}]*\}/g, '');
  assert.ok(!/backdrop-filter/.test(popupCss));
  assertGlassHooksAreAccentOnly(popupCss, 'popup.css ');
  // app 内 Apple 宿主：文档透明（卡面是 Flutter 的玻璃 / 材质面板）。
  assert.match(popupCss, /html\.fushi-glass-host,\s*html\.fushi-glass-host body\s*\{\s*background:\s*transparent;/);
  // 生成器丢弃 app 专用宿主规则，扩展 content.css 里不得出现。
  assert.ok(!/html\.fushi-glass-host body/.test(fs.readFileSync(CONTENT_CSS, 'utf8')));
});
