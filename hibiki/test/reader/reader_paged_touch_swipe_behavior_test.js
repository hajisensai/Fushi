// TODO-553 behavior test: paged-mode touch swipe must turn the page.
//
// Regression context: commit 890378f19 folded touch into the pointer drag state
// machine (the pointerdown gate changed from `e.pointerType !== 'mouse'` to
// `_hoshiReaderPointerPrimaryButton(e)`, which returns true for touch). In PAGED
// mode that routed touch into the native-text-start suppression path: a >6px
// pointermove cleared `hasStart`, and touchend was swallowed, so the
// touchstart/touchend -> _gestureEnd -> onSwipe page-turn never fired. This test
// EXECUTES the real reader event handlers (extracted verbatim from
// reader_hibiki_page.dart) against a fake DOM and asserts that a paged-mode
// horizontal touch drag emits onSwipe FROM the touchend path, while pointerup
// stays silent. Reverting the TODO-553 fix turns this red.
//
// Source-of-truth detail (the previous false-green): every onSwipe is tagged
// `<direction>@<dispatch event>`. The fake document exposes caretRangeFromPoint
// returning a TEXT_NODE range, so the finger is a real "text hit". In PAGED mode
// _hoshiReaderMouseDragStartAllowed then evaluates
// `return !_hoshiReaderCaretRangeAtPoint(...)` = `return !range` = FALSE -- the
// native-text-suppression path -- so the fix keeps touch OUT of the pointer drag
// machine and the swipe MUST come from touchend (`left@touchend`). The
// regression drives the pointer machine and (when it fires) emits from pointerup
// (`left@pointerup`); under this body-text caret it loses the swipe entirely
// (`[]`). Without the caret the helper returned null, `!null` = true, and BOTH
// versions emitted a bare `left`, so an assertion that ignored the source went
// green either way -- that was the masked regression.
//
// Run: node hibiki/test/reader/reader_paged_touch_swipe_behavior_test.js
// (also driven from reader_paged_touch_swipe_behavior_test.dart so it executes
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// TODO-589 batch8: reader setup script (_buildReaderSetupScript, which owns
// the full handler slice below) was extracted verbatim to
// reader_hibiki/webview.part.dart. The slice markers are unchanged, so the
// harness now reads the part file (the slice lives entirely inside it).
const readerPath = path.resolve(
  __dirname,
  '../../lib/src/pages/implementations/reader_hibiki/webview.part.dart',
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
  // Each onSwipe is recorded as `<direction>@<dispatch event type>` so the test
  // can prove WHICH path fired it. In paged mode the finger lands on body text,
  // so the fixed reader emits the swipe from touchend -> _gestureEnd (recorded
  // `left@touchend`) and pointerup stays silent. The 890378f19 regression
  // instead drives the pointer drag machine and would emit from pointerup
  // (`left@pointerup`) -- distinguishing the source is what catches the bug.
  const swipes = [];
  const taps = [];
  let currentDispatch = null;

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

  // A range whose startContainer is a real TEXT_NODE: models the finger landing
  // on actual reader body text. _hoshiReaderCaretRangeAtPoint returns it, so in
  // PAGED mode _hoshiReaderMouseDragStartAllowed evaluates
  // `return !_hoshiReaderCaretRangeAtPoint(...)` = `return !range` = FALSE
  // (the native-text-suppression path) -- exactly like real reader body text,
  // so paged-mode touch stays OUT of the pointer drag machine. WITHOUT this
  // caret the helper would return null, `!null` = true, and the 890378f19
  // regression would wrongly drive the pointer machine yet still emit a swipe
  // from pointerup, masking the bug (the original false-green).
  const bodyTextRange = {
    startContainer: { nodeType: 3 /* Node.TEXT_NODE */ },
  };

  const documentObj = {
    documentElement: { classList: documentElementClassList },
    head: { appendChild() {} },
    body,
    getElementById() { return null; },
    createElement() { return { id: '', textContent: '', appendChild() {} }; },
    elementFromPoint() { return fakeElement; },
    addEventListener(name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
    // The finger is on body text: browser hit testing resolves a caret range on
    // a TEXT_NODE. Provide caretRangeFromPoint (caretPositionFromPoint left
    // undefined so the helper takes this branch) returning that text range.
    caretRangeFromPoint() { return bodyTextRange; },
  };

  const windowObj = {
    hoshiReader: { isVertical() { return false; } },
    hoshiSelection: null,
    getSelection() { return { isCollapsed: true, removeAllRanges() {} }; },
    getComputedStyle() { return body; },
    scrollBy() {},
    flutter_inappwebview: {
      callHandler(name, a1) {
        // Tag every swipe with the event currently being dispatched so the test
        // can assert touchend (fix) vs pointerup (regression) as the source.
        if (name === 'onSwipe') { swipes.push(a1 + '@' + (currentDispatch || 'unknown')); }
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
    // TODO-806: [806-TAP] 探针门控用 Dart 注入期插值 ${DebugLogService.instance.enabled}，
    // 抽出的裸 JS 没替换会让 node 见到 `if (${...}) {` 语法报错。production 默认 off，
    // 这里固定替成 false（探针整段不进 JS），与默认行为一致、不影响 swipe 断言。
    .replace(/\$\{DebugLogService\.instance\.enabled\}/g, 'false')
    .replace(/\$continuousMode/g, continuousMode ? 'true' : 'false')
    // TODO-909: VN flags default false here (this harness exercises the paged
    // path); keeps the slice self-contained when VN tap-advance was added.
    .replace(/\$vnMode/g, 'false')
    .replace(/\$vnClickAdvance/g, 'false')
    .replace(/\$hoverAutoLookup/g, 'false')
    .replace(/\$swipeDistThreshold/g, '72')
    .replace(/\$swipeFastDistThreshold/g, '36');
  prepared = '(function(){\n' + prepared + '\n})();';

  vm.createContext(sandbox);
  vm.runInContext(prepared, sandbox, { filename: 'reader-handlers.js' });

  function dispatch(name, evt) {
    const list = handlers[name] || [];
    currentDispatch = name;
    try {
      for (const fn of list) { fn(evt); }
    } finally {
      currentDispatch = null;
    }
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

// Test 1: PAGED mode, leftward horizontal touch swipe over body text -> the
// page turn must come from touchend (the fixed path); pointerup must stay
// silent. Reverting the TODO-553 fix turns this red.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 150, 300, -1, 1));
  h.dispatch('pointermove', pointerEvt('touch', 80, 300, -1, 1));
  h.dispatch('touchend', touchEvt(80, 300)); // dx = -120 (> 72)
  h.dispatch('pointerup', pointerEvt('touch', 80, 300, 0, 0));
  // The page turn must come from the touchend path; pointerup must stay silent.
  // Reverting the fix makes touchend emit nothing (swipe lost to the pointer
  // machine's swallowed touchend), so this yields [] and turns red.
  assert.deepStrictEqual(
    h.swipes, ['left@touchend'],
    'paged-mode horizontal touch drag must emit exactly one onSwipe("left") '
      + 'from the touchend path (not pointerup); got ' + JSON.stringify(h.swipes),
  );
})();

// Test 2: PAGED mode, rightward touch swipe -> onSwipe('right') from touchend.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 80, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(80, 300));
  h.dispatch('pointermove', pointerEvt('touch', 160, 300, -1, 1));
  h.dispatch('touchend', touchEvt(220, 300)); // dx = +140
  h.dispatch('pointerup', pointerEvt('touch', 220, 300, 0, 0));
  assert.deepStrictEqual(
    h.swipes, ['right@touchend'],
    'paged-mode rightward touch drag must emit onSwipe("right") from touchend; '
      + 'got ' + JSON.stringify(h.swipes),
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

// TODO-971: PAGED mode, a 30px drift (below the 72px swipe threshold but above
// the old 20px tap upper-bound) must be treated as a TAP, not silently dropped.
// Pre-fix `_gestureEnd` had `else if (absDx < 20 && absDy < 20 && elapsed < 500)`
// for the tap branch, so a 20~72px drift hit neither swipe nor tap -> the word
// lookup was lost ("单词点不中"). The fix drops the 20px /
// 500ms gate: anything that did NOT trigger a page swipe is a tap.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 215, 305, -1, 1));
  h.dispatch('touchend', touchEvt(230, 308)); // dx = +30 (>20, <72), dy = +8
  h.dispatch('pointerup', pointerEvt('touch', 230, 308, 0, 0));
  assert.deepStrictEqual(
    h.swipes, [],
    'a 30px drift must NOT page-turn (below swipe threshold); got '
      + JSON.stringify(h.swipes),
  );
  assert.deepStrictEqual(
    h.taps, [230],
    'a 30px drift (no swipe) must be treated as a tap, not dropped; got '
      + JSON.stringify(h.taps),
  );
})();

// TODO-971 guard: a LARGE vertical drag (dy=120, above the 72px swipe distance)
// is a scroll/drag gesture, NOT a tap. The fix caps the tap window at the swipe
// distance threshold so continuous-mode scroll drags don't fire a spurious word
// lookup. (Vertical-dominant means absDx<absDy so the swipe branch never fires;
// without the cap this would wrongly emit onTap.)
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 205, 240, -1, 1));
  h.dispatch('touchend', touchEvt(208, 180)); // dx = +8, dy = -120 (>72)
  h.dispatch('pointerup', pointerEvt('touch', 208, 180, 0, 0));
  assert.deepStrictEqual(
    h.swipes, [], 'a vertical drag must not page-turn; got '
      + JSON.stringify(h.swipes),
  );
  assert.deepStrictEqual(
    h.taps, [],
    'a large (>72px) drag is a scroll, not a tap; must NOT emit onTap; got '
      + JSON.stringify(h.taps),
  );
})();

console.log('reader_paged_touch_swipe_behavior_test.js: all assertions passed');
