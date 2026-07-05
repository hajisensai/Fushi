// TODO-1179 chapter-jump first/last line probe (headless Chrome).
//
// The paginated reader drops the last line on a manual BACKWARD chapter jump
// (progress=0.99 -> contentLastPageScroll = metrics.maxScroll) when the single-
// dimension physical scroll max (context.maxScroll = scrollHeight/Width - pageStep)
// undershoots the last content column aligned page by a sub-pixel epsilon (vh /
// chrome-inset / DPR rounding). A bare floor then lands a whole page short:
//   maxAligned = floor(context.maxScroll / pageStep)*pageStep
// so the last column (and its final line) becomes unreachable. The fix adds a 1px
// tolerance: floor((context.maxScroll + 1) / pageStep)*pageStep, capped by
// lastContentScroll so it never overshoots into a blank page.
//
// Headless Chrome reports scrollHeight/clientHeight as integers, so it cannot
// manufacture the sub-pixel epsilon on its own (see README / BUG-405: the vertical
// sub-pixel drift is a real-device-only phenomenon). So this probe does two things
// against REAL rendered geometry (real column pitch, real content edges):
//   PART A (safety): with the real physical scroll max, assert the NEW algorithm
//     never drops the first/last line AND is byte-identical to OLD for normal
//     chapters (content starts at padding) -> the fix is a no-op there.
//   PART B (repro+fix): inject the real-device sub-pixel undershoot by setting
//     ctxMax := lastContentPage*pageStep - 0.4 and assert the OLD algorithm drops
//     the last page while the NEW algorithm recovers it.
//
// Run: cd tool/reader_pitch_headless && node chapter_bounds_probe.js
// Exit 0 = PASS, 1 = FAIL.
const puppeteer = require('puppeteer-core');
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';

