// 取词脚本 node harness 共用的最小 fake DOM：文本 / 元素节点、TreeWalker、Range，以及在
// vm 沙箱里装载取词脚本（阅读器 ReaderSelectionScripts.source() 或 assets/popup/selection.js）。
//
// 只给 ruby 读音 harness（test/lookup/ruby_reading_spans_test.js、
// test/dictionary/popup_selection_ruby_readings_test.js）用：它们需要的 DOM 面一样，各抄一份
// 就是两份要同步维护的假实现。

const vm = require('node:vm');

function matchesSelectorPart(node, part) {
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
      return node.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim()).filter(Boolean);
      let cur = node;
      while (cur?.nodeType === 1) {
        if (parts.some((p) => matchesSelectorPart(cur, p))) return cur;
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
  const walker = {
    currentNode: root,
    nextNode() {
      const next = out[out.indexOf(walker.currentNode) + 1] || null;
      if (next) walker.currentNode = next;
      return next;
    },
    previousNode() {
      const from = out.indexOf(walker.currentNode);
      const prev = from > 0 ? out[from - 1] : null;
      if (prev) walker.currentNode = prev;
      return prev;
    },
  };
  return walker;
}

// 在新 vm 沙箱里装载取词脚本 [src]（正文是 body > [paragraph]），返回 window.fushiSelection。
// [callHandler]：flutter_inappwebview.callHandler 的替身（收 textSelected 等调用）。
function loadSelectionScript(src, paragraph, callHandler) {
  const body = el('body', [paragraph]);
  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };
  const window = {
    getComputedStyle: () => ({ display: 'inline', content: 'none' }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler: callHandler || (() => {}) },
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
  vm.runInContext(src, sandbox);  // NOSONAR: harness 在本地 Node 沙箱里执行仓库自身的取词脚本（固定路径读入），无用户可控数据（S1523 误报）
  return sandbox.window.fushiSelection;
}

module.exports = { text, el, loadSelectionScript };
