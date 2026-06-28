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
    // Real DOM elements expose textContent (concatenation of descendant text);
    // fix 3's empty-after-trim fallback reads container.textContent.
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
    // Real DOM text nodes expose nodeValue; createWalker's whitespace-only
    // filter (TODO-956) reads it, so the fake must mirror it for fidelity.
    nodeValue: content,
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

// === TODO-956 regression cases (diverge pre/post block-bounded walk). ===
// Each builds a multi-block <body> tree. BEFORE the fix findParagraph() returns
// null for non-<p> blocks, so the walk falls back to document.body and crosses
// SIBLING blocks (and inter-block whitespace/newline nodes, where '\n' is a
// sentence delimiter). AFTER the fix the walk is bounded to the word's own
// block, so it returns exactly that block's sentence.

// CASE 5: word in <h2>, with a PRECEDING sibling block that has NO trailing
// delimiter. BEFORE: the "before" walk leaves the heading, crosses the inter-
// block whitespace + the previous <div>'s text, merging it into the heading
// "sentence". AFTER: bounded to <h2> -> just the heading.
(function case5_h2_crossblock() {
  const body = makeElement('body');
  const prev = makeElement('div');
  prev.parentElement = body;
  body.childNodes.push(prev);
  makeText('前の段落に句点なし', prev); // NO delimiter -> walk would keep going back
  makeText('\n  ', body);              // inter-block whitespace
  const h2 = makeElement('h2');
  h2.parentElement = body;
  body.childNodes.push(h2);
  const heading = makeText('見出し', h2);

  const document = buildDocument(body);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(heading, 1);
  record('case5_h2', { sentence: ctx.sentence, offset: ctx.sentenceOffset });
  assert.strictEqual(
    ctx.sentence,
    '見出し',
    'CASE5: <h2> word must NOT absorb the previous sibling block text',
  );
  passed++;
})();

// CASE 6: word in <li>, with a FOLLOWING sibling <li> that begins the same way.
// BEFORE: with no delimiter in the first item, the "after" walk crosses the
// inter-item whitespace into the next <li>, merging both items. AFTER: bounded
// to the first <li>.
(function case6_li_crossblock() {
  const ul = makeElement('ul');
  const li1 = makeElement('li');
  li1.parentElement = ul;
  ul.childNodes.push(li1);
  const item = makeText('一つ目の項目', li1); // no delimiter
  makeText('\n', ul);
  const li2 = makeElement('li');
  li2.parentElement = ul;
  ul.childNodes.push(li2);
  makeText('二つ目の項目', li2);

  const document = buildDocument(ul);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(item, 1);
  record('case6_li', { sentence: ctx.sentence, offset: ctx.sentenceOffset });
  assert.strictEqual(
    ctx.sentence,
    '一つ目の項目',
    'CASE6: <li> word must NOT absorb the following sibling <li> text',
  );
  passed++;
})();

// CASE 7: word in a <div> whose block holds visible text, but the selection is
// at offset 0 and the ONLY preceding node in body is a whitespace/newline node.
// BEFORE: findParagraph null -> body; the walk's "before" pass steps onto the
// whitespace node, and because '\n' counts as a delimiter the assembled sentence
// can collapse depending on layout. AFTER: createWalker REJECTs the whitespace
// node and the block bounds the walk, so the real sentence is returned and is
// never whitespace.
(function case7_div_leading_ws() {
  const body = makeElement('body');
  makeText('\n   \n', body); // leading inter-block whitespace/newline node
  const block = makeElement('div');
  block.parentElement = body;
  body.childNodes.push(block);
  const word = makeText('走れメロス。', block);

  const document = buildDocument(body);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(word, 0);
  record('case7_div_ws', { sentence: ctx.sentence, offset: ctx.sentenceOffset });
  assert.ok(
    ctx.sentence.trim().length > 0,
    'CASE7: visible word must never yield a whitespace/empty sentence',
  );
  assert.strictEqual(
    ctx.sentence,
    '走れメロス。',
    'CASE7: selection adjacent to whitespace nodes returns the real sentence',
  );
  passed++;
})();

// CASE 8 (regression): clean multi-sentence <p> still returns EXACTLY the one
// sentence containing the word -- unchanged by the block-bound / whitespace-skip
// fixes.
(function case8_multi_sentence_p() {
  const p = makeElement('p');
  const text = makeText('前の文。これが対象の文。次の文。', p);
  const document = buildDocument(p);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(text, 7);
  record('case8_multi_p', { sentence: ctx.sentence, offset: ctx.sentenceOffset });
  assert.strictEqual(
    ctx.sentence,
    'これが対象の文。',
    'CASE8: clean multi-sentence <p> returns exactly the containing sentence',
  );
  passed++;
})();

// CASE 9: export path (firstTextNode). The native-selection export resolves an
// ELEMENT start container down to its first text node. BEFORE the fix
// firstTextNode accepted ANY node with textContent.length > 0 -- including a
// leading whitespace/newline node -- so the export anchored on "\n   " and the
// sentence walk produced whitespace -> trim() => '' (the empty {sentence}). AFTER
// the fix it skips whitespace-only nodes and anchors on the visible word.
(function case9_firstTextNode_skips_ws() {
  const div = makeElement('div');
  const ws = makeText('\n   ', div);     // leading whitespace-only text node
  const word = makeText('本文です。', div); // the real visible word/sentence

  const document = buildDocument(div);
  const sel = loadHoshiSelection(document);

  // Direct contract: firstTextNode(<div>) must skip the whitespace node.
  const first = sel.firstTextNode(div);
  record('case9_firstTextNode', {
    picked: first ? first.node.textContent : null,
  });
  assert.ok(first, 'CASE9: firstTextNode must resolve a node');
  assert.strictEqual(
    first.node,
    word,
    'CASE9: firstTextNode must skip the whitespace-only node and pick the word',
  );

  // End-to-end: the sentence resolved from that node is the real, non-empty one.
  const ctx = sel.getSentenceContext(first.node, first.offset);
  record('case9_sentence', { sentence: ctx.sentence });
  assert.strictEqual(
    ctx.sentence,
    '本文です。',
    'CASE9: export-path sentence is the real text, never whitespace/empty',
  );
  void ws;
  passed++;
})();

// CASE 10: empty-after-trim guard (TODO-956 fix 3). The caret lands right after
// a sentence delimiter, and the only text that follows in the walk is a
// whitespace-only node, so the assembled raw sentence trims to ''. BEFORE: the
// extractor returns '' even though the block has visible text. AFTER: it falls
// back to the block's own visible textContent, honoring the contract that a
// visible word in visible text yields a non-empty sentence.
(function case10_empty_after_trim_fallback() {
  const div = makeElement('div');
  // "文。" then a trailing whitespace node. Caret at offset 2 (just AFTER "。").
  const head = makeText('文。', div);
  makeText('   ', div); // whitespace-only trailing node
  const document = buildDocument(div);
  const sel = loadHoshiSelection(document);
  const ctx = sel.getSentenceContext(head, 2);
  record('case10_empty_trim', { sentence: ctx.sentence, offset: ctx.sentenceOffset });
  assert.ok(
    ctx.sentence.trim().length > 0,
    'CASE10: visible block must not yield an empty sentence after the delimiter',
  );
  assert.strictEqual(
    ctx.sentence,
    '文。',
    'CASE10: empty-after-trim falls back to the block textContent',
  );
  passed++;
})();

console.log('passed ' + passed + ' cases');
console.log('all assertions passed');
