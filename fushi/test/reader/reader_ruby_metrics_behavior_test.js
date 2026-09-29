// BUG-2779 behavior test: the WebKit ruby metrics script turns the measured font
// geometry into --fushi-ruby-pull.
//
// Root cause: the Apple ruby rule pulled annotations toward the base by a fixed
// -0.2em, calibrated on Hiragino whose content area is ~1em. With Klee One
// (ascent + descent = 1.45em) the annotation sat 8.3px (ink) away from its own
// column on iOS and hugged the previous one. The fix measures a real <ruby> in the
// page and writes the gap as a multiple of the annotation font size.
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

function run(opts) {
  const props = {};
  const rt = {
    nodeType: 1, tagName: 'RT',
    getBoundingClientRect: () => opts.rtRect,
  };
  const baseText = { nodeType: 3, nodeValue: '稀', nextSibling: null };
  const ruby = {
    nodeType: 1, tagName: 'RUBY', firstChild: baseText,
    querySelector: (s) => (s === 'rt' ? rt : null),
  };
  const styles = new Map([
    [ruby, { fontSize: opts.fs + 'px', writingMode: opts.wm, fontStyle: 'normal', fontWeight: '400', fontFamily: 'X' }],
    [rt, { fontSize: opts.rfs + 'px', writingMode: opts.wm, fontStyle: 'normal', fontWeight: '400', fontFamily: 'X' }],
  ]);
  const root = {
    style: { setProperty: (k, v) => { props[k] = v; } },
  };
  const rafQueue = [];
  const sandbox = {
    window: {},
    document: {
      documentElement: root,
      body: { getElementsByTagName: () => (opts.noRuby ? [] : [ruby]) },
      createRange: () => ({ selectNodeContents() {}, getBoundingClientRect: () => opts.baseRect }),
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
    },
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
  return props['--fushi-ruby-pull'];
}

const klee = { ascent: 26, descent: 7, inkAscent: 17.484375, inkDescent: 1.796875 };
const hira = { ascent: 20, descent: 3, inkAscent: 18.421875, inkDescent: 1.6875 };

// Vertical, Klee One: base content area 33px, rt box 15px (simulator rects).
assert.strictEqual(run({
  wm: 'vertical-rl', fs: 22, rfs: 9.9, canvas: klee,
  baseRect: { width: 33, height: 22 }, rtRect: { width: 15, height: 22 },
}), '0.813', 'Klee One vertical: (5.5 + 2.55) / 9.9');

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

console.log('all assertions passed');
