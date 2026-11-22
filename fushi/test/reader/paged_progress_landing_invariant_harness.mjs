// BUG-5015: runs the production reader engine in real headless Chrome and
// checks that a coarse progress landing (scrollToProgressPaged /
// restoreProgress / the late-image re-anchor; scrollToProgressContinuous in the
// continuous shell) is a function of the chapter layout alone. It must not
// depend on where the page was before the call, nor on whether the pagination
// metrics cache was just invalidated.
//
// Root cause guarded: progress counts every text node under <body>, including
// ones with no layout box (a <style> / <script> in the body, a book's
// display:none element). When the target unit fell in such a node, the paged
// anchor came from getRect's all-zero bounding-box fallback, so anchor = 0 +
// current scroll: the landing was wherever the page already was, and in
// vertical (contentStart 24 > column gap 22) every repeat stepped one page
// back -- "the first landing differs from the later ones". The continuous
// shell's scrollIntoView on such a node was a no-op. The chapter here carries
// an unrendered block mid-chapter and one at the very end (forward and
// backward fallback), and the progress list lands inside both.
//
// Geometries: horizontal, vertical single strip (pages along y), the foldable
// vertical spread (production spreadCss, 'xr' axis; skipped on Chrome < 145),
// each at three font sizes with a fractional body so the page step is not a
// whole pixel; plus the continuous shell. Text carries ruby and leading
// whitespace text nodes like a real EPUB chapter.
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const payload = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}

const PT = 24, PB = 32, PL = 20, PR = 28;
const CONFIG = {
  vnMode: false, continuousMode: false, perfTraceEnabled: false,
  chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: 0, dartPageHeight: 0,
  initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
};

const para = (i) => `<p>\n  第${i}段。これは<ruby>本文<rt>ほんぶん</rt></ruby>です。`
  + '彼女は窓の外を眺めながら、遠い昔の出来事について静かに話し始めました。'
  + '私はその言葉を聞きながら、今まで気付かなかった世界の広さを感じていました。</p>';

// `paragraphs` visible paragraphs; an unrendered block worth ~40 of them after
// the first half (progress ~0.43-0.51) and a <style> worth ~30 at the very end
// (~0.94-1, nothing rendered after it).
function chapter(paragraphs) {
  const unrendered = (n) => Array.from({ length: n },
    (_, i) => `隠れた文章${i}は表示されません。`.repeat(5)).join('');
  const half = paragraphs / 2;
  return Array.from({ length: half }, (_, i) => para(i)).join('\n')
    + `\n<div class="hidden-note" style="display:none">${unrendered(40)}</div>\n`
    + Array.from({ length: half }, (_, i) => para(half + i)).join('\n')
    + `\n<style>/* ${unrendered(30)} */</style>`;
}

