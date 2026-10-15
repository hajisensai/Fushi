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
      if (hit) ok(Math.abs(thick(hit) - Math.min(em, thick(r))) <= 0.5,
        name + ': lane is 1em thick (' + thick(hit).toFixed(1) + ' vs ' + em + ')');
    }
  };
  const tol = vertical ? 0.5 : 0.15 * em;

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
