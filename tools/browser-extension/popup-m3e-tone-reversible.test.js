const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// HBK-AUDIT-015：M3E 暗色下词典浅底 / 深字的调色曾是「一次性标记 + 不可恢复的内联 !important」，
// 宿主主题热更新（只注入 CSS 变量 / 改 data-theme，不重建词条）后：暗→浅残留暗块、浅→暗不调色。
// 现在调色前记下原内联值，主题变化时复原再按新明暗重做。这里把 popup.js 的调色段（真源
// fushi/assets/popup/popup.js，vendor 是其字节镜像）切出来在假 DOM 上跑。
const SRC = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function slice(startMarker, endMarker) {
  const a = SRC.indexOf(startMarker);
  const b = SRC.indexOf(endMarker, a);
  assert.ok(a >= 0 && b > a, '切片锚失效：' + startMarker);
  return SRC.slice(a, b);
}

function makeStyle(init) {
  const props = Object.assign({}, init);
  return {
    props,
    getPropertyValue(k) { return props[k] ? props[k].value : ''; },
    getPropertyPriority(k) { return props[k] ? props[k].priority : ''; },
    setProperty(k, v, p) { props[k] = { value: v, priority: p || '' }; },
    removeProperty(k) { delete props[k]; },
  };
}

function makeNode(computed, inline) {
  const node = { tagName: 'DIV', style: makeStyle(inline), computed, children: [] };
  node.matches = () => false;
  // 夹具里没有 .glossary-content（词典样式统一的作用域）：按选择器如实回答。
  node.querySelectorAll = (sel) => (sel === '.glossary-content' ? [] : node.children);
  return node;
}

function load(world) {
  const sandbox = {
    // 暗色调色层只在「保留词典原样式」模式下工作：显式关掉词典样式统一。
    window: { __fushiDictUnifiedStyle: false },
    console,
    document: {
      documentElement: { classList: { contains: (c) => c === 'fushi-m3e' }, getAttribute: () => world.theme },
      body: null,
    },
    requestAnimationFrame: (fn) => { world.raf.push(fn); return world.raf.length; },
    getComputedStyle: (n) => {
      // 有内联值时计算色 = 内联值（模拟内联压过样式表）。
      const bg = n.style.getPropertyValue('background-color') || n.computed.bg;
      const color = n.style.getPropertyValue('color') || n.computed.color;
      return { backgroundColor: bg, color };
    },
    MutationObserver: function (cb) { world.mo = cb; this.observe = () => {}; },
    Set, WeakSet, Math, String, parseFloat, Object,
  };
  sandbox.__fushiContainer = () => world.root;
  vm.createContext(sandbox);
  const code = slice('function __fushiParseRgb(value)', '// BUG-1898')
    + slice('var __fushiM3eToneRoots = null;', 'function __fushiParseRgb(value)');
  vm.runInContext(code, sandbox, { filename: 'popup.js#m3e-tone' });
  return sandbox;
}

function flush(world) {
  while (world.raf.length) world.raf.shift()();
}

test('暗色调色可逆：切回浅色复原原内联值（含 !important 优先级 / 原本无内联值）', () => {
  const world = { theme: 'dark', raf: [] };
  const pink = makeNode({ bg: 'rgb(255, 220, 230)', color: 'rgb(20, 20, 20)' }, {
    'background-color': { value: 'rgb(255, 220, 230)', priority: 'important' },
  });
  const plain = makeNode({ bg: 'rgb(250, 250, 200)', color: 'rgb(30, 30, 30)' }, {});
  const root = makeNode({ bg: 'rgba(0, 0, 0, 0)', color: 'rgb(0,0,0)' }, {});
  root.querySelectorAll = (sel) => (sel === '.glossary-content' ? [] : [pink, plain]);
  pink.querySelectorAll = () => [];
  plain.querySelectorAll = () => [];
  world.root = root;
  const sb = load(world);

  sb.__fushiScheduleM3eDictTone(root);
  flush(world);
  assert.match(pink.style.getPropertyValue('background-color'), /^hsl/, '暗色下浅底被压暗');
  assert.match(plain.style.getPropertyValue('background-color'), /^hsl/);
  assert.match(plain.style.getPropertyValue('color'), /^hsl/, '浅底上的深字被提亮');

  // 宿主热更新到浅色：只改 data-theme（不重建节点），观察器排一帧重调色。
  world.theme = 'light';
  world.mo([]);
  flush(world);
  assert.deepStrictEqual({ ...pink.style.props['background-color'] }, { value: 'rgb(255, 220, 230)', priority: 'important' },
    '原内联值与 !important 原样复原');
  assert.strictEqual(plain.style.getPropertyValue('background-color'), '', '原本没有内联底色的移除干净');
  assert.strictEqual(plain.style.getPropertyValue('color'), '');

  // 再切回暗色：一次性标记已清，重新调色（以前浅→暗不再调色）。
  world.theme = 'dark';
  world.mo([]);
  flush(world);
  assert.match(plain.style.getPropertyValue('background-color'), /^hsl/, '浅→暗重新调色');
});

