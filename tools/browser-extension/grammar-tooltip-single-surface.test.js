const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 词形变化语法说明浮层的**行为**测试（BUG-2041 / BUG-2042）。
//
// 用户原话：「到底用不用点击，点击和不点击的统一改一下吧」。此前同一段
// data-description 有两套呈现：click 走 popup.html 的静态 `.overlay` 全屏卡片
// （showDescription / closeOverlay），hover 走 `.grammar-tooltip` 浮层。现在收成
// 一套——hover 预览、click 钉住，钉住只是同一节点多一个 .is-pinned。
//
// 为什么必须是行为测试而不是源码扫描：popup.js 的注释里大量出现 `.overlay`、
// `showDescription`、`is-pinned` 这些名字（讲的正是这段历史），任何按字面量扫全文的
// 守卫都会被注释喂饱而假绿。这里把真源码切片丢进 vm 真执行，对着真函数发事件、读真
// 状态。切片两端的锚点都断言过，源码重排会让本测试红而不是静默失效。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');

/** 极简 DOM：只实现被测代码真正用到的那几个能力。 */
function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    style: {},
    textContent: '',
    innerHTML: '',
    children: [],
    parentNode: null,
    _attrs: {},
    _listeners: {},
    nodeType: 1,
    setAttribute(k, v) { el._attrs[k] = String(v); if (k === 'class') el.className = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(el._attrs, k) ? el._attrs[k] : null; },
    addEventListener(type, fn) { (el._listeners[type] ||= []).push(fn); },
    dispatch(type, ev) { (el._listeners[type] || []).forEach((fn) => fn(ev)); },
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    append(...kids) { kids.forEach((k) => el.appendChild(k)); },
    contains(x) {
      if (x === el) return true;
      return el.children.some((c) => c.contains && c.contains(x));
    },
    // 只支持 `.cls` 形式——被测代码就只用这一种。
    closest(sel) {
      const want = sel.replace(/^\./, '');
      let node = el;
      while (node) {
        if (String(node.className).split(/\s+/).includes(want)) return node;
        node = node.parentNode;
      }
      return null;
    },
    querySelector(sel) {
      const want = sel.replace(/^\./, '');
      const walk = (n) => {
        for (const c of n.children) {
          if (String(c.className).split(/\s+/).includes(want)) return c;
          const hit = walk(c);
          if (hit) return hit;
        }
        return null;
      };
      return walk(el);
    },
    getBoundingClientRect() { return el._rect || { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
  };
  el.classList = {
    add(c) { if (!String(el.className).split(/\s+/).includes(c)) el.className = (el.className + ' ' + c).trim(); },
    remove(c) { el.className = String(el.className).split(/\s+/).filter((x) => x && x !== c).join(' '); },
    contains(c) { return String(el.className).split(/\s+/).includes(c); },
    toggle(c, force) { if (force) el.classList.add(c); else el.classList.remove(c); },
  };
  return el;
}

/**
 * 切出「浮层三函数 + pointerdown 收起」那一段真源码并执行。
 * 起点是浮层那段注释的第一行，终点是它下面第一个不属于浮层的函数。
 */
