// BUG-2744 behavior test: a programmatic reveal replaces the restore anchor that
// late lazy-image loads re-apply.
//
// Regression context (Windows, horizontal light novel, 2026-09-27): "at the
// illustrations the audiobook playback misbehaves — the picture flashes and is
// skipped". Every restore landing (restoreToCharOffset / restoreProgress /
// jumpToFragment) registers an image late-load anchor, and every block image
// that finishes loading afterwards calls reapplyImageLateAnchor(). Only a user
// page turn (paginate) retired that anchor. Audiobook follow-along moves the
// page through scrollToRange (paged) / scrollToTarget (continuous), and the
// image-pause reveal scrolls to the illustration the same way — none of them
// retired it. So once the follow had turned a few pages, the lazy illustration
// ahead finished loading and the viewport jumped back to the page the chapter
// was opened on (headless Chrome probe: pos 15584 -> 13636, two pages back);
// with image pause on, the reveal showed the picture for a frame and its load
// yanked the page back, leaving the pause on the wrong page.
//
// This harness instantiates the real paged and continuous shell objects
// (extracted from reader_pagination_scripts.dart via the Dart driver) with fake
// live Ranges / elements whose geometry the test moves the way a late image
// load does, and asserts:
//   A. after a reveal, a late image load re-aligns to the revealed target and
//      never re-applies the stale restore anchor (both shells);
//   B. paged image-pause reveal: the 0-size placeholder still sat on the current
//      page (no turn), the loaded image moved to the next page — the re-apply
//      follows the image there;
//   C. a later restore registration wins again, and clearing leaves no anchor.
//
// Run: node fushi/test/reader/reader_follow_reveal_late_image_anchor_behavior_test.js <payload.json>
// (driven from reader_follow_reveal_late_image_anchor_behavior_test.dart inside `flutter test`).

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

const PAGE = 1000;
const VIEWPORT_H = 800;

// Geometry lives in document coordinates; client rects are derived from the
// current scroll, like the real engine sees them.
function rectAt(state, geom) {
  if (state.vertical) {
    const top = geom.doc - state.scroll;
    return { left: 100, right: 110, top, bottom: top + geom.size, width: 10, height: geom.size };
  }
  const left = geom.doc - state.scroll;
  return { left, right: left + geom.size, top: 100, bottom: 120, width: geom.size, height: 20 };
}

// A live Range: clones share the geometry record, the way a real Range's
// boundary points follow the DOM when the lazy <img> gets wrapped on load.
function fakeRange(state, geom) {
  return {
    getClientRects() { return [rectAt(state, geom)]; },
    getBoundingClientRect() { return rectAt(state, geom); },
    cloneRange() { return fakeRange(state, geom); },
  };
}

function fakeElement(state, geom) {
  return {
    getClientRects() { return [rectAt(state, geom)]; },
    getBoundingClientRect() { return rectAt(state, geom); },
  };
}

function instantiate(shellSource, { continuous }) {
  const state = { scroll: 3000, vertical: continuous };
  const calls = { charScroll: [], setPage: [], scrollBy: [] };
  const style = {
    writingMode: 'horizontal-tb',
    getPropertyValue() { return ''; },
  };
  const getComputedStyle = () => style;
  const window = {
    innerWidth: 1000, innerHeight: VIEWPORT_H, CSS: {}, Highlight: function() {},
    getComputedStyle,
    scrollBy(opts) {
      calls.scrollBy.push(opts);
      state.scroll += opts.top || 0;
    },
  };
  const document = {
    documentElement: { style: {}, clientHeight: VIEWPORT_H, clientWidth: 1000 },
    scrollingElement: null,
    body: { clientWidth: 1000, clientHeight: VIEWPORT_H },
    caretRangeFromPoint: () => null,
  };
  const Node = { TEXT_NODE: 3 };
  const requestAnimationFrame = (fn) => fn();
  new Function('window', data.studyUnits)(window);
  const C = { perfTraceEnabled: false };
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'requestAnimationFrame',
    'window.fushiReader = ' + objectLiteral(shellSource) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, {}, window.CSS, window.Highlight,
    getComputedStyle, Node, requestAnimationFrame);

  // The restore anchor must never be re-applied after a reveal; record it.
  reader.scrollToCharOffset = function() { calls.charScroll.push(Array.from(arguments)); };
  if (!continuous) {
    reader.getScrollContext = () => ({
      vertical: false, pageSize: PAGE, contentStart: 0, columnGap: 0,
      physicalMaxScroll: 1e9,
    });
    reader.getPagePosition = () => state.scroll;
    reader.setPagePosition = (context, position) => {
      calls.setPage.push(position);
      state.scroll = position;
      return position;
    };
  }
  return { reader, calls, state };
}

