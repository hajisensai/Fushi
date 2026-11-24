// Audiobook follow styles (feedback tUJsiLpL9d / GitHub #3300, owner decision A+B). Runs the
// generated production reader CSS + engine shell in real Chrome; only the Flutter bridge is a
// recorder stub.
//  A (paginated): a sentence split across pages reports its page split; the characters before
//    the split sit inside the content box of the sentence-start page and the split character does
//    not; revealAudioCueTail advances exactly one page and shows the tail; re-revealing the same
//    sentence keeps the tail page; dropAudioCueTail brings the start page back.
//  B (continuous): with line align on, a sentence outside the content band is scrolled so the line
//    box of its first line starts at the content start edge; re-revealing a fully visible sentence
//    does not scroll; with the switch off the old 15% margin follow is unchanged.
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const payload = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}

const COMMON = String.raw`
  const errors = []; let checks = 0;
  const ok = (cond, msg) => { checks++; if (!cond) errors.push(msg); };
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  const restored = await Promise.race([window.__fushiRestored.then(() => true),
    new Promise((r) => setTimeout(() => r(false), 30000))]);
  if (!restored) throw new Error('the reader engine never reported onRestoreComplete');
  await frames();
  // The page must be laid out in the fixture CJK font the Dart test embeds, not a host fallback:
  // without a CJK font (Linux CI) the fallback glyphs are narrower, the text runs shorter, and
  // which sentence crosses a page / where the scroll range ends is no longer the same layout.
  await document.fonts.ready;
  const fixture = [...document.fonts].find((f) => f.family.replace(/["']/g, '') === 'Fushi Follow Fixture CJK');
  if (!fixture || fixture.status !== 'loaded') {
    return { errors: ['fixture CJK font not loaded (' + (fixture ? fixture.status : 'no @font-face') + ')'], checks: 1 };
  }
  const R = window.fushiReader;
  const ids = window.__cueIds;
  const wm = getComputedStyle(document.body).writingMode;
  const vertical = wm.indexOf('vertical') === 0;
  const rl = wm.indexOf('vertical-rl') === 0;
  const spanOf = (id) => R.audioCueSpan([].concat(R.cueWrappers.get(id) || [],
    R.cueRubyElements.get(id) || [], R.cueRangesMap.get(id) || []));
  const center = (rect) => ({ x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 });
`;

const PAGINATED = String.raw`(async () => {
  ${COMMON}
  const pos = () => R.getPagePosition(R.getScrollContext());
  const cs = getComputedStyle(document.body);
  const box = {
    left: parseFloat(cs.paddingLeft) || 0,
    right: window.innerWidth - (parseFloat(cs.paddingRight) || 0),
    top: parseFloat(cs.paddingTop) || 0,
    bottom: window.innerHeight - (parseFloat(cs.paddingBottom) || 0),
  };
  const inBox = (rect) => {
    const c = center(rect);
    return c.x >= box.left && c.x <= box.right && c.y >= box.top && c.y <= box.bottom;
  };
  let found = null;
  let whole = 0;
  for (const id of ids) {
    R.highlightSentenceAudioCue(id, true);
    await frames();
    const raw = R.audioCuePageSplit(id);
    if (!raw) { whole++; continue; }
    found = { id: id, split: JSON.parse(raw) };
    break;
  }
  ok(found !== null, 'no sentence was reported as split across pages');
  ok(whole > 0, 'sentences that fit on one page must not report a split');
  if (!found) return { errors, checks };
  const chars = R.audioCueChars(spanOf(found.id));
  ok(found.split.total === chars.length, 'split total ' + found.split.total + ' != ' + chars.length);
  ok(found.split.before > 0 && found.split.before < found.split.total,
    'split must fall inside the sentence: ' + JSON.stringify(found.split));
  const head = pos();
  const pageSize = R.getScrollContext().pageSize;
  const lastOnHead = R.audioCueCharRect(chars[found.split.before - 1]);
  const firstOnTail = R.audioCueCharRect(chars[found.split.before]);
  ok(lastOnHead && inBox(lastOnHead), 'the character before the split is not visible on the start page');
  ok(firstOnTail && !inBox(firstOnTail), 'the split character is already visible on the start page');
  R.revealAudioCueTail(found.id);
  await frames();
  const tail = pos();
  ok(Math.abs(tail - head - pageSize) < 1, 'tail reveal must advance one page: ' + head + ' -> ' + tail +
    ' (page ' + pageSize + ')');
  const tailChar = R.audioCueCharRect(chars[found.split.before]);
  ok(tailChar && inBox(tailChar), 'the split character is not visible after the tail reveal');
  R.highlightSentenceAudioCue(found.id, true);
  await frames();
  ok(Math.abs(pos() - tail) < 1, 'revealing the same sentence again must stay on the tail page');
  R.dropAudioCueTail();
  R.highlightSentenceAudioCue(found.id, true);
  await frames();
  ok(Math.abs(pos() - head) < 1, 'after dropping the tail the sentence start page is shown again');
  return { errors, checks };
})()`;

