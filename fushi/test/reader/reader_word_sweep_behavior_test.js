// 阅读器「整句扫词」WebView 侧行为守卫（拍板台 5H922XeDHM）。
//
// 用 node:vm 真执行 ReaderWordSweepScripts.source()（由 .dart wrapper 落到临时文件，
// 路径经环境变量 FUSHI_READER_WORD_SWEEP_JS 传入），`window.fushiSelection` 换成最小
// 替身：扫词只依赖它的一组公开谓词（createWalker / findParagraph / 句界字符表 /
// isScanBoundary / 可见判据 / selectFromPosition），替身按与真实现相同的契约实现，
// 这样断言针对的是扫词自己的取句 / 可见 / 会话 / 映射逻辑。
//
// 运行：FUSHI_READER_WORD_SWEEP_JS=<file> node fushi/test/reader/reader_word_sweep_behavior_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

const sourcePath = process.env.FUSHI_READER_WORD_SWEEP_JS;
if (!sourcePath) {
  console.error('FUSHI_READER_WORD_SWEEP_JS not set');
  process.exit(2);
}
const source = fs.readFileSync(sourcePath, 'utf8');

// ---- 最小 DOM ----------------------------------------------------------------

function makeElement(classes, attrs) {
  const el = {
    nodeType: 1,
    classes: classes || [],
    attrs: attrs || {},
    texts: [],
    parentElement: null,
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
    },
    closest(selector) {
      const cls = selector.replace(/^\./, '');
      let node = this;
      while (node) {
        if (node.classes.includes(cls)) return node;
        node = node.parentElement;
      }
      return null;
    },
  };
  return el;
}

function addText(el, content) {
  const node = { nodeType: 3, textContent: content, nodeValue: content, parentElement: el, attached: true, hidden: new Set() };
  el.texts.push(node);
  return node;
}

function setup(opts) {
  const lookups = [];
  const all = opts.paragraphs.flatMap((p) => p.texts);
  const selection = {
    sentenceDelimiters: '。！？.!?',
    trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
    selection: null,
    createWalker(root) {
      const list = root && root.texts ? root.texts : all;
      let index = -1;
      return {
        get currentNode() { return list[index]; },
        set currentNode(n) { index = list.indexOf(n); },
        nextNode() {
          if (index + 1 >= list.length) return null;
          index += 1;
          return list[index];
        },
        previousNode() {
          if (index - 1 < 0) return null;
          index -= 1;
          return list[index];
        },
      };
    },
    findParagraph(node) { return node.parentElement; },
    isScanBoundary(ch) { return /^[\s　]$/.test(ch) || '。、「」！？.,!?'.includes(ch); },
    isUnpunctuatedCueBoundary() { return false; },
    hasSkippedWhitespaceBetween() { return false; },
    isWordGapBetweenChars() { return false; },
    visibleContentBox() { return { left: 0, top: 0, right: 100, bottom: 100 }; },
    charRangeAt(node, offset) {
      if (offset < 0 || offset >= node.textContent.length) return null;
      return { node, offset };
    },
    charRangeVisible(range) { return !range.node.hidden.has(range.offset); },
    clearSelection() { this.selection = null; lookups.push('clear'); },
    selectFromPosition(node, offset, maxLength) {
      lookups.push({ node, offset, maxLength });
      this.selection = { startNode: node, startOffset: offset };
      return node.textContent.slice(offset, offset + 1);
    },
  };
  const window = {
    fushiSelection: selection,
    fushiCaret: opts.firstVisible === undefined ? undefined : {
      _firstVisibleStop() { return opts.firstVisible(); },
    },
  };
  if (opts.lyricsIndex !== undefined) {
    window.__lyricsGetCurrentIndex = () => opts.lyricsIndex();
  }
  const document = {
    contains(n) { return n.nodeType !== 3 || n.attached; },
    querySelectorAll(sel) { return (opts.query && opts.query[sel]) || []; },
    body: { texts: all },
  };
  const ctx = { window, document, Node: { TEXT_NODE: 3 }, JSON, String, parseInt };
  vm.createContext(ctx);
  vm.runInContext(source, ctx);
  const sweep = window.fushiWordSweep;
  return {
    window,
    selection,
    lookups,
    sentence() {
      const raw = sweep.sentence();
      return raw == null ? null : JSON.parse(raw);
    },
    lookupAt(id, unit) { return sweep.lookupAt(id, unit); },
  };
}

// ---- 用例 --------------------------------------------------------------------

// 一段跨两个文本节点的正文：句子跨节点、带收尾括号。
function bookParagraph() {
  const p = makeElement([]);
  const a = addText(p, '今日は天気が');
  const b = addText(p, 'いい。「そうだね。」と言った。');
  return { p, a, b };
}