function loadTooltip({ zoom = 1, viewportWidth = 800, viewportHeight = 600, canHover = true } = {}) {
  const src = fs.readFileSync(POPUP, 'utf8');
  const START = '/** 当前钉住的那枚 .deinflection-tag';
  const END = 'function createFuriganaSegment';
  const start = src.indexOf(START);
  assert.ok(start >= 0, '切片起点锚失效：找不到 _grammarPinnedAnchor 的声明注释');
  const endMarker = src.indexOf(END, start);
  assert.ok(endMarker > start, '切片终点锚失效：找不到 createFuriganaSegment');
  // 回退到该函数上方的注释之前，切片必须是自洽可执行的一段。
  const end = src.lastIndexOf('// https://', endMarker);
  let slice = src.slice(start, end > start ? end : endMarker);
  for (const need of ['showGrammarTooltip', 'hideGrammarTooltip', 'ensureGrammarTooltip',
    'onGrammarTooltipPointerDown', 'isGrammarTooltipPinned']) {
    assert.ok(slice.includes(need), `切片里没有 ${need}，锚点已漂移`);
  }

  // 第二段：createDeinflectionTag。「点击到底做什么」住在它的 onclick 里——只切浮层
  // 三函数的话，把 onclick 的 `true` 改成 `false`（= 点击退化成又一次 hover 预览，
  // 正是用户抱怨的「不统一」）本测试抓不到。变异实测发现的缺口，补在这里。
  const TAG_START = 'function createDeinflectionTag(tag) {';
  const TAG_END = 'function createFrequencyGroup';
  const tagStart = src.indexOf(TAG_START);
  assert.ok(tagStart >= 0, '切片锚失效：找不到 createDeinflectionTag');
  const tagEnd = src.indexOf(TAG_END, tagStart);
  assert.ok(tagEnd > tagStart, '切片锚失效：找不到 createDeinflectionTag 的下界');
  const tagSlice = src.slice(tagStart, tagEnd);
  assert.ok(tagSlice.includes('onclick') && tagSlice.includes('onmouseenter'),
    'createDeinflectionTag 切片里没有 onclick/onmouseenter，锚点已漂移');
  slice += '\n' + tagSlice;

  const root = makeEl('div');
  const docListeners = {};
  const ctx = {
    console,
    Node: { TEXT_NODE: 3 },
    Math,
    Number,
    document: {
      createElement: (t) => makeEl(t),
      addEventListener(type, fn) { (docListeners[type] ||= []).push(fn); },
      documentElement: { style: { zoom: String(zoom) } },
    },
    window: {
      innerHeight: viewportHeight,
      __fushiPopupViewportWidth: viewportWidth,
      matchMedia: (q) => ({ matches: q.includes('hover') ? canHover : false }),
    },
    // popup.js 里这些 helper 住在切片之外，按其真实语义提供最小实现。
    __fushiRootNode: () => root,
    __fushiOverlayParent: () => root,
    __fushiViewportWidth: () => viewportWidth,
    __fushiPopupContentZoom: () => zoom,
    __fushiEventTarget: (e) => e.target,
    el(tag, props = {}, children = []) {
      const node = makeEl(tag);
      for (const [k, v] of Object.entries(props)) {
        // 真 el() 是 `if (key in element) element[key] = value; else setAttribute(...)`。
        // onclick / onmouseenter 在真 DOM 元素上存在 → 直接赋值；'data-description'
        // 不存在 → setAttribute。这里按同一条判据分流。
        if (typeof v === 'function' || k === 'className' || k === 'textContent') node[k] = v;
        else node.setAttribute(k, v);
      }
      children.forEach((c) => node.appendChild(c));
      return node;
    },
    iconSvg: () => '<svg></svg>',
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(slice, ctx);
  return { ctx, root, docListeners };
}

/** 造一枚带说明的 .deinflection-tag（挂在 root 下，closest 才走得通）。 */
function makeTag(env, name, description, rect) {
  const tag = makeEl('span');
  tag.className = 'deinflection-tag has-description';
  tag.textContent = name;
  tag.setAttribute('data-description', description);
  tag._rect = rect || { left: 20, top: 40, right: 80, bottom: 60, width: 60, height: 20 };
  env.root.appendChild(tag);
  return tag;
}

function tooltipOf(env) {
  return env.root.querySelector('.grammar-tooltip');
}

/** 走真 createDeinflectionTag 造标签——onclick / onmouseenter 由被测源码自己挂。 */
function realTag(env, name, description) {
  const tag = env.ctx.createDeinflectionTag({ name, description });
  tag._rect = { left: 20, top: 40, right: 80, bottom: 60, width: 60, height: 20 };
  env.root.appendChild(tag);
  return tag;
}

// ── 用户的原始问题：点击到底做什么、和不点击有什么区别 ──────────────────
test('点击标签 = 钉住（不是又变成一次 hover 预览）', () => {
  const env = loadTooltip();
  const tag = realTag(env, 'causative', '让某人做某事。');

  tag.onclick.call(tag);

  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true,
    '点击必须钉住；退化成预览就等于「点击和不点击一个样」');
  const tip = tooltipOf(env);
  assert.strictEqual(tip.classList.contains('is-pinned'), true);
  assert.strictEqual(tip.querySelector('.grammar-tooltip-title').textContent, 'causative');
});

