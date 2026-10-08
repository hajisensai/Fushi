const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 「选择音频源」菜单（右键 / 长按 ♪）的落点与文案。用户报：菜单不贴音频按钮、落在弹窗
// 右缘下方约 50px、被弹窗宿主（固定尺寸、overflow 滚动、带 backdrop-filter 的 shadow host）
// 裁掉右半边；每项都显示「Anki」、真正的源名挤到第二行被截断。
// 与 popup-visible-viewport.test.js 同一做法：把 popup.js 的真源码切片丢进 vm 执行。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');
const SRC = fs.readFileSync(POPUP, 'utf8');

function sliceFunction(header) {
  const start = SRC.indexOf(header);
  assert.ok(start >= 0, `切片锚失效：找不到 ${header}`);
  const end = SRC.indexOf('\n}\n', start);
  assert.ok(end > start, `切片锚失效：${header} 没有收尾`);
  return SRC.slice(start, end + 3);
}

function load(extra) {
  const ctx = { Math, String, Array, Set, URL, ...(extra || {}) };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext([
    sliceFunction('function computeAudioMenuPlacement('),
    sliceFunction('function audioMenuItemLabel('),
    sliceFunction('function audioMenuShowsSource('),
    sliceFunction('function __fushiAudioMenuMount('),
  ].join('\n'), ctx);
  return ctx;
}

const rect = (left, top, width, height) =>
  ({ left, top, width, height, right: left + width, bottom: top + height });

test('默认落在按钮下方 6px、右缘对齐按钮右缘', () => {
  const { computeAudioMenuPlacement } = load();
  const btn = rect(300, 20, 28, 28); // right 328, bottom 48
  const bounds = { left: 0, top: 0, right: 400, bottom: 360 };
  const p = computeAudioMenuPlacement(btn, 220, 180, bounds, 6, 8);
  assert.strictEqual(p.placement, 'below');
  assert.strictEqual(p.top, 54);
  assert.strictEqual(p.left + 220, 328);
  // 展开动画从贴按钮的那个角长出来。
  assert.strictEqual(p.originX, 220);
});

test('下方放不下且上方更宽裕时翻到上方，底边贴按钮上方 6px', () => {
  const { computeAudioMenuPlacement } = load();
  const btn = rect(300, 300, 28, 28);
  const bounds = { left: 0, top: 0, right: 400, bottom: 360 };
  const p = computeAudioMenuPlacement(btn, 220, 180, bounds, 6, 8);
  assert.strictEqual(p.placement, 'above');
  assert.strictEqual(p.top + 180, 294);
});

test('两边都放不下：取较宽裕的一侧并限高，不越出可见区', () => {
  const { computeAudioMenuPlacement } = load();
  const btn = rect(300, 100, 28, 28);
  const bounds = { left: 0, top: 0, right: 400, bottom: 260 };
  const p = computeAudioMenuPlacement(btn, 220, 400, bounds, 6, 8);
  assert.strictEqual(p.placement, 'below');
  assert.ok(p.top + p.maxHeight <= bounds.bottom - 8 + 1e-9);
});

test('横向夹进弹窗可见区（两侧留 8px），不被右缘裁掉', () => {
  const { computeAudioMenuPlacement } = load();
  // 按钮贴近左缘：右对齐会越出左边。
  const nearLeft = computeAudioMenuPlacement(rect(20, 20, 28, 28), 220, 120,
    { left: 0, top: 0, right: 400, bottom: 360 }, 6, 8);
  assert.strictEqual(nearLeft.left, 8);
  // 可见区右缘（扣掉滚动条后的宿主内侧）比按钮右缘还靠左：夹回可见区。
  const clipped = computeAudioMenuPlacement(rect(360, 20, 28, 28), 220, 120,
    { left: 100, top: 0, right: 370, bottom: 360 }, 6, 8);
  assert.ok(clipped.left + 220 <= 370 - 8);
  assert.ok(clipped.left >= 100 + 8);
  // 可见区比菜单还窄：贴左边距，不出现负宽。
  const narrow = computeAudioMenuPlacement(rect(100, 20, 28, 28), 220, 120,
    { left: 0, top: 0, right: 200, bottom: 360 }, 6, 8);
  assert.strictEqual(narrow.left, 8);
});

