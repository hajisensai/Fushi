// TODO-1387 behavior harness: executes the REAL document wheel handler inside
// hibiki/assets/popup/popup.js against synthetic touchpad / mouse wheel events and
// asserts the popup actually SCROLLS (real displacement), not merely that the
// tuning constants exist. Run by popup_wheel_scroll_behavior_test.dart via node;
// prints the success marker on the last line. Node-only; the Dart wrapper skips
// when node is absent.
//
// Root cause it locks: a precision touchpad reports deltaMode=PIXEL with a tiny
// fractional deltaY. After POPUP_WHEEL_PIXEL_FACTOR (0.24) and the zoom divide each
// frame is a fraction of a layout pixel; the pre-fix handler passed that fraction
// to scrollBy and lost it every frame (preventDefault killed native scroll, so the
// popup froze). The fix carries the sub-pixel remainder across events. It also
// stops touchpad horizontal jitter from dropping genuine vertical frames.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const popupSrc = fs.readFileSync(popupPath, 'utf8');

// A controllable monotonic clock so the idle-reset branch is deterministic.
let clockMs = 1000;

function makeContext() {
  const listeners = {};
  const documentElement = { style: { zoom: '1' } };
  const body = { nodeType: 1, style: {}, scrollHeight: 1000000, clientHeight: 400, scrollTop: 0 };
  let scrollY = 0;
  const noopEl = () => ({
    tagName: 'DIV', nodeType: 1, style: {}, dataset: {}, children: [],
    classList: { add() {}, remove() {}, contains() { return false; } },
    appendChild() {}, append() {}, addEventListener() {}, setAttribute() {},
    querySelector() { return null; },
  });
  const win = {
    devicePixelRatio: 1, innerWidth: 360, innerHeight: 640,
    scrollBy(opts) { scrollY += (opts && typeof opts.top === 'number') ? opts.top : 0; },
    get scrollY() { return scrollY; },
    getSelection() { return { toString() { return ''; }, removeAllRanges() {} }; },
    getComputedStyle() { return { overflowY: 'visible', fontSize: '15px' }; },
    flutter_inappwebview: { callHandler() { return Promise.resolve(true); } },
  };
  const document = {
    body, documentElement,
    addEventListener(type, handler) { (listeners[type] = listeners[type] || []).push(handler); },
    createElement() { return noopEl(); },
    createTextNode(t) { return { nodeType: 3, textContent: String(t) }; },
    createRange() { return { setStart() {}, setEnd() {} }; },
    caretRangeFromPoint() { return null; },
    querySelector() { return null; },
    getElementById() { return null; },
  };
  const context = {
    console, document, window: win,
    performance: { now() { return clockMs; } },
    getComputedStyle() { return { overflowY: 'visible', fontSize: '15px' }; },
    setTimeout() { return 0; }, clearTimeout() {}, requestAnimationFrame() { return 0; },
    Node: { TEXT_NODE: 3 },
    Image: class { addEventListener() {} set src(_v) {} },
    event: null,
  };
  context.globalThis = context;
  win.window = win;
  context.__listeners = listeners;
  context.__win = win;
  context.__setZoom = (z) => { documentElement.style.zoom = String(z); };
  return context;
}

function loadPopup() {
  const context = makeContext();
  vm.runInNewContext(popupSrc, context, { filename: popupPath });
  assert.ok(context.__listeners.wheel && context.__listeners.wheel.length,
    'popup.js must register a document wheel listener');
  return context;
}

