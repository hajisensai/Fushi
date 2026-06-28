// TODO-948/952 characterization harness for hoshiSelection.getSentenceContext.
//
// PURPOSE: This test does NOT change getSentenceContext behaviour. It EXECUTES
// the real JS (extracted verbatim from reader_selection_scripts.dart) against a
// minimal fake DOM and RECORDS what getSentenceContext returns for boundary DOM
// shapes the user's "card has no sentence" report blamed:
//   (1) plain text with NO <p> wrapper and NO sentence delimiter,
//   (2) <p> present but NO sentence-ending punctuation at all,
//   (3) a sentence split ACROSS sibling text nodes (cross-node assembly),
//   (4) a truly empty (whitespace-only) container.
// It asserts the ACTUAL current return so we can state, with evidence, whether
// "content -> empty sentence" is a real failure mode. CONCLUSION (recorded by
// the assertions below): a NON-EMPTY container never yields an empty sentence
// (the extractor falls back to the whole container text); ONLY a whitespace-only
// container returns an empty sentence. So "card has no sentence" is NOT caused
// by missing <p> / missing punctuation per se -- it is caused either by a
// genuinely empty selection container or by an unmapped Anki {sentence} field
// (the other diagnostic the mining path now surfaces).
//
// Run: node hibiki/test/reader/reader_get_sentence_context_boundary_test.js
// (also driven from the matching .dart so it runs inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// --- Extract the verbatim hoshiSelection source from the Dart raw string. ---
const scriptsPath = path.resolve(
  __dirname,
  '../../lib/src/reader/reader_selection_scripts.dart',
);
const dart = fs.readFileSync(scriptsPath, 'utf8');
const startMarker = 'static String source() => r"""';
const startIdx = dart.indexOf(startMarker);
assert.ok(startIdx >= 0, 'missing source() raw-string start marker');
const bodyStart = startIdx + startMarker.length;
const endIdx = dart.indexOf('""";', bodyStart);
assert.ok(endIdx > bodyStart, 'missing source() raw-string end marker');
const jsSource = dart.substring(bodyStart, endIdx);
assert.ok(
  jsSource.includes('getSentenceContext: function'),
  'extracted source must contain getSentenceContext',
);

// --- Minimal fake DOM. ---------------------------------------------------
// A tree of TEXT/ELEMENT nodes. The TreeWalker we implement (SHOW_TEXT)
// iterates the text nodes in document order; furigana (rt/rp) nodes are
// REJECTED exactly like the real walker via acceptNode. closest() climbs the
// parent chain matching the tag/class selectors the reader actually queries
// (p, .glossary-content, .cue, rt, rp, ruby).
const NodeFilter = {
  SHOW_TEXT: 4,
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3,
};
const Node = { ELEMENT_NODE: 1, TEXT_NODE: 3 };

function makeElement(tag, opts) {
  opts = opts || {};
  return {
    nodeType: Node.ELEMENT_NODE,
    tagName: tag.toUpperCase(),
    className: opts.className || '',
    parentElement: null,
    childNodes: [],
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim());
      let cur = this;
      while (cur) {
        for (const part of parts) {
          if (part.startsWith('.')) {
            const cls = part.slice(1);
            if ((cur.className || '').split(/\s+/).includes(cls)) return cur;
          } else if (
            cur.tagName &&
            cur.tagName.toLowerCase() === part.toLowerCase()
          ) {
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
  const t = {
    nodeType: Node.TEXT_NODE,
    textContent: content,
    parentElement: parent,
  };
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
      const accepted = all.filter(
        (n) => filter.acceptNode(n) === NodeFilter.FILTER_ACCEPT,
      );
      let idx = -1;
      const walker = {
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
      return walker;
    },
  };
}

function loadHoshiSelection(document) {
  const windowObj = { scanNonJapaneseText: true };
  const sandbox = { window: windowObj, document, Node, NodeFilter, Math, console };
  vm.createContext(sandbox);
  vm.runInContext(jsSource, sandbox, { filename: 'hoshi-selection.js' });
  assert.ok(windowObj.hoshiSelection, 'window.hoshiSelection must be defined');
  return windowObj.hoshiSelection;
}

function record(label, value) {
  console.log('CHAR-RESULT ' + label + ' :: ' + JSON.stringify(value));
}

let passed = 0;

// CASE 1: bare <div> (NOT a paragraph), one text node, NO delimiter.
// findParagraph() -> null -> container falls back to document.body (the div).
// EXPECTED (current behaviour): whole text returned, offset 0 (NOT empty).
(function case1() {
  const div = makeElement('div');
  makeText('これはテスト', div);
  const document = buildDocument(div);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(div.childNodes[0], 2);
  record('case1_no_p_no_delim', {
    sentence: ctx.sentence,
    offset: ctx.sentenceOffset,
  });
  assert.strictEqual(
    ctx.sentence,
    'これはテスト',
    'CASE1: no-<p>/no-delim falls back to the WHOLE container text (not empty)',
  );
  // Characterization: with no preceding delimiter the sentence starts at the
  // container head, so sentenceOffset == the caret startOffset (2) -- NOT 0.
  assert.strictEqual(ctx.sentenceOffset, 2, 'CASE1 offset == caret startOffset');
  passed++;
})();

// CASE 2: <p> present but NO ending punctuation.
(function case2() {
  const p = makeElement('p');
  makeText('吾輩は猫である', p);
  const document = buildDocument(p);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(p.childNodes[0], 3);
  record('case2_p_no_delim', {
    sentence: ctx.sentence,
    offset: ctx.sentenceOffset,
  });
  assert.strictEqual(
    ctx.sentence,
    '吾輩は猫である',
    'CASE2: <p> with no delimiter returns the full paragraph text (not empty)',
  );
  passed++;
})();

// CASE 3: sentence split across sibling text nodes, delimiter only at the end.
(function case3() {
  const p = makeElement('p');
  makeText('前半', p);
  makeText('後半。', p);
  const document = buildDocument(p);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(p.childNodes[1], 1);
  record('case3_cross_node', {
    sentence: ctx.sentence,
    offset: ctx.sentenceOffset,
  });
  assert.strictEqual(
    ctx.sentence,
    '前半後半。',
    'CASE3: sentence must assemble across sibling text nodes',
  );
  passed++;
})();

// CASE 4: truly empty (whitespace-only) container -> the ONLY empty-sentence path.
(function case4() {
  const p = makeElement('p');
  makeText('   ', p);
  const document = buildDocument(p);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(p.childNodes[0], 1);
  record('case4_whitespace_only', {
    sentence: ctx.sentence,
    offset: ctx.sentenceOffset,
  });
  assert.strictEqual(
    ctx.sentence,
    '',
    'CASE4: whitespace-only container is the real path that yields an EMPTY sentence',
  );
  passed++;
})();

console.log('passed ' + passed + ' cases');
console.log('all assertions passed');
