// BUG-3606: vertical punctuation keeps one orientation whatever the body font is.
// Each page is the production reader CSS (from the Dart test) with a body font that has no
// OpenType `vert` (test/reader/fixtures/no_vert_cjk.woff2, a Noto Serif JP subset with the
// layout tables stripped, SIL OFL 1.1) and the bundled punctuation subset inlined as data URIs.
// Three fixed probes draw 「: #t inherits the body font chain, #ref names the punctuation subset
// then the no-vert font, #bad names only the no-vert font. Vertical pages must paint #t exactly
// like #ref and unlike #bad (Blink draws the horizontal 「 when the font lacks `vert`);
// horizontal pages must paint #t exactly like #bad (nothing injected, the body font is used).
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
  for (const id of ['t', 'ref', 'bad']) {
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
    for (const id of ['t', 'ref', 'bad']) shot[id] = await driver.capture(rects[id]);
    if (page.vertical) {
      // Both fonts share Noto Serif JP outlines, so only the vertical form tells them apart.
      if (shot.ref === shot.bad) {
        failures.push(page.name + ': fixture broken — the no-vert font paints the same 「 as the subset (loaded: ' + rects.loaded.join(', ') + ')');
        continue;
      }
      if (shot.t !== shot.ref) failures.push(page.name + ': body text does not use the vertical 「 of the punctuation subset');
    } else if (shot.t !== shot.bad) {
      failures.push(page.name + ': horizontal text changed (punctuation subset leaked into horizontal)');
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
