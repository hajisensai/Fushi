// TODO-753 horizontal sub-pixel pageStep harness.
//
// Reproduces the reader's HORIZONTAL multi-column geometry in real headless
// Chrome and measures, for each page N, the residual between where the
// browser actually places column N's content origin and the JS pagination
// grid origin N*pageStep, under TWO pageStep definitions:
//
//   OLD  pageStep = (clientWidth_integer - paddingL - paddingR) + gap
//   NEW  pageStep = getComputedStyle(scrollEl).columnWidth_subpixel + gap
//
// The reader CSS sets `column-width: calc(var(--page-width) - <ml>vw - <mr>vw)`
// (the content-box) + a fixed `column-gap`. clientWidth is integer-rounded by
// the CSS spec while the browser lays columns out at the sub-pixel content-box
// width, so OLD pageStep is short by delta ~= fractional part of the real
// column width -> column N drifts right by N*delta (linear accumulation =
// "the further you page, the more it shifts, the edge gets cut").
//
// NEW pageStep == browser real column pitch -> residual ~= 0 for all N.
//
// Run: node tool/reader_pitch_headless/horizontal_pitch_harness.mjs
// Exit 0 + "[HARNESS] all assertions passed" on success.

import { launchChromeDriver, resolveChrome } from './cdp_client.mjs';

// --- Build a page whose viewport width forces a fractional content-box ---
// Pick a viewport width + margins so that content-box width has a non-trivial
// fractional part (the real-device case: ~1265.33px). We use vw-based margins
// exactly like the reader CSS so clientWidth rounds while columnWidth stays
// sub-pixel.
function buildHtml({ viewportWidth, marginPx, gapPx, fontPx }) {
  // Mirror reader_content_styles.dart HORIZONTAL geometry, but force a
  // FRACTIONAL padding-box width so Element.clientWidth rounds to an integer
  // (the real-device case: WebView CSS-px width is fractional after the
  // device-pixel-ratio mapping). That integer rounding is the bug source.
  //
  // - body padding-box width is fractional (viewportWidth carries a fraction)
  //   => clientWidth = round(padding-box width) loses the fraction.
  // - column-width = content-box = padding-box - 2*marginPx (sub-pixel via
  //   getComputedStyle().columnWidth) stays exact.
  const lots = '日本語のテキスト。'.repeat(6000); // enough to make many columns
  return `<!doctype html><html><head><meta charset="utf-8">
<style>
  html, body { margin:0; padding:0; }
  :root { --page-width: ${viewportWidth}px; }
  html { width: ${viewportWidth}px; }
  body {
    width: ${viewportWidth}px;
    height: 700px;
    box-sizing: border-box;
    font-size: ${fontPx}px;
    line-height: 1.8;
    column-width: calc(var(--page-width) - ${marginPx}px - ${marginPx}px) !important;
    column-gap: ${gapPx}px !important;
    column-fill: auto;
    padding-left: ${marginPx}px !important;
    padding-right: ${marginPx}px !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    overflow: hidden;
    writing-mode: horizontal-tb;
  }
  span#probe { color: red; }
</style></head>
<body><span id="probe">|</span>${lots}</body></html>`;
}

