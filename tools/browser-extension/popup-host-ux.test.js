// BUG-3142：拖查词弹窗右下角改大小后，当前词条不重排、要重新查词才对。
// 根因：popup.js 多列 masonry 把每张词典卡的宽度 / 位置写成 inline px，只在 window resize 与卡片
// 自身高度变化时重铺；扩展弹窗是宿主页里一个可调宽的 host，宿主页 window 没变 → 卡片停在旧列宽。
// 修复：拖动中按帧合并、松手再落实一次，调 popup.js 对宿主开放的重铺入口 fushiRelayoutDictionaries。
// 本文件在 vm 里真加载 content.js，驱动把手的 pointerdown / move / up，断言重铺真的被调到。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');

// BUG-1718：真实运行时（manifest content_scripts / side-panel.html）里 vendor/dict-media.js
// 恒在 content.js / side-panel.js 之前加载，后者依赖它导出的 applyFushiPopupCss 与
// installDictMediaPlaceholderResolver。测试沙箱必须照同样顺序装，否则跑的是一个真实
// 世界里不存在的、缺半个脚本集的环境。
const FUSHI_DICT_MEDIA = require('node:path').join(__dirname, 'vendor', 'dict-media.js');
function loadFushiDictMedia(ctx) {
  require('node:vm').runInContext(
    require('node:fs').readFileSync(FUSHI_DICT_MEDIA, 'utf8'), ctx,
    { filename: 'vendor/dict-media.js' });
}


// 加载 content.js 到最小 vm 沙箱，返回 sandbox 以取顶层纯函数（fushiComputePlacement /
// fushiComputeResizedSize，均不触发任何 DOM 定位）。
function loadSandbox() {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const noop = () => {};
  const el = () => ({
    style: { cssText: '', setProperty: noop, getPropertyValue: () => '' },
    dataset: {}, classList: { add: noop }, children: [],
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
  loadFushiDictMedia(sandbox);
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  return sandbox;
}


function grip() {
  const handlers = {};
  return {
    style: {},
    handlers,
    addEventListener(type, fn) { (handlers[type] = handlers[type] || []).push(fn); },
    setPointerCapture() {}, releasePointerCapture() {},
    fire(type, x, y) {
      const ev = { button: 0, pointerId: 1, clientX: x, clientY: y, preventDefault() {}, stopPropagation() {} };
      for (const fn of handlers[type] || []) fn(ev);
    },
  };
}

function setup() {
  const sb = loadSandbox();
  // 真实 manifest 里 popup-size.js 排在 content.js 之前（尺寸下限常量在那里）。
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'popup-size.js'), 'utf8'), sb, { filename: 'popup-size.js' });
  const rafs = [];
  sb.requestAnimationFrame = (fn) => { rafs.push(fn); return rafs.length; };
  let relayouts = 0;
  sb.window.fushiRelayoutDictionaries = () => { relayouts += 1; };
  vm.runInContext(`
    fushiHost = {
      style: { width: '400px', maxHeight: '360px' },
      getBoundingClientRect() {
        const w = parseFloat(this.style.width) || 0;
        return { left: 100, top: 100, right: 100 + w, bottom: 460, width: w, height: 360 };
      },
    };
    fushiResizeBox = { zoom: 1, left: 100, top: 100, maxRight: 1200, maxBottom: 800 };
  `, sb);
  const g = grip();
  sb.fushiInstallResizeDrag(g);
  return { sb, g, rafs, relayouts: () => relayouts };
}

test('拖动中按帧合并重铺：同一帧多次 move 只排一次', () => {
  const { sb, g, rafs, relayouts } = setup();
  g.fire('pointerdown', 500, 460);
  g.fire('pointermove', 560, 470);
  g.fire('pointermove', 600, 480);
  assert.strictEqual(vm.runInContext('fushiHost.style.width', sb), '500px', '宽度跟手');
  assert.strictEqual(rafs.length, 1, '一帧只排一次重铺');
  assert.strictEqual(relayouts(), 0);
  rafs.shift()();
  assert.strictEqual(relayouts(), 1, '下一帧按新宽度重铺当前词条');
});