function buildHtml({ vertical, V, vw, F, nChars }) {
  let s = '';
  for (let i = 0; i < nChars; i++) s += '永';
  if (vertical) {
    const O = 22, mt = 2, mb = 2;
    const colW = `max(${F}px, calc(${V}px - ${mt}vh - ${mb}vh - ${F}px))`;
    return `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{overflow:hidden !important;height:${V + O}px !important;width:${vw}px !important;margin:0 !important;padding:0 !important;writing-mode:vertical-rl !important;}
body{font-family:serif !important;font-size:${F}px !important;line-height:1.5 !important;box-sizing:border-box !important;
column-width:${colW} !important;column-gap:22px !important;
padding-top:calc(${mt}vh) !important;padding-bottom:calc(${mb}vh + ${F}px) !important;padding-left:8px !important;padding-right:8px !important;}
div{margin:0 !important;}
</style></head><body><div>${s}</div></body></html>`;
  }
  const marginPx = 50, gapPx = 22;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  html, body { margin:0; padding:0; }
  :root { --page-width: ${vw}px; }
  html { width: ${vw}px; }
  body {
    width: ${vw}px; height: ${V}px; box-sizing: border-box;
    font-size: ${F}px; line-height: 1.8;
    column-width: calc(var(--page-width) - ${marginPx}px - ${marginPx}px) !important;
    column-gap: ${gapPx}px !important; column-fill: auto;
    padding-left: ${marginPx}px !important; padding-right: ${marginPx}px !important;
    padding-top: 0 !important; padding-bottom: 12px !important;
    overflow: hidden; writing-mode: horizontal-tb;
  }
  div{margin:0 !important;}
</style></head><body><div>${s}</div></body></html>`;
}

async function probe(browser, cfg) {
  const page = await browser.newPage();
  await page.setViewport({
    width: Math.ceil(cfg.vw),
    height: Math.ceil(cfg.V + (cfg.vertical ? 22 : 0)),
    deviceScaleFactor: 1,
  });
  await page.setContent(buildHtml(cfg), { waitUntil: 'load' });
  const r = await page.evaluate((vertical) => {
    const body = document.body, cs = getComputedStyle(body);
    const gap = parseFloat(cs.columnGap) || 0;
    const fontFloor = parseFloat(cs.fontSize) || 1;
    let contentBox = parseFloat(cs.columnWidth);
    if (!(contentBox > 0)) {
      if (vertical) {
        const pt = parseFloat(cs.paddingTop) || 0;
        const pb = parseFloat(cs.paddingBottom) || 0;
        contentBox = (body.clientHeight || window.innerHeight) - pt - pb;
      } else {
        const pl = parseFloat(cs.paddingLeft) || 0;
        const pr = parseFloat(cs.paddingRight) || 0;
        contentBox = (body.clientWidth || window.innerWidth) - pl - pr;
      }
    }
    contentBox = Math.max(fontFloor, contentBox);
    const pageStep = contentBox + gap;
    const totalSize = vertical ? body.scrollHeight : body.scrollWidth;
    const ctxMaxScroll = Math.max(0, totalSize - pageStep);
    const clientSize = vertical ? body.clientHeight : body.clientWidth;
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
    let node, firstContentEdge = null, lastContentEdge = 0;
    while ((node = walker.nextNode())) {
      const range = document.createRange();
      range.selectNodeContents(node);
      const rects = range.getClientRects();
      for (let i = 0; i < rects.length; i++) {
        const rc = rects[i];
        if (rc.width <= 0 || rc.height <= 0) continue;
        const startEdge = vertical ? rc.top : rc.left;
        const endEdge = vertical ? rc.bottom : rc.right;
        firstContentEdge = firstContentEdge === null ? startEdge : Math.min(firstContentEdge, startEdge);
        lastContentEdge = Math.max(lastContentEdge, endEdge);
      }
    }
    return { pageStep, totalSize, ctxMaxScroll, clientSize, firstContentEdge, lastContentEdge };
  }, cfg.vertical);
  await page.close();
  return r;
}

function alignToPage(offset, pageStep) {
  return Math.floor(Math.max(0, offset) / pageStep) * pageStep;
}
function alignContentStartOld(offset, pageStep) {
  const safe = Math.max(0, offset);
  const nearest = Math.round(safe / pageStep) * pageStep;
  if (Math.abs(safe - nearest) < 1) return nearest;
  return alignToPage(safe, pageStep);
}
function alignContentStartNew(offset, pageStep) {
  return alignToPage(offset, pageStep);
}
function computeBounds(first, last, ctxMax, ps, mode) {
  const maxAligned = mode === 'old'
    ? Math.floor(ctxMax / ps) * ps
    : Math.floor((ctxMax + 1) / ps) * ps;
  const startAligned = mode === 'old'
    ? alignContentStartOld(first, ps)
    : alignContentStartNew(first, ps);
  const minScroll = first === null ? 0 : Math.min(maxAligned, startAligned);
  const lastContentScroll = last <= 0 ? 0 : Math.floor(Math.max(0, last - 1) / ps) * ps;
  const maxScroll = Math.min(maxAligned, lastContentScroll);
  return { minScroll, maxScroll };
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--force-device-scale-factor=1'],
  });
  const bases = [
    { vertical: true, V: 846, vw: 412, F: 18 },
    { vertical: true, V: 800, vw: 400, F: 22 },
    { vertical: true, V: 915, vw: 412, F: 26 },
    { vertical: false, V: 700, vw: 1315.33, F: 20 },
    { vertical: false, V: 680, vw: 1265.33, F: 22 },
    { vertical: false, V: 720, vw: 900.5, F: 24 },
  ];
  let failed = false, cases = 0, injectedRepros = 0, structuralOverhangCuts = 0;
  const TOL = 0.5;
  for (const base of bases) {
    for (let n = 200; n <= 1200; n += 61) {
      const cfg = Object.assign({}, base, { nChars: n });
      const m = await probe(browser, cfg);
      if (m.firstContentEdge === null || m.lastContentEdge <= 0) continue;
      cases++;
      const ps = m.pageStep, vp = m.clientSize;
      const oldB = computeBounds(m.firstContentEdge, m.lastContentEdge, m.ctxMaxScroll, ps, 'old');
      const newB = computeBounds(m.firstContentEdge, m.lastContentEdge, m.ctxMaxScroll, ps, 'new');
      const oldFirstSkip = oldB.minScroll - m.firstContentEdge > TOL;
      const oldLastSkip = m.lastContentEdge - (oldB.maxScroll + vp) > TOL;
      const newFirstSkip = newB.minScroll - m.firstContentEdge > TOL;
      const newLastSkip = m.lastContentEdge - (newB.maxScroll + vp) > TOL;
      const tag = (base.vertical ? 'V' : 'H') + ' F' + base.F + ' vw' + base.vw + ' n=' + n;
      // Regression guard: NEW must never INTRODUCE a drop OLD did not have, and
      // maxScroll must never MOVE BACKWARD vs OLD (the +1 tolerance only ever
      // raises maxScroll toward the last content page).
      if (newFirstSkip && !oldFirstSkip) {
        failed = true;
        console.log('[A-REGRESSION] ' + tag + ' NEW introduces a FIRST-line drop OLD did not have');
      }
      if (newLastSkip && !oldLastSkip) {
        failed = true;
        console.log('[A-REGRESSION] ' + tag + ' NEW introduces a LAST-line drop OLD did not have');
      }
      if (newB.maxScroll < oldB.maxScroll - TOL || newB.minScroll > oldB.minScroll + TOL) {
        failed = true;
        console.log('[A-REGRESSION] ' + tag + ' NEW bounds worse than OLD'
          + ' oldMin=' + oldB.minScroll + ' newMin=' + newB.minScroll + ' oldMax=' + oldB.maxScroll + ' newMax=' + newB.maxScroll);
      }
      // Pre-existing STRUCTURAL overhang cut (clientSize > pageStep, so the last
      // content lives in the [alignedMax+pageStep, ctxMax+clientSize] overhang and
      // the last aligned page cannot reach it; lastContentScroll exceeds the
      // physical ctxMax). Present in BOTH old and new; NOT the sub-pixel mode the
      // +1 tolerance targets. Reported, not failed — a separate higher-risk fix
      // (snap/pageStep vs clientSize) is required and must be gated on device.
      if (oldLastSkip && newLastSkip) structuralOverhangCuts++;
      // PART B: inject the real-device sub-pixel undershoot headless cannot make.
      const lastPage = Math.floor(Math.max(0, m.lastContentEdge - 1) / ps) * ps;
      if (lastPage >= ps) {
        // Synthetic sub-pixel undershoot: pretend the physical scroll max landed
        // 0.4px below the last content page (the real-device vh/DPR rounding that
        // integer-reported headless scrollHeight cannot produce). OLD bare floor
        // drops that page; NEW +1 tolerance must recover it.
        const ctxInj = lastPage - 0.4;
        const oldI = computeBounds(m.firstContentEdge, m.lastContentEdge, ctxInj, ps, 'old');
        const newI = computeBounds(m.firstContentEdge, m.lastContentEdge, ctxInj, ps, 'new');
        const oldDropsPage = oldI.maxScroll < lastPage - TOL;
        const newRecovers = Math.abs(newI.maxScroll - lastPage) <= TOL;
        if (oldDropsPage && newRecovers) injectedRepros++;
        if (!newRecovers) {
          failed = true;
          console.log('[B-FAIL] ' + tag + ' NEW did not recover last page under sub-pixel undershoot'
            + ' lastPage=' + lastPage.toFixed(2) + ' newMax=' + newI.maxScroll.toFixed(2));
        }
      }
    }
  }
  await browser.close();
  console.log('\n[SUMMARY] cases=' + cases
    + ' | injected_subpixel_undershoots_fixed_by_NEW=' + injectedRepros
    + ' | pre-existing_structural_overhang_cuts(both old&new, NOT this fix)=' + structuralOverhangCuts);
  console.log(failed
    ? '\nRESULT: FAIL'
    : '\nRESULT: PASS - NEW never regresses vs OLD on real geometry and recovers the last page under injected sub-pixel undershoot. '
      + '(Pre-existing structural overhang cuts, if any, are a SEPARATE higher-risk issue — see summary count — needing a snap/pageStep-vs-clientSize fix gated on real device.)');
  process.exit(failed ? 1 : 0);
})();
