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
const sliceStart = source.indexOf('var hoshiContinuousMode = C.continuousMode;');
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

  // Controllable clock so tests can model gesture DURATION (hence velocity):
  // _gestureEnd computes `velocity = absDx / elapsed * 1000`. With the real Date
  // every synchronous dispatch has elapsed≈0 → velocity≈infinity, which would
  // make the fast-swipe path fire for any absDx>=fastDist and make a "slow short
  // drag = dead zone" case untestable. advance(ms) between touchstart and
  // touchend sets `elapsed`, so a slow drift stays below the 900px/s fast gate.
  let clockMs = 1000;
  function FakeDate() {}
  FakeDate.now = function () { return clockMs; };

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
    Date: FakeDate,
    Math,
    URL,
    document: documentObj,
    window: windowObj,
    getComputedStyle: windowObj.getComputedStyle,
  };

  // BUG-1140 第二阶段①：整段 setup 从「Dart 注入期插值」改成「运行时读 config」，
  // 于是这里不再需要一张字符串替身表——切片本身就是一段读 `C` 的代码，直接把
  // 同名 config 传进去即可（少一层「替身表漏一项就语法报错」的脆弱耦合）。
  // tapSlop 仍是 Dart 编译期常量插值（不随导航变化，故留在源码里），单独替换。
  const config = {
    continuousMode: !!continuousMode,
    // TODO-909: VN flags default false here (this harness exercises the paged
    // path); keeps the slice self-contained when VN tap-advance was added.
    vnMode: false,
    vnClickAdvance: false,
    hoverAutoLookup: false,
    swipeDistThreshold: 44,
    swipeFastDistThreshold: 22,
    scanNonJapaneseText: false,
    // TODO-806: [806-TAP] probe defaults off, matching production.
    debugLogging: false,
    // BUG-712 (1): the tap-gate mirror governs tap-to-lookup, orthogonal to the
    // paged swipe assertion, so neutral values are fine.
    highlightOnTap: true,
    showChrome: true,
  };
  const prepared = '(function(C){\n'
    + rawSlice.replace(/\$tapSlop/g, '10')
    + '\n})(' + JSON.stringify(config) + ');';

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

  function advance(ms) { clockMs += ms; }

  return { dispatch, swipes, taps, advance };
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
  h.dispatch('touchend', touchEvt(80, 300)); // dx = -120 (> 44)
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

// BUG-手机翻短了会查词: PAGED mode, a SLOW ~30px horizontal drift is a short,
// under-powered swipe -- it must be a DEAD ZONE (no page turn, and crucially NO
// word lookup). dx=30 is beyond the 10px tap-slop (so not a tap) yet below the
// 44px pure-distance swipe threshold, and the slow duration keeps velocity under
// the 900px/s fast gate. Pre-fix the tap box == the 72px swipe threshold, so this
// fell into the tap branch and fired a spurious lookup ("翻短了会查词").
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.advance(300); // slow drift: velocity = 30/300*1000 = 100px/s (< 900)
  h.dispatch('pointermove', pointerEvt('touch', 215, 305, -1, 1));
  h.dispatch('touchend', touchEvt(230, 308)); // dx = +30 (>28 slop, <44 dist), dy = +8
  h.dispatch('pointerup', pointerEvt('touch', 230, 308, 0, 0));
  assert.deepStrictEqual(
    h.swipes, [],
    'a slow 30px horizontal drift must NOT page-turn (below swipe distance); got '
      + JSON.stringify(h.swipes),
  );
  assert.deepStrictEqual(
    h.taps, [],
    'a slow 30px horizontal drift must be a DEAD ZONE, never a word lookup '
      + '(fixes 翻短了会查词); got ' + JSON.stringify(h.taps),
  );
})();

// A LARGE vertical drag (dy=120) is a scroll/drag gesture, NOT a tap: absDy
// exceeds the 10px tap-slop so the tap branch is skipped, and absDx<absDy keeps
// the swipe branch off -> dead zone, no spurious lookup.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('pointermove', pointerEvt('touch', 205, 240, -1, 1));
  h.dispatch('touchend', touchEvt(208, 180)); // dx = +8, dy = -120 (>28 slop)
  h.dispatch('pointerup', pointerEvt('touch', 208, 180, 0, 0));
  assert.deepStrictEqual(
    h.swipes, [], 'a vertical drag must not page-turn; got '
      + JSON.stringify(h.swipes),
  );
  assert.deepStrictEqual(
    h.taps, [],
    'a large vertical drag is a scroll, not a tap; must NOT emit onTap; got '
      + JSON.stringify(h.taps),
  );
})();

// BUG-手机翻页迟钝: a FAST short flick (dx=30 over 20ms -> 1500px/s) must turn the
// page via the fast-swipe gate (absDx>=22 fastDist AND velocity>=900), so users
// no longer have to drag a long way. dx=30 is below the 44px pure-distance
// threshold; only the fast path makes it a page turn.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.advance(20); // fast flick: velocity = 30/20*1000 = 1500px/s (>= 900)
  h.dispatch('pointermove', pointerEvt('touch', 185, 300, -1, 1));
  h.dispatch('touchend', touchEvt(170, 300)); // dx = -30 (leftward), dy = 0
  h.dispatch('pointerup', pointerEvt('touch', 170, 300, 0, 0));
  assert.deepStrictEqual(
    h.swipes, ['left@touchend'],
    'a fast 30px flick must page-turn via the fast gate; got '
      + JSON.stringify(h.swipes),
  );
})();

// Small finger jitter (dx=6, dy=4, within the 10px radial slop) is still a word
// lookup. The gate rejects scroll intent without requiring a perfectly motionless
// finger.
(function () {
  const h = makeHarness(false);
  h.dispatch('pointerdown', pointerEvt('touch', 200, 300, 0, 1));
  h.dispatch('touchstart', touchEvt(200, 300));
  h.advance(300); // slow, so the fast-swipe gate never fires
  h.dispatch('touchend', touchEvt(206, 304)); // radial distance ≈7.2px (<10)
  h.dispatch('pointerup', pointerEvt('touch', 206, 304, 0, 0));
  assert.deepStrictEqual(h.swipes, [], 'a small tap must not page-turn');
  assert.deepStrictEqual(
    h.taps, [206],
    'small (<10px) finger jitter must still report onTap (word lookup); got '
      + JSON.stringify(h.taps),
  );
})();

// BUG-iPhone-scroll-lookup: endpoint-only classification is insufficient.
// WKWebView can deliver touch events without the PointerEvent move sequence that
// previously happened to clear `hasStart`. A finger may move far enough to begin
// scrolling and then finish near its starting point; its final dx/dy looks like a
// tap even though the full path was a pan. Once any touchmove exceeds the 10px
// radial slop, releasing near the origin must not look up a word.
(function () {
  const h = makeHarness(true);
  h.dispatch('touchstart', touchEvt(200, 300));
  h.dispatch('touchmove', touchEvt(200, 284)); // 16px pan excursion (>10)
  h.dispatch('touchend', touchEvt(203, 298)); // ends near origin (old code: tap)
  assert.deepStrictEqual(h.swipes, [], 'continuous pan must not page-turn');
  assert.deepStrictEqual(
    h.taps, [],
    'a touch path that crossed pan slop must never become lookup just because '
      + 'touchend returned near its origin; got ' + JSON.stringify(h.taps),
  );
})();

console.log('reader_paged_touch_swipe_behavior_test.js: all assertions passed');