test('菜单项：列表型源的具体源名作主标签，配置名降为副标签', () => {
  const { audioMenuItemLabel } = load();
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(audioMenuItemLabel({ name: 'Anki', variant: 'NHK16' }, 'よむ'))),
    { primary: 'NHK16', secondary: 'Anki' });
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(audioMenuItemLabel({ name: '本地音频库', variant: '' }, 'よむ'))),
    { primary: '本地音频库', secondary: '' });
  // 旧宿主退化项（无名）：用读音兜底。
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(audioMenuItemLabel({ name: '', variant: '' }, 'よむ'))),
    { primary: 'よむ', secondary: '' });
  // 配置名与源名相同不重复显示。
  assert.strictEqual(audioMenuItemLabel({ name: 'Forvo', variant: 'Forvo' }, '').secondary, '');
});

test('菜单项：未填参的格式占位符（「TAAS %s」）不外露，剥空就退回配置名 / 域名', () => {
  const { audioMenuItemLabel } = load();
  assert.strictEqual(audioMenuItemLabel({ name: 'Anki', variant: 'TAAS %s' }, 'てにす').primary, 'TAAS');
  assert.strictEqual(audioMenuItemLabel({ name: 'Anki', variant: '%s' }, 'てにす').primary, 'Anki');
  assert.strictEqual(audioMenuItemLabel({ name: '%1$s', variant: '',
    url: 'https://audio.example.org/a.mp3' }, 'てにす').primary, 'audio.example.org');
  assert.strictEqual(audioMenuItemLabel({ name: 'Forvo (%s)', variant: '' }, '').primary, 'Forvo');
});

test('副标签只在有信息量时显示：全部来自同一个配置源就收成单行', () => {
  const { audioMenuShowsSource, audioMenuItemLabel } = load();
  const same = [{ name: 'Anki', variant: 'NHK16' }, { name: 'Anki', variant: 'Forvo (poyotan)' }];
  assert.strictEqual(audioMenuShowsSource(same), false);
  assert.strictEqual(audioMenuItemLabel(same[0], '', audioMenuShowsSource(same)).secondary, '');
  const mixed = [{ name: 'Anki', variant: 'NHK16' }, { name: '手机', variant: 'NHK16' }];
  assert.strictEqual(audioMenuShowsSource(mixed), true);
  assert.strictEqual(audioMenuItemLabel(mixed[1], '', true).secondary, '手机');
});

test('菜单不透明度：玻璃下亮 96% / 暗 94% 实底打底（可读性不依赖模糊）', () => {
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8');
  assert.match(css, /\.fushi-audio-menu\.is-glass\s*\{[^}]*96%, transparent\)/);
  assert.match(css, /\.fushi-audio-menu\.is-glass\[data-theme="dark"\]\s*\{[^}]*94%, transparent\)/);
  assert.match(sliceFunction('function applyAudioMenuTheme('), /menu\.setAttribute\('data-theme', theme\)/);
});

function fakeEl(tag) {
  const el = {
    tagName: tag.toUpperCase(), id: '', style: {}, children: [], shadowRoot: null,
    appendChild(c) { el.children.push(c); c.parentNode = el; return c; },
    attachShadow() { el.shadowRoot = fakeEl('#shadow'); return el.shadowRoot; },
    cloneNode() { const c = fakeEl(tag); c.rel = el.rel; c.cloned = true; return c; },
  };
  return el;
}

