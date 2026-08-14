// BUG-1645 行为守卫（阅读器引擎侧）：阅读器的取词/取句扫描同样不得跨渲染断点粘连。
//
// 阅读器有一份与 popup selection.js 同构、但独立维护的取词引擎
// （`lib/src/reader/reader_selection_scripts.dart` 的 `source()`，正文 / 歌词模式 /
// 漫画覆盖层 / 键盘手柄 caret 全部复用它的 `selectFromPosition`）。它的
// `selectFromPosition` 与 `getSentenceContext` 都会跨文本节点续扫，同样会把渲染上
// 分开的两段文字粘成一串——对拉丁语系是致命的（C++ scan_candidates 禁止在单词中间
// 切，粘住的 `acridpungent` 永远还原不出 `acrid`）。
//
// 本 harness 由同名 .dart wrapper 驱动：wrapper 调 `ReaderSelectionScripts.source()`
// 把真实注入脚本 dump 到临时文件再传进来（argv[2]），保证测的就是线上那份，不靠
// 复制粘贴。
//
// 运行：node reader_selection_render_boundary_bug1645_test.js <dumped-source.js>

const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

const sourcePath = process.argv[2];
assert.ok(sourcePath, 'usage: node <this> <path-to-dumped-reader-selection.js>');
const selectionSrc = fs.readFileSync(sourcePath, 'utf8');

// ---- 最小 fake DOM -------------------------------------------------------
let nodeSeq = 0;

function makeText(content, parent) {
  return {
    nodeType: 3,
    nodeValue: content,
    textContent: content,
    parentElement: parent,
    __seq: nodeSeq++,
  };
}

function makeElement(tagName, { className = '', display = 'inline', after = 'none', before = 'none' } = {}) {
  return {
    nodeType: 1,
    tagName,
    className,
    parentElement: null,
    childNodes: [],
    __display: display,
    __after: after,
    __before: before,
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim().toLowerCase());
      let node = this;
      while (node && node.nodeType === 1) {
        for (const part of parts) {
          if (part.startsWith('.')) {
            if ((node.className || '').split(/\s+/).includes(part.slice(1))) return node;
          } else if ((node.tagName || '').toLowerCase() === part) {
            return node;
          }
        }
        node = node.parentElement;
      }
      return null;
    },
  };
}

function appendChildren(parent, children) {
  parent.childNodes = children;
  for (const child of children) {
    if (child.nodeType === 1) child.parentElement = parent;
  }
  return parent;
}

function makeRange() {
  return {
    startContainer: null,
    startOffset: 0,
    endContainer: null,
    endOffset: 0,
    setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
    setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
    collapse(toStart) {
      if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; }
    },
    // 字符 i 的矩形 = [100+20i, 120+20i] x [50, 70]；跨节点时只用第一个节点的几何。
    getClientRects() {
      const n = this.startContainer;
      if (n && n.nodeType === 3) {
        return [{
          left: 100 + 20 * this.startOffset,
          right: 120 + 20 * this.startOffset,
          top: 50,
          bottom: 70,
          x: 100 + 20 * this.startOffset,
          y: 50,
          width: 20,
          height: 20,
        }];
      }
      return [];
    },
    getBoundingClientRect() {
      const rects = this.getClientRects();
      return rects.length
        ? rects[0]
        : { left: 0, right: 0, top: 0, bottom: 0, x: 0, y: 0, width: 0, height: 0 };
    },
  };
}

function makeTreeWalker(root, filter) {
  const order = [];
  (function walk(node) {
    for (const child of node.childNodes || []) {
      if (child.nodeType === 3) {
        if (filter.acceptNode(child) === 1) order.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  return {
    currentNode: root,
    nextNode() {
      const idx = order.indexOf(this.currentNode);
      this.currentNode = order[idx < 0 ? 0 : idx + 1] || null;
      return this.currentNode;
    },
    previousNode() {
      const idx = order.indexOf(this.currentNode);
      this.currentNode = idx <= 0 ? null : order[idx - 1];
      return this.currentNode;
    },
  };
}

function buildContext(buildDom) {
  nodeSeq = 0;
  const body = makeElement('body', { display: 'block' });
  const built = buildDom(body);

  const document = {
    body,
    documentElement: body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  const calls = [];
  const window = {
    flutter_inappwebview: { callHandler: (...args) => { calls.push(args); return Promise.resolve(null); } },
    getComputedStyle: (element, pseudo) => {
      if (pseudo === '::after') return { content: element.__after };
      if (pseudo === '::before') return { content: element.__before };
      return { display: element.__display };
    },
    addEventListener: () => {},
    getSelection: () => null,
  };
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3, DOCUMENT_POSITION_FOLLOWING: 4 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
    console,
    setTimeout,
    clearTimeout,
    JSON,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(selectionSrc, sandbox);
  return { sandbox, calls, ...built };
}

// 嵌套块：<div><span>acrid</span><div>pungent</div></div>
// findParagraph 从 "acrid" 起 closest 到外层 div（BLOCK_SELECTOR 含 div），于是
// walker 能走进内层 div —— 正是跨块粘连能发生的形状。
function nestedBlocks(innerDisplay) {
  return (body) => {
    const outer = makeElement('div', { display: 'block' });
    const inline = makeElement('span', { display: 'inline' });
    const inner = makeElement('div', { display: innerDisplay });
    const firstText = makeText('acrid', inline);
    const secondText = makeText('pungent', inner);
    inline.childNodes = [firstText];
    inner.childNodes = [secondText];
    appendChildren(outer, [inline, inner]);
    appendChildren(body, [outer]);
    return { hit: firstText };
  };
}

function scannedText(ctx, node, offset) {
  // selectFromPosition 尾部会 fire onTextSelected（走完整 payload 构建）。这里只关心
  // 扫描结果，用 try 兜住 payload 阶段可能触及的未实现 DOM API，再读回 selection.text。
  try {
    ctx.sandbox.window.fushiSelection.selectFromPosition(node, offset, 400);
  } catch (_) { /* payload 阶段与本用例无关 */ }
  const selection = ctx.sandbox.window.fushiSelection.selection;
  return selection ? selection.text : null;
}

function run() {
  // 场景 A（根因回归守卫）：内层是块盒，扫描必须在块边界收手。
  {
    const ctx = buildContext(nestedBlocks('block'));
    assert.strictEqual(
      scannedText(ctx, ctx.hit, 2), 'acrid',
      '[reader/block] 取词不得跨块边界粘上下一块的文字');
  }

  // 场景 B（不回归）：内层若真是 inline 盒（同一行连排），仍按旧行为粘接——
  // `<b>ac</b>rid` 这类行内标记拆开的单词靠的就是这条。
  {
    const ctx = buildContext(nestedBlocks('inline'));
    assert.strictEqual(
      scannedText(ctx, ctx.hit, 2), 'acridpungent',
      '[reader/inline] 行内连排必须仍能跨节点拼接');
  }

  // 场景 C：句子提取同样在渲染断点处收句。
  {
    const ctx = buildContext(nestedBlocks('block'));
    const context = ctx.sandbox.window.fushiSelection.getSentenceContext(ctx.hit, 2);
    assert.strictEqual(
      context.sentence, 'acrid', '[reader/sentence] 句子提取不得跨块粘连');
  }

  console.log('all assertions passed');
}

run();
