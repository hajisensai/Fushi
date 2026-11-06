// BUG-3606: vertical punctuation keeps one orientation whatever the body font is.
// Each page is the production reader CSS (from the Dart test) with a body font that has no
// OpenType `vert` (test/reader/fixtures/no_vert_cjk.woff2, a Noto Serif JP subset with the
// layout tables stripped, SIL OFL 1.1) and the bundled punctuation subset inlined as data URIs.
// Three fixed probes draw 「: #t inherits the body font chain, #ref names the punctuation subset
// then the no-vert font, #bad names only the no-vert font. Vertical pages must paint #t exactly
// like #ref and unlike #bad (Blink draws the horizontal 「 when the font lacks `vert`);
// horizontal pages must paint #t exactly like #bad (nothing injected, the body font is used).
// #t2 / #ref2 / #bad2 do the same for the long-vowel mark ー (UAX #50 Tr like 「: Blink also
// paints it as a horizontal bar when the font lacks `vert`, feedback mTof77pMTe).
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The only argument is the temp payload file the Dart test just wrote.
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: S8707 path comes from the Dart test harness

const RECTS = String.raw`(async () => {
  await document.fonts.ready;
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  const out = {};
  for (const id of ['t', 'ref', 'bad', 't2', 'ref2', 'bad2']) {
    const b = document.getElementById(id).getBoundingClientRect();
    out[id] = { x: Math.round(b.left), y: Math.round(b.top), width: Math.round(b.width), height: Math.round(b.height) };
  }
  out.loaded = Array.from(document.fonts).filter((f) => f.status === 'loaded').map((f) => f.family);
  return out;
})()`;

const driver = await launchChromeDriver();
const failures = [];
try {
  for (const page of payload.pages) {
    const rects = await driver.evalOnPage(page.html, RECTS);
    const shot = {};
    for (const id of ['t', 'ref', 'bad', 't2', 'ref2', 'bad2']) shot[id] = await driver.capture(rects[id]);
    for (const [suffix, ch] of [['', '「'], ['2', 'ー']]) {
      const t = shot['t' + suffix], ref = shot['ref' + suffix], bad = shot['bad' + suffix];
      if (page.vertical) {
        // Both fonts share Noto Serif JP outlines, so only the vertical form tells them apart.
        if (ref === bad) {
          failures.push(page.name + ': the punctuation subset and the no-vert fixture paint the same ' + ch + ' (subset lacks its vertical form, or the fixture is broken; loaded: ' + rects.loaded.join(', ') + ')');
          continue;
        }
        if (t !== ref) failures.push(page.name + ': body text does not use the vertical ' + ch + ' of the punctuation subset');
      } else if (t !== bad) {
        failures.push(page.name + ': horizontal ' + ch + ' changed (punctuation subset leaked into horizontal)');
      }
    }
  }
} finally {
  driver.close();
}
if (failures.length) {
  console.log(failures.join('\n'));
  process.exit(1);
}
console.log('PASS ' + payload.pages.length + ' punctuation pages');
