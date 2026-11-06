// BUG-4127 行为守卫：英文漫画 OCR 叠加层的取词必须停在词界。
//
// 症状（反馈 vXYKPudf7U）：英文漫画（全大写对白）OCR 后点词，查词浮层「未找到搜索结果」；
// 同一个词在查词页能查到。只有后面紧跟标点的词（WELL? / PHEW...）查得到。
//
// 根因：叠加层把每个可见字渲染成一个绝对定位的 <span class="ocr-char">，OCR 区域不覆盖
// 空格、各行直接拼接——DOM 正文成了 "BEENSOLONGSINCE…"。阅读器取词从被点的词一路扫过词界，
// 查询串是 "BEENSOLONGSINCEILASTSENT"；引擎（word_scan.cpp）不在两个拉丁字母之间切，
// 整串一个候选，查不到。修复：两个字格之间夹着空白或拉丁文行界时补一个纯空白文本节点，
// 阅读器取词按 BUG-3453 的规则把它当词界。
//
// 本 harness 在最小 fake DOM 里真执行阅读器注入脚本 ReaderSelectionScripts.source()，
// DOM 结构（字格 span / 纯空白文本节点的序列）来自真实的 mangaOcrBoxesHtml 输出——
// 由 .dart wrapper 落成 JSON（FUSHI_MANGA_OCR_CASES），脚本路径经
// FUSHI_READER_SELECTION_JS 传入。

const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

function makeText(content, parent) {
  return { nodeType: 3, textContent: content, nodeValue: content, parentElement: parent };
}

function selectorTags(selector) {
  return selector
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0 && !s.startsWith('.') && !s.startsWith('['));
}

function makeElement(tagName) {
  return {
    nodeType: 1,
    tagName,
    className: '',
    parentElement: null,
    childNodes: [],
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const tags = selectorTags(selector);
      let node = this;
      while (node && node.nodeType === 1) {
        if (tags.includes((node.tagName || '').toLowerCase())) return node;
        node = node.parentElement;
      }
      return null;
    },
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
      const from = out.indexOf(this.currentNode);
      const next = out[from + 1] || null;
      if (next) this.currentNode = next;
      return next;
    },
    previousNode() {
      const from = out.indexOf(this.currentNode);
      const prev = from > 0 ? out[from - 1] : null;
      if (prev) this.currentNode = prev;
      return prev;
    },
  };
}

/// items：{char: 'B'} = 一个 ocr-char span 里的文本节点；{gap: ' '} = 直接挂在 <p> 下的
/// 文本节点（字格之间的空白）。返回 { sel, chars }，chars 是各字格的文本节点。
function build(src, items) {
  const body = makeElement('body');
  const p = makeElement('p');
  p.parentElement = body;
  body.childNodes = [p];
  const chars = [];
  for (const item of items) {
    if (item.char !== undefined) {
      const span = makeElement('span');
      span.parentElement = p;
      const t = makeText(item.char, span);
      span.childNodes = [t];
      p.childNodes.push(span);
      chars.push(t);
    } else {
      p.childNodes.push(makeText(item.gap, p));
    }
  }
  const document = {
    body,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };
  const window = {
    getComputedStyle: () => ({ display: 'inline', content: 'none' }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler: () => {} },
    scanNonJapaneseText: true,
  };
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  const sel = sandbox.window.fushiSelection;
  sel.fireTextSelected = function () {
    return this.selection ? this.selection.text : null;
  };
  return { sel, chars };
}

const readerPath = process.env.FUSHI_READER_SELECTION_JS;
const casesPath = process.env.FUSHI_MANGA_OCR_CASES;
if (!readerPath || !casesPath) {
  console.log('FUSHI_READER_SELECTION_JS / FUSHI_MANGA_OCR_CASES not provided');
  process.exit(1);
}
const src = fs.readFileSync(readerPath, 'utf8');
const blocks = JSON.parse(fs.readFileSync(casesPath, 'utf8'));

let checked = 0;
for (const block of blocks) {
  for (const c of block.cases) {
    const { sel, chars } = build(src, block.items);
    sel.selection = null;
    sel.selectFromPosition(chars[c.char], 0, 24);
    const text = sel.selection ? sel.selection.text : null;
    assert.strictEqual(text, c.expect, `${block.name}: 点第 ${c.char} 个字格`);
    checked++;
  }
}
assert.ok(checked > 0, 'no cases executed');
console.log(`all assertions passed (${checked})`);