// Dispatch one wheel event through the real handler. Returns whether the handler
// called preventDefault (it took over the scroll instead of leaving native).
function fireWheel(ctx, opts) {
  opts = opts || {};
  const deltaY = opts.deltaY, deltaX = opts.deltaX || 0;
  const deltaMode = opts.deltaMode || 0, ctrlKey = opts.ctrlKey || false;
  const target = ctx.document.body; // ancestor walk terminates immediately at body
  let prevented = false;
  const evt = {
    deltaY, deltaX, deltaMode, ctrlKey, target,
    preventDefault() { prevented = true; },
    composedPath() { return [target]; },
  };
  for (const handler of ctx.__listeners.wheel) handler(evt);
  return prevented;
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

// A. Slow touchpad frames accumulate into REAL visible scrolling.
// Each frame: deltaMode=PIXEL, deltaY=2 => deltaPx=2 => x0.24=0.48px => sub-pixel.
// The pre-fix handler lost 0.48 every frame (scrollBy(0.48) rounds to 0 => frozen).
test('slow touchpad sub-pixel frames accumulate into visible scroll (zoom 1)', () => {
  const ctx = loadPopup();
  clockMs = 1000;
  let prevCount = 0;
  for (let i = 0; i < 12; i++) {
    clockMs += 16; // ~60fps, well within the idle window
    if (fireWheel(ctx, { deltaY: 2, deltaX: 1, deltaMode: 0 })) prevCount++;
  }
  // 12 frames x 0.48px = 5.76 => 5 whole layout px emitted (0.76 carried).
  assert.equal(ctx.__win.scrollY, 5,
    'slow touchpad must accumulate to 5px after 12 frames, got ' + ctx.__win.scrollY);
  assert.ok(ctx.__win.scrollY > 0, 'slow touchpad must NOT be frozen (regression = 0)');
  assert.equal(prevCount, 12, 'every accepted vertical frame must preventDefault');
});

// Sub-pixel steps are LOSSLESS across many frames (zoom>1 shrinks the step).
test('touchpad carry is lossless across many frames (zoom 2 amplifies sub-pixel)', () => {
  const ctx = loadPopup();
  ctx.__setZoom(2);
  clockMs = 5000;
  // deltaY=3 => deltaPx=3 => x0.24=0.72 visual => /2 zoom = 0.36 layout px/frame.
  for (let i = 0; i < 30; i++) { clockMs += 10; fireWheel(ctx, { deltaY: 3, deltaMode: 0 }); }
  assert.equal(ctx.__win.scrollY, 10,
    'zoom>1 sub-pixel carry must reach 10px after 30 frames, got ' + ctx.__win.scrollY);
});

// B. Mouse-wheel large-delta path is UNCHANGED (no regression).
test('mouse notch (large delta) moves the full step every notch, zoom 1', () => {
  const ctx = loadPopup();
  clockMs = 1000;
  // A Windows WebView2 mouse notch: deltaMode=PIXEL, deltaY=100 => x0.24=24 (< cap).
  for (let n = 1; n <= 3; n++) {
    clockMs += 200; // notch-to-notch; even crossing idle the whole step is intact
    fireWheel(ctx, { deltaY: 100, deltaMode: 0 });
    assert.equal(ctx.__win.scrollY, 24 * n,
      'mouse notch ' + n + ' must move a full 24px, got ' + ctx.__win.scrollY);
  }
});

test('mouse notch under zoom keeps the pre-fix zoom-divided step (12px at zoom 2)', () => {
  const ctx = loadPopup();
  ctx.__setZoom(2);
  clockMs = 1000; clockMs += 16;
  fireWheel(ctx, { deltaY: 100, deltaMode: 0 }); // 24 visual / 2 zoom = 12 layout px
  assert.equal(ctx.__win.scrollY, 12,
    'mouse notch at zoom 2 must still move 12px, got ' + ctx.__win.scrollY);
  assert.ok(ctx.__win.scrollY > 1, 'a mouse notch must never freeze');
});

// C. Horizontal-reject: strict gt plus jitter margin (the choppiness co-cause).
test('vertical frame with horizontal jitter is NOT dropped (deltaY 5, deltaX 8)', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  const prevented = fireWheel(ctx, { deltaY: 5, deltaX: 8, deltaMode: 0 });
  assert.equal(prevented, true, 'jittery vertical frame must be taken over');
  assert.ok(ctx.__win.scrollY > 0, 'jittery vertical frame must still scroll, got ' + ctx.__win.scrollY);
});

test('equal-magnitude diagonal frame scrolls vertically (deltaY 5, deltaX 5)', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  const prevented = fireWheel(ctx, { deltaY: 5, deltaX: 5, deltaMode: 0 });
  assert.equal(prevented, true, 'equal-magnitude frame must scroll vertically (strict gt not le)');
  assert.ok(ctx.__win.scrollY > 0, 'equal frame must move, got ' + ctx.__win.scrollY);
});

test('clearly-horizontal frame is left to native (deltaY 1, deltaX 20)', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  const prevented = fireWheel(ctx, { deltaY: 1, deltaX: 20, deltaMode: 0 });
  assert.equal(prevented, false, 'a clearly horizontal wheel must fall through to native');
  assert.equal(ctx.__win.scrollY, 0, 'a horizontal wheel must not scroll the popup vertically');
});

test('pure horizontal frame (deltaY 0) is ignored', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  const prevented = fireWheel(ctx, { deltaY: 0, deltaX: 30, deltaMode: 0 });
  assert.equal(prevented, false, 'deltaY zero must be left to native');
  assert.equal(ctx.__win.scrollY, 0, 'no vertical component => no vertical scroll');
});

// D. ctrl+wheel (zoom gesture) is still ignored.
test('ctrl+wheel is ignored (zoom gesture, not scroll)', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  const prevented = fireWheel(ctx, { deltaY: 100, deltaMode: 0, ctrlKey: true });
  assert.equal(prevented, false, 'ctrl+wheel must not be taken over by the scroll handler');
  assert.equal(ctx.__win.scrollY, 0, 'ctrl+wheel must not scroll');
});

// E. Idle reset clears a stale sub-pixel remainder (no delayed jump).
test('stale sub-pixel carry is reset after an idle gap', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  fireWheel(ctx, { deltaY: 2, deltaMode: 0 }); // residual 0.48, scrollY 0
  clockMs += 16;
  fireWheel(ctx, { deltaY: 2, deltaMode: 0 }); // residual 0.96, scrollY 0
  assert.equal(ctx.__win.scrollY, 0, 'two 0.48 frames stay sub-pixel');
  clockMs += 500; // long idle (> POPUP_WHEEL_RESIDUAL_IDLE_MS)
  fireWheel(ctx, { deltaY: 2, deltaMode: 0 }); // reset first => residual 0.48, still 0
  assert.equal(ctx.__win.scrollY, 0,
    'after idle reset the stale 0.96 must NOT combine into a delayed 1px jump');
});

let failed = 0;
for (const entry of tests) {
  const name = entry[0], fn = entry[1];
  try { fn(); console.log('  ok - ' + name); }
  catch (e) { failed++; console.error('  FAIL - ' + name + ': ' + (e && e.message)); }
}
if (failed) { console.error(failed + ' assertion group(s) failed'); process.exit(1); }
console.log('all assertions passed');
