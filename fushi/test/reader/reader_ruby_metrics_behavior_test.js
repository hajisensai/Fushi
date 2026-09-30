// BUG-2779 behavior test: the WebKit ruby metrics script turns the measured font
// geometry into --fushi-ruby-pull.
//
// Root cause: the Apple ruby rule pulled annotations toward the base by a fixed
// -0.2em, calibrated on Hiragino whose content area is ~1em. With Klee One
// (ascent + descent = 1.45em) the annotation sat 8.3px (ink) away from its own
// column on iOS and hugged the previous one. The fix measures a real <ruby> in the
// page and writes the gap as a multiple of the annotation font size.
//
// BUG-2810: the probe must only trust annotation / base boxes laid out as ONE
// fragment — a page-top annotation split across two columns reports the union of
// both pages and clamped the pull to 1.5 (see the cases at the end).
//
// Executes kReaderRubyMetricsJs verbatim (extracted from
// reader_ruby_metrics_script.dart) on a fake DOM whose rects are the ones measured
// on the iOS 26.5 simulator (22px body, 9.9px annotations).
//
// Run: node fushi/test/reader/reader_ruby_metrics_behavior_test.js
// (driven from reader_ruby_metrics_script_test.dart inside `flutter test`).
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dart = fs.readFileSync(
  path.resolve(__dirname, '../../lib/src/reader/reader_ruby_metrics_script.dart'),
  'utf8',
);
const m = dart.match(/kReaderRubyMetricsJs = r'''([\s\S]*?)''';/);
assert.ok(m, 'kReaderRubyMetricsJs not found');
const script = m[1];

// One fake <ruby>. `rtRects` / `baseRects` are what getClientRects() returns, so a
// ruby whose annotation was split across two columns (BUG-2810) has two rt rects.
function makeRuby(spec, opts) {
  const rt = {
    nodeType: 1, tagName: 'RT',
    getClientRects: () => spec.rtRects,
  };
  const rtText = { nodeType: 3, nodeValue: 'まれ', parentNode: rt };
  rt.childNodes = [rtText];
  rt.closest = (s) => (s === 'rt, rp' ? rt : null);
  const baseText = { nodeType: 3, nodeValue: spec.baseText || '稀', baseRects: spec.baseRects };
  const ruby = {
    nodeType: 1, tagName: 'RUBY',
    querySelector: (s) => (s === 'rt' ? rt : null),
    closest: () => null,
  };
  rt.parentNode = ruby;
  // BUG-2806: the audiobook follow highlight wraps the base text in a span INSIDE
  // the ruby; the probe must still find it.
  if (spec.wrappedBase) {
    const wrapper = { nodeType: 1, tagName: 'SPAN', childNodes: [baseText], parentNode: ruby, closest: () => null };
    baseText.parentNode = wrapper;
    ruby.childNodes = [wrapper, rt];
  } else {
    baseText.parentNode = ruby;
    ruby.childNodes = [baseText, rt];
  }
  return { ruby, rt, baseText, fs: opts.fs, rfs: opts.rfs };
}

function run(opts) {
  const props = {};
  const specs = opts.rubies || [{
    wrappedBase: opts.wrappedBase,
    rtRects: [opts.rtRect],
    baseRects: [opts.baseRect],
  }];
  const rubies = specs.map((spec) => makeRuby(spec, opts));
  const measured = [];
  const styles = new Map();
  for (const r of rubies) {
    styles.set(r.ruby, { fontSize: opts.fs + 'px', writingMode: opts.wm, fontStyle: 'normal', fontWeight: '400', fontFamily: 'X' });
    styles.set(r.rt, { fontSize: opts.rfs + 'px', writingMode: opts.wm, fontStyle: 'normal', fontWeight: '400', fontFamily: 'X' });
  }
  const root = {
    style: { setProperty: (k, v) => { props[k] = v; } },
  };
  const rafQueue = [];
  const sandbox = {
    window: {},
    document: {
      documentElement: root,
      body: { getElementsByTagName: () => (opts.noRuby ? [] : rubies.map((r) => r.ruby)) },
      createRange: () => {
        const range = {
          setStart(n, i) { range.node = n; range.start = i; },
          setEnd(n, i) {
            assert.strictEqual(n, range.node, 'range must stay inside one text node');
            range.end = i;
          },
          getClientRects() {
            const r = rubies.find((x) => x.baseText === range.node);
            assert.ok(r, 'must measure a ruby base text node');
            measured.push(range.node.nodeValue.slice(range.start, range.end));
            return range.node.baseRects;
          },
        };
        return range;
      },
      createElement: () => ({
        getContext: () => ({
          font: '',
          measureText: function() {
            const size = parseFloat(this.font.split(' ')[2]);
            const k = size / opts.fs;
            return {
              fontBoundingBoxAscent: opts.canvas.ascent * k,
              fontBoundingBoxDescent: opts.canvas.descent * k,
              actualBoundingBoxAscent: opts.canvas.inkAscent * k,
              actualBoundingBoxDescent: opts.canvas.inkDescent * k,
            };
          },
        }),
      }),
      getElementById: () => null,
      fonts: null,
      createTreeWalker: (root) => {
        const texts = [];
        (function walk(n) {
          if (n.nodeType === 3) { texts.push(n); return; }
          (n.childNodes || []).forEach(walk);
        })(root);
        let i = 0;
        return { nextNode: () => texts[i++] || null };
      },
    },
    NodeFilter: { SHOW_TEXT: 4 },
    getComputedStyle: (el) => {
      if (el === root) return { getPropertyValue: (k) => (k === '--fushi-ruby-snap' ? (opts.snap === false ? '' : ' 1') : '') };
      return styles.get(el);
    },
    requestAnimationFrame: (fn) => rafQueue.push(fn),
    isFinite,
    Math,
  };
  vm.createContext(sandbox);
  vm.runInContext(script, sandbox);
  while (rafQueue.length) rafQueue.shift()();
  if (opts.measured) opts.measured.push(...measured);
  return props['--fushi-ruby-pull'];
}

