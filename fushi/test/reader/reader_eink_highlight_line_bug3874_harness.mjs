// BUG-3886: on e-ink the current-sentence line must run unbroken along the whole cue — across
// ruby words, emphasis-marked text and line breaks — and must not be painted through a CSS
// highlight (Blink clips the glyph ink of highlighted text, BUG-3776). Runs the generated
// production reader CSS (einkMode) + engine shell + selection script in real Chrome, plays the
// cue, then scans the band just outside each cue line on its block-end side (left of a vertical
// column, below a horizontal line) pixel by pixel along the line.
import fs from 'node:fs';
import zlib from 'node:zlib';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The only argument is the temp payload file the Dart test just wrote.
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: S8707 path comes from the Dart test harness

// Play the cue and return one band per visual line of cue text, plus what the engine paints.
const PLAY = String.raw`(async () => {
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 700));
  window.fushiReader.highlightSentenceAudioCue('c1', true);
  await frames();
  await new Promise((r) => setTimeout(r, 200));
  await frames();
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const ranges = [];
  const logical = CSS.highlights && CSS.highlights.get('fushi-sentence-audio');
  if (logical) logical.forEach((r) => ranges.push(r));
  document.querySelectorAll('.fushi-sentence-audio-cue.fushi-sentence-audio-active, ruby.fushi-sentence-audio-ruby-active')
    .forEach((el) => { const r = document.createRange(); r.selectNodeContents(el); ranges.push(r); });
  if (!ranges.length) return { error: 'the cue is neither a CSS highlight nor a wrapper' };
  // Base glyph boxes of the cue (furigana excluded), one per character.
  const boxes = [];
  const g = document.createRange();
  ranges.forEach((range) => {
    const root = range.commonAncestorContainer;
    const nodes = [];
    if (root.nodeType === 3) nodes.push(root);
    else {
      const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let n = w.nextNode(); n; n = w.nextNode()) if (range.intersectsNode(n)) nodes.push(n);
    }
    nodes.forEach((n) => {
      if (n.parentElement.closest('rt, rp')) return;
      const s = n === range.startContainer ? range.startOffset : 0;
      const e = n === range.endContainer ? range.endOffset : n.data.length;
      for (let i = s; i < e; i++) {
        if (!n.data[i].trim()) continue;
        g.setStart(n, i); g.setEnd(n, i + 1);
        const b = g.getBoundingClientRect();
        if (b.width && b.height) boxes.push({ l: b.left, r: b.right, t: b.top, b: b.bottom, ch: n.data[i] });
      }
    });
  });
  // Group into visual lines by the box centre across the line.
  const lines = [];
  boxes.forEach((b) => {
    const c = vertical ? (b.l + b.r) / 2 : (b.t + b.b) / 2;
    let line = lines.find((l) => Math.abs(l.c - c) < 2);
    if (!line) { line = { c, boxes: [] }; lines.push(line); }
    line.boxes.push(b);
  });
  const em = parseFloat(getComputedStyle(document.body).fontSize);
  const bands = lines.map((l) => {
    const a = Math.min(...l.boxes.map((b) => vertical ? b.t : b.l));
    const z = Math.max(...l.boxes.map((b) => vertical ? b.b : b.r));
    const text = l.boxes.map((b) => b.ch).join('');
    if (vertical) {
      const edge = Math.min(...l.boxes.map((b) => b.l));
      return { text, rect: { x: Math.floor(edge - 0.45 * em), y: Math.ceil(a), width: Math.round(0.35 * em), height: Math.floor(z - a) } };
    }
    const edge = Math.max(...l.boxes.map((b) => b.b));
    return { text, rect: { x: Math.ceil(a), y: Math.ceil(edge + 0.1 * em), width: Math.floor(z - a), height: Math.round(0.35 * em) } };
  });
  // What the engine itself paints for the cue (the hooked get() returns the caller's ranges).
  const painted = typeof HighlightRegistry === 'function'
    ? HighlightRegistry.prototype.get.call(CSS.highlights, 'fushi-sentence-audio') : null;
  return { vertical, em, bands, painted: painted ? painted.size : 0, chars: boxes.length };
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

// Positions along the line (rows of a vertical band, columns of a horizontal one) with no dark
// pixel anywhere across the band: the blank run before the line starts (lead), after it ends
// (trail) and the longest one inside it (worst). The e-ink page is black on white.
function lineGaps(png64, vertical) {
  const img = decodePng(Buffer.from(png64, 'base64'));
  const dark = (x, y) => {
    const i = (y * img.w + x) * img.ch;
    return img.data[i] + img.data[i + 1] + img.data[i + 2] < 3 * 110;
  };
  const along = vertical ? img.h : img.w;
  const across = vertical ? img.w : img.h;
  let gap = 0, worst = 0, first = -1, last = -1;
  for (let u = 0; u < along; u++) {
    let hit = false;
    for (let v = 0; v < across && !hit; v++) hit = vertical ? dark(v, u) : dark(u, v);
    if (hit) {
      if (first < 0) first = u;
      else worst = Math.max(worst, gap);
      last = u;
      gap = 0;
    } else {
      gap++;
    }
  }
  if (first < 0) return { lead: along, trail: along, worst: along, along };
  return { lead: first, trail: along - 1 - last, worst, along };
}

const driver = await launchChromeDriver();
const failures = [];
let checked = 0;
try {
  for (const page of payload.pages) {
    const fail = (msg) => failures.push(page.name + ': ' + msg);
    const play = await driver.evalOnPage(page.html, PLAY);
    if (play.error) { fail(play.error); continue; }
    if (play.chars < 40) fail('the cue is not on screen (' + play.chars + ' glyphs)');
    if (play.bands.length < 2) fail('the cue should wrap onto a second line (' + play.bands.length + ' lines)');
    // Blink clips the glyph ink of any text a live CSS highlight covers (BUG-3776).
    if (play.painted) fail('the engine still paints the cue highlight (' + play.painted + ' ranges)');
    for (const band of play.bands) {
      const g = lineGaps(await driver.capture(band.rect), play.vertical);
      // The lane ends at the ink of line-final punctuation (。 sits in the first half of its box),
      // so the line may stop up to half an em early; anywhere else a gap is a break.
      if (g.lead > 3 || g.worst > 3 || g.trail > 0.5 * play.em) {
        fail('the line breaks along 「' + band.text + '」 (' + g.along + ' px): lead ' + g.lead +
          ' px, longest inner gap ' + g.worst + ' px, trail ' + g.trail + ' px');
      }
    }
    console.log(page.name + ': ' + play.bands.length + ' lines');
    checked++;
  }
} finally {
  driver.close();
}
if (failures.length) {
  console.log('FAIL\n' + failures.join('\n'));
  process.exit(1);
}
console.log('PASS ' + checked + ' e-ink pages');
