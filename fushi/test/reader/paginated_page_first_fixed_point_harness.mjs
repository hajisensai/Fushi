// Runs the production paginated engine shell in real headless Chrome and walks
// every page of a chapter in three geometries: horizontal, vertical (single
// strip, pages stacked along y) and the foldable book-posture vertical spread
// (CSS multicol rows with column-wrap: wrap, right page + left page, pages
// advancing right-to-left along x — the 'xr' turn axis).
//
// On every page: the page's first visible character f, saved and restored with
// restoreToCharOffset(f), must land back on the same page and be drawn on it.
// That is the save -> reopen fixed point: when f starts a soft-wrapped line,
// Chromium puts the collapsed caret at the END of the previous line, which is
// the previous page's last line; aligning that caret dropped every reopen one
// page back (BUG-3431 paged side). The spread additionally checks its axis and
// a backward walk that retraces the forward pages.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const PT = 24, PB = 32, PL = 20, PR = 28;
// The body fills the real viewport, as in production (the reader WebView is the
// viewport). cdp_client's window is not exactly its --window-size once headless
// chrome is subtracted (measured 1258x646), and a body larger or smaller than the
// viewport puts the caret probes and page edges in the wrong place.
const CONFIG = {
  vnMode: false, continuousMode: false, perfTraceEnabled: false,
  chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: 0, dartPageHeight: 0,
  initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
};

