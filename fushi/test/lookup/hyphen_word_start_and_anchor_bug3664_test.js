// BUG-3664 / BUG-3665 行为守卫（node:vm 在最小 fake DOM 里真执行取词脚本）。
//
// BUG-3664：`time-blackened` 点 blackened，词首回退跨过连字符一路退到 time，喂给
// 引擎的是「time-blackened …」，词典没有复合词时只匹配出前半截 time（用户报「只能
// 查到前面」）。回退必须停在词内连字符上；前向扫描不停（点 time 仍带上整个复合词）。
//
// BUG-3665：查词弹窗锚点矩形 = 被查词所有字形片段的并集。词被断在两页 / 两栏时
// 屏外那段也被并进来，并集从页顶拉到页底，弹窗被挤成贴底一条。anchoredWordBounds
// 只取视口内、与点中片段相邻（两行以内）的片段。
//
// 两份实现：① assets/popup/selection.js（浮窗 / 扩展，三镜像 parity 另有测试守）
//          ② 阅读器注入脚本 ReaderSelectionScripts.source()（.dart wrapper 落临时文件，
//             路径经 FUSHI_READER_SELECTION_JS 传入）。
//
// 运行：node fushi/test/lookup/hyphen_word_start_and_anchor_bug3664_test.js

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

function runScanSuite(label, src) {
  // ① 根因回归：点 blackened 的任意字母都从 b 起扫，不再退回 time。
  for (const offset of [5, 8, 13]) {
    assert.strictEqual(
      scan(src, ['time-blackened oak'], 0, offset),
      'blackened oak',
      `[${label}] 点 blackened 第 ${offset} 位必须从 blackened 起扫`,
    );
  }
  // ② 点前半截仍把整个复合词交给引擎（well-known 这类词条照样能查到）。
  assert.strictEqual(
    scan(src, ['a well-known fact'], 0, 4),
    'well-known fact',
    `[${label}] 点 well 必须仍带上连字符后的部分`,
  );
  // ③ 各种连字符 / 破折号都截回退：U+2010 hyphen、U+2011 不断行连字符、en dash。
  for (const dash of ['\u2010', '\u2011', '\u2013']) {
    assert.strictEqual(
      scan(src, [`self${dash}evident truth`], 0, 7),
      'evident truth',
      `[${label}] 连字符 U+${dash.codePointAt(0).toString(16)} 必须截住词首回退`,
    );
  }
  // ④ 软连字符 U+00AD 不截（不可见的断词点，属于同一个词）。
  assert.strictEqual(
    scan(src, ['super\u00ADfluous thing'], 0, 8),
    'super\u00ADfluous thing',
    `[${label}] 软连字符不得截住词首回退`,
  );
  // ⑤ 撇号仍是回退终点（BUG-2056：l\u2019homme 点 homme 查 homme）。
  assert.strictEqual(
    scan(src, ['l\u2019homme est'], 0, 4),
    'homme est',
    `[${label}] 撇号仍截住词首回退`,
  );
}

function rect(left, top, width, height) {
  return { left, top, right: left + width, bottom: top + height, x: left, y: top, width, height };
}

function runAnchorSuite(label, src) {
  const { sandbox } = buildContext(src, ['x']);
  sandbox.window.innerWidth = 360;
  sandbox.window.innerHeight = 772;
  const sel = sandbox.window.fushiSelection;
  // 结果对象生在 vm 沙箱的 realm 里，原型与本 realm 不同，deepStrictEqual 会因原型不等判红；
  // 先过一遍 JSON 变成本 realm 的普通对象再比。
  const bounds = (rects, point, vertical) =>
    JSON.parse(JSON.stringify(sel.anchoredWordBounds(rects, point, !!vertical)));

  // ① 翻页模式断在两页：上一页那段在屏外（x<0、贴页底），本页那段在页顶。
  //    旧并集 top=60 bottom=716，弹窗只剩贴底一条；锚点必须只剩本页那段。
  const prevPage = rect(-330, 690, 40, 26);
  const thisPage = rect(18, 60, 110, 26);
  assert.deepStrictEqual(
    bounds([prevPage, thisPage], { x: 60, y: 70 }),
    { left: 18, top: 60, right: 128, bottom: 86 },
    `[${label}] 屏外片段不得并进锚点`,
  );
  // ② 双栏同屏：两段都可见但隔着半页，只取点中的那段。
  const leftCol = rect(150, 700, 30, 26);
  const rightCol = rect(200, 60, 110, 26);
  assert.deepStrictEqual(
    bounds([leftCol, rightCol], { x: 220, y: 70 }),
    { left: 200, top: 60, right: 310, bottom: 86 },
    `[${label}] 隔栏片段不得并进锚点`,
  );
  // 没有点击点（键盘 / 手柄光标）→ 取第一段。
  assert.deepStrictEqual(
    bounds([leftCol, rightCol], null),
    { left: 150, top: 700, right: 180, bottom: 726 },
    `[${label}] 无点击点时以第一段为锚`,
  );
  // ③ 同一栏折到下一行（行距 1 行内）：两行都并进来，弹窗不压后半个词。
  const lineEnd = rect(300, 100, 40, 26);
  const nextLine = rect(18, 140, 80, 26);
  assert.deepStrictEqual(
    bounds([lineEnd, nextLine], { x: 310, y: 110 }),
    { left: 18, top: 100, right: 340, bottom: 166 },
    `[${label}] 相邻行的片段必须并进锚点`,
  );
  // ④ 竖排：交叉轴是 x，隔列远的片段不并、相邻列并。
  const colA = rect(300, 600, 26, 100);
  const colB = rect(270, 20, 26, 60);
  const colFar = rect(40, 20, 26, 60);
  assert.deepStrictEqual(
    bounds([colA, colB, colFar], { x: 310, y: 650 }, true),
    { left: 270, top: 20, right: 326, bottom: 700 },
    `[${label}] 竖排相邻列并入、远列不并`,
  );
  // ⑤ 全在屏外（防御）：退回全部片段，不返回 null。
  assert.notStrictEqual(
    bounds([rect(-400, 10, 20, 20)], null),
    null,
    `[${label}] 全在屏外时仍要给出矩形`,
  );
}

function run() {
  const popupSrc = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'assets', 'popup', 'selection.js'),
    'utf8',
  );
  runScanSuite('popup/extension', popupSrc);

  const readerJsPath = process.env.FUSHI_READER_SELECTION_JS;
  if (readerJsPath && fs.existsSync(readerJsPath)) {
    const readerSrc = fs.readFileSync(readerJsPath, 'utf8');
    runScanSuite('reader', readerSrc);
    runAnchorSuite('reader', readerSrc);
  } else {
    console.log('reader selection script not provided; skipped that suite');
  }

  console.log('all assertions passed');
}

run();