test('松手立刻按最终宽度再铺一次（不必重新查词）', () => {
  const { g, relayouts } = setup();
  g.fire('pointerdown', 500, 460);
  g.fire('pointermove', 420, 470);
  g.fire('pointerup', 420, 470);
  assert.strictEqual(relayouts(), 1);
});

test('纯点击把手（没拖动）不重铺', () => {
  const { g, rafs, relayouts } = setup();
  g.fire('pointerdown', 500, 460);
  g.fire('pointerup', 500, 460);
  assert.strictEqual(relayouts(), 0);
  assert.strictEqual(rafs.length, 0);
});

// 用户群 10-09「右侧条」：可滚动的是 shadow 宿主自己，它的滚动条按**宿主页**配色画——浅色网页上
// 深色弹窗右侧挂一条带箭头的白色经典滚动条。页面级样式给宿主画无箭头、透明轨道、圆角滑块，
// 并把网页可能继承下来的标准 scrollbar-* 压回 auto（否则整族 ::-webkit-scrollbar 失效）。
test('宿主滚动条：页面级样式无箭头、透明轨道、圆角滑块，标准属性压回 auto', () => {
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  const block = (sel) => {
    const at = css.indexOf(sel + ' {');
    assert.ok(at >= 0, 'content.css 缺 ' + sel);
    return css.slice(at, css.indexOf('}', at));
  };
  assert.match(block('#hibiki-popup-host'), /scrollbar-width: auto !important;[\s\S]*scrollbar-color: auto !important;/);
  assert.match(block('#hibiki-popup-host::-webkit-scrollbar-button'), /display: none/);
  assert.match(css, /#hibiki-popup-host::-webkit-scrollbar-track,[\s\S]*?background: transparent/);
  assert.match(block('#hibiki-popup-host::-webkit-scrollbar-thumb'), /border-radius: 999px/);
  // 滚动条那一列与卡片同色：只给最右 10px（= 滚动条宽）上色，用 content.js 量到的卡片底色。
  assert.match(block('#hibiki-popup-host'), /linear-gradient\(to left, var\(--fushi-host-gutter, transparent\) 10px, transparent 10px\)/);
  assert.match(block('#hibiki-popup-host::-webkit-scrollbar'), /width: 10px/);
  // 宿主 inline 样式不得再写标准滚动条属性（会把上面整族伪元素禁用）。
  const src = fs.readFileSync(CONTENT, 'utf8');
  assert.doesNotMatch(src, /fushiHost\.style\.scrollbar(Color|Width)|host\.style\.scrollbar(Color|Width)/);
});

test('滚动条那一列取卡片实际底色：实色 / 半透明照抄，全透明则不写', () => {
  const sb = loadSandbox();
  const props = {};
  const host = { style: { setProperty(k, v) { props[k] = v; }, removeProperty(k) { delete props[k]; } } };
  const bgOf = (bg) => { sb.getComputedStyle = () => ({ backgroundColor: bg, getPropertyValue: () => '' }); };
  bgOf('rgb(0, 0, 0)');
  sb.fushiPaintHostGutter(host, {});
  assert.strictEqual(props['--fushi-host-gutter'], 'rgb(0, 0, 0)');
  bgOf('rgba(29, 27, 32, 0.62)');
  sb.fushiPaintHostGutter(host, {});
  assert.strictEqual(props['--fushi-host-gutter'], 'rgba(29, 27, 32, 0.62)');
  bgOf('rgba(0, 0, 0, 0)');
  sb.fushiPaintHostGutter(host, {});
  assert.ok(!('--fushi-host-gutter' in props));
  const src = fs.readFileSync(CONTENT, 'utf8');
  const start = src.indexOf('function fushiApplyTheme(');
  const body = src.slice(start, src.indexOf('\nfunction ', start + 10));
  assert.ok(/fushiPaintHostGutter\(fushiHost, c\)/.test(body), '每次套主题都重量一次（换明暗 / 风格即跟随）');
});