const klee = { ascent: 26, descent: 7, inkAscent: 17.484375, inkDescent: 1.796875 };
const hira = { ascent: 20, descent: 3, inkAscent: 18.421875, inkDescent: 1.6875 };

// Vertical, Klee One: base content area 33px, rt box 15px (simulator rects).
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 33, height: 22 }, rtRect: { width: 15, height: 22 },
}), '0.813', 'Klee One vertical: (5.5 + 2.55) / 9.9');

// BUG-2806: base text wrapped by the audiobook follow highlight inside the ruby.
assert.strictEqual(run({
  wrappedBase: true, wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 33, height: 22 }, rtRect: { width: 15, height: 22 },
}), '0.813', 'base text inside a highlight wrapper is still measured');

// Vertical, Hiragino: stays at the legacy ~0.1 (default of the CSS var).
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: hira,
  baseRect: { width: 23, height: 22 }, rtRect: { width: 11, height: 22 },
}), '0.106', 'Hiragino vertical keeps the BUG-2724 calibration');

// Horizontal uses canvas ink centre for the em box: Klee pulls far more than Hiragino.
const hk = Number(run({
  wm: 'horizontal-tb', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 22, height: 33 }, rtRect: { width: 22, height: 15 },
}));
const hh = Number(run({
  wm: 'horizontal-tb', fs: 22, rfs: 9.9, canvas: hira,
  baseRect: { width: 22, height: 23 }, rtRect: { width: 22, height: 11 },
}));
assert.ok(hk > 0.7 && hk < 1.0, 'Klee One horizontal pull ' + hk);
assert.ok(hh > 0.05 && hh < 0.2, 'Hiragino horizontal pull ' + hh);

// No snap marker (Blink CSS) or no ruby in the chapter → nothing written.
assert.strictEqual(run({
  snap: false, wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 33, height: 22 }, rtRect: { width: 15, height: 22 },
}), undefined, 'without --fushi-ruby-snap the script must stay inert');
assert.strictEqual(run({
  noRuby: true, wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 33, height: 22 }, rtRect: { width: 15, height: 22 },
}), undefined, 'no ruby → keep the CSS default');

// BUG-2810: in paginated multicol the annotation of a ruby on a page's first line
// can stick out past the column top and get split into the previous column. Its
// rt then has two client rects and the bounding box is the union of both pages
// (iOS simulator, real Oregairu chapter at 42px: 385.9 x 818). Measuring that
// clamped the pull to 1.5 and pushed every annotation of the chapter into its
// base glyphs. The split ruby must be skipped and the next one measured.
// Rects below are the simulator's at 42px (rt 18.9px): base 62, whole rt 28.
const split = { rtRects: [{ width: 7, height: 42 }, { width: 21, height: 42 }], baseRects: [{ width: 62, height: 42 }] };
const whole = { rtRects: [{ width: 28, height: 42 }], baseRects: [{ width: 62, height: 42 }] };
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 42, rfs: 18.9, canvas: klee, rubies: [split, whole],
}), '0.770', 'a column-split annotation is skipped; the next ruby gives (10 + 4.55) / 18.9');
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 42, rfs: 18.9, canvas: klee, rubies: [split, split],
}), undefined, 'every candidate split → keep the previous value instead of writing a union');

// A base whose Range is not one box is skipped the same way.
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 42, rfs: 18.9, canvas: klee,
  rubies: [{ rtRects: whole.rtRects, baseRects: [{ width: 62, height: 20 }, { width: 62, height: 22 }] }, whole],
}), '0.770', 'a base split into two boxes is skipped');

// Only the first non-blank character of the base is measured (content area is the
// same for every glyph of the font); a leading surrogate pair stays whole.
const measured = [];
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 42, rfs: 18.9, canvas: klee, measured,
  rubies: [{ ...whole, baseText: '\n　平塚' }],
}), '0.770');
run({
  wm: 'vertical-rl', fs: 42, rfs: 18.9, canvas: klee, measured,
  rubies: [{ ...whole, baseText: '\u{20BB7}野' }],
});
assert.deepStrictEqual(measured, ['平', '\u{20BB7}'], 'first non-blank code point of the base');

console.log('all assertions passed');
