const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// BUG-767 行为守卫：浏览器扩展「Shift 查词」弹窗**遮住被查词**。
// 根因：content.js 的 place() 落点逻辑在「下方放不下 → 翻到词上方」时，只把 top 夹到边距 8
// （`top = Math.max(8, ay - H - 4)`），从不把弹窗高度夹到可用空间。当词典结果多、弹窗较高而视口
// 不够高（vh < ~2×弹窗高）时，翻上方后 top 被夹到 8，弹窗从 8 往下铺开，直接盖住上半屏的词。
// 修复：把落点收敛进纯函数 hibikiComputePlacement——下方能放整只→落下方；上方能放整只→落上方；
// 两侧都放不下→选空间更大的一侧并把弹窗高度夹到该侧空间（内部滚动），弹窗底/顶恰贴词边，绝不覆盖。
// 本测试在受控 vm 里真加载 content.js，直接调用其顶层纯函数，断言：弹窗矩形在纵向上**永不**与被查
// 词矩形重叠，且落在视口内。含旧逻辑必然翻车的高弹窗场景。

const CONTENT = path.join(__dirname, 'content.js');

// 加载 content.js 到最小 vm 沙箱，仅为拿到顶层纯函数 hibikiComputePlacement（不触发任何 DOM 定位）。
function loadPlacement() {
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
  return sandbox.hibikiComputePlacement;
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

test('顶层纯函数 hibikiComputePlacement 存在', () => {
  const fn = loadPlacement();
  assert.strictEqual(typeof fn, 'function', 'content.js 未导出 hibikiComputePlacement 全局函数');
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
