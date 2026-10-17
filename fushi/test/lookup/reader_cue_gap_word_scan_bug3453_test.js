// BUG-3453 行为守卫：有声书 cue wrapper 之间的空格不能被取词 / 句子拼接吞掉。
//
// 症状（英文有声书 + SRT 字幕）：每条字幕最后一个词（`greeted us` 的 us、`boy with`
// 的 with）点了查不到；以标点收尾的（`hair.`）正常。
//
// 根因：有声书句子高亮把每条 cue 的文字各自包进 wrapper span，cue 之间的空格落在两个
// wrapper 之间，成了独立的纯空白文本节点。阅读器的 createWalker 为句子拼接（TODO-956）
// 跳过纯空白节点，于是前向取词从 "us" 的节点末尾直接续到下一条 cue 的 "belonged"，
// 查询串成了 "usbelonged to a…"，英文整词匹配不到；句子也被拼成 "greeted usbelonged"。
//
// 本 harness 在最小 fake DOM 里真执行阅读器注入脚本 ReaderSelectionScripts.source()
// （由 .dart wrapper 落到临时文件，路径经 FUSHI_READER_SELECTION_JS 传入）。
//
// 运行：FUSHI_READER_SELECTION_JS=<path> node fushi/test/lookup/reader_cue_gap_word_scan_bug3453_test.js

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

// TreeWalker：尊重 acceptNode 的 FILTER_REJECT（阅读器 createWalker 据此跳过纯空白节点），
// hasSkippedWhitespaceBetween 的原始游走传的 filter 只拒振假名，纯空白节点照样被访问。
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

/// 建一个 <p>：字符串项 = 一个 cue wrapper <span> 里的文本节点；`{gap: ' '}` 项 = 直接挂在
/// <p> 下的纯空白文本节点（cue 之间的空格）。返回 { sel, cues }，cues 是各 wrapper 的文本节点。
function build(src, items) {
  const body = makeElement('body');
  const p = makeElement('p');
  p.parentElement = body;
  body.childNodes = [p];
  const cues = [];
  for (const item of items) {
    if (typeof item === 'string') {
      const span = makeElement('span');
      span.parentElement = p;
      const t = makeText(item, span);
      span.childNodes = [t];
      p.childNodes.push(span);
      cues.push(t);
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
  return { sel, cues };
}

function scan(src, items, cueIndex, offset) {
  const { sel, cues } = build(src, items);
  sel.selection = null;
  sel.selectFromPosition(cues[cueIndex], offset, 24);
  return sel.selection ? sel.selection.text : null;
}

const readerPath = process.env.FUSHI_READER_SELECTION_JS;
if (!readerPath) {
  console.log('reader selection script not provided');
  process.exit(1);
}
const src = fs.readFileSync(readerPath, 'utf8');

const english = [
  'The lively voice that now greeted us',
  { gap: ' ' },
  'belonged to a good-looking boy with',
  { gap: ' ' },
  'spiky black hair.',
];

// ① 根因回归：每条 cue 的最后一个词只扫到它自己，不粘下一条 cue。
assert.strictEqual(scan(src, english, 0, english[0].indexOf('us')), 'us',
  'cue 末词 us 不得与下一条 cue 的 belonged 粘连');
assert.strictEqual(scan(src, english, 1, english[2].indexOf('with')), 'with',
  'cue 末词 with 不得与下一条 cue 的 spiky 粘连');

// ② 同一节点内的单个空格仍是词间连接符（BUG-1773 短语查词不回退）。
assert.strictEqual(scan(src, english, 1, 0), 'belonged to a good-looki',
  'cue 内部空格仍要桥接（查询串到 maxLength 截断）');
assert.strictEqual(scan(src, english, 2, 0), 'spiky black hair',
  '以标点收尾的 cue 照旧在标点处终止');

// ③ 日文排版的空白缝维持旧行为（跨过、不当词界）：HTML 换行缝夹在两个日文 span 之间。
assert.strictEqual(scan(src, ['日本', { gap: '\n' }, '語です。'], 0, 0), '日本語です',
  '日文字符后的空白缝不得截断取词');

// ④ 句子拼接把被跳过的空白缝还原成一个空格，词在句中的偏移随之对齐。
{
  const { sel, cues } = build(src, english);
  const ctx = sel.getSentenceContext(cues[1], 0);
  assert.strictEqual(ctx.sentence,
    'The lively voice that now greeted us belonged to a good-looking boy with spiky black hair.',
    '句子不得丢掉 cue 之间的空格');
  assert.strictEqual(ctx.sentence.slice(ctx.sentenceOffset, ctx.sentenceOffset + 8), 'belonged',
    'sentenceOffset 必须指向句中被选词');
}

// ⑤ 日文句子不因 HTML 换行缝插入空格。
{
  const { sel, cues } = build(src, ['日本', { gap: '\n' }, '語です。']);
  assert.strictEqual(sel.getSentenceContext(cues[1], 0).sentence, '日本語です。',
    '日文句子不得插入空格');
}

// ⑥ textBetween（拖选跨句合并的句子正文）同一规则。
{
  const { sel, cues } = build(src, english);
  assert.strictEqual(sel.textBetween(cues[0], 4, cues[2], 5),
    'lively voice that now greeted us belonged to a good-looking boy with spiky',
    'textBetween 不得丢掉 cue 之间的空格');
}

console.log('all assertions passed');
