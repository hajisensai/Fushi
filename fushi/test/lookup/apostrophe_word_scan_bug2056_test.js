// BUG-2056 行为守卫：词内撇号必须被前向扫描跨过去，英语的缩合形/所有格才查得到。
//
// 症状：英文正文里点 "don’t" 的 don，喂给引擎的查询串是 "don"；点 t 是 "t"。
// en.json 词形还原表里 don't / it's / John's 这类整类匹配不到。真实 EPUB 几乎都用
// 排版撇号 U+2019，而它和 ASCII ' 一样在 scanDelimiters 里，前向扫描一撞上就 break。
//
// 根因修复：撇号是否词边界取决于**上下文**，不是字符本身。两侧都是空格分词类字母
// （字母集与 native/fushidicts/fushidicts_src/scan/word_scan.cpp 的
// is_space_delimited_letter 逐区间对齐）时它是词内字符，前向扫描跨过去。
//
// 刻意**不改词首回退**：回退跨撇号会把 l’homme / dell’arte 的锚点从 homme 拖回 l’，
// 反而查不到 homme。前向跨过是纯增益（scan_candidates 生成 don’t / don’ / don
// 三级前缀，短词不会被挤掉），回退跨过是零和的锚点搬家。⑥⑦ 两条把这个取舍钉死。
//
// 本 harness 用 node:vm 在最小 fake DOM 里真执行两份实现的 selectFromPosition
// （fake DOM 与 phrase_lookup_whitespace_bridge_bug1773_test.js 同构）：
//   ① assets/popup/selection.js（浮窗 / 浏览器扩展，三镜像逐字节 parity 另有测试守）
//   ② 阅读器注入脚本 ReaderSelectionScripts.source()——由 .dart wrapper 落到临时
//      文件，路径经环境变量 FUSHI_READER_SELECTION_JS 传入；没传就只测 ①。
//
// 运行：node fushi/test/lookup/apostrophe_word_scan_bug2056_test.js

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

// ---- 断言 ----------------------------------------------------------------

const RSQUO = '\u2019'; // ’ 排版撇号：真实 EPUB 里的主流写法
const MODAP = '\u02BC'; // ʼ MODIFIER LETTER APOSTROPHE

function runSuite(label, src) {
  // ① 根因回归：排版撇号必须被跨过，don’t 整体进查询串。
  //    修复前 offset 0/1/2 都只得到 "don"。
  for (const offset of [0, 1, 2]) {
    assert.strictEqual(
      scan(src, [`I don${RSQUO}t.`], 0, 2 + offset),
      `don${RSQUO}t`,
      `[${label}] 点 don 的第 ${offset} 位必须扫出跨撇号的 don’t（'.' 处终止）`,
    );
  }

  // ② ASCII 撇号同样处理（纯文本字幕/OCR 里常见）。
  assert.strictEqual(
    scan(src, ["don't."], 0, 0),
    "don't",
    `[${label}] ASCII 撇号也必须被跨过`,
  );

  // ③ U+02BC 同样处理。
  assert.strictEqual(
    scan(src, [`can${MODAP}t.`], 0, 0),
    `can${MODAP}t`,
    `[${label}] U+02BC 也必须被跨过`,
  );

  // ④ 所有格 + 空格桥接叠加：撇号跨过后，BUG-1773 的空格桥接照常接上下一个词。
  assert.strictEqual(
    scan(src, [`John${RSQUO}s book.`], 0, 0),
    `John${RSQUO}s book`,
    `[${label}] 所有格与空格桥接必须叠加生效`,
  );

  // ⑤ 引号语义不受影响：右侧是空白 → 撇号仍是扫描终点。
  assert.strictEqual(
    scan(src, [`${RSQUO}hello${RSQUO} world`], 0, 1),
    'hello',
    `[${label}] 收尾引号（右侧空白）必须仍是终点`,
  );

  // ⑥ **词首回退不得跨撇号**：法语省音 l’homme 点 homme 仍锚在 homme。
  //    若把桥接也加进回退，这里会退回 l’homme，反而查不到 homme。
  assert.strictEqual(
    scan(src, [`l${RSQUO}homme.`], 0, 3),
    'homme',
    `[${label}] 词首回退必须仍在撇号处停住（法/意省音不得被拖回前缀）`,
  );

  // ⑦ 同理，点 don’t 的 t 仍只得到 t——这是 ⑥ 的同一条规则，刻意保留。
  assert.strictEqual(
    scan(src, [`don${RSQUO}t.`], 0, 4),
    't',
    `[${label}] 点撇号右侧首字母仍只从该字母起扫（与 ⑥ 同一条规则）`,
  );

  // ⑧ 非空格分词脚本两侧的撇号仍是终点（日文正文里的 ’ 是引号，不是词内字符）。
  assert.strictEqual(
    scan(src, [`私は${RSQUO}そう${RSQUO}言った`], 0, 0),
    '私は',
    `[${label}] 日文两侧的撇号必须仍是终点`,
  );

  // ⑨ 跨文本节点时新节点开头的撇号不得桥接（与空白桥接同一条纪律）。
  assert.strictEqual(
    scan(src, ['don', `${RSQUO}t`], 0, 0),
    'don',
    `[${label}] 新文本节点开头的撇号不得被当成词内字符`,
  );

  // ⑩ 撇号后必须真有字母才跨：`rock 'n' roll` 的 ' 右侧是 n、左侧是空白 → 终点。
  assert.strictEqual(
    scan(src, ["rock 'n' roll"], 0, 0),
    'rock',
    `[${label}] 左侧非字母的撇号必须仍是终点`,
  );

  // ⑪ maxLength 仍是硬上限。
  assert.strictEqual(
    scan(src, [`don${RSQUO}t ask`], 0, 0, 4),
    `don${RSQUO}`,
    `[${label}] maxLength 必须仍然截断`,
  );

  // ⑫ 日文逐字扫描完全不受影响（回归护栏）。
  assert.strictEqual(
    scan(src, ['素晴らしい世界'], 0, 0),
    '素晴らしい世界',
    `[${label}] 日文扫描行为不变`,
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
