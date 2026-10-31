// 反馈 pm3A75D5xZ 行为守卫（node:vm 在最小 fake DOM 里真执行取词脚本）。
//
// 大辞泉『テンパリング〖tempering〗』点 t，高亮却从『〖』开始、整体左移一格：点非日文
// 字符时的词首回退只认 scanDelimiters 清单，〖〗（U+3016/3017）不在表内，回退吃进
// 『〖』（同节点时甚至一路退进前面的片假名）；引擎跳过前导标点匹配出 tempering，
// highlightSelection 从 startOffset 数 9 字。回退必须停在日文字符与 Unicode 开/闭括号、
// 引号上。两份实现：assets/popup/selection.js 与 ReaderSelectionScripts.source()。
//
// 运行：node fushi/test/lookup/token_start_cjk_bracket_fb_pm3a_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// ---- 最小 fake DOM -------------------------------------------------------

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
  const el = {
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
  return el;
}

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
    collapse() {},
    getClientRects() {
      return [{ left: 0, right: 10, top: 0, bottom: 10, x: 0, y: 0, width: 10, height: 10 }];
    },
    getBoundingClientRect() {
      return { left: 0, right: 10, top: 0, bottom: 10, x: 0, y: 0, width: 10, height: 10 };
    },
  };
}

// TreeWalker：尊重 acceptNode 的 FILTER_REJECT（阅读器版据此跳过纯空白节点）。
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
  };
}

/// 建一个 <p>，其中每段文字是一个 <span> 里的文本节点（segments 长度 > 1 时用来
/// 覆盖「跨文本节点续扫」）。返回 { sandbox, textNodes }。
function buildContext(src, segments) {
  const body = makeElement('body');
  const p = makeElement('p');
  p.parentElement = body;
  body.childNodes = [p];

  const textNodes = [];
  for (const seg of segments) {
    const span = makeElement('span');
    span.parentElement = p;
    const t = makeText(seg, span);
    span.childNodes = [t];
    p.childNodes.push(span);
    textNodes.push(t);
  }

  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };

  const window = {
    // 所有 span 都是行内盒 → crossesRenderBoundary 判「同一行连排」，跨节点续扫放行
    // （popup 版的 BUG-1645 路径；阅读器版没有这个函数，行为一致）。
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

  // 阅读器版的收尾走 fireTextSelected → buildSelectionPayload（依赖整套
  // window.fushiReader 归一化偏移）。本测试只关心扫描产出的查询串，stub 掉收尾。
  sandbox.window.fushiSelection.fireTextSelected = function () {
    return this.selection ? this.selection.text : null;
  };
  return { sandbox, textNodes };
}

/// 跑一次取词，返回喂给引擎的查询串（没选到返回 null）。
function scan(src, segments, nodeIndex, offset, maxLength) {
  const { sandbox, textNodes } = buildContext(src, segments);
  const sel = sandbox.window.fushiSelection;
  sel.selection = null;
  sel.selectFromPosition(textNodes[nodeIndex], offset, maxLength === undefined ? 24 : maxLength);
  return sel.selection ? sel.selection.text : null;
}

// ---- 断言 ----------------------------------------------------------------

function runSuite(label, src) {
  // ① 反馈原样：同一文本节点里『テンパリング〖tempering〗』点 t / e / g。
  for (const offset of [7, 8, 15]) {
    const got = scan(src, ['テンパリング〖tempering〗'], 0, offset);
    assert.ok(
      got !== null && got.startsWith('tempering'),
      `[${label}] 点第 ${offset} 位必须从 t 起扫，实际 ${JSON.stringify(got)}`,
    );
  }
  // ② 括号自成文本节点（词典 HTML 常见）：〖 不得被吃进起点。
  const split = scan(src, ['テンパリング', '〖tempering〗'], 1, 3);
  assert.ok(split.startsWith('tempering'), `[${label}] 跨节点：${JSON.stringify(split)}`);
  // ③ scanDelimiters 清单之外的 Unicode 开括号 / 引号同样截住：⟨ ⦅ „。
  for (const open of ['⟨', '⦅', '„']) {
    const got = scan(src, [`${open}word end`], 0, 3);
    assert.ok(got.startsWith('word'), `[${label}] U+${open.codePointAt(0).toString(16)}：${JSON.stringify(got)}`);
  }
  // ④ 不误截：普通拉丁词内回退照旧（点 blackened 中间仍退回 b）。
  assert.strictEqual(scan(src, ['so blackened oak'], 0, 8), 'blackened oak', `[${label}] 拉丁词内回退`);
}

function run() {
  const popupSrc = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'assets', 'popup', 'selection.js'),
    'utf8',
  );
  runSuite('popup/extension', popupSrc);
  const readerJsPath = process.env.FUSHI_READER_SELECTION_JS;
  if (readerJsPath && fs.existsSync(readerJsPath)) {
    runSuite('reader', fs.readFileSync(readerJsPath, 'utf8'));
  } else {
    console.log('reader selection script not provided; skipped that suite');
  }
  console.log('all assertions passed');
}

run();
