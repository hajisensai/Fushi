// BUG-1773 行为守卫：取词的前向扫描必须把空格当**词间连接符**，而不是终点。
//
// 症状：英文正文里点 "listen" 只查到 listen，`listen to` 这类空格分词短语的词条
// 永远匹配不到——因为 selectFromPosition 的前向扫描一遇空白就 break，喂给引擎的
// 查询串被截成单个单词。C++ scan_candidates 本来就按空格分词生成
// `listen to music` / `listen to` / `listen` 三级候选（禁止在单词中间切），拿不到
// 空格就等于把短语整类排除。
//
// 根因修复：把混成一坨的 isScanBoundary 拆成两个语义不同的谓词——
//   isScanBoundary（词边界：点击命中判定 + 词首回退用，含空白，语义不变）
//   isScanStop    （扫描终点：标点 / 门控，**不含空白**）
// 空白能否跨过去由桥接规则单独决定：只在**同一文本节点内部**跨、且只跨一个
// （左边必须已有本节点扫入的内容，右边必须紧跟一个可扫字符）。
//
// 本 harness 用 node:vm 在最小 fake DOM 里真执行两份实现的 selectFromPosition：
//   ① assets/popup/selection.js（浮窗 / 浏览器扩展，三镜像 parity 另有测试守）
//   ② 阅读器注入脚本 ReaderSelectionScripts.source()——由 .dart wrapper 落到临时
//      文件，路径经环境变量 FUSHI_READER_SELECTION_JS 传入；没传就只测 ①。
//
// 运行：node fushi/test/lookup/phrase_lookup_whitespace_bridge_bug1773_test.js

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
  // ① 根因回归：点 "listen" 的任意字母，查询串都必须带上后面的 " to"。
  //    修复前这里是 "listen"，短语词条永远匹配不到。
  for (const offset of [2, 4, 7]) {
    assert.strictEqual(
      scan(src, ['I listen to music.'], 0, offset),
      'listen to music',
      `[${label}] 点 listen 的第 ${offset} 位必须扫出跨空格的短语查询串（'.' 处终止）`,
    );
  }

  // ② 起点仍回退到词首（TODO-916 症状③向后兼容）。
  assert.strictEqual(
    scan(src, ['say hello world'], 0, 6),
    'hello world',
    `[${label}] 点单词中间字母仍从词首起扫`,
  );

  // ③ 连续空白终止——空格只是词间连接符，不是「吞掉排版空白」的许可证。
  assert.strictEqual(scan(src, ['a  b'], 0, 0), 'a', `[${label}] 连续空白必须终止扫描`);

  // ④ 节点末尾的空白终止（后面没有可扫字符）。
  assert.strictEqual(scan(src, ['listen '], 0, 0), 'listen', `[${label}] 节点末尾空白必须终止`);

  // ⑤ 空白后接标点终止。
  assert.strictEqual(scan(src, ['listen ,to'], 0, 0), 'listen', `[${label}] 空白后接标点必须终止`);

  // ⑥ 本节点**开头**的空白不桥接 → 跨节点不会把块间空白粘成一个词。
  assert.strictEqual(
    scan(src, ['listen', ' to'], 0, 0),
    'listen',
    `[${label}] 跨文本节点时新节点开头的空白不得桥接`,
  );

  // ⑦ 行内标签劈开的单词仍照旧续扫（BUG-1645 向后兼容，非空白续接不受影响）。
  assert.strictEqual(
    scan(src, ['lis', 'ten'], 0, 0),
    'listen',
    `[${label}] 行内标签劈开的单词必须继续粘`,
  );

  // ⑧ 日文逐字扫描不受影响。
  assert.strictEqual(
    scan(src, ['素晴らしい世界'], 0, 0),
    '素晴らしい世界',
    `[${label}] 日文扫描行为不变`,
  );

  // ⑨ maxLength 仍然是硬上限。
  assert.strictEqual(
    scan(src, ['I listen to music.'], 0, 2, 8),
    'listen t',
    `[${label}] maxLength 必须仍然截断`,
  );
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
