// TODO-1104 harness for fushiSelection drag-selection sentence span.
//
// PURPOSE: The user reported that mining an audiobook card from a DRAG selection
// spanning multiple sentences only captured (text + audio for) the START
// sentence. This harness EXECUTES the real selection JS (extracted verbatim from
// reader_selection_scripts.dart) against a minimal fake DOM + a fake
// window.fushiReader (normalized-offset map), and asserts:
//   (A) a drag spanning two sentences -> sentence text + sentenceNormalized range
//       both cover START-sentence-head .. END-sentence-tail (merged, wide);
//   (B) a collapsed selection (start == end == tap single point) -> byte-identical
//       to START-sentence-only (never-break hard constraint);
//   (C) a reversed / discontiguous span -> conservative fallback to the start
//       sentence;
//   (F) BUG-2058: getNormalizedOffset 的边界值（句首 / 句中 / 句尾 / 跨节点 / 西文
//       词中前缀），在真学习单位口径下逐点钉住，快路径与 walker 兜底两条都走。
// It also exercises the pure helpers spanSentenceRange / textBetween directly.
//
// Run: node fushi/test/media/audiobook/mining_clip_span_test.js
// (also driven from the matching .dart so it runs inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const scriptsPath = path.resolve(
  __dirname,
  '../../../lib/src/reader/reader_selection_scripts.dart',
);
const dart = fs.readFileSync(scriptsPath, 'utf8');
const TQ = String.fromCharCode(34).repeat(3);
const startMarker = 'static String source() => r' + TQ;
const startIdx = dart.indexOf(startMarker);
assert.ok(startIdx >= 0, 'missing source() raw-string start marker');
const bodyStart = startIdx + startMarker.length;
const endIdx = dart.indexOf(TQ + ';', bodyStart);
assert.ok(endIdx > bodyStart, 'missing source() raw-string end marker');
const jsSource = dart.substring(bodyStart, endIdx);
assert.ok(
  jsSource.includes('spanSentenceRange: function'),
  'extracted source must contain the TODO-1104 spanSentenceRange helper',
);
assert.ok(
  jsSource.includes('textBetween: function'),
  'extracted source must contain the TODO-1104 textBetween helper',
);

// BUG-2058: getNormalizedOffset 的计数判据搬到了 window.fushiStudyUnits（真机由
// ReaderPaginationScripts.engineShell 在任何 shell 之前注入）。这里同样从**真值常量**
// 里抽出来跑，不再自己造一个「每个字符都算数」的假判据 —— 假判据既会让 12 这种只在
// 假宇宙里成立的期望固化下来，也让「调用点被改回 isMatchableChar」这类回归照绿。
const unitScriptPath = path.resolve(
  __dirname,
  '../../../lib/src/reader/reader_study_unit_script.dart',
);
const unitDart = fs.readFileSync(unitScriptPath, 'utf8');
const unitMarker = 'const String kStudyUnitJs = r' + TQ;
const unitStart = unitDart.indexOf(unitMarker);
assert.ok(unitStart >= 0, 'missing kStudyUnitJs raw-string start marker');
const unitBodyStart = unitStart + unitMarker.length;
const unitEnd = unitDart.indexOf(TQ + ';', unitBodyStart);
assert.ok(unitEnd > unitBodyStart, 'missing kStudyUnitJs raw-string end marker');
const studyUnitJs = unitDart.substring(unitBodyStart, unitEnd);

// 一份独立实例，只用来给假的 nodeStartOffsets 算基准（见 makeFushiReader）。
const unitProbe = { window: {} };
vm.createContext(unitProbe);
vm.runInContext(studyUnitJs, unitProbe, { filename: 'fushi-study-units.js' });
const studyUnits = unitProbe.window.fushiStudyUnits;
assert.ok(studyUnits && studyUnits.count && studyUnits.isUnitEnd,
  'kStudyUnitJs must define window.fushiStudyUnits');

const NodeFilter = { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3 };
const Node = { ELEMENT_NODE: 1, TEXT_NODE: 3 };

