// BUG-2492 behavior test: the paged shell's first-visible-char scan fallback must
// count along the PAGE-TURN axis, and a start offset that is not on the current
// page must never become a study-ledger unit.
//
// Regression context (iOS, 2026-09-13): one page turn credited 5172 chars. The
// page-top caret probe landed on a non-text element (illustration `<p><img>`),
// `getFirstVisibleCharOffset` fell back to `firstVisibleCharOffsetByScanPaged`,
// and that scan judged "before the viewport" with the CONTINUOUS-mode axes
// (horizontal `rect.bottom <= 0`, vertical `rect.left >= body.clientWidth`).
// Paged layout is CSS multicol along the turn axis (horizontal: columns left→
// right, scrollLeft; vertical: columns top→bottom, scrollTop), so previous pages
// sit to the LEFT / ABOVE and never satisfied the test → the scan returned 0 →
// `fushiProgressDetails` reported [0, pageEnd) as the visible unit → the ledger
// credited the whole preceding chapter text on the next page turn.
//
// This harness instantiates the real paged shell object (extracted from
// reader_pagination_scripts.dart via the Dart driver) against a fake DOM whose
// per-character rects are laid out on a 3-page band grid, and asserts:
//   1. the scan returns the number of characters on previous pages (not 0), for
//      both writing modes;
//   2. `charOffsetOnCurrentPage` accepts offsets drawn on the current page and
//      rejects previous / next page offsets;
//   3. `getLastVisibleCharOffset(start)` returns -1 for an off-page start (so the
//      Dart side does not arrive) and the page end for an on-page start;
//   4. `getFirstVisibleCharOffset` with a caret on an element (illustration)
//      takes the geometric scan instead of the element subtree's first text;
//   5. `fushiProgressDetails` does not let the atEnd clamp bypass the -1.
//
// Run: node fushi/test/reader/paged_first_visible_scan_axis_behavior_test.js <payload.json>
// (driven from paged_first_visible_scan_axis_behavior_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');

const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function objectLiteral(source) {
  const marker = 'window.fushiReader = {';
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'fushiReader object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  assert.ok(end >= 0, 'fushiReader object terminator missing');
  return source.slice(brace, end + 2);
}

// ── fake DOM ──────────────────────────────────────────────────────────────
// Page bands along the turn axis, body-relative. Current page = 1. Content box
// starts at `first` (padding-top / padding-left) and ends at `last`.
const GAP = 20;
const BAND = 560;            // content-box extent along the turn axis
const STEP = BAND + GAP;     // pageStep
const PT = 110, PB = 30, PL = 30, PR = 30;
const CLIENT_H = PT + BAND + PB;  // 700
const CLIENT_W = PL + BAND + PR;  // 620

function charRect(vertical, page, k) {
  // Along the turn axis: page 0 lies one step before the current band.
  const bandStart = (vertical ? PT : PL) + (page - 1) * STEP;
  const along = bandStart + (k % 20) * 25;
  const across = 300 - Math.floor(k / 20) * 30;
  return vertical
    ? { top: along, bottom: along + 25, left: across, right: across + 28, width: 28, height: 25 }
    : { left: along, right: along + 25, top: across, bottom: across + 28, width: 25, height: 28 };
}

function textNode(text, pageOf, vertical) {
  const rects = [];
  const chars = Array.from(text);
  for (let i = 0; i < chars.length; i++) rects.push(charRect(vertical, pageOf(i), i));
  return { nodeType: 3, textContent: text, charRects: rects };
}

function makeRange() {
  return {
    node: null, start: 0, end: 0,
    setStart(n, o) { this.node = n; this.start = o; },
    setEnd(n, o) { this.end = o; },
    collapse() {},
    selectNodeContents(n) { this.node = n; this.start = 0; this.end = n.textContent.length; },
    getClientRects() { return this.node ? this.node.charRects.slice(this.start, this.end) : []; },
    getBoundingClientRect() {
      return this.getClientRects()[0] || { width: 0, height: 0, top: 0, bottom: 0, left: 0, right: 0 };
    },
  };
}