function page({ writingMode, spread, paragraphs, fontSize = 22, fullwidthPrefix = false }) {
  const vertical = writingMode === 'vertical-rl';
  const css = 'html,body{margin:0;padding:0}html{overflow:hidden}'
    + `body{width:100vw;height:100vh;box-sizing:border-box;padding:${PT}px ${PR}px ${PB}px ${PL}px;`
    + `writing-mode:${writingMode};`
    + `column-width:${vertical ? `calc(100vh - ${PT + PB}px)` : `calc(100vw - ${PL + PR}px)`};`
    + `column-gap:22px;column-fill:auto;font-size:${fontSize}px;line-height:1.8;overflow:hidden}`
    + (vertical ? 'p{margin:0 1em 0 0}' : 'p{margin:0 0 1em 0}');
  // The trailing 「文章…章。」 matters: 「。」 may not start a line, so the wrap is
  // pushed back before 「章」 and that page-first 「章」 is exactly where the
  // collapsed caret is reported at the previous line's end. Varying the text
  // loses the case (a mutation run of the old caret anchor stayed green).
  // fullwidthPrefix: 「Ｐ０８　」 instead of 「P8 」. The Latin prefix is set in the
  // platform's proportional Latin face (its advance differs between Windows and
  // Linux CI), so it shifts every soft wrap after it; all-fullwidth text advances
  // exactly 1em per code unit in any CJK face, and the wraps fall on
  // floor(line length / font size) code units on every platform.
  const prefix = (i) => (fullwidthPrefix
    ? `Ｐ${String(i).padStart(2, '0').replace(/[0-9]/g, (d) => String.fromCharCode(0xFF10 + Number(d)))}　`
    : `P${i} `);
  const paras = Array.from({ length: paragraphs }, (_, i) =>
    `<p>${prefix(i)}これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを`
    + '並べています。文章文章文章文章文章文章文章文章。</p>').join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style>`
    + (spread ? `<style>${payload.spreadCss}</style>` : '')
    + `</head><body>${paras}\n${payload.engine}\n`
    + `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});</script></body></html>`;
}

const check = (expectAxis) => `(async () => {
  const r = window.fushiReader;
  const settle = () => new Promise(res => setTimeout(res, 40));
  const fails = [];
  await settle();
  const ctx0 = r.getScrollContext();
  if (ctx0.axis !== ${JSON.stringify(expectAxis)}) fails.push('axis ' + ctx0.axis);
  // Pages whose first unit directly follows a 「。」 in the same text node: the
  // inverse unit -> text-offset lookup used to stop on that 「。」, which is drawn
  // on the previous page (BUG-3651).
  const followsStop = (f) => {
    const w = r.createWalker();
    let run = 0, n;
    while ((n = w.nextNode())) {
      const c = r.countChars(n.textContent);
      if (run + c > f) {
        const o = window.fushiStudyUnits.unitStartOffset(n.textContent, f - run);
        return o > 0 && n.textContent[o - 1] === '。';
      }
      run += c;
    }
    return false;
  };
  let afterStop = 0;
  const forward = [];
  for (let i = 0; i < 300; i++) {
    const ctx = r.getScrollContext();
    const pos = r.getPagePosition(ctx);
    forward.push(pos);
    const f = r.getFirstVisibleCharOffset();
    if (f > 0) {
      if (followsStop(f)) afterStop++;
      if (!r.charOffsetOnCurrentPage(f)) fails.push('page ' + i + ': first char ' + f + ' not on page');
      await r.restoreToCharOffset(f);
      await settle();
      const back = r.getPagePosition(r.getScrollContext());
      if (Math.abs(back - pos) > 1) fails.push('page ' + i + ': first char ' + f + ' restores to ' + back + ' not ' + pos);
      r.setPagePosition(r.getScrollContext(), pos);
    }
    if (r.paginate('forward') === 'limit') break;
    r.finishPageTurnAnimation();
  }
  const backward = [];
  for (let i = 0; i < 300; i++) {
    backward.push(r.getPagePosition(r.getScrollContext()));
    if (r.paginate('backward') === 'limit') break;
    r.finishPageTurnAnimation();
  }
  backward.reverse();
  if (JSON.stringify(backward.map(Math.round)) !== JSON.stringify(forward.map(Math.round))) {
    fails.push('backward walk ' + JSON.stringify(backward.map(Math.round))
      + ' != forward ' + JSON.stringify(forward.map(Math.round)));
  }
  return { fails, pages: forward.length, pageSize: ctx0.pageSize, afterStop };
})()`;

const CASES = [
  ['horizontal', { writingMode: 'horizontal-tb', spread: false, paragraphs: 71 }, 'x'],
  ['horizontal (longer)', { writingMode: 'horizontal-tb', spread: false, paragraphs: 97 }, 'x'],
  ['vertical', { writingMode: 'vertical-rl', spread: false, paragraphs: 71 }, 'y'],
  ['vertical (longer)', { writingMode: 'vertical-rl', spread: false, paragraphs: 97 }, 'y'],
  ['vertical spread', { writingMode: 'vertical-rl', spread: true, paragraphs: 71 }, 'xr'],
  ['vertical spread (other parity)', { writingMode: 'vertical-rl', spread: true, paragraphs: 75 }, 'xr'],
  // Whether a page starts on a kinsoku-pushed wrap depends on the exact metrics;
  // two more font sizes keep the spread geometry inside the mutation net.
  ['vertical spread 20px', { writingMode: 'vertical-rl', spread: true, paragraphs: 83, fontSize: 20 }, 'xr'],
  ['vertical spread 26px', { writingMode: 'vertical-rl', spread: true, paragraphs: 83, fontSize: 26 }, 'xr'],
  // BUG-3651: every page must start right after the previous paragraph's
  // 「…並べています。」, where the old unit -> text-offset lookup stopped on that
  // 「。」 (drawn on the previous page) and every reopen fell one page back.
  // The premise is pinned by arithmetic, not by a measured viewport: the prefix
  // is fullwidth (see page()), so each paragraph is 69 code units at exactly
  // 1em each; the viewport height 586 leaves a 530px line = 26 units, so every
  // paragraph wraps 26 + 26 + 17 and its third line starts right after the
  // 「。」 at code unit 51. Paragraph pitch = 3 x 36px + 20px margin = 128px,
  // nine paragraphs per 1272px spread at width 1280 (the page breaks then fall
  // on those third lines). The former 「P8 」 prefix at 1280x560 only hit on
  // Windows: Linux CI's wider Latin face moved the wraps (0 pages after 「。」).
  // requireAfterStop still guards the premise. Must stay last: the viewport
  // override persists for the rest of the run.
  ['vertical spread 20px @1280x586', { writingMode: 'vertical-rl', spread: true, paragraphs: 83, fontSize: 20, fullwidthPrefix: true }, 'xr',
    { viewport: [1280, 586], requireAfterStop: true }],
];

const driver = await launchChromeDriver();
let failed = 0;
try {
  const supported = await driver.evalOnPage('<!doctype html><body></body>', "CSS.supports('column-wrap', 'wrap')");
  for (const [name, opts, axis, extra = {}] of CASES) {
    if (opts.spread && !supported) {
      console.log(`skip ${name}: Chrome lacks column-wrap (needs 145+)`);
      continue;
    }
    if (extra.viewport) {
      // snap() is the driver's only Emulation.setDeviceMetricsOverride entry.
      await driver.snap('<!doctype html><body></body>', null, extra.viewport[0], extra.viewport[1]);
    }
    const res = await driver.evalOnPage(page(opts), check(axis));
    if (extra.requireAfterStop && res.afterStop === 0) {
      res.fails.push('no page starts right after 「。」; the case no longer exercises BUG-3651');
    }
    if (res.fails.length) {
      failed++;
      console.log(`FAIL ${name}: ${res.fails.join('; ')}`);
    } else {
      console.log(`ok ${name}: ${res.pages} pages, pageSize ${res.pageSize}, ${res.afterStop} after 「。」`);
    }
  }
} finally {
  await driver.close();
}
if (failed) process.exit(1);
console.log('PASS paginated page-first fixed point');
