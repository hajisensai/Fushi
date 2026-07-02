// TODO-1104 harness for hoshiSelection drag-selection sentence span.
//
// PURPOSE: The user reported that mining an audiobook card from a DRAG selection
// spanning multiple sentences only captured (text + audio for) the START
// sentence. This harness EXECUTES the real selection JS (extracted verbatim from
// reader_selection_scripts.dart) against a minimal fake DOM + a fake
// window.hoshiReader (normalized-offset map), and asserts:
//   (A) a drag spanning two sentences -> sentence text + sentenceNormalized range
//       both cover START-sentence-head .. END-sentence-tail (merged, wide);
//   (B) a collapsed selection (start == end == tap single point) -> byte-identical
//       to START-sentence-only (never-break hard constraint);
//   (C) a reversed / discontiguous span -> conservative fallback to the start
//       sentence.
// It also exercises the pure helpers spanSentenceRange / textBetween directly.
//
// Run: node hibiki/test/media/audiobook/mining_clip_span_test.js
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

// Fake whole-book normalized-offset map: every char is matchable, so a node's
// normalized offset == cumulative text length in document order.
function makeHoshiReader(textNodesInOrder, baseByNode) {
  const nodeStartOffsets = new Map();
  for (const node of textNodesInOrder) nodeStartOffsets.set(node, baseByNode.get(node));
  return { nodeStartOffsets, isMatchableChar() { return true; }, buildNodeOffsets() {} };
}

function loadHoshiSelection(document, hoshiReader) {
  const windowObj = { scanNonJapaneseText: true, hoshiReader };
  const sandbox = { window: windowObj, document, Node, NodeFilter, Math, console };
  vm.createContext(sandbox);
  vm.runInContext(jsSource, sandbox, { filename: 'hoshi-selection.js' });
  assert.ok(windowObj.hoshiSelection, 'window.hoshiSelection must be defined');
  return windowObj.hoshiSelection;
}

let passed = 0;

// CASE A: drag spans TWO sentences in one <p>. Card text + sentence normalized
// range must cover BOTH sentences (start-head .. end-tail), same source.
(function caseA() {
  const p = makeElement('p');
  const t = makeText('一つ目の文。二つ目の文。', p);
  const document = buildDocument(p);
  const reader = makeHoshiReader([t], new Map([[t, 0]]));
  const sel = loadHoshiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t, 2);
  const endCtx = sel.getSentenceContext(t, 8);
  const snStart = sel.getNormalizedOffset(startCtx.sStartNode, startCtx.sStartOffset);
  const snEnd = sel.getNormalizedOffset(endCtx.sEndNode, endCtx.sEndOffset);
  assert.strictEqual(snStart, 0, 'A: start head 0');
  assert.strictEqual(snEnd, 12, 'A: end tail 12');
  const span = sel.spanSentenceRange(startCtx, endCtx, snStart, snEnd);
  assert.strictEqual(span.merged, true, 'A: merged');
  assert.strictEqual(span.offset, 0, 'A: offset 0');
  assert.strictEqual(span.length, 12, 'A: length 12 covers both sentences');
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
  const reader = makeHoshiReader([t1, t2], new Map([[t1, 0], [t2, 4]]));
  const sel = loadHoshiSelection(document, reader);
  const startCtx = sel.getSentenceContext(t1, 1);
  const endCtx = sel.getSentenceContext(t2, 1);
  const snStart = sel.getNormalizedOffset(startCtx.sStartNode, startCtx.sStartOffset);
  const snEnd = sel.getNormalizedOffset(endCtx.sEndNode, endCtx.sEndOffset);
  const span = sel.spanSentenceRange(startCtx, endCtx, snStart, snEnd);
  assert.strictEqual(span.merged, true, 'A2: merged');
  assert.strictEqual(span.length, 8, 'A2: length 8');
  const mergedText = sel.textBetween(span.sStartNode, span.sStartOffset, span.sEndNode, span.sEndOffset);
  assert.strictEqual(mergedText, '前の文。後の文。', 'A2: cross-node merged text');
  passed++;
})();

// CASE B: collapsed selection -> byte-identical to single sentence (never-break).
(function caseB() {
  const p = makeElement('p');
  const t = makeText('前の文。これが対象の文。次の文。', p);
  const document = buildDocument(p);
  const reader = makeHoshiReader([t], new Map([[t, 0]]));
  const sel = loadHoshiSelection(document, reader);
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
  const reader = makeHoshiReader([t], new Map([[t, 0]]));
  const sel = loadHoshiSelection(document, reader);
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
  const reader = makeHoshiReader([t], new Map([[t, 0]]));
  const sel = loadHoshiSelection(document, reader);
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
  const reader = makeHoshiReader([a, b], new Map([[a, 0], [b, 5]]));
  const sel = loadHoshiSelection(document, reader);
  assert.strictEqual(sel.textBetween(a, 0, b, 5), '', 'E: unreachable end node -> empty (caller falls back)');
  passed++;
})();

console.log('passed ' + passed + ' cases');
console.log('all assertions passed');
