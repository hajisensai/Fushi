// BUG-1012 行为守卫：浏览器扩展取词必须穿透 open Shadow DOM。
//
// 用 node:vm 在最小 fake DOM 里真执行 assets/popup/selection.js 的取词引擎
// `window.fushiSelection.getCharacterAtPoint`，覆盖两个场景：
//   A. 普通文本（caretPositionFromPoint 命中文本节点）—— 向后兼容，必须照常取词。
//   B. Web Component（<bili-comments> 之类 shadow root 渲染，B 站评论区形态）：
//      caretPositionFromPoint / elementFromPoint 只在顶层 document 下钻，命中的是
//      shadow 宿主元素（元素节点）而非内部文字节点。修复前 getCharacterAtPoint 在
//      `nodeType !== TEXT_NODE` 处直接 return null（Yomitan 能读、Hibiki 读不了的
//      根因）。修复后必须沿 element.shadowRoot 下钻到内部文字节点并成功取词。
//
// 运行：node hibiki/test/lookup/browser_extension_shadow_dom_lookup_bug1012_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const selectionSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'selection.js'),
  'utf8',
);

// ---- 最小 fake DOM -------------------------------------------------------
// 文字几何：字符 i 的矩形 = [100+20i, 120+20i] × [50, 70]。命中点固定 (110, 60)
// 落在字符 0 上。这正好是 getCaretRange 的 charRangeInContainer 逐字 getClientRects
// 命中路径要走通的几何。
const HIT_X = 110;
const HIT_Y = 60;
const TEXT = '素晴らしい';

function rectForChar(offset) {
  return { left: 100 + 20 * offset, right: 120 + 20 * offset, top: 50, bottom: 70 };
}

function makeText(content, parent) {
  return { nodeType: 3, textContent: content, parentElement: parent, __rectForChar: rectForChar };
}

function makeElement(tagName) {
  const el = {
    nodeType: 1,
    tagName,
    className: '',
    parentElement: null,
    shadowRoot: null,
    childNodes: [],
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const tags = selector.split(',').map((s) => s.trim().toLowerCase());
      let node = this;
      while (node && node.nodeType === 1) {
        if (tags.includes((node.tagName || '').toLowerCase())) return node;
        node = node.parentElement;
      }
      return null;
    },
  };
  return el;
}

// Range：只实现取词路径用到的 setStart/setEnd/collapse/getClientRects。
function makeRange() {
  return {
    startContainer: null,
    startOffset: 0,
    endContainer: null,
    endOffset: 0,
    setStart(node, offset) {
      this.startContainer = node;
      this.startOffset = offset;
    },
    setEnd(node, offset) {
      this.endContainer = node;
      this.endOffset = offset;
    },
    collapse(toStart) {
      if (toStart) {
        this.endContainer = this.startContainer;
        this.endOffset = this.startOffset;
      }
    },
    getClientRects() {
      const n = this.startContainer;
      if (n && n.nodeType === 3 && this.endOffset === this.startOffset + 1) {
        return [n.__rectForChar(this.startOffset)];
      }
      return [];
    },
    getBoundingClientRect() {
      const rects = this.getClientRects();
      return rects.length ? rects[0] : { left: 0, right: 0, top: 0, bottom: 0 };
    },
  };
}

function makeTreeWalker(root, filter) {
  const out = [];
  (function walk(node) {
    for (const child of node.childNodes || []) {
      if (child.nodeType === 3) {
        if (filter.acceptNode(child) === 1 /* FILTER_ACCEPT */) out.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  let idx = 0;
  return {
    currentNode: root,
    nextNode() {
      return idx < out.length ? out[idx++] : null;
    },
  };
}

// scenario: 'plain' | 'shadow'
function buildContext(scenario) {
  const body = makeElement('body');

  let elementAtPoint;
  let caretPos;

  if (scenario === 'plain') {
    const p = makeElement('p');
    const text = makeText(TEXT, p);
    p.childNodes = [text];
    p.parentElement = body;
    body.childNodes = [p];
    elementAtPoint = p;
    // 普通网页：浏览器直接把 caret 命中在文字节点上。
    caretPos = { offsetNode: text, offset: 0 };
  } else {
    // <bili-comments> host → shadowRoot → 内部 <div class="reply-content"> 文字。
    const host = makeElement('bili-comments');
    const inner = makeElement('div');
    inner.className = 'reply-content';
    const text = makeText(TEXT, inner);
    inner.childNodes = [text];
    // 内部元素 parentElement 到 shadow 边界即止（closest('rt,rp') 不得越界）。
    inner.parentElement = null;
    host.parentElement = body;
    body.childNodes = [host];
    host.shadowRoot = {
      elementFromPoint(x, y) {
        return x === HIT_X && y === HIT_Y ? inner : null;
      },
    };
    elementAtPoint = host;
    // 关键：顶层 document 不穿透 shadow，caret / elementFromPoint 落在宿主元素上。
    caretPos = { offsetNode: host, offset: 0 };
  }

  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: (x, y) => (x === HIT_X && y === HIT_Y ? caretPos : null),
    elementFromPoint: (x, y) => (x === HIT_X && y === HIT_Y ? elementAtPoint : null),
    caretRangeFromPoint: () => null,
  };

  const window = {};
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
  };
  vm.createContext(sandbox);
  vm.runInContext(selectionSrc, sandbox);
  return sandbox;
}

// ---- 断言 ----------------------------------------------------------------
function run() {
  // 场景 A：普通文本，向后兼容。
  {
    const ctx = buildContext('plain');
    const hit = ctx.window.fushiSelection.getCharacterAtPoint(HIT_X, HIT_Y);
    assert.ok(hit, '[plain] 普通文本必须能取词（向后兼容）');
    assert.strictEqual(hit.node.textContent, TEXT, '[plain] 取到的文字节点内容应为评论文字');
    assert.strictEqual(hit.offset, 0, '[plain] 命中点应落在字符 0');
  }

  // 场景 B：Shadow DOM（根因回归守卫）。先确认前置条件成立——顶层 caret 命中的
  // 确实是元素节点（浏览器没穿透），否则这个测试就没在守护真正的路径。
  {
    const ctx = buildContext('shadow');
    const caret = ctx.document.caretPositionFromPoint(HIT_X, HIT_Y);
    assert.strictEqual(
      caret.offsetNode.nodeType,
      1,
      '[shadow] 前置：顶层 caretPositionFromPoint 应命中 shadow 宿主（元素节点）',
    );

    const hit = ctx.window.fushiSelection.getCharacterAtPoint(HIT_X, HIT_Y);
    assert.ok(
      hit,
      '[shadow] 修复后必须穿透 shadow DOM 取到文字（修复前此处为 null —— B 站评论区读不了的根因）',
    );
    assert.strictEqual(hit.node.nodeType, 3, '[shadow] 取到的应是 shadow 内部的文字节点');
    assert.strictEqual(hit.node.textContent, TEXT, '[shadow] 取到的文字应为评论内容');
    assert.strictEqual(hit.offset, 0, '[shadow] 命中点应落在字符 0');
  }

  console.log('all assertions passed');
}

run();
