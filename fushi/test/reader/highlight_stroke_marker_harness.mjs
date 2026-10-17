// Highlight stroke styles (user 2026-10-15: "highlight bars as a setting, users pick a style",
// "every highlight must be customisable"). Runs the generated production reader CSS (favourite =
// marker, lookup = fluo, audiobook = rough, search = tape) + engine shell (paginated / continuous
// / VN) + the selection script (window.__fushiLanes) in real Chrome, and checks the SVG strokes
// the lane layer paints instead of 1em lanes for each of the four highlight kinds. Only the
// Flutter bridge is replaced by a recorder.
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
  const rubyOf = (base) => Array.from(root().querySelectorAll('ruby'))
    .find((r) => textNodes(r).map((n) => n.data).join('') === base);
  const vertical = getComputedStyle(document.body).writingMode.indexOf('vertical') === 0;
  const em = parseFloat(getComputedStyle(root().querySelector('p')).fontSize);
  const thick = (r) => vertical ? r.width : r.height;
  const mid = (r) => vertical ? r.left + r.width / 2 : r.top + r.height / 2;
  const span = (r) => vertical ? [r.top, r.bottom] : [r.left, r.right];
  const group = (name) => document.querySelector('fushi-hl-lanes-group[data-hl-group="' + name + '"]');
  const strokes = (name) => Array.from(group(name).querySelectorAll('svg.fushi-mark-ink path'))
    .map((p) => {
      const b = p.getBoundingClientRect();
      const half = (parseFloat(p.getAttribute('stroke-width')) || 0) / 2;
      return new DOMRect(b.left - half, b.top - half, b.width + 2 * half, b.height + 2 * half);
    }).filter((b) => b.width > 0.5 && b.height > 0.5);
  const ink = (name) => group(name).querySelector('svg.fushi-mark-ink');
  const classicLanes = (name) => group(name).querySelectorAll('fushi-hl-lane').length;
  const overlap = (a, b) => Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
    Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  const setVar = async (name, value) => {
    document.documentElement.style.setProperty(name, value);
    window.__fushiLanes.repaint();
    await frames();
  };
  const cs = getComputedStyle(document.documentElement);
  const styleOf = (kind) => cs.getPropertyValue('--fushi-mark-' + kind + '-style').trim();
  // BUG-3506: every stroke lies inside its own svg box. WebKit (vertical writing) gets the repaint
  // area of overflow:visible content wrong — strokes painted outside a 1x1 svg stopped updating on
  // screen (and never showed in vertical continuous mode) even though the DOM was right.
  const contained = (name, label) => {
    const svgs = Array.from(group(name).querySelectorAll('svg.fushi-mark-ink'));
    for (const s of svgs) {
      const box = s.getBoundingClientRect();
      ok(box.width > 1 && box.height > 1, label + ': the stroke svg box is the stroke bounds (' +
        box.width.toFixed(1) + 'x' + box.height.toFixed(1) + ')');
      for (const p of s.querySelectorAll('path')) {
        const b = p.getBoundingClientRect();
        if (b.width <= 0.5 || b.height <= 0.5) continue;
        const half = (parseFloat(p.getAttribute('stroke-width')) || 0) / 2;
        ok(b.left - half >= box.left - 0.5 && b.right + half <= box.right + 0.5 &&
          b.top - half >= box.top - 0.5 && b.bottom + half <= box.bottom + 0.5,
          label + ': a stroke stays inside its svg box, not in the overflow area');
      }
    }
  };
  // Every text box of the range sits under a stroke about one character high.
  const covers = (name, rects, label) => {
    const bb = strokes(name);
    ok(bb.length > 0, label + ': strokes painted');
    ok(classicLanes(name) === 0, label + ': no classic lane');
    contained(name, label);
    for (const r of rects.filter((x) => x.width > 0.5 && x.height > 0.5)) {
      const hit = bb.find((b) => Math.abs(mid(b) - mid(r)) <= 0.25 * em &&
        span(b)[0] <= span(r)[0] + 1 && span(b)[1] >= span(r)[1] - 1);
      ok(!!hit, label + ': a stroke covers the text box at ' + Math.round(mid(r)));
      // Stroke styles may exceed one character height (user 2026-10-16): at least the
      // glyph, at most the widest natural thickness (washi tape 1.45em) plus jitter.
      if (hit) ok(thick(hit) >= em * 0.9 && thick(hit) <= em * 1.6,
        label + ': stroke between one character and the widest natural thickness (' + thick(hit).toFixed(1) + ' vs ' + em + ')');
    }
  };

  ok(styleOf('favorite') === 'marker' && styleOf('lookup') === 'fluo' &&
    styleOf('audio') === 'rough' && styleOf('search') === 'tape',
    'the reader stylesheet carries one style per kind');

  // ── favourites ──
  const fav = rangeOf('気味に笑った');
  const ruby = rubyOf('烏滸');
  ok(!!fav && !!ruby, 'favourite targets exist');
  CSS.highlights.set('fushi-hl-yellow', new Highlight(fav));
  ruby.classList.add('fushi-hl-pink-ruby-active');
  await frames();
  covers('fushi-hl-yellow', Array.from(fav.getClientRects()), 'favourite');
  // Path boxes ignore clipping: the svg must not clip its strokes (UA default overflow:hidden).
  const svg = ink('fushi-hl-yellow');
  ok(!!svg && getComputedStyle(svg).overflow === 'visible' && getComputedStyle(svg).position === 'absolute',
    'the stroke svg does not clip its strokes');
  // A 0x0 outer svg is not rendered at all (SVG spec) — the reader's generic image rule
  // (svg { width/height: 100% }) inside the 0-size lane host would make it 0x0.
  const svgBox = svg ? svg.getBoundingClientRect() : { width: 0, height: 0 };
  ok(svgBox.width > 0 && svgBox.height > 0, 'the stroke svg has a non-zero viewport (' + svgBox.width + 'x' + svgBox.height + ')');

  const rt = ruby.querySelector('rt').getBoundingClientRect();
  const rtArea = rt.width * rt.height;
  const pink = strokes('fushi-hl-pink');
  ok(pink.length > 0, 'the ruby favourite gets strokes');
  const coverOff = Math.max(...pink.map((b) => overlap(b, rt)));
  ok(getComputedStyle(ruby).textDecorationLine === 'none', 'favourite stroke styles draw no underline');

  const before = group('fushi-hl-yellow').__fushiInk;
  window.__fushiLanes.repaint();
  await frames();
  ok(group('fushi-hl-yellow').__fushiInk === before, 'a repaint draws the very same stroke (no jitter on page turns)');

  await setVar('--fushi-mark-favorite-cover-ruby', '1');
  const coverOn = Math.max(...strokes('fushi-hl-pink').map((b) => overlap(b, rt)));
  ok(coverOn > rtArea * 0.6 && coverOn > coverOff + rtArea * 0.25,
    'cover-ruby extends the stroke over the furigana (' + (coverOff / rtArea).toFixed(2) + ' -> ' + (coverOn / rtArea).toFixed(2) + ')');
  await setVar('--fushi-mark-favorite-cover-ruby', '0');

  for (const s of ['marker', 'fluo', 'rough', 'under', 'crayon', 'tape']) {
    await setVar('--fushi-mark-favorite-style', s);
    const bb = strokes('fushi-hl-yellow');
    ok(bb.length > 0 && bb.some((b) => b.width > 2 && b.height > 2), s + ': paints a visible stroke');
    ok(classicLanes('fushi-hl-yellow') === 0, s + ': no classic lane');
    // Widest stroke settings: thickness x2 + covering the furigana.
    await setVar('--fushi-mark-favorite-thickness', '2');
    await setVar('--fushi-mark-favorite-cover-ruby', '1');
    contained('fushi-hl-yellow', s + ' (thickest, covering furigana)');
    contained('fushi-hl-pink', s + ' ruby (thickest, covering furigana)');
    document.documentElement.style.removeProperty('--fushi-mark-favorite-thickness');
    await setVar('--fushi-mark-favorite-cover-ruby', '0');
  }
  await setVar('--fushi-mark-favorite-style', 'marker');

  // A book paragraph with its own background (BUG-3421): the lane layer moves into that paragraph,
  // and the stroke style must follow it there (with document-unique SVG ids).
  const favP = fav.startContainer.parentElement.closest('p');
  favP.style.backgroundColor = 'rgb(240, 230, 210)';
  window.__fushiLanes.repaint();
  await frames();
  const bdGroup = favP.querySelector(':scope > fushi-hl-lanes > fushi-hl-lanes-group[data-hl-group="fushi-hl-yellow"]');
  ok(!!bdGroup && bdGroup.querySelectorAll('svg.fushi-mark-ink path').length > 0 && bdGroup.querySelectorAll('fushi-hl-lane').length === 0,
    'a stroke inside a book-coloured paragraph is painted into that paragraph\'s own layer');
  const ids = Array.from(document.querySelectorAll('svg.fushi-mark-ink [id]')).map((e) => e.id);
  ok(new Set(ids).size === ids.length, 'stroke SVG ids stay unique across lane layers');
  favP.style.backgroundColor = '';
  window.__fushiLanes.repaint();
  await frames();
  ok(!favP.querySelector(':scope > fushi-hl-lanes'), 'the paragraph layer is removed once its background is gone');

  // The sweep pacing comes from Dart (FushiMotion tokens) through the stylesheet.
  const sweepMs = (n) => parseFloat(cs.getPropertyValue('--fushi-mark-sweep-' + n + '-ms'));
  ok(sweepMs('base') > 0 && sweepMs('per-em') > 0 && sweepMs('gap') > 0,
    'the reader stylesheet carries the sweep pacing');
  // Reduced motion / e-ink: Dart writes the pacing as 0 — a fresh favourite must not sweep.
  CSS.highlights.delete('fushi-hl-yellow');
  await frames();
  for (const n of ['base', 'per-em', 'gap']) document.documentElement.style.setProperty('--fushi-mark-sweep-' + n + '-ms', '0');
  window.__fushiLanes.markFresh([fav], []);
  CSS.highlights.set('fushi-hl-yellow', new Highlight(fav));
  await frames();
  ok(strokes('fushi-hl-yellow').length > 0 && !group('fushi-hl-yellow').querySelector('clipPath animate'),
    'with motion off the fresh favourite is painted without a sweep');
  for (const n of ['base', 'per-em', 'gap']) document.documentElement.style.removeProperty('--fushi-mark-sweep-' + n + '-ms');

  // Same order as HighlightBridge: register the fresh lines, then write CSS.highlights.
  CSS.highlights.delete('fushi-hl-yellow');
  await frames();
  window.__fushiLanes.markFresh([fav], []);
  CSS.highlights.set('fushi-hl-yellow', new Highlight(fav));
  await frames();
  ok(!!group('fushi-hl-yellow').querySelector('clipPath animate'), 'a freshly added favourite sweeps in');
  const sweeping = ink('fushi-hl-yellow');
  window.__fushiLanes.repaint();
  await frames();
  ok(ink('fushi-hl-yellow') === sweeping, 'a repaint keeps the running sweep (the stroke DOM is not rebuilt)');
  window.__fushiLanes.markFresh([], []);
  CSS.highlights.set('fushi-hl-yellow', new Highlight(fav));
  await frames();
  ok(ink('fushi-hl-yellow') === sweeping, 're-applying the same favourites never replays the sweep');

  // Lines sweep in reading order (user 2026-10-16): vertical-rl right to left, horizontal top to bottom.
  const longRange = (() => {
    for (const n of textNodes(root())) {
      if (n.data.indexOf('窓の外') >= 0) { const r = document.createRange(); r.selectNodeContents(n); return r; }
    }
    return null;
  })();
  CSS.highlights.delete('fushi-hl-blue');
  await frames();
  window.__fushiLanes.markFresh([longRange], []);
  CSS.highlights.set('fushi-hl-blue', new Highlight(longRange));
  await frames();
  const order = Array.from(group('fushi-hl-blue').querySelectorAll('clipPath rect'))
    .map((r) => ({ begin: parseFloat(r.querySelector('animate').getAttribute('begin')),
      pos: vertical ? parseFloat(r.getAttribute('x')) : parseFloat(r.getAttribute('y')) }))
    .sort((a, b) => a.begin - b.begin);
  ok(order.length > 0, 'the long favourite sweeps in');
  for (let i = 1; i < order.length; i++) {
    ok(vertical ? order[i].pos < order[i - 1].pos : order[i].pos > order[i - 1].pos,
      'line ' + i + ' sweeps after the one before it in reading order');
  }
  CSS.highlights.delete('fushi-hl-blue');
  await frames();

  // ── lookup (text range + ruby class), search ──
  const look = rangeOf('がましい');
  CSS.highlights.set('fushi-selection', new Highlight(look));
  const search = rangeOf('窓の外');
  CSS.highlights.set('fushi-search', new Highlight(search));
  await frames();
  covers('fushi-selection', Array.from(look.getClientRects()), 'lookup');
  covers('fushi-search', Array.from(search.getClientRects()), 'search');
  ok(!!group('fushi-selection').querySelector('clipPath animate'), 'a new lookup selection sweeps in');
  ok(!!group('fushi-search').querySelector('clipPath animate'), 'a new search hit sweeps in');
  // Drag-extending the selection overlaps the previous frame: no replay (the stroke DOM is either
  // kept as is, or rebuilt without a sweep).
  const lookInk = ink('fushi-selection');
  const grown = look.cloneRange();
  grown.setEnd(look.endContainer, look.endOffset - 1);
  CSS.highlights.set('fushi-selection', new Highlight(grown));
  await frames();
  ok(ink('fushi-selection') !== lookInk, 'the shrunk selection is redrawn');
  ok(!group('fushi-selection').querySelector('clipPath animate'), 'changing the selection by dragging does not sweep again');
  const lookStill = ink('fushi-selection');
  window.__fushiLanes.repaint();
  await frames();
  ok(ink('fushi-selection') === lookStill, 'a repaint of the same selection does not sweep');
  // Jumping to another hit (no overlap with the last one) sweeps again.
  const search2 = rangeOf('がましい');
  CSS.highlights.set('fushi-search', new Highlight(search2));
  await frames();
  ok(!!group('fushi-search').querySelector('clipPath animate'), 'jumping to the next hit sweeps in');

  // ── audiobook current sentence ──
  const R = window.fushiReader;
  R.highlightSentenceAudioCue('c1', true);
  await frames();
  const active = () => Array.from(root().querySelectorAll('.fushi-sentence-audio-active, .fushi-sentence-audio-ruby-active'));
  const activeRects = () => {
    const out = [];
    for (const n of active().flatMap(textNodes)) {
      const r = document.createRange(); r.selectNodeContents(n);
      for (const x of r.getClientRects()) out.push(x);
    }
    return out;
  };
  covers('fushi-sentence-audio', activeRects(), 'audio');
  ok(!group('fushi-sentence-audio').querySelector('clipPath animate'), 'the first sentence of a chapter does not sweep');
  R.highlightSentenceAudioCue('c2', true);
  await frames();
  await new Promise((r) => setTimeout(r, 300));
  ok(!!group('fushi-sentence-audio').querySelector('clipPath animate'),
    'the next sentence sweeps in (and survives the scroll / re-anchor repaint)');
  const reading = ink('fushi-sentence-audio');
  window.__fushiLanes.repaint();
  await frames();
  ok(ink('fushi-sentence-audio') === reading, 'a repaint of the same sentence does not sweep again');
  // Audio background switched off (transparent colour) → nothing painted.
  document.documentElement.style.setProperty('--fushi-sentence-audio-background-color', 'transparent');
  window.__fushiLanes.repaint();
  await frames();
  ok(strokes('fushi-sentence-audio').length === 0, 'a transparent audio colour paints no stroke');

  // ── back to classic ──
  for (const k of ['favorite', 'lookup', 'audio', 'search']) document.documentElement.style.setProperty('--fushi-mark-' + k + '-style', 'classic');
  document.documentElement.style.removeProperty('--fushi-sentence-audio-background-color');
  window.__fushiLanes.repaint();
  await frames();
  for (const name of ['fushi-hl-yellow', 'fushi-selection', 'fushi-search', 'fushi-sentence-audio']) {
    ok(group(name).querySelector('svg') === null && classicLanes(name) > 0, name + ': classic goes back to 1em lanes');
  }
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
console.log('PASS ' + payload.pages.length + ' stroke pages, ' + total + ' checks');
