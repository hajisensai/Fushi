// BUG-2652 behavior test: a re-anchor that runs right after a restore must not
// sample the viewport.
//
// Regression context (iOS, 2026-09-25): opening a book in paged mode and
// switching to scroll mode from the in-book settings reloads the chapter in the
// SAME WKWebView. The continuous restore writes the right scroll (e.g. -1047 for
// charOffset 663), but for the next few frames WebKit's native side makes
// scrollX / scrollY read back as 0 (probe on the iOS simulator: -1047 written at
// t=3ms, 0 read at +16ms with no JS write in between, -1047 again in the
// scrolling tree at ~40ms). Two re-anchors ran inside that window and sampled
// getFirstVisibleCharOffset() == chapter start, then scrollToChapterStart() —
// the reader landed on the chapter start every time (8/8 switches), while a
// fresh open (new WebView) never shows the transient:
//   1. setChromeInsets() re-sent the insets that were already baked into the
//      engine config — no reflow to compensate, yet it sampled and re-anchored;
//   2. the TODO-718 restore re-anchor (beginUiScaleReanchor) sampled the
//      viewport instead of using the restore's own anchor.
//
// This harness instantiates the real paged and continuous shell objects
// (extracted from reader_pagination_scripts.dart via the Dart driver) with a
// viewport sampler that always answers "chapter start", and asserts:
//   A. setChromeInsets with unchanged insets + image box neither samples nor
//      re-anchors (both shells), and leaves the paged metrics cache alone;
//   B. setChromeInsets with a real inset change still samples and re-anchors;
//   C. beginRestoreReanchor takes the registered char anchor (and the sentence
//      end) without sampling, and commitUiScaleReanchor scrolls to it;
//   D. without a precise char anchor (progress restore) it falls back to the
//      sampling begin, and the UI-scale path still passes no sentence end.
//
// Run: node fushi/test/reader/restore_reanchor_transient_viewport_behavior_test.js <payload.json>
// (driven from restore_reanchor_transient_viewport_behavior_test.dart inside `flutter test`).

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

const IMAGE_BOX = { w: 300, h: 700 };

function instantiate(shellSource) {
  const vars = new Map();
  const rootStyle = {
    setProperty(k, v) { vars.set(k, String(v)); },
    getPropertyValue(k) { return vars.has(k) ? vars.get(k) : ''; },
  };
  const window = {
    scrollX: -1047, scrollY: 0, innerWidth: 402, innerHeight: 874,
    CSS: {}, Highlight: function() {},
  };
  const cs = {
    writingMode: 'vertical-rl', columnWidth: 'auto',
    paddingTop: '0px', paddingBottom: '0px', paddingLeft: '0px', paddingRight: '0px',
  };
  const getComputedStyle = () => cs;
  window.getComputedStyle = getComputedStyle;
  const document = {
    documentElement: { style: rootStyle, clientHeight: 874, clientWidth: 402 },
    scrollingElement: null,
    body: { clientWidth: 402, clientHeight: 874 },
    caretRangeFromPoint: () => null,
  };
  const Node = { TEXT_NODE: 3 };
  new Function('window', data.studyUnits)(window);
  const C = { perfTraceEnabled: false };
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'window.fushiReader = ' + objectLiteral(shellSource) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, {}, window.CSS, window.Highlight, getComputedStyle, Node);

  const calls = { sample: 0, scrollTo: [] };
  // The unsettled viewport: every sample answers "chapter start".
  reader.getFirstVisibleCharOffset = () => { calls.sample++; return 0; };
  reader.scrollToCharOffset = function() { calls.scrollTo.push(Array.from(arguments)); };
  reader._reanchorFrame = (fn) => fn();
  reader._imageMaxBox = () => IMAGE_BOX;
  // Paged-only geometry used for the hint; harmless on the continuous shell.
  reader.getScrollContext = () => ({ vertical: true, pageSize: 874 });
  reader.getPagePosition = () => 874;

  // What initialize() leaves behind: the insets and image box of this layout.
  rootStyle.setProperty('--chrome-top-inset', '62px');
  rootStyle.setProperty('--chrome-bottom-inset', '34px');
  rootStyle.setProperty('--fushi-image-max-width', IMAGE_BOX.w + 'px');
  rootStyle.setProperty('--fushi-image-max-height', IMAGE_BOX.h + 'px');
  return { reader, calls, rootStyle };
}

