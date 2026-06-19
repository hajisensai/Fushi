// TODO-553 behavior test: paged-mode touch swipe must turn the page.
//
// Regression context: commit 890378f19 folded touch into the pointer drag state
// machine (the pointerdown gate changed from `e.pointerType !== 'mouse'` to
// `_hoshiReaderPointerPrimaryButton(e)`, which returns true for touch). In PAGED
// mode that routed touch into the native-text-start suppression path: a >6px
// pointermove cleared `hasStart`, and touchend was swallowed, so `onSwipe` never
// fired and the page never turned. This test EXECUTES the real reader event
// handlers (extracted verbatim from reader_hibiki_page.dart) against a fake DOM
// and asserts a paged-mode horizontal touch drag emits onSwipe. Reverting the
// TODO-553 fix turns this red.
//
// Run: node hibiki/test/reader/reader_paged_touch_swipe_behavior_test.js
// (also driven from reader_paged_touch_swipe_behavior_test.dart so it executes
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const readerPath = path.resolve(
  __dirname,
  '../../lib/src/pages/implementations/reader_hibiki_page.dart',
);
const source = fs.readFileSync(readerPath, 'utf8');

// Extract the self-contained handler slice: from the continuous-mode flag down
// to (but excluding) the non-left mouse seek listener. Every function the
// handlers call is declared inside this slice, so it runs standalone.
const sliceStart = source.indexOf('var hoshiContinuousMode = $continuousMode;');
assert.ok(sliceStart >= 0, 'missing handler slice start marker');
const sliceEndMarker = '// 非左键';
const sliceEnd = source.indexOf(sliceEndMarker, sliceStart);
assert.ok(sliceEnd > sliceStart, 'missing handler slice end marker');
const rawSlice = source.substring(sliceStart, sliceEnd);

function makeHarness(continuousMode) {
  const handlers = {};
  const swipes = [];
  const taps = [];

  const body = { writingMode: 'horizontal-tb' };
  const fakeElement = {
    tagName: 'P',
    src: null,
    closest() { return null; },
    setPointerCapture() {},
  };

  const documentElementClassList = {
    _set: new Set(),
    toggle(name, on) { if (on) { this._set.add(name); } else { this._set.delete(name); } },
  };

  const documentObj = {
    documentElement: { classList: documentElementClassList },
    head: { appendChild() {} },
    body,
    getElementById() { return null; },
    createElement() { return { id: '', textContent: '', appendChild() {} }; },
    elementFromPoint() { return fakeElement; },
    addEventListener(name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
    // No caretRangeFromPoint / caretPositionFromPoint: the body text under the
    // finger is a "text hit", so in paged mode _hoshiReaderMouseDragStartAllowed
    // returns false (native-text path), exactly like real plain reader text.
  };

  const windowObj = {
    hoshiReader: { isVertical() { return false; } },
    hoshiSelection: null,
    getSelection() { return { isCollapsed: true, removeAllRanges() {} }; },
    getComputedStyle() { return body; },
    scrollBy() {},
    flutter_inappwebview: {
      callHandler(name, a1) {
        if (name === 'onSwipe') { swipes.push(a1); }
        if (name === 'onTap') { taps.push(a1); }
      },
    },
  };

  const sandbox = {
    Node: { TEXT_NODE: 3 },
    Date,
    Math,
    URL,
    document: documentObj,
    window: windowObj,
    getComputedStyle: windowObj.getComputedStyle,
  };

  let prepared = rawSlice
    .replace(/\$continuousMode/g, continuousMode ? 'true' : 'false')
    .replace(/\$swipeDistThreshold/g, '72')
    .replace(/\$swipeFastDistThreshold/g, '36');
  prepared = '(function(){\n' + prepared + '\n})();';

  vm.createContext(sandbox);
  vm.runInContext(prepared, sandbox, { filename: 'reader-handlers.js' });

  function dispatch(name, evt) {
    const list = handlers[name] || [];
    for (const fn of list) { fn(evt); }
  }

  return { dispatch, swipes, taps };
}

function pointerEvt(type, x, y, button, buttons) {
  return {
    pointerType: type,
    pointerId: 1,
    button,
    buttons,
    clientX: x,
    clientY: y,
    target: null,
    preventDefault() {},
  };
}

function touchEvt(x, y) {
  const t = { clientX: x, clientY: y };
  return { touches: [t], changedTouches: [t], target: null, preventDefault() {} };
}

// Test 1: PAGED mode, leftward horizontal touch swipe -> onSwipe('left').
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 150, 300, -1, 1));
  h.dispatch('pointermove', pointerEvt('touch', 80, 300, -1, 1));
  h.dispatch('touchend', touchEvt(80, 300)); // dx = -120 (> 72)
  h.dispatch('pointerup', pointerEvt('touch', 80, 300, 0, 0));
  assert.deepStrictEqual(
    h.swipes, ['left'],
    'paged-mode horizontal touch drag must emit one onSwipe("left"); got '
      + JSON.stringify(h.swipes),
  );
})();

// Test 2: PAGED mode, rightward touch swipe -> onSwipe('right').
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 80, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(80, 300));
  h.dispatch('pointermove', pointerEvt('touch', 160, 300, -1, 1));
  h.dispatch('touchend', touchEvt(220, 300)); // dx = +140
  h.dispatch('pointerup', pointerEvt('touch', 220, 300, 0, 0));
  assert.deepStrictEqual(
    h.swipes, ['right'],
    'paged-mode rightward touch drag must emit onSwipe("right"); got '
      + JSON.stringify(h.swipes),
  );
})();

// Test 3: PAGED mode, small touch tap -> onTap, no swipe.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('touchend', touchEvt(203, 302));
  h.dispatch('pointerup', pointerEvt('touch', 203, 302, 0, 0));
  assert.deepStrictEqual(h.swipes, [], 'a touch tap must not page-turn');
  assert.deepStrictEqual(h.taps, [203], 'a touch tap must still report onTap');
})();

// Test 4: CONTINUOUS mode, vertical touch drag scrolls, never page-turns.
(function () {
  const h = makeHarness(true);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 200, 240, -1, 1));
  h.dispatch('pointermove', pointerEvt('touch', 200, 120, -1, 1));
  h.dispatch('touchend', touchEvt(200, 120));
  h.dispatch('pointerup', pointerEvt('touch', 200, 120, 0, 0));
  assert.deepStrictEqual(
    h.swipes, [],
    'continuous-mode touch drag must scroll, never page-turn via onSwipe',
  );
})();

console.log('reader_paged_touch_swipe_behavior_test.js: all assertions passed');