test('再点同一枚标签 = 收起（toggle）', () => {
  const env = loadTooltip();
  const tag = realTag(env, 'causative', '说明');

  tag.onclick.call(tag);
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true);
  tag.onclick.call(tag);
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false, '再点一次应收起');
  assert.strictEqual(tooltipOf(env).style.display, 'none');
});

test('hover 进入 = 预览，离开即收（未钉住时）', () => {
  const env = loadTooltip();
  const tag = realTag(env, 'causative', '说明');

  tag.onmouseenter.call(tag);
  assert.strictEqual(tooltipOf(env).style.display, 'block');
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false);

  tag.onmouseleave.call(tag);
  assert.strictEqual(tooltipOf(env).style.display, 'none');
});

test('已钉住时，鼠标划过/离开不动摇浮层', () => {
  const env = loadTooltip();
  const a = realTag(env, 'causative', '甲');
  const b = realTag(env, 'passive', '乙');

  a.onclick.call(a);
  b.onmouseenter.call(b);
  assert.strictEqual(tooltipOf(env).querySelector('.grammar-tooltip-body').textContent, '甲',
    '钉住是显式选择，不该被划过别的标签顶掉');

  a.onmouseleave.call(a);
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true, '钉住态不该被 mouseleave 收走');
  assert.strictEqual(tooltipOf(env).style.display, 'block');
});

test('没有说明的标签（文本变体归一回落）既不可点也不 hover', () => {
  const env = loadTooltip();
  const tag = env.ctx.createDeinflectionTag({ name: 'colour → color', description: '' });
  assert.strictEqual(tag.onclick, undefined, '没说明就不该挂 click，免得点开一个空框');
  assert.strictEqual(tag.onmouseenter, undefined);
  assert.ok(!String(tag.className).includes('has-description'));
});

test('hover 预览：不钉住、不显示标题、鼠标穿透', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '让某人做某事。');
  env.ctx.showGrammarTooltip(tag, false);

  const tip = tooltipOf(env);
  assert.ok(tip, '浮层未创建');
  assert.strictEqual(tip.style.display, 'block');
  assert.strictEqual(tip.querySelector('.grammar-tooltip-body').textContent, '让某人做某事。');
  assert.strictEqual(tip.classList.contains('is-pinned'), false, 'hover 不该钉住');
  assert.strictEqual(tip.querySelector('.grammar-tooltip-title').textContent, '',
    'hover 预览不显示标题');
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false);
});

test('click 钉住：同一个节点，加 .is-pinned 并显示变形名标题', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '让某人做某事。');
  env.ctx.showGrammarTooltip(tag, true);

  const tip = tooltipOf(env);
  assert.strictEqual(tip.classList.contains('is-pinned'), true);
  assert.strictEqual(tip.querySelector('.grammar-tooltip-title').textContent, 'causative');
  assert.strictEqual(tip.querySelector('.grammar-tooltip-body').textContent, '让某人做某事。');
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true);
});

test('钉住态与预览态是同一个 DOM 节点（不是两套皮）', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '说明');
  env.ctx.showGrammarTooltip(tag, false);
  const preview = tooltipOf(env);
  env.ctx.showGrammarTooltip(tag, true);
  const pinned = tooltipOf(env);
  assert.strictEqual(preview, pinned, 'hover 与 click 必须复用同一个浮层节点');
});

test('触屏（无 hover 能力）：预览被抑制，但点击钉住照常可用', () => {
  const env = loadTooltip({ canHover: false });
  const tag = makeTag(env, 'causative', '说明');

  env.ctx.showGrammarTooltip(tag, false);
  assert.strictEqual(tooltipOf(env), null, '不可 hover 的设备不该弹出预览');

  env.ctx.showGrammarTooltip(tag, true);
  const tip = tooltipOf(env);
  assert.ok(tip && tip.style.display === 'block',
    '触屏靠点击看说明——这正是原 .overlay 卡片的职责，不能一起被抑制');
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true);
});

test('收起会清空内容与钉住态', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '说明');
  env.ctx.showGrammarTooltip(tag, true);
  env.ctx.hideGrammarTooltip();

  const tip = tooltipOf(env);
  assert.strictEqual(tip.style.display, 'none');
  assert.strictEqual(tip.classList.contains('is-pinned'), false);
  assert.strictEqual(tip.querySelector('.grammar-tooltip-body').textContent, '');
  assert.strictEqual(tip.querySelector('.grammar-tooltip-title').textContent, '');
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false);
});