function makeElement(tag, opts) {
  opts = opts || {};
  return {
    nodeType: Node.ELEMENT_NODE,
    tagName: tag.toUpperCase(),
    className: opts.className || '',
    parentElement: null,
    childNodes: [],
    get textContent() {
      let out = '';
      (function collect(n) {
        for (const c of n.childNodes || []) {
          if (c.nodeType === Node.TEXT_NODE) out += c.textContent;
          else collect(c);
        }
      })(this);
      return out;
    },
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim());
      let cur = this;
      while (cur) {
        for (const part of parts) {
          if (part.startsWith('.')) {
            const cls = part.slice(1);
            if ((cur.className || '').split(/\s+/).includes(cls)) return cur;
          } else if (cur.tagName && cur.tagName.toLowerCase() === part.toLowerCase()) {
            return cur;
          }
        }
        cur = cur.parentElement;
      }
      return null;
    },
  };
}

function makeText(content, parent) {
  const t = { nodeType: Node.TEXT_NODE, textContent: content, nodeValue: content, parentElement: parent };
  if (parent) parent.childNodes.push(t);
  return t;
}

function buildDocument(container) {
  return {
    body: container,
    createTreeWalker(root, whatToShow, filter) {
      const all = [];
      (function walk(n) {
        for (const c of n.childNodes || []) {
          if (c.nodeType === Node.TEXT_NODE) all.push(c);
          else walk(c);
        }
      })(root);
      const accepted = all.filter((n) => filter.acceptNode(n) === NodeFilter.FILTER_ACCEPT);
      let idx = -1;
      return {
        currentNode: root,
        nextNode() {
          let start = accepted.indexOf(this.currentNode);
          if (start < 0) start = idx;
          idx = start + 1;
          this.currentNode = idx < accepted.length ? accepted[idx] : null;
          return this.currentNode;
        },
        previousNode() {
          let start = accepted.indexOf(this.currentNode);
          if (start < 0) start = idx;
          idx = start - 1;
          this.currentNode = idx >= 0 ? accepted[idx] : null;
          return this.currentNode;
        },
      };
    },
  };
}

// Fake whole-book normalized-offset map. The BASES are computed with the REAL
// study-unit counter, so the map is in the same coordinate system the shipped
// fushiReader.buildNodeOffsets produces: a node's base == 学习单位 count of every
// preceding text node in document order.
//
// 故意不再提供 isMatchableChar：选区 JS 里已经没有这个调用点了（计数走
// window.fushiStudyUnits），谁把 getNormalizedOffset 改回 fushiReader.isMatchableChar
// 就会在这里 TypeError 而不是静默换口径。
function makeFushiReader(textNodesInOrder) {
  const nodeStartOffsets = new Map();
  let base = 0;
  for (const node of textNodesInOrder) {
    nodeStartOffsets.set(node, base);
    base += studyUnits.count(node.textContent);
  }
  return { nodeStartOffsets, buildNodeOffsets() {} };
}

function loadFushiSelection(document, fushiReader) {
  const windowObj = { scanNonJapaneseText: true, fushiReader };
  const sandbox = { window: windowObj, document, Node, NodeFilter, Math, console, String, Array, Number, RegExp };
  vm.createContext(sandbox);
  // 真机顺序：engineShell 先注入 kStudyUnitJs，再装 shell / 选区 JS。
  vm.runInContext(studyUnitJs, sandbox, { filename: 'fushi-study-units.js' });
  assert.ok(windowObj.fushiStudyUnits, 'window.fushiStudyUnits must be defined');
  vm.runInContext(jsSource, sandbox, { filename: 'fushi-selection.js' });
  assert.ok(windowObj.fushiSelection, 'window.fushiSelection must be defined');
  return windowObj.fushiSelection;
}

let passed = 0;

// CASE A: drag spans TWO sentences in one <p>. Card text + sentence normalized
// range must cover BOTH sentences (start-head .. end-tail), same source.
(function caseA() {
  const p = makeElement('p');
  const t = makeText('一つ目の文。二つ目の文。', p);
  const document = buildDocument(p);
  const reader = makeFushiReader([t]);
  const sel = loadFushiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t, 2);
  const endCtx = sel.getSentenceContext(t, 8);
  const snStart = sel.getNormalizedOffset(startCtx.sStartNode, startCtx.sStartOffset);
  const snEnd = sel.getNormalizedOffset(endCtx.sEndNode, endCtx.sEndOffset);
  assert.strictEqual(snStart, 0, 'A: start head 0');
  // 10 而不是 12：`。` 不是学习单位。旧期望里的 12 只在本 harness 早先那个
  // 「每个字符都算数」的假判据下成立；真机的 fushiReader.buildNodeOffsets 与
  // getNormalizedOffset 现在都在学习单位坐标系里（BUG-2058），两者同源。
  assert.strictEqual(snEnd, 10, 'A: end tail 10 (2 sentences x 5 units, 句点不计)');
  const span = sel.spanSentenceRange(startCtx, endCtx, snStart, snEnd);
  assert.strictEqual(span.merged, true, 'A: merged');
  assert.strictEqual(span.offset, 0, 'A: offset 0');
  assert.strictEqual(span.length, 10, 'A: length 10 covers both sentences');
  const mergedText = sel.textBetween(span.sStartNode, span.sStartOffset, span.sEndNode, span.sEndOffset);
  assert.strictEqual(mergedText, '一つ目の文。二つ目の文。', 'A: merged card text covers both sentences');
  passed++;
})();

