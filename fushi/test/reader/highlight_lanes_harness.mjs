// Highlight lanes (user 2026-10-15: every highlight is one character high). Runs the
// generated production reader CSS + engine shell (paginated / continuous / VN) + the
// selection script (window.__fushiLanes) in real Chrome, plays a ruby-heavy cue, puts
// a lookup (text + ruby class), a favourite and a search hit inside it, and checks the
// painted lane layer geometry. Only the Flutter bridge is replaced by a recorder.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The only argument is the temp payload file the Dart test just wrote.
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: S8707 path comes from the Dart test harness

const CHECK = String.raw`(async () => {
  const errors = []; let checks = 0;
  const ok = (cond, msg) => { checks++; if (!cond) errors.push(msg); };
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 700));
  // Apple CSS pages: pull the furigana deep into the base text box (what an off WebKit
  // --fushi-ruby-pull measurement does), so a centred 1em lane would run over the furigana ink.
  const pulled = getComputedStyle(document.documentElement).getPropertyValue('--fushi-ruby-snap').trim() === '1';
  if (pulled) {
    document.documentElement.style.setProperty('--fushi-ruby-pull', '0.5');
    await frames();
  }
  const root =() => document.querySelector('.fushi-vn-content') || document.body;
  const textNodes = (el) => {
    const out = []; const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) if (!n.parentElement.closest('rt, rp, fushi-hl-lanes')) out.push(n);
    return out;
  };
  const rangeOf = (str) => {
    for (const n of textNodes(root())) {
      const k = n.data.indexOf(str);
      if (k >= 0) { const r = document.createRange(); r.setStart(n, k); r.setEnd(n, k + str.length); return r; }
    }
    return null;
  };
  const rubyOf = (base) => Array.from(root().querySelectorAll('ruby'))
    .find((r) => textNodes(r).map((n) => n.data).join('') === base);
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const em = parseFloat(getComputedStyle(root().querySelector('p')).fontSize);
  const lanes = (name) => Array.from(document.querySelectorAll('fushi-hl-lane[data-hl="' + name + '"]'))
    .map((l) => l.getBoundingClientRect());
  const thick = (r) => vertical ? r.width : r.height;
  const mid = (r) => vertical ? r.left + r.width / 2 : r.top + r.height / 2;
  const span = (r) => vertical ? [r.top, r.bottom] : [r.left, r.right];
  const textRects = (nodes) => {
    const out = [];
    for (const n of nodes) {
      const r = document.createRange(); r.selectNodeContents(n);
      for (const x of r.getClientRects()) if (x.width > 0.5 && x.height > 0.5) out.push(x);
    }
    return out;
  };
  // Every text box must sit under one lane of the group: 1em thick (or the box when
  // thinner), centred within tol, covering the box along the line.
  const covered = (name, rects, tol) => {
    const ls = lanes(name);
    ok(ls.length > 0, name + ': has lanes');
    for (const r of rects) {
      const hit = ls.find((l) => Math.abs(mid(l) - mid(r)) <= tol &&
        span(l)[0] <= span(r)[0] + 1 && span(l)[1] >= span(r)[1] - 1);
      ok(!!hit, name + ': text box at ' + Math.round(mid(r)) + ' has a covering lane');
      // Pulled furigana: the lane gives way to the furigana ink (checked below), so it is
      // thinner than 1em and off-centre, but still at least half a character inside the box.
      if (hit && pulled) ok(thick(hit) <= Math.min(em, thick(r)) + 0.5 && thick(hit) >= 0.5 * em,
        name + ': lane gives way to pulled furigana but keeps >= 0.5em (' + thick(hit).toFixed(1) + ' vs ' + em + ')');
      else if (hit) ok(Math.abs(thick(hit) - Math.min(em, thick(r))) <= 0.5,
        name + ': lane is 1em thick (' + thick(hit).toFixed(1) + ' vs ' + em + ')');
    }
  };
  const tol = pulled ? 0.5 * em : vertical ? 0.5 : 0.15 * em;

  const R = window.fushiReader;
  R.highlightSentenceAudioCue('c2', true);
  await frames();
  const active = Array.from(root().querySelectorAll('.fushi-sentence-audio-active, .fushi-sentence-audio-ruby-active'));
  ok(active.length >= 3, 'cue wrapped into several pieces around the ruby (' + active.length + ')');
  const audioText = textRects(active.flatMap(textNodes));
  covered('fushi-sentence-audio', audioText, tol);
  // One lane per line: the ruby-split wrappers join, no gap fills left behind.
  const lines = new Set(audioText.map((r) => Math.round(mid(r) / 4)));
  ok(lanes('fushi-sentence-audio').length === lines.size,
    'one current-sentence lane per line (' + lanes('fushi-sentence-audio').length + ' lanes, ' + lines.size + ' lines)');
  ok(Array.from(root().querySelectorAll('.fushi-sentence-audio-cue')).every((e) => !e.style.boxShadow),
    'no gap-fill box-shadow on cue wrappers');

  const look = rangeOf('がましい');
  const ruby = rubyOf('烏滸');
  ok(!!look && !!ruby, 'lookup targets exist');
  ruby.classList.add('fushi-selection-ruby-active');
  const h = new Highlight(look); h.priority = 1;
  CSS.highlights.set('fushi-selection', h);
  const fav = rangeOf('気味に笑った');
  CSS.highlights.set('fushi-hl-yellow', new Highlight(fav));
  const search = rangeOf('窓の外');
  CSS.highlights.set('fushi-search', new Highlight(search));
  await frames();
  covered('fushi-selection', textRects([...textNodes(ruby)]).concat(Array.from(look.getClientRects())), tol);
  ok(lanes('fushi-selection').length === 1, 'ruby lookup and the following text join into one lookup lane');
  covered('fushi-hl-yellow', Array.from(fav.getClientRects()), tol);
  covered('fushi-search', Array.from(search.getClientRects()), tol);
  const order = Array.from(document.querySelectorAll('fushi-hl-lanes-group')).map((g) => g.getAttribute('data-hl-group'));
  ok(order[0] === 'fushi-sentence-audio' && order[order.length - 1] === 'fushi-selection' &&
    order.indexOf('fushi-hl-yellow') < order.indexOf('fushi-search'),
    'stacking: current sentence < favourites < search < lookup (' + order.join(',') + ')');
  const host = document.querySelector('fushi-hl-lanes');
  ok(host && host.parentNode === document.body && getComputedStyle(host).zIndex === '-1', 'lane layer is a z-index:-1 child of body');
  ok(getComputedStyle(document.body).isolation === 'isolate', 'body is the lanes stacking context');
  ok(getComputedStyle(ruby).backgroundColor === 'rgba(0, 0, 0, 0)' &&
    getComputedStyle(ruby).backgroundImage === 'none' &&
    active.every((el) => getComputedStyle(el).backgroundColor === 'rgba(0, 0, 0, 0)' &&
      getComputedStyle(el).backgroundImage === 'none'),
    'ruby-class / cue wrappers paint no full-box background of their own');

  // BUG-3417 / F-JNEJVkuC: lanes hug the real glyph ink — Latin ascenders (f/l/t) and
  // descenders (p/g/y) inside the lane — and never overlap furigana ink.
  const fontOf = (cs) => cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  // Pixel-scanned ink of a horizontal run relative to its alphabetic baseline (independent
  // of canvas measureText bounding boxes, which the lane code itself uses).
  const scanInk = (font, text, size) => {
    const c = document.createElement('canvas');
    c.width = Math.ceil(size * (text.length + 4)); c.height = Math.ceil(size * 4);
    const g = c.getContext('2d');
    g.font = font; g.textBaseline = 'alphabetic'; g.fillStyle = '#000';
    const base = Math.round(size * 2.5);
    g.fillText(text, size, base);
    const data = g.getImageData(0, 0, c.width, c.height).data;
    let top = -1, bottom = -1;
    for (let y = 0; y < c.height; y++) {
      for (let x = 0; x < c.width; x++) {
        if (data[(y * c.width + x) * 4 + 3] > 40) { if (top < 0) top = y; bottom = y + 1; break; }
      }
    }
    return { asc: base - top, desc: bottom - base };
  };
  const latinP = Array.from(root().querySelectorAll('p')).find((p) => p.textContent.indexOf('Flight') === 0);
  ok(!!latinP, 'latin paragraph rendered');
  if (latinP) {
    // Zero-size inline-block at the line start: its bottom edge is the alphabetic baseline
    // (inserted at runtime because VN rebuilds the paragraphs and drops empty spans).
    const marker = document.createElement('span');
    marker.className = 'fushi-bl';
    marker.style.cssText = 'display:inline-block;width:0;height:0';
    latinP.insertBefore(marker, latinP.firstChild);
    const lr = document.createRange(); lr.selectNodeContents(latinP);
    CSS.highlights.set('fushi-hl-green', new Highlight(lr));
    await frames();
    const pcs = getComputedStyle(latinP);
    const pem = parseFloat(pcs.fontSize);
    const latinText = textNodes(latinP).map((n) => n.data).join('');
    const ink = scanInk(fontOf(pcs), latinText, pem);
    ok(ink.asc > 0.5 * pem && ink.desc > 0.1 * pem, 'latin sample has ascenders and descenders (' + ink.asc + '/' + ink.desc + ')');
    const gl = lanes('fushi-hl-green');
    const boxes = textRects(textNodes(latinP));
    ok(gl.length > 0, 'latin paragraph has lanes');
    for (const l of gl) {
      const box = boxes.find((b) => Math.abs(mid(b) - mid(l)) <= 0.5 * pem);
      ok(!!box, 'latin lane sits on a text line');
      if (box) ok(vertical ? l.left >= box.left - 0.5 && l.right <= box.right + 0.5
        : l.top >= box.top - 0.5 && l.bottom <= box.bottom + 0.5, 'latin lane stays inside the text box');
      // Pulled furigana over "Tokyo" wins over the Latin ink on that line (checked below).
      if (!(pulled && vertical)) ok(thick(l) >= ink.asc + ink.desc - 1,
        'latin lane is as thick as the ink (' + thick(l).toFixed(1) + ' vs ' + (ink.asc + ink.desc) + ')');
    }
    if (!vertical) {
      ok(new Set(boxes.map((b) => Math.round(mid(b) / 4))).size === 1, 'latin paragraph is one line');
      const base = latinP.querySelector('.fushi-bl').getBoundingClientRect().bottom;
      for (const l of gl) {
        ok(l.top <= base - ink.asc + 0.5, 'latin lane covers the ascenders (lane top ' + (base - l.top).toFixed(1) +
          ' above baseline, ink ' + ink.asc + ')');
        ok(l.bottom >= base + ink.desc - 0.5, 'latin lane covers the descenders (lane bottom ' + (l.bottom - base).toFixed(1) +
          ' below baseline, ink ' + ink.desc + ')');
      }
    }
  }
  // Furigana ink per rt glyph: horizontal from the rt font box baseline and the scanned run ink;
  // vertical (upright, advance centred in the column) from each glyph's ink bounds.
  const rubyInk = [];
  for (const rt of root().querySelectorAll('rt')) {
    const cs = getComputedStyle(rt);
    const font = fontOf(cs);
    const size = parseFloat(cs.fontSize);
    for (const n of Array.from(rt.childNodes).filter((x) => x.nodeType === 3)) {
      const rg = document.createRange(); rg.selectNodeContents(n);
      const g = document.createElement('canvas').getContext('2d'); g.font = font;
      for (const r of rg.getClientRects()) {
        if (r.width < 0.5 || r.height < 0.5) continue;
        if (vertical) {
          let lo = Infinity, hi = -Infinity;
          for (const ch of n.data) {
            const m = g.measureText(ch);
            const c = r.left + r.width / 2;
            lo = Math.min(lo, c - m.width / 2 - m.actualBoundingBoxLeft);
            hi = Math.max(hi, c - m.width / 2 + m.actualBoundingBoxRight);
          }
          rubyInk.push({ lo, hi, a: r.top, b: r.bottom });
        } else {
          const m = g.measureText(n.data);
          const s = scanInk(font, n.data, size);
          const base = r.top + r.height * m.fontBoundingBoxAscent / (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent);
          rubyInk.push({ lo: base - s.asc, hi: base + s.desc, a: r.left, b: r.right });
        }
      }
    }
  }
  ok(rubyInk.length >= 5, 'furigana ink measured (' + rubyInk.length + ')');
  for (const l of document.querySelectorAll('fushi-hl-lane')) {
    const b = l.getBoundingClientRect();
    const lo = vertical ? b.left : b.top, hi = vertical ? b.right : b.bottom;
    const a = vertical ? b.top : b.left, z = vertical ? b.bottom : b.right;
    for (const k of rubyInk) {
      if (k.b <= a + 0.5 || k.a >= z - 0.5) continue;
      ok(hi <= k.lo + 0.5 || lo >= k.hi - 0.5, l.getAttribute('data-hl') + ': lane [' + lo.toFixed(1) + ', ' + hi.toFixed(1) +
        '] overlaps furigana ink [' + k.lo.toFixed(1) + ', ' + k.hi.toFixed(1) + ']');
    }
  }
  CSS.highlights.delete('fushi-hl-green');

  CSS.highlights.delete('fushi-selection');
  ruby.classList.remove('fushi-selection-ruby-active');
  (R.clearSentenceAudioCue || R.clearSentenceAudioCuePresentation).call(R);
  await frames();
  ok(lanes('fushi-selection').length === 0, 'lookup lanes go away with the lookup');
  ok(lanes('fushi-sentence-audio').length === 0, 'current-sentence lanes go away when the cue clears');
  ok(lanes('fushi-hl-yellow').length > 0, 'favourite lanes stay');
  return { errors, checks };
})()`;

const driver = await launchChromeDriver();
let total = 0;
const failures = [];
try {
  for (const page of payload.pages) {
    const res = await driver.evalOnPage(page.html, CHECK);
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
console.log('PASS ' + payload.pages.length + ' lane pages, ' + total + ' checks');
