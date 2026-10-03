// 查词「按句意挑词条」的弹窗侧行为守卫：宿主只换词条顺序时，popup.js 的
// `window.fushiReorderPopupEntries` 只挪已渲染的 `.entry` 卡片——
//   * 不调 renderPopup / 不滚回顶 / 不清已选释义 / 不把句子上下文镜像归 0（全量重渲染
//     会做这三件事，而宿主的制卡草稿没清，于是界面 0/0、卡片却带着旧前后句：BUG-297 型错位）；
//   * window.lookupEntries 原样不动（按钮闭包与 selectedDictionaries 都按它的下标记账）；
//   * _entryDomIndex 按卡片自带的下标重建，之后的增量追加仍能找对卡片；
//   * 尾批渲染未完时先挂起，收尾才挪；被新一轮渲染取代就作废。
//
// 真执行 popup.js 里提取出的函数（不是复刻品），DOM 用最小 fake。
// 运行：node fushi/test/dictionary/popup_entry_reorder_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupPath = path.resolve(
  __dirname, '..', '..', 'assets', 'popup', 'popup.js');
const popupSrc = fs.readFileSync(popupPath, 'utf8');

// ---- 最小 fake DOM：只实现被测代码用到的兄弟链操作 -------------------------
class FakeNode {
  constructor(tagName, className, label) {
    this.tagName = String(tagName).toUpperCase();
    this.className = className || '';
    this.label = label || '';
    this.parentNode = null;
    this.childNodes = [];
    this.top = 0;
  }

  get previousSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    const i = siblings.indexOf(this);
    return i > 0 ? siblings[i - 1] : null;
  }

  get nextSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    const i = siblings.indexOf(this);
    return i >= 0 && i + 1 < siblings.length ? siblings[i + 1] : null;
  }

  appendChild(child) {
    return this.insertBefore(child, null);
  }

  insertBefore(child, ref) {
    if (child.parentNode) child.parentNode.removeChild(child);
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (ref && i < 0) throw new Error('insertBefore: ref is not a child');
    if (i < 0) this.childNodes.push(child);
    else this.childNodes.splice(i, 0, child);
    child.parentNode = this;
    return child;
  }

  removeChild(child) {
    const i = this.childNodes.indexOf(child);
    if (i < 0) throw new Error('removeChild: not a child');
    this.childNodes.splice(i, 1);
    child.parentNode = null;
    return child;
  }

  querySelectorAll(selector) {
    assert.strictEqual(selector, ':scope > .entry',
      'reorder must only address direct .entry children');
    return this.childNodes.filter((n) => n.className === 'entry');
  }

  // 纵向布局：按兄弟序累加固定高度，供滚动锚定断言。
  getBoundingClientRect() {
    const scroller = this.__scroller;
    let y = 0;
    for (const n of this.parentNode.childNodes) {
      if (n === this) break;
      y += n.tagName === 'HR' ? 1 : 100;
    }
    const top = y - (scroller ? scroller.scrollTop : 0);
    return { top: top, bottom: top + 100 };
  }
}

function extract(pattern, what) {
  const match = popupSrc.match(pattern);
  assert.ok(match, 'popup.js must define ' + what);
  return match[0];
}

const sources = [
  extract(/function rebuildEntryDomIndex\(container, length\) \{[\s\S]*?\n\}/,
    'rebuildEntryDomIndex'),
  extract(/function popupEntryOrderKey\(entry\) \{[\s\S]*?\n\}/,
    'popupEntryOrderKey'),
  extract(/window\.fushiReorderPopupEntries = function\(keys\) \{[\s\S]*?\n\};/,
    'window.fushiReorderPopupEntries'),
  extract(/function applyPendingPopupEntryOrder\(\) \{[\s\S]*?\n\}/,
    'applyPendingPopupEntryOrder'),
  extract(/function applyPopupEntryOrder\(keys\) \{[\s\S]*?\n\}/,
    'applyPopupEntryOrder'),
];

// 卡片必须在唯一的建卡点带上自己的数组下标，否则重排后无从重建映射。
assert.ok(
  /const entryDiv = el\('div', \{ className: 'entry' \}\);\s*(\/\/[^\n]*\n\s*)*entryDiv\.__fushiLookupIndex = idx;/
    .test(popupSrc),
  'buildEntryElement must stamp entryDiv.__fushiLookupIndex = idx');
// 增量追加不得再按「DOM 序 = 数组序」数数重建映射。
assert.ok(
  popupSrc.includes(
    'window._entryDomIndex = rebuildEntryDomIndex(container, entries.length);'),
  'updatePopupIncremental must rebuild _entryDomIndex from card identity');