// CASE A2: drag spans two sentences across SEPARATE sibling text nodes.
(function caseA2() {
  const p = makeElement('p');
  const t1 = makeText('前の文。', p);
  const t2 = makeText('後の文。', p);
  const document = buildDocument(p);
  const reader = makeFushiReader([t1, t2]);
  const sel = loadFushiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t1, 1);
  const endCtx = sel.getSentenceContext(t2, 1);
  const snStart = sel.getNormalizedOffset(startCtx.sStartNode, startCtx.sStartOffset);
  const snEnd = sel.getNormalizedOffset(endCtx.sEndNode, endCtx.sEndOffset);
  const span = sel.spanSentenceRange(startCtx, endCtx, snStart, snEnd);
  assert.strictEqual(span.merged, true, 'A2: merged');
  assert.strictEqual(snStart, 0, 'A2: 跨节点起点 0');
  // 第二个节点的基准由真计数给出（前节点 3 个单位），跨节点累加不错位。
  assert.strictEqual(snEnd, 6, 'A2: 跨节点终点 6 = 3 + 3');
  assert.strictEqual(span.length, 6, 'A2: length 6');
  const mergedText = sel.textBetween(span.sStartNode, span.sStartOffset, span.sEndNode, span.sEndOffset);
  assert.strictEqual(mergedText, '前の文。後の文。', 'A2: cross-node merged text');
  passed++;
})();

// CASE B: collapsed selection -> byte-identical to single sentence (never-break).
(function caseB() {
  const p = makeElement('p');
  const t = makeText('前の文。これが対象の文。次の文。', p);
  const document = buildDocument(p);
  const reader = makeFushiReader([t]);
  const sel = loadFushiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t, 7);
  const endCtx = startCtx;
  assert.strictEqual(startCtx.sentence, 'これが対象の文。', 'B: single sentence');
  const snStart = sel.getNormalizedOffset(startCtx.sStartNode, startCtx.sStartOffset);
  const snEnd = sel.getNormalizedOffset(endCtx.sEndNode, endCtx.sEndOffset);
  const span = sel.spanSentenceRange(startCtx, endCtx, snStart, snEnd);
  assert.strictEqual(span.offset, snStart, 'B: offset == single head');
  assert.strictEqual(span.length, snEnd - snStart, 'B: length == single own length');
  assert.strictEqual(span.sStartNode, startCtx.sStartNode, 'B: sStartNode identical');
  assert.strictEqual(span.sEndNode, startCtx.sEndNode, 'B: sEndNode identical');
  assert.strictEqual(span.sEndOffset, startCtx.sEndOffset, 'B: sEndOffset identical');
  const spanText = sel.textBetween(span.sStartNode, span.sStartOffset, span.sEndNode, span.sEndOffset);
  assert.strictEqual(spanText, 'これが対象の文。', 'B: collapsed span text == single sentence');
  passed++;
})();

// CASE C: reversed / discontiguous -> conservative fallback to start.
(function caseC() {
  const p = makeElement('p');
  const t = makeText('一つ目の文。二つ目の文。', p);
  const document = buildDocument(p);
  const reader = makeFushiReader([t]);
  const sel = loadFushiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t, 8);
  const endCtx = sel.getSentenceContext(t, 2);
  const reversed = sel.spanSentenceRange(startCtx, endCtx, 6, 5);
  assert.strictEqual(reversed.merged, false, 'C: reversed pair falls back');
  assert.strictEqual(reversed.offset, 6, 'C: fallback keeps start head');
  assert.strictEqual(reversed.sEndNode, startCtx.sEndNode, 'C: fallback sEnd == start sentence');
  passed++;
})();