{
  // ① 无锚点：取屏上第一个可见字所在的句子，句子跨节点拼接，标点不当停靠点。
  const { p, a } = bookParagraph();
  const env = setup({ paragraphs: [p], firstVisible: () => ({ node: a, offset: 0 }) });
  const s = env.sentence();
  assert.strictEqual(s.text, '今日は天気がいい。');
  assert.deepStrictEqual(s.stops, [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.strictEqual(s.at, -1);
  // 同句再取：会话延续（id 不变）。
  assert.strictEqual(env.sentence().id, s.id);
}

{
  // ② 句末收尾括号归前一句：选区在「と言った」里 → 新句从 」 之后起，at 指向选区字。
  const { p, a, b } = bookParagraph();
  const env = setup({ paragraphs: [p], firstVisible: () => ({ node: a, offset: 0 }) });
  env.selection.selection = { startNode: b, startOffset: 11 }; // 「言」
  const s = env.sentence();
  assert.strictEqual(s.text, 'と言った。');
  assert.strictEqual(s.at, 1);
  // 选区在引号句里 → 句子含开括号与收尾括号。
  env.selection.selection = { startNode: b, startOffset: 4 }; // 「そ」
  const q = env.sentence();
  assert.strictEqual(q.text, '「そうだね。」');
  assert.notStrictEqual(q.id, s.id, '换句必须换会话号');
  assert.deepStrictEqual(q.stops, [1, 2, 3, 4]);
}

{
  // ③ 可见判据：分页页边以外（被 clip）的字不能当停靠点。
  const { p, a, b } = bookParagraph();
  b.hidden.add(0);
  b.hidden.add(1);
  const env = setup({ paragraphs: [p], firstVisible: () => ({ node: a, offset: 0 }) });
  assert.deepStrictEqual(env.sentence().stops, [0, 1, 2, 3, 4, 5]);
}

{
  // ④ 节点离开文档（VN 换屏 / 章节重载）：会话作废、按新锚重建。
  const { p, a } = bookParagraph();
  const p2 = makeElement([]);
  const c = addText(p2, '次の画面。');
  let first = { node: a, offset: 0 };
  const env = setup({ paragraphs: [p, p2], firstVisible: () => first });
  const s1 = env.sentence();
  a.attached = false;
  first = { node: c, offset: 0 };
  const s2 = env.sentence();
  assert.notStrictEqual(s2.id, s1.id);
  assert.strictEqual(s2.text, '次の画面。');
}

{
  // ⑤ 有声书正在播放的句优先于屏首。
  const { p, a, b } = bookParagraph();
  const active = makeElement(['fushi-sentence-audio-active']);
  active.texts = [b];
  const env = setup({
    paragraphs: [p],
    firstVisible: () => ({ node: a, offset: 0 }),
    query: { '.fushi-sentence-audio-active': [active] },
  });
  assert.strictEqual(env.sentence().text, '今日は天気がいい。', 'b 的首字「い」在第一句里');
}

{
  // ⑥ lookupAt：码元 → (节点, 偏移)，与光标查词同一调用（先清选区，再 400 扫描上限）；
  //    过期会话号拒绝。
  const { p, a, b } = bookParagraph();
  const env = setup({ paragraphs: [p], firstVisible: () => ({ node: a, offset: 0 }) });
  const s = env.sentence();
  assert.strictEqual(env.lookupAt(s.id, 6), true);
  assert.deepStrictEqual(env.lookups, ['clear', { node: b, offset: 0, maxLength: 400 }]);
  assert.strictEqual(env.lookupAt(s.id + 1, 0), false);
  // 查完选区落在本句：下一次取句延续会话，at 指向刚查的字。
  const again = env.sentence();
  assert.strictEqual(again.id, s.id);
  assert.strictEqual(again.at, 6);
}

{
  // ⑦ 歌词文档：一行 .cue 即一句，锚为正在播放的行；lookupAt 写 cue 上下文。
  const cue0 = makeElement(['cue'], { 'data-text-fragment-id': 'f0', 'data-cue-index': '0' });
  addText(cue0, '一行目。');
  const cue1 = makeElement(['cue'], { 'data-text-fragment-id': 'f1', 'data-cue-index': '1' });
  addText(cue1, 'ふたつ。');
  addText(cue1, 'みっつ');
  let playing = 1;
  const env = setup({
    paragraphs: [cue0, cue1],
    lyricsIndex: () => playing,
    query: { '.cue': [cue0, cue1] },
  });
  const s = env.sentence();
  assert.strictEqual(s.text, 'ふたつ。みっつ', '歌词行整行是一句，行内句号不切');
  assert.strictEqual(env.lookupAt(s.id, 4), true);
  // vm 上下文里的对象原型属另一 realm，按 JSON 比较。
  assert.strictEqual(JSON.stringify(env.window.__lyricsCueContext), '{"textFragmentId":"f1","cueIndex":1}');
  // 选区仍在 cue1：即使播放行变了，扫词也留在用户正在查的这一行。
  playing = 0;
  assert.strictEqual(env.sentence().id, s.id);
  // 弹窗关掉（选区清空）后跟随播放行。
  env.selection.selection = null;
  assert.strictEqual(env.sentence().text, '一行目。');
}

{
  // ⑧ 空页（插图页）：无可见字 → null，不抛。
  const p = makeElement([]);
  const env = setup({ paragraphs: [p], firstVisible: () => null });
  assert.strictEqual(env.sentence(), null);
}

console.log('all assertions passed');
