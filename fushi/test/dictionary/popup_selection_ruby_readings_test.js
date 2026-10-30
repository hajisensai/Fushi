// 释义里点词带来源振假名：assets/popup/selection.js 的 rubyReadings。
//
// 症状：弹窗释义里的 `<ruby>忙<rt>せわ</rt></ruby>しい` 点「忙」发起嵌套查词，来源读音
// 在取词时随 <rt> 被 createWalker 拒掉而丢失，嵌套弹窗按词频排序而不是按来源读音。
// 修：selectFromPosition 产出 selection.rubyReadings 并作为 textSelected 第 3 参交给宿主。
//
// 在最小 fake DOM 里真执行 popup selection.js（路径经 FUSHI_POPUP_SELECTION_JS，缺省取
// assets/popup/selection.js）。
//
// 运行：node fushi/test/dictionary/popup_selection_ruby_readings_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function matches(node, part) {
  if (part.startsWith('.')) {
    return (node.className || '').split(/\s+/).includes(part.slice(1));
  }
  return (node.tagName || '').toLowerCase() === part.toLowerCase();
}

function link(parent, children) {
  parent.childNodes = children;
  for (let i = 0; i < children.length; i++) {
    children[i].parentElement = parent;
    children[i].nextSibling = children[i + 1] || null;
  }
  parent.firstChild = children[0] || null;
  return parent;
}

function text(content) {
  return { nodeType: 3, textContent: content, nodeValue: content, parentElement: null, nextSibling: null };
}

function el(tagName, children, className) {
  const node = {
    nodeType: 1,
    tagName: tagName.toUpperCase(),
    className: className || '',
    parentElement: null,
    nextSibling: null,
    firstChild: null,
    childNodes: [],
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim()).filter(Boolean);
      let cur = this;
      while (cur && cur.nodeType === 1) {
        if (parts.some((p) => matches(cur, p))) return cur;
        cur = cur.parentElement;
      }
      return null;
    },
  };
  return link(node, (children || []).map((c) => (typeof c === 'string' ? text(c) : c)));
}

function makeRange() {
  const rect = { left: 0, right: 10, top: 0, bottom: 10, x: 0, y: 0, width: 10, height: 10 };
  return {
    setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
    setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
    collapse() {},
    getClientRects() { return [rect]; },
    getBoundingClientRect() { return rect; },
  };
}

function makeTreeWalker(root, filter) {
  const out = [];
  (function walk(node) {
    for (const child of node.childNodes || []) {
      if (child.nodeType === 3) {
        if (!filter || filter.acceptNode(child) === 1) out.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  return {
    currentNode: root,
    nextNode() {
      const next = out[out.indexOf(this.currentNode) + 1] || null;
      if (next) this.currentNode = next;
      return next;
    },
  };
}

// 固定读仓库内的资产（不接受外部传入路径：被执行的只能是本仓的 selection.js）。
const src = fs.readFileSync(path.join(__dirname, '../../assets/popup/selection.js'), 'utf8');

// 从 [node] 的 [offset] 起取词，返回 { text, rubyReadings, handlerArgs }。
function scan(paragraph, node, offset) {
  const body = el('body', [paragraph]);
  const calls = [];
  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _w, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };
  const window = {
    getComputedStyle: () => ({ display: 'inline', content: 'none' }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler: (...args) => { calls.push(args); } },
  };
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
    Map,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  const sel = sandbox.window.fushiSelection;
  sel.selection = null;
  sel.selectFromPosition(node, offset, 16);
  assert.ok(sel.selection, 'selectFromPosition 必须产生选区');
  assert.strictEqual(calls.length, 1, 'textSelected 恰好发一次');
  return {
    text: sel.selection.text,
    rubyReadings: JSON.parse(JSON.stringify(sel.selection.rubyReadings)),
    handlerArgs: JSON.parse(JSON.stringify([calls[0][0], calls[0][3]])),
  };
}

// ① 点 ruby 基字：selection.rubyReadings 与 textSelected 第 3 参一致。
{
  const base = text('忙');
  const p = el('p', [el('ruby', [base, el('rt', ['せわ'])]), 'しい']);
  const r = scan(p, base, 0);
  assert.strictEqual(r.text, '忙しい');
  assert.deepStrictEqual(r.rubyReadings, [{ s: 0, e: 1, r: 'せわ' }]);
  assert.deepStrictEqual(r.handlerArgs, ['textSelected', [{ s: 0, e: 1, r: 'せわ' }]]);
}

// ② 一个 <ruby> 多对基字 / rt（含 rp），逐对配对。
{
  const kan = text('漢');
  const p = el('p', [
    el('ruby', [kan, el('rp', ['(']), el('rt', ['かん']), el('rp', [')']), '字', el('rt', ['じ'])]),
    'を',
  ]);
  const r = scan(p, kan, 0);
  assert.strictEqual(r.text, '漢字を');
  assert.deepStrictEqual(r.rubyReadings, [
    { s: 0, e: 1, r: 'かん' },
    { s: 1, e: 2, r: 'じ' },
  ]);
}

// ③ popup.js postProcessRuby 之后的真实结构：ruby > .ruby-unit > [.ruby-reserve, 基字, .ruby-rt > rt]。
//    reserve 的读音副本不得混进基字，也不得进取词串。
{
  const base1 = text('将');
  const base2 = text('棋');
  const unit = (b, rt) =>
    el('span', [el('span', [rt], 'ruby-reserve'), b, el('span', [el('rt', [rt])], 'ruby-rt')], 'ruby-unit');
  const p = el('p', [el('ruby', [unit(base1, 'しょう'), unit(base2, 'ぎ')]), 'を指す']);
  const r = scan(p, base1, 0);
  assert.strictEqual(r.text, '将棋を指す');
  assert.deepStrictEqual(r.rubyReadings, [
    { s: 0, e: 1, r: 'しょう' },
    { s: 1, e: 2, r: 'ぎ' },
  ]);
}

// ④ 从多字基字中间起点：基字只被扫到一部分 → 不报。
{
  const base = text('今日');
  const p = el('p', [el('ruby', [base, el('rt', ['きょう'])]), 'は晴れ']);
  const r = scan(p, base, 1);
  assert.strictEqual(r.text, '日は晴れ');
  assert.deepStrictEqual(r.rubyReadings, []);
}

// ⑤ 没有 ruby：空数组，第 3 参也是空数组。
{
  const t = text('忙しい日々');
  const r = scan(el('p', [t]), t, 0);
  assert.deepStrictEqual(r.rubyReadings, []);
  assert.deepStrictEqual(r.handlerArgs, ['textSelected', []]);
}

// ⑥ 前面有普通文字：偏移以取词串为坐标系。
{
  const start = text('毎日');
  const p = el('p', [start, el('ruby', ['忙', el('rt', ['せわ'])]), 'しい']);
  const r = scan(p, start, 0);
  assert.strictEqual(r.text, '毎日忙しい');
  assert.deepStrictEqual(r.rubyReadings, [{ s: 2, e: 3, r: 'せわ' }]);
}

console.log('all assertions passed');