const CONTINUOUS = String.raw`(async () => {
  ${COMMON}
  const root = document.scrollingElement || document.documentElement;
  const scrollPos = () => vertical ? window.scrollX : root.scrollTop;
  const settle = async () => {
    let last = scrollPos(); let still = 0; const end = Date.now() + 3000;
    while (still < 8 && Date.now() < end) {
      await new Promise((r) => requestAnimationFrame(r));
      const now = scrollPos();
      if (now === last) still++; else { still = 0; last = now; }
    }
  };
  const cs = getComputedStyle(document.body);
  const vw = window.innerWidth; const vh = window.innerHeight;
  const toD = (r) => !vertical ? { s: r.top, e: r.bottom } : (rl ? { s: -r.right, e: -r.left } : { s: r.left, e: r.right });
  const band = !vertical
    ? { s: parseFloat(cs.paddingTop) || 0, e: vh - (parseFloat(cs.paddingBottom) || 0) }
    : (rl ? { s: -(vw - (parseFloat(cs.paddingRight) || 0)), e: -(parseFloat(cs.paddingLeft) || 0) }
          : { s: parseFloat(cs.paddingLeft) || 0, e: vw - (parseFloat(cs.paddingRight) || 0) });
  const extent = (id) => {
    const rects = spanOf(id).getClientRects(); let s = Infinity; let e = -Infinity;
    for (const r of rects) { if (!(r.width > 0 && r.height > 0)) continue; const d = toD(r); s = Math.min(s, d.s); e = Math.max(e, d.e); }
    return { s, e };
  };
  const lineStart = (id) => {
    const chars = R.audioCueChars(spanOf(id));
    const d = toD(R.audioCueCharRect(chars[0]));
    const lh = parseFloat(getComputedStyle(chars[0][0].parentElement).lineHeight);
    const glyph = d.e - d.s;
    return d.s - (lh > glyph ? (lh - glyph) / 2 : 0);
  };
  // 1. A far sentence: jump, then its first line box starts at the content start edge.
  const far = ids[Math.floor(ids.length * 0.6)];
  R.highlightSentenceAudioCue(far, true);
  await settle();
  ok(Math.abs(lineStart(far) - band.s) <= 1, 'far sentence first line ' + lineStart(far) + ' != band start ' + band.s);
  // 2. Fully visible sentence: no scroll.
  const before = scrollPos();
  R.highlightSentenceAudioCue(far, true);
  await settle();
  ok(scrollPos() === before, 'a fully visible sentence must not scroll (' + before + ' -> ' + scrollPos() + ')');
  // 3. The next sentence crossing the band end: smooth follow lands line aligned.
  let crossing = null;
  for (let i = ids.indexOf(far) + 1; i < ids.length; i++) {
    const x = extent(ids[i]);
    if (x.e > band.e) { crossing = ids[i]; break; }
  }
  ok(crossing !== null, 'no sentence crosses the end of the content band');
  if (crossing) {
    R.highlightSentenceAudioCue(crossing, true);
    await settle();
    ok(Math.abs(lineStart(crossing) - band.s) <= 1,
      'crossing sentence first line ' + lineStart(crossing) + ' != band start ' + band.s);
  }
  // 4. Switch off: the old 15% margin follow.
  window.__harnessConfig.audiobookLineAlignFollow = false;
  const old = ids[Math.floor(ids.length * 0.25)];
  R.highlightSentenceAudioCue(old, true);
  await settle();
  const first = (R.cueWrappers.get(old) || R.cueRangesMap.get(old) || [])[0];
  const rect = R.getRect(first);
  const expected = vertical ? (rl ? vw - vw * 0.15 : vw * 0.15) : vh * 0.15;
  const actual = vertical ? (rl ? rect.right : rect.left) : rect.top;
  ok(Math.abs(actual - expected) <= 1, 'switch off: old margin follow expected ' + expected + ' got ' + actual);
  return { errors, checks };
})()`;

const driver = await launchChromeDriver();
let total = 0;
const failures = [];
try {
  // The pages are built for a 1280x800 viewport (config dartPageWidth / dartPageHeight size the
  // columns); pin the real viewport to it so the columns are not taller than the window.
  await driver.send('Emulation.setDeviceMetricsOverride',
    { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  for (const page of payload.paginated) {
    const res = await driver.evalOnPage(page.html, PAGINATED);
    total += res.checks;
    for (const e of res.errors) failures.push(page.name + ': ' + e);
  }
  for (const page of payload.continuous) {
    const res = await driver.evalOnPage(page.html, CONTINUOUS);
    total += res.checks;
    for (const e of res.errors) failures.push(page.name + ': ' + e);
  }
} finally {
  driver.close();
}
if (failures.length) {
  console.log(failures.join('\n'));
  process.exit(1);
}
console.log('PASS ' + payload.paginated.length + ' paginated pages, ' + payload.continuous.length +
  ' continuous pages, ' + total + ' checks');
