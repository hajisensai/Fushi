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

// ── BUG-1726：渲染中弹窗持续长高（Netflix 底部字幕查词）→ 超出视口底部被截断 ──
// 根因：place() 只在 fushiRenderEntries 后的一帧 rAF 量过一次尺寸（此刻只有首词条+第 1 个词典
// 块，高度被低估），fushiComputePlacement 误判「放得下」且 maxHeight=null；随后 popup.js 逐宏
// 任务追加词典块把弹窗撑到全高，溢出视口无人复算。修复：① fushiPlacementSideMax 纯函数给出
// 「所选一侧可用空间上限」，place 恒把 maxHeight 夹到 min(theme 上限, sideMax)（无观察器的老
// WebView 也被兜住）；② host+容器挂 ResizeObserver，尺寸变化用同一份锚点重跑落点。

function loadSideMax() {
  return loadSandbox().fushiPlacementSideMax;
}

test('顶层纯函数 fushiPlacementSideMax 存在', () => {
  assert.strictEqual(typeof loadSideMax(), 'function',
    'content.js 未导出 fushiPlacementSideMax 全局函数');
});

test('BUG-1726 sideMax：两侧都放不下时直接等于 pos.maxHeight', () => {
  const place = loadPlacement();
  const sideMax = loadSideMax();
  const vp = { width: 1200, height: 500 };
  const anchor = { x: 300, y: 240, height: 22 }; // 词在半屏，弹窗 360 两侧都放不下
  const pos = place(anchor, { width: 400, height: 360 }, vp);
  assert.notStrictEqual(pos.maxHeight, null);
  assert.strictEqual(sideMax(pos, anchor, vp), pos.maxHeight);
});

test('BUG-1726 落点后继续长高（复算尚未发生的窗口期）：sideMax 夹取恒不压词、不出视口', () => {
  // 核心时序：place() 在 hSmall 时刻落点并写 maxHeight=min(theme, sideMax)；随后 popup.js 把
  // 内容撑到 hBig，而 ResizeObserver 复算**还没跑**（或老 WebView 根本没有）——此窗口期弹窗
  // 实际渲染高 = min(hBig, sideMax(落点))，必须已经被夹到不压词、不出视口。
  const place = loadPlacement();
  const sideMax = loadSideMax();
  for (const vh of [500, 700, 800]) {
    for (let y = 8; y <= vh - 30; y += 41) {
      for (const hSmall of [80, 160, 240]) {
        for (const hBig of [hSmall, hSmall + 120, 360, 520]) {
          const vp = { width: 1200, height: vh };
          const anchor = { x: 300, y, height: 22 };
          const pos = place(anchor, { width: 400, height: hSmall }, vp);
          const sm = sideMax(pos, anchor, vp);
          const rendered = Math.min(hBig, sm);
          const clamped = { top: pos.top, maxHeight: rendered };
          assert.ok(!overlapsVertically(clamped, { height: rendered }, anchor),
            `未复算窗口期压词：vh=${vh} y=${y} ${hSmall}→${hBig} → popup=[${pos.top}, ${pos.top + rendered}] word=[${y}, ${y + 22}]`);
          assert.ok(pos.top + rendered <= vh - 8 + 0.5,
            `未复算窗口期弹窗底出视口：vh=${vh} y=${y} ${hSmall}→${hBig} bottom=${pos.top + rendered}`);
          assert.ok(pos.top >= 8 - 0.5,
            `弹窗顶出视口：vh=${vh} y=${y} ${hSmall}→${hBig} top=${pos.top}`);
        }
      }
    }
  }
});

test('BUG-1726 Netflix 场景：词贴视口底 + 渲染中长高，复算后始终不压词不出视口', () => {
  const place = loadPlacement();
  const sideMax = loadSideMax();
  const vp = { width: 1600, height: 900 };
  const anchor = { x: 700, y: 860, height: 24 }; // 底部字幕：词底距视口底仅 16px
  // 首帧低估高度 100 → 渲染推进逐步长高到 360（--fushi-popup-max-height 默认）。
  // 每一步都用「上一步不存在依赖、只按当前自然高度复算」模拟 ResizeObserver 重跑落点。
  for (const h of [100, 180, 260, 360]) {
    const pos = place(anchor, { width: 400, height: h }, vp);
    const rendered = Math.min(h, sideMax(pos, anchor, vp));
    assert.ok(pos.top + rendered <= anchor.y + 0.5,
      `长高到 ${h} 后压住底部字幕词：popup=[${pos.top}, ${pos.top + rendered}] word.top=${anchor.y}`);
    assert.ok(pos.top >= 8 - 0.5 && pos.top + rendered <= vp.height - 8 + 0.5,
      `长高到 ${h} 后出视口：popup=[${pos.top}, ${pos.top + rendered}]`);
  }
});

// 布线守卫（源码扫描）：纯函数对了但没接上观察器/侧夹照样复发，锁住三处接线。
test('BUG-1726 布线：ResizeObserver 复算 + maxHeight 侧夹 + 拖拽手动优先', () => {
  const src = fs.readFileSync(CONTENT, 'utf8');
  assert.ok(src.includes('function fushiApplyPlacement('),
    '落点写回必须收敛进 fushiApplyPlacement（首帧与复算共用同一份实现）');
  assert.ok(src.includes('function fushiObservePopupResize(') &&
    src.includes('new ResizeObserver('),
    'host/容器必须挂 ResizeObserver，弹窗渲染中长高要重跑落点');
  assert.ok(src.includes('fushiObservePopupResize();'),
    'place() 必须真的调用 fushiObservePopupResize()——函数存在但没接线照样复发');
  assert.ok(src.includes('fushiPlacementSideMax(pos, anchor, viewport)'),
    'fushiApplyPlacement 必须用 fushiPlacementSideMax 恒夹 maxHeight（兜底老 WebView）');
  assert.ok(src.includes("'min(' + fushiHostBaseMaxHeight"),
    '侧夹必须与 theme 原始上限取 min——夹取只缩不放，不得放大用户配置的弹窗高度');
  assert.ok(src.includes('fushiUserResizedPopup = true'),
    'Phase D 拖拽动过尺寸后必须停自动复位（手动优先），否则复算和用户打架');
  assert.ok(src.includes('fushiPlaceObserver.disconnect()'),
    '关窗必须 disconnect 落点观察器');
});
