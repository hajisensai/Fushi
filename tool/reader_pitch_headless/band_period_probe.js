// Reader vertical pagination geometry probe (headless Chrome).
//
// WHY THIS EXISTS (BUG-405): the Dart algebraic guard
// `hibiki/test/reader/reader_vertical_pitch_invariant_test.dart` defines realPitch as
// `columnWidth + gap` (the *nominal* value), so it structurally cannot tell whether the
// browser's *actual* multicol column period matches that nominal pitch. A "cumulative
// pagination offset" P0 was raised on the hypothesis that the real period drifts from the
// nominal one; this probe renders the real reader vertical CSS in Chromium and measures the
// true per-column band tops, proving the nominal pageStep IS the correct cumulative period
// (the per-column period is a BOUNDED saw-tooth whose mean == nominal pageStep; perceived
// top-offset oscillates within ~one column-internal step and does NOT grow with page count).
//
// Run:  cd tool/reader_pitch_headless && npm install && node band_period_probe.js
// Requires system Chrome at the path below (puppeteer-core does NOT download Chromium).
//
// Invariants asserted (exit code 1 on violation):
//   I1  mean column period over all bands ≈ nominal pageStep (|Δ| <= 1px).
//   I2  perceived viewport-top offset after scrollTop=k*pageStep stays bounded across all
//       pages (max-min <= one nominal pageStep worth of saw-tooth, ~ font*line-height+gap),
//       and does NOT grow monotonically with k (net drift p0->pN is bounded, not linear).
const puppeteer = require('puppeteer-core');

const CHROME = process.env.CHROME_PATH
  || 'C:/Program Files/Google/Chrome/Application/chrome.exe';

