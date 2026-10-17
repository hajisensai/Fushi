// Highlight lanes (user 2026-10-15: every highlight is one character high). Runs the
// generated production reader CSS + engine shell (paginated / continuous / VN) + the
// selection script (window.__fushiLanes) in real Chrome, plays a ruby-heavy cue, puts
// a lookup (text + ruby class), a favourite and a search hit inside it, and checks the
// painted lane layer geometry. Only the Flutter bridge is replaced by a recorder.
import fs from 'node:fs';
import zlib from 'node:zlib';
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
      // A box ending on full-width closing punctuation (、。) may stop at that glyph's ink
      // (BUG-3518: checked exactly further down), 0.4em short of the box end.
      const hit = ls.find((l) => Math.abs(mid(l) - mid(r)) <= tol &&
        span(l)[0] <= span(r)[0] + 1 && span(l)[1] >= span(r)[1] - 1 - 0.45 * em);
      ok(!!hit, name + ': text box at ' + Math.round(mid(r)) + ' has a covering lane');
      // Pulled furigana: the lane gives way to the furigana ink (checked below), so it is
      // thinner than 1em and off-centre, but still at least half a character inside the box.
      if (hit && pulled) ok(thick(hit) <= Math.min(em, thick(r)) + 0.5 && thick(hit) >= 0.5 * em,
        name + ': lane gives way to pulled furigana but keeps >= 0.5em (' + thick(hit).toFixed(1) + ' vs ' + em + ')');
      // Furigana whose real ink reaches into the 1em band (wide kana such as ぶ) shaves the lane by
      // up to a pixel or two: not touching the furigana wins (checked below).
      else if (hit) ok(thick(hit) <= Math.min(em, thick(r)) + 0.5 && thick(hit) >= Math.min(em, thick(r)) - 0.1 * em,
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

  // BUG-3435 / F-JNEJVkuC: lanes hug the real glyph ink — Latin ascenders (f/l/t) and
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

  // BUG-3518: a lane ending on full-width closing punctuation stops at the punctuation ink
  // (first ~0.6 of its cell), not at the blank second half of the cell.
  const stopNode = textNodes(root()).find((n) => n.data.indexOf('。') >= 2);
  ok(!!stopNode, 'a text run with 。 exists');
  if (stopNode) {
    const k = stopNode.data.indexOf('。');
    const sr = document.createRange(); sr.setStart(stopNode, k - 2); sr.setEnd(stopNode, k + 1);
    const pr = document.createRange(); pr.setStart(stopNode, k); pr.setEnd(stopNode, k + 1);
    const cell = pr.getClientRects()[0];
    CSS.highlights.set('fushi-search', new Highlight(sr));
    await frames();
    const sl = lanes('fushi-search').filter((l) => Math.abs(mid(l) - mid(cell)) <= 0.5 * em &&
      span(l)[1] >= span(cell)[0] - 1);
    ok(sl.length === 1, 'one lane on the 。 line');
    const len = span(cell)[1] - span(cell)[0];
    if (sl.length === 1 && len >= 0.75 * em) {
      const end = span(sl[0])[1] - span(cell)[0];
      ok(end <= 0.6 * len + 0.5 && end >= 0.4 * len, 'lane ends at the 。 ink (' + end.toFixed(1) + ' of a ' +
        len.toFixed(1) + 'px cell)');
    }
    CSS.highlights.delete('fushi-search');
    await frames();
  }

  // BUG-3518: paginated pages are columns of the body multicol. Text that runs past the
  // column end (WebKit hanging punctuation; here a nowrap run, which Chrome overflows the
  // same way) must not drag its lane through the column gap into the next page.
  const bcs = getComputedStyle(document.body);
  const colW = parseFloat(bcs.columnWidth);
  if (colW > 0 && !document.querySelector('.fushi-vn-content')) {
    const step = colW + (parseFloat(bcs.columnGap) || 0);
    const box = document.body.getBoundingClientRect();
    const start = vertical
      ? box.top + parseFloat(bcs.paddingTop) - document.body.scrollTop
      : box.left + parseFloat(bcs.paddingLeft) - document.body.scrollLeft;
    const over = document.createElement('span');
    over.style.whiteSpace = 'nowrap';
    // Grow the run by its measured extent, not by an assumed 1em advance: without a CJK font
    // (Linux CI) あ falls back to a narrower glyph and a 1.5-column count stays inside it.
    over.textContent = 'あ'.repeat(Math.ceil(1.5 * colW / em));
    root().querySelector('p').appendChild(over);
    const extent = () => { const r = over.getBoundingClientRect(); return vertical ? r.height : r.width; };
    for (let i = 0; i < 8 && extent() < 1.5 * colW; i++) over.textContent += over.textContent;
    const or = document.createRange(); or.selectNodeContents(over.firstChild);
    CSS.highlights.set('fushi-search', new Highlight(or));
    await frames();
    const runEnd = Math.max(...Array.from(or.getClientRects()).map((r) => span(r)[1]));
    const runStart = Math.min(...Array.from(or.getClientRects()).map((r) => span(r)[0]));
    const k = Math.floor((runStart + 0.5 - start) / step);
    ok(runEnd > start + k * step + colW + 1, 'overflowing run reaches past its column end');
    const sl = lanes('fushi-search').filter((l) => Math.abs(mid(l) - mid(or.getClientRects()[0])) <= em);
    ok(sl.length > 0, 'overflowing run has a lane');
    for (const l of sl) {
      const lk = Math.floor((span(l)[0] + 0.5 - start) / step);
      ok(span(l)[1] <= start + lk * step + colW + 0.5, 'lane stays inside its column (ends ' +
        (span(l)[1] - (start + lk * step + colW)).toFixed(1) + 'px past the column end)');
    }
    CSS.highlights.delete('fushi-search');
    over.remove();
    await frames();
  }
  return { errors, checks };
})()`;

// BUG-3421: the book's own paragraph background (p.bd) must not hide the lanes. Lanes for
// text inside it go into a z-index:-1 layer of that element (the element is isolated), so
// they paint over its background and under its text. Checked on real pixels: inside every
// such lane no bare book background shows through, and the glyph ink is still on top.
// An inline background (span.mk) cannot be lifted this way (Chromium paints an inline's
// background with the line content, above any negative layer, isolated or not): its text
// stays in the paragraph's layer and the span gets no layer of its own. Known gap.
const BACKDROP = String.raw`(async () => {
  const errors = []; let checks = 0;
  const ok = (cond, msg) => { checks++; if (!cond) errors.push(msg); };
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 700));
  const root = () => document.querySelector('.fushi-vn-content') || document.body;
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
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const em = parseFloat(getComputedStyle(root().querySelector('p')).fontSize);
  const mid = (r) => vertical ? r.left + r.width / 2 : r.top + r.height / 2;
  const span = (r) => vertical ? [r.top, r.bottom] : [r.left, r.right];
  const tol = vertical ? 0.5 : 0.15 * em;

  window.fushiReader.highlightSentenceAudioCue('c2', true);
  const look = rangeOf('がましい');
  const search = rangeOf('窓の外');
  ok(!!look && !!search, 'targets exist');
  const h = new Highlight(look); h.priority = 1;
  CSS.highlights.set('fushi-selection', h);
  CSS.highlights.set('fushi-search', new Highlight(search));
  await frames();

  const bd = root().querySelector('p.bd');
  const mk = root().querySelector('span.mk');
  ok(!!bd && !!mk, 'book-background elements exist');
  ok(getComputedStyle(bd).backgroundColor === 'rgb(60, 200, 120)' &&
    getComputedStyle(mk).backgroundColor === 'rgb(240, 130, 60)', "the book's own backgrounds are kept");
  ok(bd.hasAttribute('data-fushi-hl-backdrop') && getComputedStyle(bd).isolation === 'isolate',
    'paragraph with a background is marked and isolated');
  const bdLayer = bd.querySelector(':scope > fushi-hl-lanes');
  const mkLayer = mk.querySelector(':scope > fushi-hl-lanes');
  ok(!!bdLayer && getComputedStyle(bdLayer).zIndex === '-1', 'paragraph has its own z-index:-1 lane layer');
  ok(!mkLayer && !mk.hasAttribute('data-fushi-hl-backdrop'), 'inline background gets no layer of its own');
  const inLayer = (layer, name) => layer ? Array.from(layer.querySelectorAll('fushi-hl-lane[data-hl="' + name + '"]')) : [];
  ok(inLayer(bdLayer, 'fushi-sentence-audio').length > 0, 'current-sentence lanes are in the paragraph layer');
  ok(inLayer(bdLayer, 'fushi-selection').length > 0, 'lookup lane is in the paragraph layer');
  ok(inLayer(bdLayer, 'fushi-search').length > 0, 'search lane (inside the inline background) is in the paragraph layer');
  const bodyLayer = document.body.querySelector(':scope > fushi-hl-lanes');
  ok(!!bodyLayer && bodyLayer.querySelectorAll('fushi-hl-lane[data-hl="fushi-selection"], fushi-hl-lane[data-hl="fushi-search"]').length === 0,
    'no lane for text inside a book background is left in the body layer');
  // Nested layers keep the same geometry: lookup / search lanes centred on their text, 1em thick.
  const covers = (lanes, rects, name) => {
    for (const r of rects) {
      if (r.width <= 0.5 || r.height <= 0.5) continue;
      const hit = lanes.map((l) => l.getBoundingClientRect()).find((l) => Math.abs(mid(l) - mid(r)) <= tol &&
        span(l)[0] <= span(r)[0] + 1 && span(l)[1] >= span(r)[1] - 1);
      ok(!!hit, name + ': text box at ' + Math.round(mid(r)) + ' has a covering lane');
    }
  };
  covers(inLayer(bdLayer, 'fushi-selection'), Array.from(look.getClientRects()), 'lookup');
  covers(inLayer(bdLayer, 'fushi-search'), Array.from(search.getClientRects()), 'search');

  // Pixel samples: the lane rect, inset along the line (rounded ends) and across it (edges).
  const samples = [];
  const vw = window.innerWidth, vh = window.innerHeight;
  const sample = (name, lane, bg) => {
    const r = lane.getBoundingClientRect();
    const along = 0.3 * em, across = 2;
    let x0 = r.left + (vertical ? across : along), x1 = r.right - (vertical ? across : along);
    let y0 = r.top + (vertical ? along : across), y1 = r.bottom - (vertical ? along : across);
    x0 = Math.max(0, Math.ceil(x0)); y0 = Math.max(0, Math.ceil(y0));
    x1 = Math.min(vw, Math.floor(x1)); y1 = Math.min(vh, Math.floor(y1));
    if (x1 - x0 < 4 || y1 - y0 < 4) return;
    samples.push({ name, bg, rect: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 } });
  };
  inLayer(bdLayer, 'fushi-sentence-audio').forEach((l) => sample('current-sentence', l, [60, 200, 120]));
  inLayer(bdLayer, 'fushi-selection').forEach((l) => sample('lookup', l, [60, 200, 120]));
  ok(samples.length >= 2, 'enough visible lanes to sample (' + samples.length + ')');
  return { errors, checks, samples };
})()`;

// BUG-3518: on WebKit the current sentence is a set of live Ranges in CSS.highlights instead
// of <span> wrappers (splitting a text node drops WebKit's kerning at the cut and shifts the
// rest of the line). Chrome runs that path here with window.__fushiSentenceAudioRangeMode.
const RANGE = String.raw`(async () => {
  const errors = []; let checks = 0;
  const ok = (cond, msg) => { checks++; if (!cond) errors.push(msg); };
  const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 700));
  const root = () => document.querySelector('.fushi-vn-content') || document.body;
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const em = parseFloat(getComputedStyle(root().querySelector('p')).fontSize);
  const mid = (r) => vertical ? r.left + r.width / 2 : r.top + r.height / 2;
  const span = (r) => vertical ? [r.top, r.bottom] : [r.left, r.right];
  const lanes = () => Array.from(document.querySelectorAll('fushi-hl-lane[data-hl="fushi-sentence-audio"]'))
    .map((l) => l.getBoundingClientRect());
  const wrappers = () => document.querySelectorAll('.fushi-sentence-audio-cue, .fushi-sentence-audio-active, .fushi-sentence-audio-ruby-active').length;
  const html = () => Array.from(root().querySelectorAll('p')).map((p) => p.innerHTML).join('|');
  ok(window.__fushiCueRanges && window.__fushiCueRanges.enabled(), 'range mode is on');
  const R = window.fushiReader;
  const clear = () => (R.clearSentenceAudioCue || R.clearSentenceAudioCuePresentation).call(R);
  ok(wrappers() === 0, 'no cue wrappers in the text after the cues are applied');
  // VN renders the screen holding the cue on the first call; take the baseline on that screen.
  R.highlightSentenceAudioCue('c2', true);
  await frames();
  clear();
  await frames();
  const before = html();
  R.highlightSentenceAudioCue('c2', true);
  await frames();
  const hl = CSS.highlights.get('fushi-sentence-audio');
  ok(!!hl && hl.size > 0, 'current sentence is registered as a CSS highlight');
  ok(wrappers() === 0, 'highlighting adds no wrappers or classes to the text');
  ok(html() === before, 'highlighting leaves the text DOM unchanged');
  const ls = lanes();
  ok(ls.length > 0, 'current sentence has lanes');
  if (hl) {
    for (const range of hl) {
      for (const r of range.getClientRects()) {
        if (r.width <= 0.5 || r.height <= 0.5) continue;
        const hit = ls.find((l) => Math.abs(mid(l) - mid(r)) <= 0.5 * em &&
          span(l)[0] <= span(r)[0] + 1 && span(l)[1] >= span(r)[1] - 1 - 0.45 * em);
        ok(!!hit, 'text box at ' + Math.round(mid(r)) + ' has a covering lane');
      }
    }
    const first = hl.values().next().value;
    if (first && typeof R.cueIdAtDomPoint === 'function') {
      const hit = R.cueIdAtDomPoint(first.startContainer, first.startOffset);
      ok(!!hit && JSON.parse(hit).id === 'c2', 'a point in the sentence resolves to its cue (' + hit + ')');
    }
  }
  clear();
  await frames();
  ok(!CSS.highlights.has('fushi-sentence-audio'), 'clearing the cue removes the highlight');
  ok(lanes().length === 0, 'clearing the cue removes its lanes');
  ok(html() === before, 'text DOM still unchanged after clearing');
  return { errors, checks };
})()`;

const CLEAR = String.raw`(async () => {
  const errors = []; let checks = 0;
  const ok = (cond, msg) => { checks++; if (!cond) errors.push(msg); };
  CSS.highlights.delete('fushi-selection');
  CSS.highlights.delete('fushi-search');
  const R = window.fushiReader;
  (R.clearSentenceAudioCue || R.clearSentenceAudioCuePresentation).call(R);
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  const root = document.querySelector('.fushi-vn-content') || document.body;
  ok(root.querySelectorAll('[data-fushi-hl-backdrop]').length === 0, 'backdrop marks go away with the highlights');
  ok(Array.from(document.querySelectorAll('fushi-hl-lanes')).every((l) => l.parentNode === document.body),
    'backdrop lane layers are removed from the book DOM');
  return { errors, checks };
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

const driver = await launchChromeDriver();
let total = 0;
let pixelSamples = 0;
const failures = [];
try {
  for (const page of payload.pages) {
    const res = await driver.evalOnPage(page.html, CHECK);
    total += res.checks;
    for (const e of res.errors) failures.push(page.name + ': ' + e);
  }
  for (const page of payload.rangePages || []) {
    const res = await driver.evalOnPage(page.html, RANGE);
    total += res.checks;
    for (const e of res.errors) failures.push(page.name + ': ' + e);
  }
  for (const page of payload.backdropPages || []) {
    const res = await driver.evalOnPage(page.html, BACKDROP);
    total += res.checks;
    for (const e of res.errors) failures.push(page.name + ': ' + e);
    for (const s of res.samples) {
      const img = decodePng(Buffer.from(await driver.capture(s.rect), 'base64'));
      let bare = 0, ink = 0;
      const n = img.w * img.h;
      for (let i = 0; i < n; i++) {
        const r = img.data[i * img.ch], g = img.data[i * img.ch + 1], b = img.data[i * img.ch + 2];
        if (Math.abs(r - s.bg[0]) + Math.abs(g - s.bg[1]) + Math.abs(b - s.bg[2]) <= 12) bare++;
        if (r + g + b < 3 * 90) ink++;
      }
      pixelSamples++;
      total += 2;
      if (bare / n > 0.05) {
        failures.push(page.name + ': ' + s.name + ' lane is hidden under the book background (' +
          (100 * bare / n).toFixed(1) + '% bare background pixels)');
      }
      if (ink / n < 0.03) {
        failures.push(page.name + ': ' + s.name + ' lane covers the text (' + (100 * ink / n).toFixed(1) + '% ink pixels)');
      }
    }
    const cleared = await driver.evalHere(CLEAR);
    total += cleared.checks;
    for (const e of cleared.errors) failures.push(page.name + ': ' + e);
  }
} finally {
  driver.close();
}
if (failures.length) {
  console.log(failures.join('\n'));
  process.exit(1);
}
console.log('PASS ' + payload.pages.length + ' lane pages, ' + (payload.rangePages || []).length +
  ' range-mode pages, ' + (payload.backdropPages || []).length +
  ' book-background pages, ' + pixelSamples + ' pixel samples, ' + total + ' checks');