test('扩展 shadow 弹窗：菜单挂到 documentElement 上独立的 shadow 宿主，不进被裁剪的弹窗宿主', () => {
  const docEl = fakeEl('html');
  const body = fakeEl('body');
  const popupHost = fakeEl('div');
  const root = fakeEl('#shadow');
  root.host = popupHost;
  const style = fakeEl('style');
  const link = fakeEl('link'); link.rel = 'stylesheet';
  root.children.push(style, link, fakeEl('div'));
  const document = {
    documentElement: docEl, body,
    createElement: (t) => fakeEl(t),
    getElementById: (id) => docEl.children.find((c) => c.id === id) || null,
  };
  const ctx = load({ document, __fushiRoot: root });
  const mount = ctx.__fushiAudioMenuMount();
  const host = docEl.children[0];
  assert.ok(host && host.id === 'fushi-audio-menu-host');
  assert.strictEqual(mount, host.shadowRoot);
  assert.match(host.style.cssText, /position:fixed/);
  assert.doesNotMatch(host.style.cssText, /filter|transform|overflow/);
  // 样式表从弹窗 shadow root 克隆（style + link），容器本身不克隆。
  assert.strictEqual(mount.children.length, 2);
  assert.ok(mount.children.every((c) => c.cloned));
  // 第二次复用同一个宿主。
  assert.strictEqual(ctx.__fushiAudioMenuMount(), mount);
  assert.strictEqual(docEl.children.length, 1);
  assert.strictEqual(popupHost.children.length, 0);
});

test('app 内 / 无 shadow root：菜单挂 body（fixed 即弹窗自己的视口）', () => {
  const body = fakeEl('body');
  const ctx = load({ document: { body, documentElement: fakeEl('html'), createElement: (t) => fakeEl(t) } });
  assert.strictEqual(ctx.__fushiAudioMenuMount(), body);
});

test('定位 / 关闭接线：量包含块比例、按可见区限宽、滚动 / 缩放即关、减少动态效果关动画', () => {
  const pos = sliceFunction('function positionAudioSourceMenu(');
  assert.match(pos, /s\.left = '100px'/);
  assert.match(pos, /computeAudioMenuPlacement\(btn,/);
  assert.match(pos, /transformOrigin/);
  const open = sliceFunction('async function openAudioSourceMenu(');
  assert.match(open, /__fushiAudioMenuMount\(\)\.appendChild\(menu\)/);
  assert.match(open, /addEventListener\('scroll', onViewportChange, true\)/);
  assert.match(open, /addEventListener\('resize', onViewportChange\)/);
  assert.match(open, /prefers-reduced-motion: reduce/);
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8');
  assert.match(css, /\.fushi-audio-menu\s*\{[^}]*min-width: min\(200px, calc\(100vw - 16px\)\)/);
  assert.match(css, /\.fushi-audio-menu\s*\{[^}]*max-width: min\(320px, calc\(100vw - 16px\)\)/);
  assert.match(css, /\.fushi-audio-menu\s*\{[^}]*transform: scale\(0\.97\)/);
  assert.match(css, /\.fushi-audio-menu\.no-motion\s*\{[^}]*transition: none/);
  assert.match(css, /\.fushi-audio-menu-name,\s*\.fushi-audio-menu-variant\s*\{[^}]*text-overflow: ellipsis/);
});

test('宿主声明背后采不到模糊（iOS / macOS）：菜单换实底、去模糊', () => {
  assert.match(sliceFunction('function applyAudioMenuTheme('),
    /has\('fushi-solid-backdrop'\)\) menu\.classList\.add\('is-solid'\)/);
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8');
  assert.match(css, /\.fushi-audio-menu\.is-glass\.is-solid\s*\{[^}]*backdrop-filter: none/);
});

test('扩展嵌套子层：填充与第一层同一组规则，不另立不透明度下限（用户 2026-10-05 拍板）', () => {
  const content = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.doesNotMatch(content, /fushi-nested-layer/, 'content.css 不得为嵌套层另立填充');
  // 第一层的两条填充规则就是嵌套层用的那两条（nested-popup.js 只挂 .fushi-glass）。
  assert.match(content, /#entries-container\.fushi-glass:not\(\.eink\)\s*\{[^}]*0\.72\)/);
  assert.match(content, /#entries-container\.fushi-glass:not\(\.eink\)\[data-theme="dark"\]\s*\{[^}]*0\.62\)/);
  const nested = fs.readFileSync(path.join(__dirname, 'nested-popup.js'), 'utf8');
  assert.doesNotMatch(nested, /container\.className = 'fushi-nested-layer'/);
  assert.match(nested, /classList\.toggle\('fushi-glass', glass\)/);
  // 音频源菜单是菜单不是查词层：高不透明度保留。
  const popupCss = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8');
  assert.match(popupCss, /\.fushi-audio-menu/);
});