test('点浮层自身不收起（钉住态要能选中复制、点关闭按钮）', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '说明');
  env.ctx.showGrammarTooltip(tag, true);

  const body = tooltipOf(env).querySelector('.grammar-tooltip-body');
  env.ctx.onGrammarTooltipPointerDown({ target: body });
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true,
    '按在浮层内部就收起的话，钉住态根本没法用');
});

test('点当前钉住的那枚标签不收起（否则 click 的 toggle 永远打不开）', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '说明');
  env.ctx.showGrammarTooltip(tag, true);

  env.ctx.onGrammarTooltipPointerDown({ target: tag });
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), true,
    'pointerdown 先把 _grammarPinnedAnchor 清掉，click 就判不出「已钉住」了');
});

test('点别处收起', () => {
  const env = loadTooltip();
  const tag = makeTag(env, 'causative', '说明');
  env.ctx.showGrammarTooltip(tag, true);

  const other = makeEl('div');
  env.root.appendChild(other);
  env.ctx.onGrammarTooltipPointerDown({ target: other });
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false);
  assert.strictEqual(tooltipOf(env).style.display, 'none');
});

test('点另一枚标签会收起当前钉住的（随后由它自己的 click 重新钉住）', () => {
  const env = loadTooltip();
  const a = makeTag(env, 'causative', '甲');
  const b = makeTag(env, 'passive', '乙');
  env.ctx.showGrammarTooltip(a, true);

  env.ctx.onGrammarTooltipPointerDown({ target: b });
  assert.strictEqual(env.ctx.isGrammarTooltipPinned(), false);
});

test('BUG-2042：left/top 按内容 zoom 折回 layout px，不再双重缩放', () => {
  const zoom = 2;
  const env = loadTooltip({ zoom, viewportWidth: 800, viewportHeight: 600 });
  // 锚点 rect 是**视觉 px**（已乘 zoom）。
  const tag = makeTag(env, 'causative', '说明',
    { left: 100, top: 40, right: 160, bottom: 60, width: 60, height: 20 });
  const tip = makeElRectPatch(env, { width: 200, height: 50 });

  env.ctx.showGrammarTooltip(tag, false);

  // 期望：视觉坐标 left=100 / top=bottom+6=66，写进 style 前各 / zoom。
  assert.strictEqual(tip().style.left, (100 / zoom) + 'px');
  assert.strictEqual(tip().style.top, ((60 + 6) / zoom) + 'px');
});

test('BUG-2042：max-width 按视口收窄且同样折回 layout px（窄屏自适应）', () => {
  const zoom = 2;
  const env = loadTooltip({ zoom, viewportWidth: 300, viewportHeight: 600 });
  const tag = makeTag(env, 'causative', '说明');
  makeElRectPatch(env, { width: 200, height: 50 });

  env.ctx.showGrammarTooltip(tag, false);

  // 视觉可用宽 = 300 - 2*8 = 284（< 460 上限）→ layout px = 284 / 2。
  assert.strictEqual(tooltipOf(env).style.maxWidth, (284 / zoom) + 'px');
});

test('zoom = 1 时坐标与折算前逐字节等价（不引入回归）', () => {
  const env = loadTooltip({ zoom: 1, viewportWidth: 800, viewportHeight: 600 });
  const tag = makeTag(env, 'causative', '说明',
    { left: 100, top: 40, right: 160, bottom: 60, width: 60, height: 20 });
  makeElRectPatch(env, { width: 200, height: 50 });

  env.ctx.showGrammarTooltip(tag, false);
  assert.strictEqual(tooltipOf(env).style.left, '100px');
  assert.strictEqual(tooltipOf(env).style.top, '66px');
});

/**
 * 让浮层量出给定尺寸：浮层是懒创建的，先跑一次拿到节点再钉死它的 rect，
 * 返回一个取当前浮层的 getter。
 */
function makeElRectPatch(env, size) {
  const seed = makeTag(env, 'seed', 'seed');
  env.ctx.showGrammarTooltip(seed, false);
  const tip = tooltipOf(env);
  tip._rect = { left: 0, top: 0, right: size.width, bottom: size.height, ...size };
  env.ctx.hideGrammarTooltip();
  return () => tooltipOf(env);
}
