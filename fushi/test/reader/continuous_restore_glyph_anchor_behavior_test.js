// BUG-3431 behavior test: the continuous shell's scrollToCharOffset aligns the
// target character's own glyph box, not its collapsed caret.
//
// Regression context (Android tablet, vertical-rl scroll mode, 2026-10-15):
// reopening a book restored charOffset 1551, which starts a column. Chromium
// places a collapsed caret at a soft wrap at the END of the previous column, so
// aligning the caret rect to the content edge showed the previous column
// (1513..1550) at the edge. The next progress sample faithfully reported 1513,
// and every reopen lost one more column (912 → 874 → 837, 1551 → 1513).
//
// The harness instantiates the real continuous shell (extracted from
// reader_pagination_scripts.dart by the Dart driver) with a fake range whose
// caret rect sits at the previous column / line end and whose glyph sits at the
// next column / line start, and asserts the scroll lands on the glyph.
//
// Run: node fushi/test/reader/continuous_restore_glyph_anchor_behavior_test.js <payload.json>
// (driven from continuous_restore_glyph_anchor_behavior_test.dart inside `flutter test`).

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

function instantiate(writingMode, padding) {
  const window = {
    scrollX: 0, scrollY: 0, innerWidth: 411, innerHeight: 900,
    CSS: {}, Highlight: function() {},
  };
  const cs = {
    writingMode, columnWidth: 'auto',
    paddingTop: padding.top + 'px', paddingBottom: '0px',
    paddingLeft: '0px', paddingRight: padding.right + 'px',
    lineHeight: '30px', fontSize: '20px',
    getPropertyValue: () => '',
  };
  const getComputedStyle = () => cs;
  window.getComputedStyle = getComputedStyle;
  const root = { scrollLeft: 0, scrollTop: 0, style: { setProperty() {}, getPropertyValue: () => '' } };
  const document = {
    documentElement: root,
    scrollingElement: root,
    body: { clientWidth: 411, clientHeight: 900 },
    caretRangeFromPoint: () => null,
    fonts: { ready: Promise.resolve() },
  };
  window.scrollBy = () => {};
  const Node = { TEXT_NODE: 3 };
  new Function('window', data.studyUnits)(window);
  const C = { perfTraceEnabled: false };
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'window.fushiReader = ' + objectLiteral(data.continuous) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, {}, window.CSS, window.Highlight, getComputedStyle, Node);
  return { reader, root };
}

// A collapsed range at a soft wrap: the caret rect belongs to the previous
// column / line end, the character itself is laid out at the next one.
function wrapRange(caretRect, glyphRect) {
  const node = { nodeType: 3, textContent: 'はじめの字' };
  return {
    startContainer: node,
    startOffset: 0,
    getBoundingClientRect: () => caretRect,
    cloneRange() {
      return {
        setStart() {}, setEnd() {},
        getClientRects: () => [glyphRect],
      };
    },
  };
}

function rect(left, top, width, height) {
  return { left, top, width, height, right: left + width, bottom: top + height };
}

// Vertical-rl: content edge = innerWidth - padding-right = 403.
{
  const { reader, root } = instantiate('vertical-rl', { top: 0, right: 8 });
  root.scrollLeft = -2000;
  // Caret at the bottom of the column right at the edge (371..403); the glyph
  // heads the next column to its left (339..371).
  reader.collapsedRangeAtCharOffset = () =>
    wrapRange(rect(371, 870, 32, 0), rect(339, 0, 32, 32));
  reader.scrollToCharOffset(1551);
  assert.strictEqual(root.scrollLeft, -2000 + (371 - 403),
    'vertical: the target glyph column must land on the content edge, not the caret column');
}

// Horizontal-tb: content edge = padding-top = 10.
{
  const { reader, root } = instantiate('horizontal-tb', { top: 10, right: 0 });
  root.scrollTop = 500;
  // Caret at the end of the line at 100..130; the glyph starts the next line.
  reader.collapsedRangeAtCharOffset = () =>
    wrapRange(rect(380, 100, 0, 30), rect(10, 136, 20, 30));
  reader.scrollToCharOffset(1551);
  assert.strictEqual(root.scrollTop, 500 + (136 - 10),
    'horizontal: the target glyph line must land on the content edge, not the caret line');
}

// No glyph box (collapsed whitespace only): falls back to the caret rect.
{
  const { reader, root } = instantiate('vertical-rl', { top: 0, right: 8 });
  root.scrollLeft = -2000;
  const node = { nodeType: 3, textContent: '' };
  reader.collapsedRangeAtCharOffset = () => ({
    startContainer: node,
    startOffset: 0,
    getBoundingClientRect: () => rect(300, 0, 32, 0),
    cloneRange() { throw new Error('no glyph to clone'); },
  });
  reader.scrollToCharOffset(1551);
  assert.strictEqual(root.scrollLeft, -2000 + (332 - 403),
    'fallback: a range without a measurable glyph still aligns its caret rect');
}

console.log('all assertions passed');
