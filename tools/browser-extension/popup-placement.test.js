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

// ── BUG-2773：弹窗先落字幕下方显示、尾批长高后又翻到上方（用户录屏：「最终弹窗之前又往下弹了」）──
// 根因：place() 在 rAF 首帧量高度时 popup.js 只建了首词条 + 1 个词典块（尾批仍在 MessageChannel
// 宏任务里追加），fushiComputePlacement 按这个矮高度判「下方放得下」→ 落字幕下方并立即 reveal；
// 随后 ResizeObserver 见弹窗长高重跑落点，下方放不下了 → 翻到词上方。修复：① 未锁边且尾批在途
// （window._renderInProgress）时按 theme 上限选边、按实测高度定位；② reveal 时把所选一侧锁进
// fushiPlaceSide，此后复算只在同侧夹高，不再翻边。
// 驱动真实的 fushiApplyPlacement（量 host/容器 rect → 选边 → 写回 host.style），不是抄一份逻辑。
function loadApplySandbox(vp) {
  const ctx = loadSandbox();
  ctx.window.innerWidth = vp.width;
  ctx.window.innerHeight = vp.height;
  const state = { height: 0 };
  const rect = () => ({ x: 0, y: 0, left: 0, top: 0, width: 400, height: state.height });
  ctx.__host = { style: { zoom: '' }, getBoundingClientRect: rect };
  ctx.__container = { style: {}, getBoundingClientRect: rect };
  vm.runInContext(`
    fushiHost = __host; fushiContainer = __container;
    fushiEnsureResizeGrip = function () {}; fushiPositionResizeGrip = function () {};
    fushiThemeMaxHeightPx = 360; fushiHostBaseMaxHeight = 'min(360px, 80vh)';
    fushiPlaceSide = null; fushiPlacedSide = null;
  `, ctx);
  return {
    ctx,
    setAnchor: (a) => vm.runInContext(`fushiPlaceAnchor = ${JSON.stringify(a)};`, ctx),
    apply: (height, inProgress) => {
      state.height = height;
      ctx.window._renderInProgress = inProgress;
      vm.runInContext('fushiApplyPlacement();', ctx);
      return parseFloat(ctx.__host.style.top);
    },
    // 与 fushiRender 的 reveal 同一句：显示即锁边。
    reveal: () => vm.runInContext('fushiPlaceSide = fushiPlacedSide;', ctx),
    side: () => vm.runInContext('fushiPlacedSide', ctx),
  };
}

test('BUG-2773 尾批在途的首帧按最终高度选边：底部字幕查词直接落上方，长高全程不翻边', () => {
  const vp = { width: 1200, height: 800 };
  const anchor = { x: 300, y: 560, height: 24 }; // 字幕词 560..584，下方只剩 208px，放不下 360
  const h = loadApplySandbox(vp);
  h.setAnchor(anchor);
  const firstTop = h.apply(150, true); // 首帧：只有首词条，尾批在途
  assert.strictEqual(h.side(), 'above', '首帧按矮高度落到了字幕下方——尾批长高后必然翻边');
  assert.ok(firstTop + 150 <= anchor.y - 4 + 0.5, `首帧弹窗压词：top=${firstTop}`);
  h.reveal();
  for (const grown of [220, 300, 360]) {
    const top = h.apply(grown, grown < 360);
    assert.strictEqual(h.side(), 'above', `长高到 ${grown} 时翻边了`);
    assert.ok(top + grown <= anchor.y - 4 + 0.5 && top >= 8 - 0.5,
      `长高到 ${grown} 后压词或出视口：top=${top}`);
  }
});

test('BUG-2773 显示后锁边：落下方的短结果再长高也只在下方夹高，不跳到上方', () => {
  const vp = { width: 1200, height: 800 };
  const anchor = { x: 300, y: 560, height: 24 };
  const h = loadApplySandbox(vp);
  h.setAnchor(anchor);
  h.apply(120, false); // 渲染已完成的短结果：下方放得下
  assert.strictEqual(h.side(), 'below');
  h.reveal();
  const top = h.apply(300, false); // 之后图片/字体加载把它撑高
  assert.strictEqual(h.side(), 'below', '已显示的弹窗被翻到了上方');
  assert.strictEqual(top, anchor.y + anchor.height + 4);
  const maxH = h.ctx.__host.style.maxHeight;
  assert.ok(/^min\(min\(360px, 80vh\), 20\d(\.\d+)?px\)$/.test(maxH),
    `锁在下方时必须夹到下方可用空间（不出视口）：maxHeight=${maxH}`);
});

test('BUG-2773 空间充足时尾批在途仍落词下方（原行为不回归）', () => {
  const vp = { width: 1200, height: 800 };
  const anchor = { x: 300, y: 100, height: 24 }; // 词在上部：下方 668px 放得下 theme 上限
  const h = loadApplySandbox(vp);
  h.setAnchor(anchor);
  h.apply(150, true);
  assert.strictEqual(h.side(), 'below');
});

test('BUG-2773 纯函数强制侧：锁定一侧放不下时夹高，仍不压词不出视口', () => {
  const place = loadPlacement();
  const vp = { width: 1200, height: 800 };
  const below = place({ x: 300, y: 560, height: 24 }, { width: 400, height: 360 }, vp, 'below');
  assert.strictEqual(below.side, 'below');
  assert.strictEqual(below.top, 588);
  assert.ok(below.top + below.maxHeight <= vp.height - 8 + 0.5);
  const above = place({ x: 300, y: 90, height: 24 }, { width: 400, height: 360 }, vp, 'above');
  assert.strictEqual(above.side, 'above');
  assert.ok(above.top >= 8 - 0.5 && above.top + above.maxHeight <= 90 - 4 + 0.5);
});

test('BUG-2773 布线：reveal 锁边、新查词与关窗清锁', () => {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const revealAt = src.indexOf('const reveal = () => {');
  assert.ok(revealAt > 0 &&
    src.slice(revealAt, revealAt + 300).includes('fushiPlaceSide = fushiPlacedSide;'),
    'reveal 必须把本次落点的一侧锁进 fushiPlaceSide');
  assert.ok((src.match(/fushiPlaceSide = null;/g) || []).length >= 2,
    '新查词（fushiRender）与关窗都必须清掉锁边，否则下一次查词沿用上一窗的一侧');
  assert.ok(src.includes('window._renderInProgress && themeCap > height'),
    '未锁边时必须按尾批在途状态用 theme 上限选边');
});