// 终渲染信号要落地挂起的重排。
assert.ok(
  /function _firePopupRendered\(stillRendering\) \{[\s\S]*?if \(!stillRendering\) applyPendingPopupEntryOrder\(\);/
    .test(popupSrc),
  '_firePopupRendered must apply a pending reorder on the final signal');

function setup({ kanji = false, scrollTop = 0 } = {}) {
  const container = new FakeNode('div', 'entries-container');
  const scroller = { scrollTop: scrollTop };
  const calls = [];
  const spy = (name) => () => { calls.push(name); };
  const lookupEntries = [
    { expression: '期限', reading: 'きげん' },
    { expression: '機嫌', reading: 'きげん' },
    { expression: '起源', reading: 'きげん' },
  ];
  if (kanji) container.appendChild(new FakeNode('div', 'kanji-section'));
  lookupEntries.forEach((entry, idx) => {
    if (container.childNodes.length > 0) container.appendChild(new FakeNode('hr'));
    const card = new FakeNode('div', 'entry', entry.expression);
    card.__fushiLookupIndex = idx;
    card.__scroller = scroller;
    container.appendChild(card);
  });
  const window = {
    lookupEntries: lookupEntries,
    _entryDomIndex: [0, 1, 2],
    _renderInProgress: false,
    _renderGeneration: 7,
    __fushiPendingEntryOrder: null,
    renderPopup: spy('renderPopup'),
    __fushiResetPopupScroll: spy('__fushiResetPopupScroll'),
    resetSelectedDictionaries: spy('resetSelectedDictionaries'),
    resetSentenceContextMirror: spy('resetSentenceContextMirror'),
  };
  const context = {
    window: window,
    document: {
      scrollingElement: scroller,
      documentElement: scroller,
      createElement: (tag) => new FakeNode(tag),
    },
    __fushiContainer: () => container,
    Array, Map, Set, String,
  };
  vm.createContext(context);
  vm.runInContext(sources.join('\n') +
    '\nthis.__applyPending = applyPendingPopupEntryOrder;', context);
  return { container, window, calls, scroller, applyPending: context.__applyPending };
}

const key = (e, r) => e + '\u0001' + r;
const labels = (container) => container.childNodes.map(
  (n) => (n.tagName === 'HR' ? '|' : n.label || n.className));

// ---- ① 只挪卡片，不触发任何重置 -------------------------------------------
{
  const { container, window, calls } = setup();
  const before = window.lookupEntries;
  const ok = window.fushiReorderPopupEntries([
    key('機嫌', 'きげん'), key('期限', 'きげん'), key('起源', 'きげん'),
  ]);
  assert.strictEqual(ok, true);
  assert.deepStrictEqual(labels(container), ['機嫌', '|', '期限', '|', '起源'],
    'the chosen headword card moves first, separators stay between cards');
  assert.deepStrictEqual(calls, [],
    'an order-only update must not re-render, reset scroll, clear the selected '
    + 'dictionaries or zero the sentence-context mirror');
  assert.strictEqual(window.lookupEntries, before,
    'window.lookupEntries must stay the same array');
  assert.deepStrictEqual(window.lookupEntries.map((e) => e.expression),
    ['期限', '機嫌', '起源'], 'lookupEntries keeps its original order');
  assert.deepStrictEqual(window._entryDomIndex, [1, 0, 2],
    '_entryDomIndex follows the cards: entries[1] is now DOM card 0');
}

// ---- ② 上方有汉字卡：首卡前的分隔线保留 -------------------------------------
{
  const { container, window } = setup({ kanji: true });
  window.fushiReorderPopupEntries([key('起源', 'きげん')]);
  assert.deepStrictEqual(labels(container),
    ['kanji-section', '|', '起源', '|', '期限', '|', '機嫌'],
    'unlisted cards keep their DOM order after the claimed ones; kanji card stays on top');
  assert.deepStrictEqual(window._entryDomIndex, [1, 2, 0]);
}

// ---- ③ 已滚动：以视口顶部那张卡为锚，挪完内容不跳 -------------------------
{
  // 每卡 100、分隔线 1：scrollTop=150 时视口顶落在第二张卡（期限 0..100 | 機嫌 101..201）。
  const { container, window, scroller } = setup({ scrollTop: 150 });
  const anchor = container.childNodes[2];
  const before = anchor.getBoundingClientRect().top;
  window.fushiReorderPopupEntries([key('機嫌', 'きげん')]);
  assert.strictEqual(anchor.getBoundingClientRect().top, before,
    'the card at the viewport top keeps its on-screen position');
  assert.notStrictEqual(scroller.scrollTop, 0, 'scroll position is never reset to top');
}

// ---- ④ 尾批渲染未完：挂起，终信号落地；换代作废 -----------------------------
{
  const { container, window, applyPending } = setup();
  window._renderInProgress = true;
  assert.strictEqual(
    window.fushiReorderPopupEntries([key('機嫌', 'きげん')]), true);
  assert.deepStrictEqual(labels(container), ['期限', '|', '機嫌', '|', '起源'],
    'nothing moves while the tail batch is still being built');
  window._renderInProgress = false;
  applyPending();
  assert.deepStrictEqual(labels(container), ['機嫌', '|', '期限', '|', '起源'],
    'the pending order lands on the final render signal');
}
{
  const { container, window, applyPending } = setup();
  window._renderInProgress = true;
  window.fushiReorderPopupEntries([key('機嫌', 'きげん')]);
  window._renderGeneration += 1; // 新一轮 renderPopup 取代了这批 DOM
  window._renderInProgress = false;
  applyPending();
  assert.deepStrictEqual(labels(container), ['期限', '|', '機嫌', '|', '起源'],
    'a pending order from a superseded render generation is dropped');
  assert.strictEqual(window.__fushiPendingEntryOrder, null);
}

// ---- ⑤ 顺序没变：零 DOM 操作 ----------------------------------------------
{
  const { container, window } = setup();
  const nodes = container.childNodes.slice();
  window.fushiReorderPopupEntries([
    key('期限', 'きげん'), key('機嫌', 'きげん'), key('起源', 'きげん'),
  ]);
  assert.ok(container.childNodes.every((n, i) => n === nodes[i]),
    'an unchanged order must not touch the DOM');
}

console.log('all assertions passed');