function page({ vertical, spread, paragraphs, continuous }) {
  if (continuous) {
    const css = 'html,body{margin:0;padding:0}body{padding:24px 28px 32px 20px;font-size:21px;line-height:1.8}';
    return `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head>`
      + `<body>${chapter(paragraphs)}\n${payload.continuousEngine}\n`
      + `<script>window.__fushiInstallShell(${JSON.stringify({ ...CONFIG, continuousMode: true })});</script>`
      + '</body></html>';
  }
  // A body a fraction of a pixel short of the viewport: the page step (content
  // box + gap) is then fractional, as on fractional-DPR devices (BUG-2325).
  const css = 'html,body{margin:0;padding:0}html{overflow:hidden}'
    + 'body{width:calc(100vw - 0.533px);height:calc(100vh - 0.067px);box-sizing:border-box;'
    + `padding:${PT}px ${PR}px ${PB}px ${PL}px;writing-mode:${vertical ? 'vertical-rl' : 'horizontal-tb'};`
    + `column-width:${vertical ? `calc(100vh - 0.067px - ${PT + PB}px)` : `calc(100vw - 0.533px - ${PL + PR}px)`};`
    + 'column-gap:22px;column-fill:auto;font-size:21px;line-height:1.8;overflow:hidden}';
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style>`
    + (spread ? `<style>${payload.spreadCss}</style>` : '')
    + `</head><body>${chapter(paragraphs)}\n${payload.engine}\n`
    + `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});</script></body></html>`;
}

const PROGRESSES = [0.1, 0.25, 0.45, 0.5, 0.67, 0.9, 0.95, 0.97];
const STARTS = [0, 0.5, 0.98];

// The engine's own <script> text sits in this test page's body (production
// injects it with evaluateJavascript); drop it so progress means the chapter.
const DROP_ENGINE_SCRIPTS = "document.querySelectorAll('body > script').forEach((s) => s.remove());";

const check = (expectAxis) => `(async () => {
  const r = window.fushiReader;
  const settle = () => new Promise((res) => setTimeout(res, 40));
  const fails = [];
  let landings = 0;
  await settle();
  ${DROP_ENGINE_SCRIPTS}
  r.paginationMetrics = null;
  if (r.getScrollContext().axis !== ${JSON.stringify(expectAxis)}) fails.push('axis ' + r.getScrollContext().axis);
  const at = () => r.getPagePosition(r.getScrollContext());
  const land = (p) => { r.scrollToProgressPaged(r.getScrollContext(), p); landings++; return at(); };
  for (const size of [24, 19, 21]) {
    document.body.style.fontSize = size + 'px';
    r.paginationMetrics = null;
    const ctx = r.getScrollContext();
    for (const p of ${JSON.stringify(PROGRESSES)}) {
      const seen = [];
      for (const start of ${JSON.stringify(STARTS)}) {
        // Start page set directly on the grid, not through a progress landing
        // (which is the thing under test and could itself stay put).
        const m = r.buildPaginationMetrics();
        r.setPagePosition(ctx, m.minScroll
          + Math.floor(start * (m.maxScroll - m.minScroll) / ctx.pageSize) * ctx.pageSize);
        r.paginationMetrics = null;
        seen.push(land(p), land(p));
      }
      // The restore entry and the late-image re-anchor after a cache drop take
      // the same conversion.
      r.paginationMetrics = null;
      await r.restoreProgress(p);
      await settle();
      seen.push(at());
      r.paginationMetrics = null;
      r.reapplyImageLateAnchor();
      seen.push(at());
      if (!seen.every((v) => v === seen[0])) {
        fails.push('font ' + size + ' progress ' + p + ': ' + JSON.stringify(seen));
      }
      // On the page grid (a whole number of steps), never between two pages.
      const steps = seen[0] / ctx.pageSize;
      if (Math.abs(steps - Math.round(steps)) > 0.01) {
        fails.push('font ' + size + ' progress ' + p + ': ' + seen[0] + ' off the ' + ctx.pageSize + ' grid');
      }
    }
  }
  return { fails, landings, pageSize: r.getScrollContext().pageSize };
})()`;

const checkContinuous = () => `(async () => {
  const r = window.fushiReader;
  const settle = () => new Promise((res) => setTimeout(res, 40));
  const fails = [];
  let landings = 0;
  await settle();
  ${DROP_ENGINE_SCRIPTS}
  const se = document.scrollingElement;
  const at = () => se.scrollTop;
  const land = (p) => { r.scrollToProgressContinuous(p); landings++; return at(); };
  for (const p of ${JSON.stringify(PROGRESSES)}) {
    const seen = [];
    for (const start of [0, 0.5, 1]) {
      se.scrollTop = Math.round(start * (se.scrollHeight - se.clientHeight));
      seen.push(land(p), land(p));
    }
    if (!seen.every((v) => v === seen[0])) fails.push('progress ' + p + ': ' + JSON.stringify(seen));
  }
  return { fails, landings, pageSize: se.clientHeight };
})()`;

const CASES = [
  ['horizontal', { vertical: false, spread: false, paragraphs: 400 }, 'x'],
  ['vertical', { vertical: true, spread: false, paragraphs: 400 }, 'y'],
  ['vertical spread', { vertical: true, spread: true, paragraphs: 400 }, 'xr'],
  ['continuous', { continuous: true, paragraphs: 400 }, null],
];

const driver = await launchChromeDriver();
let failed = 0;
try {
  const supported = await driver.evalOnPage('<!doctype html><body></body>', "CSS.supports('column-wrap', 'wrap')");
  for (const [name, opts, axis] of CASES) {
    if (opts.spread && !supported) {
      console.log(`skip ${name}: Chrome lacks column-wrap (needs 145+)`);
      continue;
    }
    const res = await driver.evalOnPage(page(opts), opts.continuous ? checkContinuous() : check(axis));
    if (res.fails.length) {
      failed++;
      console.log(`FAIL ${name}: pageSize ${res.pageSize}, ${res.landings} landings: ${res.fails.join('; ')}`);
    } else {
      console.log(`ok ${name}: pageSize ${res.pageSize}, ${res.landings} landings`);
    }
  }
} finally {
  await driver.close();
}
if (failed) process.exit(1);
console.log('PASS paged progress landing invariant');