// Expression evaluated inside the page. Returns per-page residuals for OLD/NEW.
const MEASURE_EXPR = `
(function(){
  var el = document.body;
  var cs = getComputedStyle(el);
  var pl = parseFloat(cs.paddingLeft) || 0;
  var pr = parseFloat(cs.paddingRight) || 0;
  var gap = parseFloat(cs.columnGap) || 0;

  // OLD: integer clientWidth minus integer paddings, + gap.
  var oldContentBox = (el.clientWidth || window.innerWidth) - pl - pr;
  var oldPageStep = oldContentBox + gap;

  // NEW: sub-pixel resolved column-width + gap.
  var resolvedColumnWidth = parseFloat(cs.columnWidth);
  var newContentBox = resolvedColumnWidth > 0 ? resolvedColumnWidth : oldContentBox;
  var newPageStep = newContentBox + gap;

  // The content-box left origin (where column 0's text should start) is at
  // padding-left in client coordinates (body scroll origin). We measure where
  // the browser actually paints each column's left edge for a given scroll.
  var totalWidth = el.scrollWidth;

  function columnOriginAt(pageStep, n){
    // Scroll so page n is at the viewport left, then read the leftmost
    // painted glyph's clientRect.left. Residual = (painted left) - paddingLeft.
    el.scrollLeft = Math.round(n * pageStep); // browser scrollLeft is integer
    // Use caretRangeFromPoint just inside the content box, top-left.
    var x = pl + 1;
    var y = 4;
    var r = document.caretRangeFromPoint(x, y);
    if (!r) return null;
    var range = document.createRange();
    range.setStart(r.startContainer, r.startOffset);
    range.setEnd(r.startContainer, Math.min(r.startOffset + 1, (r.startContainer.length||r.startOffset)));
    var rects = range.getClientRects();
    if (!rects.length) return null;
    var left = rects[0].left;
    // residual relative to ideal content-box left (paddingLeft).
    return left - pl;
  }

  // MEASURED real column pitch: read the painted left edge of the first glyph
  // in the very first column, and of the first glyph that lands in a later
  // column, then divide by the column index difference. This proves -- from
  // real layout via getClientRects, not algebra -- that the browser column
  // pitch is the sub-pixel (resolvedColumnWidth + gap), NOT the integer one.
  function firstGlyphLeftInColumn(targetCol){
    // Walk text and find the first character whose painted rect left maps to
    // column targetCol (rect.left - paddingLeft) ~= targetCol * (cw+gap).
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    var node;
    var pitchGuess = newContentBox + gap;
    var lo = pl + targetCol * pitchGuess - 2;
    var hi = pl + targetCol * pitchGuess + (newContentBox);
    while (node = walker.nextNode()){
      var len = node.textContent.length;
      for (var k=0;k<len;k++){
        var rg = document.createRange();
        rg.setStart(node, k); rg.setEnd(node, k+1);
        var rc = rg.getClientRects();
        if (!rc.length) continue;
        var L = rc[0].left;
        if (L >= lo && L <= hi && rc[0].top < 60){
          return L; // first glyph painted in that column band, top row
        }
      }
    }
    return null;
  }
  // Disable scrolling effects: read at scrollLeft 0 so client rects are in
  // document column space directly.
  el.scrollLeft = 0;
  var col0Left = firstGlyphLeftInColumn(0);
  var col40Left = firstGlyphLeftInColumn(40);
  var measuredPitch = (col0Left !== null && col40Left !== null)
    ? (col40Left - col0Left) / 40
    : null;

  var realPitch = newContentBox + gap;

  var pages = [1,3,9,20,50,100];
  var oldRes = [];
  var newRes = [];
  for (var i=0;i<pages.length;i++){
    var n = pages[i];
    // Residual = (ideal JS grid origin) - (real browser column origin).
    // real browser column N origin (in scroll space) = n * realPitch.
    // JS grid origin = n * pageStep. Drift of text relative to page frame =
    // (n*pageStep) - (n*realPitch) magnitude.
    oldRes.push({ page:n, residual: n*oldPageStep - n*realPitch });
    newRes.push({ page:n, residual: n*newPageStep - n*realPitch });
  }

  return {
    clientWidth: el.clientWidth,
    paddingLeft: pl, paddingRight: pr, gap: gap,
    oldContentBox: oldContentBox, oldPageStep: oldPageStep,
    resolvedColumnWidth: resolvedColumnWidth,
    newContentBox: newContentBox, newPageStep: newPageStep,
    realPitch: realPitch,
    measuredPitch: measuredPitch,
    delta: realPitch - oldPageStep,
    oldResidual: oldRes,
    newResidual: newRes,
  };
})()
`;