// CASE D: null normalized offset (reader not ready) -> fallback.
(function caseD() {
  const p = makeElement('p');
  const t = makeText('文。', p);
  const document = buildDocument(p);
  const reader = makeFushiReader([t]);
  const sel = loadFushiSelection(document, reader);
  const ctx = sel.getSentenceContext(t, 0);
  assert.strictEqual(sel.spanSentenceRange(ctx, ctx, null, 4).merged, false, 'D: null start -> fallback');
  assert.strictEqual(sel.spanSentenceRange(ctx, ctx, 0, null).merged, false, 'D: null end -> fallback');
  passed++;
})();

// CASE E: textBetween end node UNREACHABLE from start block -> empty string.
(function caseE() {
  const body = makeElement('body');
  const p1 = makeElement('p');
  p1.parentElement = body;
  body.childNodes.push(p1);
  const a = makeText('第一段落。', p1);
  const p2 = makeElement('p');
  p2.parentElement = body;
  body.childNodes.push(p2);
  const b = makeText('第二段落。', p2);
  const document = buildDocument(body);
  const reader = makeFushiReader([a, b]);
  const sel = loadFushiSelection(document, reader);
  assert.strictEqual(sel.textBetween(a, 0, b, 5), '', 'E: unreachable end node -> empty (caller falls back)');
  passed++;
})();

// CASE F (BUG-2058): getNormalizedOffset 的**边界值**，在真学习单位口径下逐点钉死。
// 三条改动过的计数循环全部走到：① nodeStartOffsets 命中的快路径；② walker 兜底里
// 「目标节点之前的整节点」；③ walker 兜底里「目标节点的前缀」。
(function caseF() {
  const p = makeElement('p');
  const ja = makeText('一つ目の文。', p);     // 5 个单位（句点不计）
  const en = makeText('Hello world.', p);     // 2 个单位（整词各算一个）
  const document = buildDocument(p);
  const sel = loadFushiSelection(document, makeFushiReader([ja, en]));

  // ① 快路径：句首 / 句中 / 句尾。
  assert.strictEqual(sel.getNormalizedOffset(ja, 0), 0, 'F: 句首 = 0');
  assert.strictEqual(sel.getNormalizedOffset(ja, 3), 3, 'F: 句中 3 个假名 = 3');
  assert.strictEqual(sel.getNormalizedOffset(ja, 5), 5, 'F: 句点之前 = 5');
  assert.strictEqual(sel.getNormalizedOffset(ja, 6), 5, 'F: 句尾含句点仍 = 5（句点不是学习单位）');

  // 跨节点：第二个节点的基准 == 前一个节点的单位总数。
  assert.strictEqual(sel.getNormalizedOffset(en, 0), 5, 'F: 跨节点头 = 5');
  // 西文前缀语义（reader_study_unit_script.dart 顶部写明）：词没写完不计。
  assert.strictEqual(sel.getNormalizedOffset(en, 3), 5, 'F: 词中前缀 "Hel" 不加 1');
  assert.strictEqual(sel.getNormalizedOffset(en, 5), 6, 'F: 整词 "Hello" 结束 = 6');
  assert.strictEqual(sel.getNormalizedOffset(en, 11), 7, 'F: "Hello world" = 7');
  assert.strictEqual(sel.getNormalizedOffset(en, 12), 7, 'F: 句点不再加 = 7');

  // ②③ walker 兜底：把 en 从 nodeStartOffsets 里拿掉，逼 getNormalizedOffset 走
  // 「从 body 起逐节点累加」的第二条路径，结果必须与快路径逐值相同 —— 两条路径
  // 用同一个判据，错位一格会在这里立刻暴露。
  const partial = { nodeStartOffsets: new Map([[ja, 0]]), buildNodeOffsets() {} };
  const sel2 = loadFushiSelection(document, partial);
  assert.strictEqual(sel2.getNormalizedOffset(en, 0), 5, 'F: 兜底路径 跨节点头 = 5');
  assert.strictEqual(sel2.getNormalizedOffset(en, 3), 5, 'F: 兜底路径 词中前缀不加 1');
  assert.strictEqual(sel2.getNormalizedOffset(en, 5), 6, 'F: 兜底路径 整词结束 = 6');
  assert.strictEqual(sel2.getNormalizedOffset(en, 12), 7, 'F: 兜底路径 节点尾 = 7');
  passed++;
})();

console.log('passed ' + passed + ' cases');
console.log('all assertions passed');
