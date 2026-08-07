const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-767 行为守卫：浏览器扩展「Shift 查词」弹窗**遮住被查词**。
// 根因：content.js 的 place() 落点逻辑在「下方放不下 → 翻到词上方」时，只把 top 夹到边距 8
// （`top = Math.max(8, ay - H - 4)`），从不把弹窗高度夹到可用空间。当词典结果多、弹窗较高而视口
// 不够高（vh < ~2×弹窗高）时，翻上方后 top 被夹到 8，弹窗从 8 往下铺开，直接盖住上半屏的词。
// 修复：把落点收敛进纯函数 fushiComputePlacement——下方能放整只→落下方；上方能放整只→落上方；
// 两侧都放不下→选空间更大的一侧并把弹窗高度夹到该侧空间（内部滚动），弹窗底/顶恰贴词边，绝不覆盖。
// 本测试在受控 vm 里真加载 content.js，直接调用其顶层纯函数，断言：弹窗矩形在纵向上**永不**与被查
// 词矩形重叠，且落在视口内。含旧逻辑必然翻车的高弹窗场景。

const CONTENT = path.join(__dirname, 'content.js');

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
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  return sandbox;
}

function loadPlacement() {
  return loadSandbox().fushiComputePlacement;
}

function loadResized() {
  return loadSandbox().fushiComputeResizedSize;
}

// 弹窗实际渲染高度：被夹高时用 maxHeight，否则用自然高度。
function popupHeight(pos, size) {
  return pos.maxHeight != null ? pos.maxHeight : size.height;
}

// 纵向重叠：两个区间 [a0,a1) 与 [b0,b1) 有交集（允许 0.5px 容差消除等边争议）。
function overlapsVertically(pos, size, anchor) {
  const pTop = pos.top;
  const pBot = pos.top + popupHeight(pos, size);
  const wTop = anchor.y;
  const wBot = anchor.y + anchor.height;
  return pBot > wTop + 0.5 && pTop < wBot - 0.5;
}

const VP = { width: 1200, height: 800 };
const SIZE_SHORT = { width: 400, height: 200 };
const SIZE_TALL = { width: 400, height: 360 };

test('顶层纯函数 fushiComputePlacement 存在', () => {
  const fn = loadPlacement();
  assert.strictEqual(typeof fn, 'function', 'content.js 未导出 fushiComputePlacement 全局函数');
});

// 核心回归：矮视口 + 高弹窗 + 词在上半屏——旧逻辑翻上方后夹到 top=8、从 8 往下盖住词，本例必须不覆盖。
test('BUG-767 高弹窗矮视口场景弹窗不覆盖被查词', () => {
  const fn = loadPlacement();
  const vp = { width: 1200, height: 700 };
  const anchor = { x: 200, y: 340, height: 20 }; // 词 340..360，位于上半屏
  const pos = fn(anchor, SIZE_TALL, vp);
  assert.ok(!overlapsVertically(pos, SIZE_TALL, anchor),
    `弹窗覆盖了被查词：popup=[${pos.top}, ${pos.top + popupHeight(pos, SIZE_TALL)}] word=[${anchor.y}, ${anchor.y + anchor.height}]`);
  // 且弹窗不溢出视口底（含被夹高时）。
  assert.ok(pos.top + popupHeight(pos, SIZE_TALL) <= vp.height + 0.5, '弹窗底溢出视口');
  assert.ok(pos.top >= -0.5, '弹窗顶溢出视口');
});

// 遍历词从顶到底、矮/高弹窗、矮/高视口的组合，弹窗**始终**不覆盖被查词。
test('BUG-767 跨词位置/弹窗高度/视口高度弹窗均不覆盖被查词', () => {
  const fn = loadPlacement();
  for (const vh of [500, 700, 900]) {
    for (const size of [SIZE_SHORT, SIZE_TALL]) {
      for (let y = 8; y <= vh - 30; y += 37) {
        const vp = { width: 1200, height: vh };
        const anchor = { x: 300, y, height: 22 };
        const pos = fn(anchor, size, vp);
        assert.ok(!overlapsVertically(pos, size, anchor),
          `覆盖被查词：vh=${vh} size.h=${size.height} y=${y} → popup=[${pos.top}, ${pos.top + popupHeight(pos, size)}] word=[${y}, ${y + 22}]`);
        assert.ok(pos.left >= 8 - 0.5 && pos.left + size.width <= vp.width - 8 + 0.5,
          `横向溢出：vh=${vh} y=${y} left=${pos.left}`);
      }
    }
  }
});

