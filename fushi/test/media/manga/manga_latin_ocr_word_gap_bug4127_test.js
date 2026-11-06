// BUG-4127 行为守卫：英文漫画 OCR 叠加层的取词必须停在词界。
//
// 症状（反馈 vXYKPudf7U）：英文漫画（全大写对白）OCR 后点词，查词浮层「未找到搜索结果」；
// 同一个词在查词页能查到。只有后面紧跟标点的词（WELL? / PHEW...）查得到。
//
// 根因：叠加层把每个可见字渲染成一个绝对定位的 <span class="ocr-char">，OCR 区域不覆盖
// 空格、各行直接拼接——DOM 正文成了 "BEENSOLONGSINCE…"。阅读器取词从被点的词一路扫过词界，
// 引擎（word_scan.cpp）不在两个拉丁字母之间切，整串一个候选，查不到。
//
// 本文件不能单独运行：.dart wrapper（manga_latin_ocr_word_gap_bug4127_test.dart）在它前面
// 拼上两样东西再交给 node——
//   MANGA_OCR_CASES：真实 mangaOcrBoxesHtml 输出里 <p class="ocr-box"> 的子节点序列
//     （{char} = 一个字格 span 的文字，{gap} = 字格之间的裸文本）与待点的字格；
//   loadReaderSelection(window, document, Node, NodeFilter)：把阅读器注入脚本
//     ReaderSelectionScripts.source() 原样包进函数体，返回 window.fushiSelection。

/* global MANGA_OCR_CASES, loadReaderSelection */

const assert = require('node:assert');

const NODE_TYPES = { ELEMENT_NODE: 1, TEXT_NODE: 3 };
const NODE_FILTER = { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 };

class FakeText {
  constructor(value, parentElement) {
    this.nodeType = NODE_TYPES.TEXT_NODE;
    this.nodeValue = value;
    this.textContent = value;
    this.parentElement = parentElement;
  }
}

class FakeElement {
  constructor(tagName, parentElement) {
    this.nodeType = NODE_TYPES.ELEMENT_NODE;
    this.tagName = tagName.toUpperCase();
    this.parentElement = parentElement;
    this.childNodes = [];
  }

  get textContent() {
    return this.childNodes.map((child) => child.textContent).join('');
  }

  // 只认标签名选择器（类 / 属性选择器一律视为不匹配，与叠加层取词无关）。
  closest(selector) {
    const wanted = new Set(
      selector.split(',').map((part) => part.trim().toUpperCase())
        .filter((part) => /^[A-Z][A-Z0-9]*$/.test(part)));
    for (let el = this; el; el = el.parentElement) {
      if (wanted.has(el.tagName)) return el;
    }
    return null;
  }
}

function textNodesUnder(root, filter) {
  const found = [];
  const visit = (node) => {
    for (const child of node.childNodes) {
      if (child instanceof FakeText) {
        if (!filter || filter.acceptNode(child) === NODE_FILTER.FILTER_ACCEPT) found.push(child);
      } else {
        visit(child);
      }
    }
  };
  visit(root);
  return found;
}

function fakeDocument(body) {
  return {
    body,
    createTreeWalker(root, _whatToShow, filter) {
      const nodes = textNodesUnder(root, filter);
      return {
        currentNode: root,
        nextNode() {
          const next = nodes[nodes.indexOf(this.currentNode) + 1] || null;
          if (next) this.currentNode = next;
          return next;
        },
        previousNode() {
          const index = nodes.indexOf(this.currentNode);
          const prev = index > 0 ? nodes[index - 1] : null;
          if (prev) this.currentNode = prev;
          return prev;
        },
      };
    },
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };
}

/// 按生成器给的子节点序列搭 <body><p class="ocr-box">…</p></body>，返回字格文本节点。
function mountOcrBox(items) {
  const body = new FakeElement('body', null);
  const box = new FakeElement('p', body);
  body.childNodes.push(box);
  const glyphs = [];
  for (const item of items) {
    if (item.char === undefined) {
      box.childNodes.push(new FakeText(item.gap, box));
      continue;
    }
    const span = new FakeElement('span', box);
    const glyph = new FakeText(item.char, span);
    span.childNodes.push(glyph);
    box.childNodes.push(span);
    glyphs.push(glyph);
  }
  return { body, glyphs };
}

function tap(items, glyphIndex) {
  const { body, glyphs } = mountOcrBox(items);
  const window = {
    getComputedStyle: () => ({ display: 'inline', content: 'none' }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler: () => {} },
    scanNonJapaneseText: true,
  };
  const selection = loadReaderSelection(window, fakeDocument(body), NODE_TYPES, NODE_FILTER);
  // 只看取词串：payload 组装（几何 / 句子）与本 bug 无关。
  selection.fireTextSelected = () => null;
  selection.selection = null;
  selection.selectFromPosition(glyphs[glyphIndex], 0, 24);
  return selection.selection ? selection.selection.text : null;
}

let executed = 0;
for (const block of MANGA_OCR_CASES) {
  for (const probe of block.cases) {
    assert.strictEqual(tap(block.items, probe.char), probe.expect,
      `${block.name}: tap glyph #${probe.char}`);
    executed++;
  }
}
assert.ok(executed > 0, 'no cases executed');
console.log(`all assertions passed (${executed})`);