function instantiate(vertical) {
  const window = { scrollX: 0, CSS: {}, Highlight: function() {} };
  const style = {
    writingMode: vertical ? 'vertical-rl' : 'horizontal-tb',
    paddingTop: PT + 'px', paddingBottom: PB + 'px',
    paddingLeft: PL + 'px', paddingRight: PR + 'px',
  };
  const getComputedStyle = () => style;
  window.getComputedStyle = getComputedStyle;
  const document = {
    documentElement: {},
    scrollingElement: null,
    body: { clientWidth: CLIENT_W, clientHeight: CLIENT_H },
    createRange: makeRange,
    caretRangeFromPoint: () => null,
  };
  const Node = { TEXT_NODE: 3 };
  new Function('window', data.studyUnits)(window);
  const C = { perfTraceEnabled: false };
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'window.fushiReader = ' + objectLiteral(data.paged) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, {}, window.CSS, window.Highlight, getComputedStyle, Node);

  // A: 10 chars on page 0 · B: 5 on page 0 + 5 on page 1 · C: 12 on page 1 · D: 8 on page 2.
  // Offsets: A 0–9 · B 10–19 (15 = first char of the current page) · C 20–31 · D 32–39.
  const nodes = [
    textNode('あいうえおかきくけこ', () => 0, vertical),
    textNode('さしすせそたちつてと', i => (i < 5 ? 0 : 1), vertical),
    textNode('なにぬねのはひふへほまみ', () => 1, vertical),
    textNode('むめもやゆよらり', () => 2, vertical),
  ];
  reader.createWalker = () => {
    let i = -1;
    return { nextNode() { i++; return nodes[i] || null; } };
  };
  reader.getScrollContext = () => ({ vertical, pageSize: STEP, scrollEl: document.body });
  reader.getPagePosition = () => STEP;
  reader.isAtEnd = () => false;
  reader.paginationMetrics = { totalChars: 40, maxScroll: 3 * STEP, minScroll: 0, progressStops: [] };
  return { reader, document, nodes };
}

for (const vertical of [true, false]) {
  const label = vertical ? 'vertical-rl' : 'horizontal-tb';
  const { reader, document, nodes } = instantiate(vertical);

  // 1. scan counts characters on previous pages along the turn axis.
  assert.strictEqual(
    reader.firstVisibleCharOffsetByScanPaged(), 15,
    label + ': scan fallback must count the 15 chars on the previous page (was 0 with the continuous-mode axes)');

  // 2. on-page check.
  assert.strictEqual(reader.charOffsetOnCurrentPage(15), true, label + ': first char of current page is on page');
  assert.strictEqual(reader.charOffsetOnCurrentPage(31), true, label + ': last char of current page is on page');
  assert.strictEqual(reader.charOffsetOnCurrentPage(14), false, label + ': previous-page char rejected');
  assert.strictEqual(reader.charOffsetOnCurrentPage(0), false, label + ': chapter start rejected');
  assert.strictEqual(reader.charOffsetOnCurrentPage(32), false, label + ': next-page char rejected');
  assert.strictEqual(reader.charOffsetOnCurrentPage(-1), false, label + ': negative offset rejected');
  assert.strictEqual(reader.charOffsetOnCurrentPage(40), false, label + ': offset past chapter end rejected');

  // 3. getLastVisibleCharOffset(start): off-page start → -1; on-page start → page end.
  reader._charOffsetAtPoint = () => ({ offset: 31, node: nodes[2], index: 11 });
  reader._caretCharCoversPoint = () => true;
  assert.strictEqual(reader.getLastVisibleCharOffset(0), -1,
    label + ': chapter-start fallback value must not become a unit start');
  assert.strictEqual(reader.getLastVisibleCharOffset(15), 32, label + ': on-page start yields the page end');
  // The atEnd clamp must not bypass the on-page check.
  reader.isAtEnd = () => true;
  assert.strictEqual(reader.getLastVisibleCharOffset(0), -1, label + ': atEnd must not clamp an off-page start to total');
  assert.strictEqual(reader.getLastVisibleCharOffset(15), 40, label + ': atEnd clamps an on-page start to total');
  reader.isAtEnd = () => false;

  // 4. caret on an element (illustration <p><img>) → geometric scan, not the
  //    element subtree's first text node + child index.
  document.caretRangeFromPoint = () => ({ startContainer: { nodeType: 1, childNodes: [] }, startOffset: 3 });
  assert.strictEqual(reader.getFirstVisibleCharOffset(), 15,
    label + ': element caret must fall back to the geometric scan');
  document.caretRangeFromPoint = () => null;
  assert.strictEqual(reader.getFirstVisibleCharOffset(), 15, label + ': null caret must fall back to the geometric scan');
}

// 5. fushiProgressDetails assembly: -1 from getLastVisibleCharOffset survives atEnd.
const progressStart = data.engine.indexOf('window.fushiProgressDetails = function()');
const progressEnd = data.engine.indexOf('\n  };', progressStart);
assert.ok(progressStart >= 0 && progressEnd > progressStart, 'production progress assembly missing');
const progressSource = data.engine.slice(progressStart, progressEnd + 5);
const progressWindow = {};
new Function('window', progressSource)(progressWindow);
const progressReader = {
  calculateProgress: () => 0.9,
  paginationMetrics: { totalChars: 100 },
  getFirstVisibleCharOffset: () => 0,
  getLastVisibleCharOffset: () => -1,
  isAtEnd: () => true,
};
progressWindow.fushiReader = progressReader;
assert.strictEqual(progressWindow.fushiProgressDetails(), '100,100,0,-1',
  'atEnd must not clamp an unverified end to total');
progressReader.getLastVisibleCharOffset = () => 90;
assert.strictEqual(progressWindow.fushiProgressDetails(), '100,100,0,100',
  'atEnd clamps a verified end to total');
progressReader.isAtEnd = () => false;
assert.strictEqual(progressWindow.fushiProgressDetails(), '90,100,0,90',
  'non-terminal keeps the probed end');

process.stdout.write('all assertions passed\n');
