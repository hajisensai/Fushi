// BUG-3770: a current-sentence highlight must not clip the emphasis marks (text-emphasis)
// it covers. Runs the generated production reader CSS + engine shell + selection script in
// real Chrome (default and custom cue text colour), screenshots the emphasis-mark strip before and after the cue highlight and
// compares the mark ink. Only the Flutter bridge is replaced by a recorder.
import fs from 'node:fs';
import zlib from 'node:zlib';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The only argument is the temp payload file the Dart test just wrote.
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: S8707 path comes from the Dart test harness

// Show the screen holding the cue (VN renders it on the first highlight call), clear the
// highlight and return the emphasis-mark strip: the band beside the emphasised text on the
// marks' side (right in vertical-rl, 0.6em thick; above in horizontal-tb, 1em thick).
const PREP = String.raw`(async () => {
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 700));
  const R = window.fushiReader;
  R.highlightSentenceAudioCue('c1', true);
  await frames();
  (R.clearSentenceAudioCue || R.clearSentenceAudioCuePresentation).call(R);
  await frames();
  const root = document.querySelector('.fushi-vn-content') || document.body;
  const el = root.querySelector('.em');
  if (!el) return { error: 'no emphasised element' };
  const r = el.getBoundingClientRect();
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const em = parseFloat(getComputedStyle(el).fontSize);
  const strip = vertical
    ? { x: r.right, y: r.top, width: 0.6 * em, height: r.height }
    : { x: r.left, y: r.top - em, width: r.width, height: em };
  window.__emphasisScreenHtml = Array.from(root.querySelectorAll('p')).map((p) => p.innerHTML).join('|');
  return { strip, vertical };
})()`;

const PLAY = String.raw`(async () => {
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  window.fushiReader.highlightSentenceAudioCue('c1', true);
  await frames();
  const root = document.querySelector('.fushi-vn-content') || document.body;
  const el = root.querySelector('.em');
  const r = el.getBoundingClientRect();
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const lanes = Array.from(document.querySelectorAll('fushi-hl-lane[data-hl="fushi-sentence-audio"]'))
    .map((l) => l.getBoundingClientRect());
  const covered = lanes.some((l) => vertical
    ? l.left < r.right && l.right > r.left && l.top <= r.top + 1 && l.bottom >= r.bottom - 1
    : l.top < r.bottom && l.bottom > r.top && l.left <= r.left + 1 && l.right >= r.right - 1);
  // CSS.highlights.get is hooked to hand back the caller's highlight; the native getter returns
  // what the engine actually paints.
  const logical = CSS.highlights.get('fushi-sentence-audio');
  const hl = HighlightRegistry.prototype.get.call(CSS.highlights, 'fushi-sentence-audio');
  let paintsEmphasis = false;
  let paintsPlain = false;
  if (hl) {
    const emText = el.firstChild;
    hl.forEach((range) => {
      if (range.intersectsNode(emText)) paintsEmphasis = true;
      else paintsPlain = true;
    });
  }
  const emText = document.createTreeWalker(el, NodeFilter.SHOW_TEXT).nextNode();
  return {
    // Playing the cue only toggles classes: the screen text DOM stays as it was (BUG-3741).
    domSame: Array.from(root.querySelectorAll('p')).map((p) => p.innerHTML).join('|')
      .replace(/ fushi-sentence-audio-active/g, '') === window.__emphasisScreenHtml,
    emColor: getComputedStyle(emText.parentElement).color,
    covered,
    lanes: lanes.length,
    rangeMode: !!logical,
    logicalCoversEmphasis: !!logical && Array.from(logical).some((range) => range.intersectsNode(el.firstChild)),
    paintsEmphasis,
    paintsPlain,
    wrapped: !!root.querySelector('.fushi-sentence-audio-active'),
  };
})()`;

function decodePng(buf) {
  let p = 8, w = 0, h = 0, ct = 0;
  const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); ct = data[9]; }
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    p += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const ch = ct === 6 ? 4 : (ct === 2 ? 3 : 1);
  const stride = w * ch;
  const out = Buffer.alloc(h * stride);
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[pos++];
    for (let x = 0; x < stride; x++) {
      const v = raw[pos++];
      const a = x >= ch ? out[y * stride + x - ch] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= ch && y > 0 ? out[(y - 1) * stride + x - ch] : 0;
      let r;
      switch (f) {
        case 1: r = v + a; break;
        case 2: r = v + b; break;
        case 3: r = v + ((a + b) >> 1); break;
        case 4: { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          r = v + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)); break; }
        default: r = v;
      }
      out[y * stride + x] = r & 0xff;
    }
  }
  return { w, h, ch, data: out };
}

// Dark (text-coloured) pixels: the default theme prints dark text on a light page and the
// lane colour is light, so only glyph / mark ink counts.
function inkOf(png64) {
  const img = decodePng(Buffer.from(png64, 'base64'));
  let ink = 0;
  for (let i = 0; i < img.w * img.h; i++) {
    const r = img.data[i * img.ch], g = img.data[i * img.ch + 1], b = img.data[i * img.ch + 2];
    if (r + g + b < 3 * 110) ink++;
  }
  return ink;
}

const driver = await launchChromeDriver();
const failures = [];
let checked = 0;
try {
  for (const page of payload.pages) {
    const prep = await driver.evalOnPage(page.html, PREP);
    if (prep.error) { failures.push(page.name + ': ' + prep.error); continue; }
    const before = inkOf(await driver.capture(prep.strip));
    const play = await driver.evalHere(PLAY);
    const after = inkOf(await driver.capture(prep.strip));
    const fail = (msg) => failures.push(page.name + ': ' + msg);
    // Horizontal continuous draws the sesame marks as small dots (about 5 dark pixels).
    if (before < 4) fail('no emphasis marks painted before the highlight (ink ' + before + ')');
    if (after < before * 0.9) fail('emphasis marks clipped by the highlight: ink ' + before + ' -> ' + after);
    if (!play.covered) fail('the current-sentence lane does not cover the emphasised text (' + play.lanes + ' lanes)');
    if (!play.rangeMode && !play.wrapped) fail('the cue is neither a CSS highlight nor a wrapper');
    if (play.rangeMode && !play.logicalCoversEmphasis) fail('CSS.highlights.get no longer returns the full cue');
    if (play.rangeMode && play.paintsEmphasis) fail('the painted CSS highlight still covers emphasised text');
    if (!play.domSame) fail('playing the cue changed the screen DOM');
    // A custom cue colour must not go through a CSS highlight on Blink (it would clip the ink):
    // the text is pre-wrapped and recoloured through the wrapper, emphasised text included.
    if (page.customColor && play.rangeMode) fail('a custom cue text colour still goes through a CSS highlight');
    if (page.customColor && play.emColor !== 'rgb(30, 90, 200)') fail('emphasised text did not take the custom cue colour: ' + play.emColor);
    if (play.rangeMode && !page.customColor && play.paintsPlain) fail('a no-op cue highlight is still painted by the engine');
    console.log(page.name + ': ink ' + before + ' -> ' + after + (play.rangeMode ? ' (range)' : ' (wrapper)'));
    checked++;
  }
} finally {
  driver.close();
}
if (failures.length) {
  console.log('FAIL\n' + failures.join('\n'));
  process.exit(1);
}
console.log('PASS ' + checked + ' emphasis pages');