test('宿主可显式调用 __fushiRetoneDictColors（主题热更新路径）', () => {
  assert.match(SRC, /window\.__fushiRetoneDictColors = __fushiRetoneDictColors;/);
});

// ── 由 tool/review_repros/popup_m3e_theme_transition.repro.mjs（HBK-AUDIT-015 复现）迁来 ──
// 真源调色段 + 最小 DOM 边界；宿主主题热更新 = 改 data-theme 后调 __fushiRetoneDictColors
// （dictionary_popup_webview.dart didChangeDependencies 注入 themeVarsJs 之后紧跟这一调用）。
function reproFixture(initialTheme) {
  const properties = new Map([
    ['background-color', { value: 'rgb(255, 255, 255)', priority: '' }],
    ['color', { value: 'rgb(0, 0, 0)', priority: '' }],
  ]);
  const card = {
    tagName: 'DIV', isConnected: true,
    matches: (selector) => selector === '.glossary-group > div[data-dictionary]',
    querySelectorAll: () => [],
    style: {
      setProperty: (key, value, priority) => properties.set(key, { value, priority: priority || '' }),
      getPropertyValue: (key) => (properties.get(key) || {}).value || '',
      getPropertyPriority: (key) => (properties.get(key) || {}).priority || '',
    },
  };
  const attributes = new Map([['data-theme', initialTheme]]);
  const html = {
    classList: { contains: (name) => name === 'fushi-m3e' },
    getAttribute: (name) => attributes.get(name),
    setAttribute: (name, value) => attributes.set(name, value),
  };
  let frames = [];
  const scope = {
    console, Set, WeakSet,
    window: { __fushiDictUnifiedStyle: false },
    document: { documentElement: html },
    __fushiContainer: () => null,
    requestAnimationFrame: (callback) => (frames.push(callback), frames.length),
    getComputedStyle: (node) => ({
      backgroundColor: node.style.getPropertyValue('background-color'),
      color: node.style.getPropertyValue('color'),
    }),
  };
  vm.createContext(scope);
  vm.runInContext(slice('var __fushiM3eToneRoots = null;', '// BUG-1898:'), scope, { filename: 'popup.js#m3e-tone' });
  const flush = () => { const p = frames; frames = []; p.forEach((cb) => cb()); };
  return {
    card,
    postProcess() { scope.__fushiScheduleM3eDictTone(card); flush(); },
    setTheme(theme) { html.setAttribute('data-theme', theme); scope.__fushiRetoneDictColors(); flush(); },
  };
}

test('HBK-AUDIT-015 复现：初始暗色调色、初始浅色保持', () => {
  const dark = reproFixture('dark');
  dark.postProcess();
  assert.strictEqual(dark.card.style.getPropertyValue('background-color'), 'hsl(0, 0%, 22%)');
  assert.strictEqual(dark.card.style.getPropertyValue('color'), 'hsl(0, 0%, 82%)');
  assert.strictEqual(dark.card.style.getPropertyPriority('background-color'), 'important');
  const light = reproFixture('light');
  light.postProcess();
  assert.strictEqual(light.card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
});

test('HBK-AUDIT-015 复现：暗→浅在现有 DOM 上复原；浅→暗对已渲染词条调色；浅色下再跑调度也复原', () => {
  const a = reproFixture('dark');
  a.postProcess();
  a.setTheme('light');
  assert.strictEqual(a.card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
  assert.strictEqual(a.card.style.getPropertyValue('color'), 'rgb(0, 0, 0)');
  const b = reproFixture('light');
  b.postProcess();
  b.setTheme('dark');
  assert.strictEqual(b.card.style.getPropertyValue('background-color'), 'hsl(0, 0%, 22%)');
  const c = reproFixture('dark');
  c.postProcess();
  c.setTheme('light');
  c.postProcess();
  assert.strictEqual(c.card.style.getPropertyValue('background-color'), 'rgb(255, 255, 255)');
});
