// 词典样式统一（M3E）的行为测试：用 node 真执行 popup.js 的
// __fushiScheduleM3eDictTone → __fushiUnifyDictStyles / __fushiClearDictUnify，
// 喂一棵带「计算样式」的假 DOM，断言：
//   1. 默认开（宿主没注入 window.__fushiDictUnifiedStyle）：作用域挂上
//      .fushi-dict-unified，各元素按语义打上 data-fushi-dt*；
//   2. 量样式时作用域类必须已摘掉（否则量到的是统一后的颜色而不是词典原色）；
//   3. 关掉（false）后经 __fushiApplyDictUnifiedStyle 就地摘类 → 词典原样式回来；
//      再打开又按原色重新分类。
// 不按词典名做任何判断：这里的元素都没有词典名，只有颜色 / 显示类型 / 字数。

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('./_popup_dom_host');

const UNIFIED = 'fushi-dict-unified';
const MEASURING = 'fushi-dict-unify-measuring';

function rgb(r, g, b, a) {
  return a === undefined ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${a})`;
}

const BASE_STYLE = {
  color: rgb(26, 28, 25),
  backgroundColor: rgb(0, 0, 0, 0),
  backgroundImage: 'none',
  display: 'inline',
  fontSize: '15px',
  paddingLeft: '0px',
  borderTopWidth: '0px', borderRightWidth: '0px', borderBottomWidth: '0px', borderLeftWidth: '0px',
  borderTopStyle: 'none', borderRightStyle: 'none', borderBottomStyle: 'none', borderLeftStyle: 'none',
  borderTopColor: rgb(26, 28, 25),
};

// 极简元素：只实现分类代码真正用到的接口。
function node(tag, opts, children) {
  opts = opts || {};
  const classes = new Set((opts.className || '').split(/\s+/).filter(Boolean));
  const n = {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    isConnected: true,
    parentElement: null,
    children: [],
    attributes: {},
    style: Object.assign({}, BASE_STYLE, opts.style || {}),
    pseudo: opts.pseudo || {},
    ownText: opts.text || '',
    classList: {
      add(c) { classes.add(c); },
      remove(c) { classes.delete(c); },
      contains(c) { return classes.has(c); },
    },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    getAttribute(k) { return this.hasAttribute(k) ? this.attributes[k] : null; },
    setAttribute(k, v) { this.attributes[k] = String(v); },
    removeAttribute(k) { delete this.attributes[k]; },
    get textContent() { return this.ownText + this.children.map((c) => c.textContent).join(''); },
    descendants() {
      const out = [];
      const walk = (p) => p.children.forEach((c) => { out.push(c); walk(c); });
      walk(this);
      return out;
    },
    matchesOne(sel) {
      sel = sel.trim();
      if (sel === '*') return true;
      const desc = /^(\S+)\s+\*$/.exec(sel);
      if (desc) {
        for (let p = this.parentElement; p; p = p.parentElement) {
          if (p.matchesOne(desc[1])) return true;
        }
        return false;
      }
      if (sel.startsWith('.')) return classes.has(sel.slice(1));
      if (/^[a-z]+$/i.test(sel)) return this.tagName === sel.toUpperCase();
      return false; // 复合选择器：本测试的节点都不需要命中
    },
    matches(sel) { return sel.split(',').some((s) => this.matchesOne(s)); },
    querySelectorAll(sel) { return this.descendants().filter((d) => d.matches(sel)); },
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
  };
  (children || []).forEach((c) => { c.parentElement = n; n.children.push(c); });
  return n;
}

function hasUnifiedAncestor(n) {
  for (let p = n; p; p = p.parentElement) {
    if (p.classList.contains(UNIFIED)) return true;
  }
  return false;
}

const sandbox = loadPopup();
let measuredUnderUnifiedClass = 0;
let measuredWithoutMeasuringClass = 0;
sandbox.getComputedStyle = (n, pseudo) => {
  if (hasUnifiedAncestor(n)) measuredUnderUnifiedClass++;
  // 量的时候作用域必须挂着 measuring 类：popup.css 的旧暗色调灰规则见它让路。
  let scopeNode = n;
  while (scopeNode && !scopeNode.classList.contains('glossary-content')) scopeNode = scopeNode.parentElement;
  if (scopeNode && !scopeNode.classList.contains(MEASURING)) measuredWithoutMeasuringClass++;
  if (pseudo) {
    const key = pseudo.replace(/^:+/, '');
    return Object.assign({}, BASE_STYLE, { content: 'none' }, n.pseudo[key] || {});
  }
  return n.style;
};
// 同步执行；返回 0 是因为调度器在回调里先清 raf 句柄、返回后又把返回值写回句柄，
// 非 0 会让之后的每次调度都以为「已有一帧在排队」。
sandbox.requestAnimationFrame = (fn) => { fn(); return 0; };
const fn = (name) => vm.runInContext(name, sandbox);

function buildTree() {
  const els = {
    posTag: node('span', { text: '動', style: { backgroundColor: rgb(200, 30, 30), color: rgb(255, 255, 255) } }),
    posTagInner: null,
    framedLabel: node('span', {
      text: '参考',
      style: {
        color: rgb(30, 60, 200),
        paddingLeft: '2px',
        borderTopWidth: '1px', borderRightWidth: '1px', borderBottomWidth: '1px', borderLeftWidth: '1px',
        borderTopStyle: 'solid', borderRightStyle: 'solid', borderBottomStyle: 'solid', borderLeftStyle: 'solid',
        borderTopColor: rgb(30, 60, 200),
      },
    }),
    kanjiBox: node('div', { text: '字', style: { display: 'block', fontSize: '40px', backgroundColor: rgb(130, 20, 30), color: rgb(255, 255, 255) } }),
    exampleBlock: node('div', { text: '例文がここに入る長い一文です。', style: { display: 'block', backgroundColor: rgb(255, 240, 240) } }),
    greenExample: node('span', { text: '緑の例文', style: { color: rgb(0, 128, 0) } }),
    grayNote: node('span', { text: '注記', style: { color: rgb(130, 130, 130) } }),
    whitePage: node('div', { text: '本文', style: { display: 'block', backgroundColor: rgb(255, 255, 255) } }),
    pseudoTag: node('span', { text: 'みる', pseudo: { before: { content: '"名"', backgroundColor: rgb(0, 90, 180), color: rgb(255, 255, 255) } } }),
    image: node('img', { style: { backgroundColor: rgb(0, 0, 0) } }),
    plainText: node('span', { text: '普通の本文' }),
  };
  // 标签里再套一层同色字：它跟随标签的 on-color，不得单独打标。
  els.posTagInner = node('span', { text: '詞', style: { color: rgb(255, 255, 255), backgroundColor: rgb(200, 30, 30) } });
  els.posTag.children.push(els.posTagInner);
  els.posTagInner.parentElement = els.posTag;

  const scope = node('div', { className: 'glossary-content' }, Object.keys(els)
    .filter((k) => k !== 'posTagInner')
    .map((k) => els[k]));
  scope.style = Object.assign({}, BASE_STYLE, { display: 'block' });
  const root = node('div', { className: 'entry' }, [scope]);
  return { root, scope, els };
}

const schedule = fn('__fushiScheduleM3eDictTone');
const dt = (n, attr) => n.getAttribute(attr || 'data-fushi-dt');

// ── 1. 默认开：宿主没注入开关 ─────────────────────────────────────────────
assert.strictEqual(sandbox.window.__fushiDictUnifiedStyle, undefined);
const { root, scope, els } = buildTree();
schedule(root);

assert.ok(scope.classList.contains(UNIFIED), 'default (no host flag) must unify');
assert.strictEqual(measuredUnderUnifiedClass, 0,
  'computed styles must be read with the unified class removed (dictionary originals)');
assert.strictEqual(measuredWithoutMeasuringClass, 0,
  'measurement must run under the measuring class so legacy recolour rules stand down');
assert.ok(!scope.classList.contains(MEASURING), 'measuring class is removed afterwards');
assert.strictEqual(dt(els.posTag), 'chip', 'short inline element with a solid background -> chip');
assert.strictEqual(els.posTag.hasAttribute('data-fushi-dt-pad'), true, 'zero-padding chip gets inline padding');
assert.strictEqual(dt(els.posTagInner), null, 'content inside a chip follows the chip on-color');
assert.strictEqual(dt(els.framedLabel), 'chip-outline', 'short inline element boxed on all sides -> outlined chip');
assert.strictEqual(els.framedLabel.hasAttribute('data-fushi-dt-pad'), false);
assert.strictEqual(dt(els.kanjiBox), 'block', 'enlarged / block element on a dark fill -> primaryContainer block');
assert.strictEqual(dt(els.exampleBlock), 'panel', 'block on a pale fill -> surface panel');
assert.strictEqual(dt(els.greenExample), 'accent', 'chromatic text -> primary accent');
assert.strictEqual(dt(els.grayNote), 'muted', 'grey text -> onSurfaceVariant');
assert.strictEqual(dt(els.whitePage), null, 'a white page fill is not a semantic surface');
assert.strictEqual(dt(els.pseudoTag), null);
assert.strictEqual(dt(els.pseudoTag, 'data-fushi-dt-before'), 'chip', '::before label on a fill -> chip');
assert.strictEqual(dt(els.image), null, 'media is never classified');
assert.strictEqual(dt(els.plainText), null, 'default body text keeps inheriting');

// ── 2. 关掉：就地摘类，词典原样式回来 ─────────────────────────────────────
sandbox.window.__fushiDictUnifiedStyle = false;
sandbox.window.__fushiApplyDictUnifiedStyle();
assert.ok(!scope.classList.contains(UNIFIED), 'turning it off must drop the unified scope class');

// 关着时新渲染的词条也不会被统一。
const second = buildTree();
schedule(second.root);
assert.ok(!second.scope.classList.contains(UNIFIED), 'new renders stay original while off');
assert.strictEqual(dt(second.els.posTag), null, 'no classification happens while off');

// ── 3. 再打开：按词典原色重新分类（量的时候类已摘） ──────────────────────
// 模拟用户在关闭期间换了词典样式：原本红底的标签变成无底彩字。
els.posTag.style = Object.assign({}, BASE_STYLE, { color: rgb(200, 30, 30) });
measuredUnderUnifiedClass = 0;
sandbox.window.__fushiDictUnifiedStyle = true;
sandbox.window.__fushiApplyDictUnifiedStyle();
assert.ok(scope.classList.contains(UNIFIED), 're-enabling must unify again');
assert.ok(second.scope.classList.contains(UNIFIED), 're-enabling covers renders made while off');
assert.strictEqual(measuredUnderUnifiedClass, 0, 're-classification must also read dictionary originals');
assert.strictEqual(dt(els.posTag), 'accent', 'stale tags are replaced, not accumulated');
assert.strictEqual(els.posTag.hasAttribute('data-fushi-dt-pad'), false, 'stale pad marker removed');

console.log('popup dict unified style: all assertions passed');