for (const [label, source] of [['paged', data.paged], ['continuous', data.continuous]]) {
  // A. unchanged insets → no sample, no re-anchor, metrics cache untouched.
  {
    const { reader, calls } = instantiate(source);
    const metrics = { sentinel: true };
    reader.paginationMetrics = metrics;
    reader.setChromeInsets(62, 34);
    assert.strictEqual(calls.sample, 0,
      label + ': unchanged insets must not sample the (possibly unsettled) viewport');
    assert.strictEqual(calls.scrollTo.length, 0,
      label + ': unchanged insets must not re-anchor (scrollToCharOffset(0) = chapter start)');
    assert.notStrictEqual(reader._reanchorPending, true,
      label + ': unchanged insets must not raise the re-anchor flag');
    assert.strictEqual(reader.paginationMetrics, metrics,
      label + ': unchanged insets must keep the pagination metrics cache');
  }

  // A'. same insets but a stale image box is still a layout change.
  {
    const { reader, calls, rootStyle } = instantiate(source);
    rootStyle.setProperty('--fushi-image-max-height', '640px');
    reader.setChromeInsets(62, 34);
    assert.strictEqual(calls.sample, 1,
      label + ': a changed image box reflows, so the re-anchor must still sample');
    assert.strictEqual(rootStyle.getPropertyValue('--fushi-image-max-height'), IMAGE_BOX.h + 'px',
      label + ': the image box must be re-derived');
  }

  // B. a real inset change keeps the existing re-anchor behaviour.
  {
    const { reader, calls, rootStyle } = instantiate(source);
    reader.setChromeInsets(62, 90);
    assert.strictEqual(calls.sample, 1, label + ': a changed inset must sample the anchor');
    assert.strictEqual(calls.scrollTo.length, 1, label + ': a changed inset must re-anchor');
    assert.strictEqual(rootStyle.getPropertyValue('--chrome-bottom-inset'), '90px',
      label + ': the new inset must be applied');
    assert.notStrictEqual(reader._reanchorPending, true,
      label + ': the re-anchor frame must clear the flag');
  }
}

// C. restore re-anchor takes the restore's own anchor.
{
  const { reader, calls } = instantiate(data.continuous);
  reader.registerImageLateAnchor({ charOffset: 663, endCharOffset: -1 });
  assert.strictEqual(reader.beginRestoreReanchor(), 663,
    'restore re-anchor must return the restore char anchor');
  assert.strictEqual(calls.sample, 0,
    'restore re-anchor must not sample the unsettled viewport');
  assert.strictEqual(reader._reanchorPending, true,
    'restore re-anchor must hold the flag until commit');
  assert.strictEqual(reader.commitUiScaleReanchor(), true, 'commit must run');
  assert.deepStrictEqual(calls.scrollTo[0].slice(0, 2), [663, -1],
    'commit must scroll back to the restore anchor');
  assert.notStrictEqual(reader._reanchorPending, true, 'commit must clear the flag');

  // Favourite-sentence restore keeps its sentence end (BUG-461 whole-sentence alignment).
  reader.registerImageLateAnchor({ charOffset: 100, endCharOffset: 140 });
  assert.strictEqual(reader.beginRestoreReanchor(), 100);
  reader.commitUiScaleReanchor();
  assert.deepStrictEqual(calls.scrollTo[1].slice(0, 2), [100, 140],
    'commit must carry the restore sentence end');

  // An in-flight re-anchor keeps ownership.
  reader._reanchorPending = true;
  reader.registerImageLateAnchor({ charOffset: 200 });
  assert.strictEqual(reader.beginRestoreReanchor(), -1,
    'an in-flight re-anchor must keep ownership');
  reader._reanchorPending = false;
}

// D. no precise anchor → sampling fallback; UI-scale path passes no sentence end.
{
  const { reader, calls } = instantiate(data.continuous);
  reader.registerImageLateAnchor({ progress: 0.4 });
  assert.strictEqual(reader.beginRestoreReanchor(), 0,
    'a progress restore falls back to the sampling begin');
  assert.strictEqual(calls.sample, 1, 'the fallback samples once');
  reader.commitUiScaleReanchor();

  reader.clearImageLateAnchor();
  reader.beginUiScaleReanchor();
  reader.commitUiScaleReanchor();
  assert.strictEqual(calls.scrollTo[calls.scrollTo.length - 1][1], undefined,
    'the UI-scale re-anchor must not inherit a sentence end');
}

console.log('all assertions passed');