// 有充足空间时优先落词下方（原行为不回归）。
test('空间充足时弹窗落在词下方且不夹高', () => {
  const fn = loadPlacement();
  const anchor = { x: 100, y: 60, height: 18 };
  const pos = fn(anchor, SIZE_SHORT, VP);
  assert.strictEqual(pos.maxHeight, null, '空间充足不应夹高');
  assert.ok(pos.top >= anchor.y + anchor.height, '弹窗未落在词下方');
});

// 词贴视口底、下方放不下时翻到词上方。
test('词贴视口底时弹窗翻到词上方且不覆盖', () => {
  const fn = loadPlacement();
  const anchor = { x: 100, y: 760, height: 18 }; // 词 760..778，vh=800
  const pos = fn(anchor, SIZE_SHORT, VP);
  assert.ok(pos.top + popupHeight(pos, SIZE_SHORT) <= anchor.y + 0.5, '弹窗未落在词上方');
  assert.ok(!overlapsVertically(pos, SIZE_SHORT, anchor), '弹窗覆盖了被查词');
});

// ── Phase D：拖拽调整尺寸的纯函数 fushiComputeResizedSize ──
// 宽敞 bounds（视口大、可用空间远超上下限），只考验位移折算与下限。
const WIDE_BOUNDS = { minW: 250, minH: 200, maxW: 2000, maxH: 1600 };

test('顶层纯函数 fushiComputeResizedSize 存在', () => {
  assert.strictEqual(typeof loadResized(), 'function',
    'content.js 未导出 fushiComputeResizedSize 全局函数');
});

test('zoom=1：位移直接加到基准宽高', () => {
  const fn = loadResized();
  const r = fn({ width: 400, height: 360 }, { dx: 120, dy: 80 }, 1, WIDE_BOUNDS);
  assert.strictEqual(r.width, 520);
  assert.strictEqual(r.height, 440);
});

test('zoom>1：视口位移除以 zoom 折回基准尺度', () => {
  const fn = loadResized();
  // 渲染盒 = 基准 × zoom；拖动发生在已缩放坐标系，故 base delta = 视口 delta / zoom。
  const r = fn({ width: 400, height: 360 }, { dx: 200, dy: 100 }, 2, WIDE_BOUNDS);
  assert.strictEqual(r.width, 500); // 400 + 200/2
  assert.strictEqual(r.height, 410); // 360 + 100/2
});

test('zoom<=0 兜底为 1（不除零/不反向缩放）', () => {
  const fn = loadResized();
  const r = fn({ width: 400, height: 360 }, { dx: 50, dy: 50 }, 0, WIDE_BOUNDS);
  assert.strictEqual(r.width, 450);
  assert.strictEqual(r.height, 410);
});

test('缩小时夹到下限 250×200', () => {
  const fn = loadResized();
  const r = fn({ width: 300, height: 240 }, { dx: -400, dy: -400 }, 1, WIDE_BOUNDS);
  assert.strictEqual(r.width, 250);
  assert.strictEqual(r.height, 200);
});

test('放大时夹到 bounds 上限（视口可用空间÷zoom，不撑出视口/不遮词）', () => {
  const fn = loadResized();
  // maxW/maxH 由 place() 用视口可用空间÷zoom 算出（此处模拟为 700×500）。
  const bounds = { minW: 250, minH: 200, maxW: 700, maxH: 500 };
  const r = fn({ width: 400, height: 360 }, { dx: 9999, dy: 9999 }, 1, bounds);
  assert.strictEqual(r.width, 700);
  assert.strictEqual(r.height, 500);
});

test('视口过小导致上界<下界时仍返回下限（不倒挂）', () => {
  const fn = loadResized();
  // maxW/maxH 折算后小于下限（极小视口 / 大 zoom）：clamp 上界取 max(lo,hi)=lo，恒返回下限。
  const bounds = { minW: 250, minH: 200, maxW: 100, maxH: 90 };
  const r = fn({ width: 400, height: 360 }, { dx: 0, dy: 0 }, 1, bounds);
  assert.strictEqual(r.width, 250);
  assert.strictEqual(r.height, 200);
});