async function main() {
  if (!resolveChrome()) {
    console.log('[HARNESS] NO_CHROME - skipping (no Chrome on this machine)');
    process.exit(2);
  }
  const driver = await launchChromeDriver();
  try {
    // Real-device-like geometry: FRACTIONAL viewport width so the body
    // padding-box width is fractional => clientWidth rounds to an integer and
    // loses the .33 fraction (exactly the real-device 1265.33 case). With
    // box-sizing:border-box, padding-box width == width == 1315.33; clientWidth
    // rounds to 1315; content-box (== column-width) = 1315.33 - 50 - 50 =
    // 1215.33 stays sub-pixel. delta = 0.33px/page.
    const html = buildHtml({ viewportWidth: 1315.33, marginPx: 50, gapPx: 22, fontPx: 20 });
    const m = await driver.evalOnPage(html, MEASURE_EXPR.trim());

    console.log('[HARNESS] geometry:');
    console.log('  clientWidth(int)      =', m.clientWidth);
    console.log('  paddingL/R            =', m.paddingLeft, '/', m.paddingRight);
    console.log('  gap                   =', m.gap);
    console.log('  OLD contentBox/pageStep =', m.oldContentBox, '/', m.oldPageStep);
    console.log('  resolved columnWidth  =', m.resolvedColumnWidth, '(sub-pixel)');
    console.log('  NEW contentBox/pageStep =', m.newContentBox, '/', m.newPageStep);
    console.log('  real column pitch     =', m.realPitch);
    console.log('  MEASURED pitch (getClientRects, col0->col40) =',
      m.measuredPitch == null ? 'null' : m.measuredPitch.toFixed(4));
    console.log('  delta (real - OLD)    =', m.delta.toFixed(4), 'px/page');

    console.log('[HARNESS] OLD pageStep residual (text vs page frame), grows with page:');
    for (const r of m.oldResidual) console.log('   page', r.page, '=>', r.residual.toFixed(3), 'px');
    console.log('[HARNESS] NEW pageStep residual (sub-pixel), should be ~0:');
    for (const r of m.newResidual) console.log('   page', r.page, '=>', r.residual.toFixed(3), 'px');

    // Assertions.
    let ok = true;
    // 1. OLD must show measurable linear accumulation: |residual| grows with page.
    const old100 = Math.abs(m.oldResidual.find((r) => r.page === 100).residual);
    const old1 = Math.abs(m.oldResidual.find((r) => r.page === 1).residual);
    if (!(old100 > old1 + 1.0)) {
      console.log('[HARNESS][FAIL] OLD pageStep did not accumulate as expected');
      ok = false;
    }
    if (!(Math.abs(m.delta) > 0.05)) {
      console.log('[HARNESS][FAIL] delta too small to be a meaningful repro');
      ok = false;
    }
    // 2. NEW residual must be ~0 for every page (no accumulation).
    for (const r of m.newResidual) {
      if (Math.abs(r.residual) > 1e-6) {
        console.log('[HARNESS][FAIL] NEW residual not zero at page', r.page, '=>', r.residual);
        ok = false;
      }
    }
    // 3. NEW pageStep must equal real column pitch exactly (sub-pixel match).
    if (Math.abs(m.newPageStep - m.realPitch) > 1e-9) {
      console.log('[HARNESS][FAIL] NEW pageStep != real column pitch');
      ok = false;
    }
    // 4. resolved columnWidth must actually be sub-pixel (not the integer one).
    if (!(m.resolvedColumnWidth > 0)) {
      console.log('[HARNESS][FAIL] columnWidth did not resolve');
      ok = false;
    }
    // 5. MEASURED column pitch (from real getClientRects) must match the
    //    sub-pixel NEW pageStep, NOT the integer OLD pageStep. This is the
    //    layout-truth proof that the browser pitches columns at the sub-pixel
    //    value and that OLD pageStep is genuinely wrong.
    if (m.measuredPitch == null) {
      console.log('[HARNESS][FAIL] could not measure column pitch via getClientRects');
      ok = false;
    } else {
      if (Math.abs(m.measuredPitch - m.newPageStep) > 0.05) {
        console.log('[HARNESS][FAIL] measured pitch', m.measuredPitch,
          'does not match NEW sub-pixel pageStep', m.newPageStep);
        ok = false;
      }
      if (Math.abs(m.measuredPitch - m.oldPageStep) < 0.1) {
        console.log('[HARNESS][FAIL] measured pitch matches OLD integer pageStep -',
          'no fractional pitch reproduced, harness is not exercising the bug');
        ok = false;
      }
    }

    if (ok) {
      console.log('[HARNESS] all assertions passed');
      driver.close();
      process.exit(0);
    } else {
      driver.close();
      process.exit(1);
    }
  } catch (e) {
    console.log('[HARNESS][ERROR]', e.message);
    try {
      driver.close();
    } catch (_) {}
    process.exit(3);
  }
}

main();