// ── Paged shell ──────────────────────────────────────────────────────────
{
  // A. follow-along turned pages, then an illustration ahead finished loading.
  const { reader, calls, state } = instantiate(data.paged, { continuous: false });
  reader.registerImageLateAnchor({ charOffset: 5700 }); // restore landing (page 3)
  const cue = { doc: 5200, size: 40 };
  assert.strictEqual(reader.scrollToRange(fakeRange(state, cue)), true,
    'paged: the follow reveal must turn to the cue page');
  assert.strictEqual(state.scroll, 5000, 'paged: follow lands on the cue page');
  // The load callback: metrics invalidated, then the late anchor re-applied.
  assert.strictEqual(reader.reapplyImageLateAnchor(), true,
    'paged: the revealed target is the live anchor');
  assert.strictEqual(calls.charScroll.length, 0,
    'paged: a late image load after a follow reveal must not re-apply the stale restore anchor ' +
    '(it yanks the viewport back to the page the chapter was opened on)');
  assert.strictEqual(state.scroll, 5000, 'paged: the viewport stays on the cue page');

  // The illustration was before the cue and pushed it one page on: follow it.
  cue.doc = 6200;
  reader.reapplyImageLateAnchor();
  assert.strictEqual(state.scroll, 6000,
    'paged: when the late image moves the revealed cue, re-align to the cue');
  assert.strictEqual(calls.charScroll.length, 0);
}

{
  // B. image-pause reveal of a not-yet-loaded illustration.
  const { reader, calls, state } = instantiate(data.paged, { continuous: false });
  reader.registerImageLateAnchor({ charOffset: 5700 });
  state.scroll = 5000;
  const img = { doc: 5900, size: 0 }; // 0-size lazy placeholder, still on this page
  assert.strictEqual(reader.scrollToRange(fakeRange(state, img)), false,
    'paged: the placeholder is on the current page — no turn yet');
  // Loaded: break-inside:avoid pushes the page-high image to the next column.
  img.doc = 6000;
  img.size = 700;
  reader.reapplyImageLateAnchor();
  assert.strictEqual(state.scroll, 6000,
    'paged: after the image loads the pause must show the image page');
  assert.strictEqual(calls.charScroll.length, 0,
    'paged: the image-pause reveal must not fall back to the restore anchor');
}

{
  // C. a new restore wins again; clearing leaves nothing to re-apply.
  const { reader, calls, state } = instantiate(data.paged, { continuous: false });
  reader.scrollToRange(fakeRange(state, { doc: 5200, size: 40 }));
  reader.registerImageLateAnchor({ charOffset: 800 });
  reader.reapplyImageLateAnchor();
  assert.deepStrictEqual(calls.charScroll, [[800]],
    'paged: a later restore registration replaces the reveal target');
  reader.clearImageLateAnchor();
  const before = calls.setPage.length;
  assert.strictEqual(reader.reapplyImageLateAnchor(), false,
    'paged: a cleared anchor re-applies nothing');
  assert.strictEqual(calls.setPage.length, before);
}

// ── Continuous shell ─────────────────────────────────────────────────────
{
  // A. follow-along scrolled on, then an illustration above the cue loaded.
  const { reader, calls, state } = instantiate(data.continuous, { continuous: true });
  reader.registerImageLateAnchor({ charOffset: 5700, endCharOffset: -1 });
  const cue = { doc: 4500, size: 30 };
  assert.strictEqual(reader.scrollToTarget(fakeElement(state, cue)), true,
    'continuous: the follow reveal must scroll to the cue');
  const followed = state.scroll;
  assert.strictEqual(reader.reapplyImageLateAnchor(), true,
    'continuous: the revealed target is the live anchor');
  assert.strictEqual(calls.charScroll.length, 0,
    'continuous: a late image load after a follow reveal must not re-apply the stale restore anchor');
  assert.strictEqual(state.scroll, followed,
    'continuous: an in-band cue stays put');

  cue.doc += 700; // the loaded illustration pushed the cue down
  reader.reapplyImageLateAnchor();
  const rect = rectAt(state, cue);
  assert.ok(rect.top >= VIEWPORT_H * 0.15 && rect.bottom <= VIEWPORT_H * 0.85,
    'continuous: re-apply brings the moved cue back into the follow band, got top=' + rect.top);
  assert.strictEqual(calls.charScroll.length, 0);
}

{
  // C. a new restore wins again on the continuous shell too.
  const { reader, calls, state } = instantiate(data.continuous, { continuous: true });
  reader.scrollToTarget(fakeElement(state, { doc: 4500, size: 30 }));
  reader.registerImageLateAnchor({ charOffset: 800, endCharOffset: -1 });
  reader.reapplyImageLateAnchor();
  assert.deepStrictEqual(calls.charScroll, [[800, -1]],
    'continuous: a later restore registration replaces the reveal target');
}

console.log('all assertions passed');