// Vertical reader CSS, mirroring reader_content_styles.dart:
//   column-width: max(F, V - mt*vh - mb*vh - F)   (TODO-743 floor)
//   column-gap:   22px (ReaderLayoutDefaults.columnGapPx)
//   padding-top:    mt*vh ; padding-bottom: mb*vh + F (the +F is the reader's bottom reserve)
//   --page-height = V + O (O=bottomOverlap=22); viewport height = V + O.
function buildHtml({ V, vw, F }) {
  const O = 22, mt = 2, mb = 2;
  const colW = `max(${F}px, calc(${V}px - ${mt}vh - ${mb}vh - ${F}px))`;
  let s = '';
  for (let i = 0; i < 40000; i++) s += '永';
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{overflow:hidden !important;height:${V + O}px !important;width:${vw}px !important;margin:0 !important;padding:0 !important;writing-mode:vertical-rl !important;}
body{font-family:serif !important;font-size:${F}px !important;line-height:1.5 !important;box-sizing:border-box !important;
column-width:${colW} !important;column-gap:22px !important;
padding-top:calc(${mt}vh) !important;padding-bottom:calc(${mb}vh + ${F}px) !important;padding-left:8px !important;padding-right:8px !important;}
div{margin:0 !important;}
</style></head><body><div>${s}</div></body></html>`;
}

async function probe(browser, cfg) {
  const { V, vw } = cfg;
  const page = await browser.newPage();
  await page.setViewport({ width: vw, height: V + 22, deviceScaleFactor: 1 });
  await page.setContent(buildHtml(cfg), { waitUntil: 'load' });
  const r = await page.evaluate((V) => {
    const body = document.body, cs = getComputedStyle(body);
    const pt = parseFloat(cs.paddingTop) || 0;
    const pb = parseFloat(cs.paddingBottom) || 0;
    const gap = parseFloat(cs.columnGap) || 0;
    const contentBox = Math.max(parseFloat(cs.fontSize) || 1, V - pt - pb);
    const pageStep = contentBox + gap;

    // --- band tops: per-column min char top at scroll 0 ---
    body.scrollTop = 0;
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    const tops = [];
    let node, c = 0;
    while ((node = walker.nextNode()) && c < 40000) {
      const len = node.textContent.length;
      for (let i = 0; i < len; i++) {
        const rg = document.createRange();
        rg.setStart(node, i); rg.setEnd(node, i + 1);
        const rc = rg.getBoundingClientRect();
        if (rc.width === 0 && rc.height === 0) continue;
        tops.push(rc.top); c++;
      }
    }
    const bandMin = new Map();
    for (const t of tops) {
      const k = Math.floor(t / pageStep);
      if (!bandMin.has(k) || t < bandMin.get(k)) bandMin.set(k, t);
    }
    const ks = [...bandMin.keys()].filter((k) => k >= 0).sort((a, b) => a - b);
    const bt = ks.map((k) => bandMin.get(k));
    const meanPeriod = bt.length > 1 ? (bt[bt.length - 1] - bt[0]) / (bt.length - 1) : null;

    // --- alignment residual after paginate snaps scrollTop = k*pageStep ---
    // paginate() lands the page at the absolute grid k*pageStep. The visible misalignment
    // is the distance from that grid line to the nearest real column band top. Measure it
    // directly from band tops (no caretRangeFromPoint — that wraps a full column at the
    // boundary and injects a fake ~pageStep jump). residual in [-pageStep/2, +pageStep/2];
    // if the nominal pitch matched the real period perfectly this would be ~0 every page;
    // with the bounded saw-tooth it oscillates within the saw amplitude and does NOT grow.
    const residuals = [];
    for (let k = 1; k < bt.length; k++) {
      const grid = k * pageStep;
      // nearest band top to this grid line
      let best = bt[0], bestD = Math.abs(bt[0] - grid);
      for (const t of bt) { const d = Math.abs(t - grid); if (d < bestD) { bestD = d; best = t; } }
      let res = best - grid;
      residuals.push(res);
    }
    return { pt, pageStep, numBands: bt.length, meanPeriod, residuals };
  }, V);
  await page.close();
  return r;
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--force-device-scale-factor=1'],
  });
  const cfgs = [
    { label: 'F18 V846', V: 846, vw: 412, F: 18 },
    { label: 'F22 V800', V: 800, vw: 400, F: 22 },
    { label: 'F26 V915', V: 915, vw: 412, F: 26 },
    { label: 'F30 V780', V: 780, vw: 390, F: 30 },
    { label: 'F30 V780 w412', V: 780, vw: 412, F: 30 },
  ];
  let failed = false;
  for (const cfg of cfgs) {
    const r = await probe(browser, cfg);
    const meanDelta = Math.abs(r.meanPeriod - r.pageStep);
    const res = r.residuals;
    const spread = Math.max(...res) - Math.min(...res);
    const netDrift = res[res.length - 1] - res[0];
    // I1: mean period within 1px of nominal pageStep.
    const i1 = meanDelta <= 1.0;
    // I2: residual is a BOUNDED saw-tooth (amplitude ~ one within-column step, well under
    // half a pageStep) and its net change across all pages stays inside that band — i.e. it
    // does NOT grow with page count. A real cumulative bug would push |residual| past
    // pageStep/2 and keep climbing.
    const ceiling = r.pageStep * 0.5;
    const i2 = spread <= ceiling && Math.abs(netDrift) <= ceiling;
    if (!i1 || !i2) failed = true;
    console.log(
      `${cfg.label.padEnd(14)} pageStep=${r.pageStep.toFixed(2)} `
      + `meanPeriod=${r.meanPeriod.toFixed(3)} (Δ=${meanDelta.toFixed(3)}) `
      + `| residual spread=${spread.toFixed(2)} netDrift=${netDrift.toFixed(2)} (bound ${ceiling.toFixed(1)}) `
      + `| I1 ${i1 ? 'PASS' : 'FAIL'} I2 ${i2 ? 'PASS' : 'FAIL'}`
    );
  }
  await browser.close();
  console.log(failed
    ? '\nRESULT: FAIL — real column period diverges from nominal pageStep (a real cumulative bug).'
    : '\nRESULT: PASS — nominal pageStep == real mean column period; offset bounded, no drift (BUG-405 stays证伪).');
  process.exit(failed ? 1 : 0);
})();
