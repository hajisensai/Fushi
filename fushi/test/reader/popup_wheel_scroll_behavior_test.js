// TODO-1387 behavior harness: executes the REAL document wheel handler inside
// fushi/assets/popup/popup.js against synthetic touchpad / mouse wheel events and
// asserts the popup actually SCROLLS (real displacement), not merely that the
// tuning constants exist. Run by popup_wheel_scroll_behavior_test.dart via node;
// prints the success marker on the last line. Node-only; the Dart wrapper skips
// when node is absent.
//
// Root cause it locks (TODO-1387): a precision touchpad reports deltaMode=PIXEL
// with a tiny fractional deltaY; without a cross-event accumulator scrollBy lost
// the sub-pixel fraction every frame and the popup froze. The fix carries the
// remainder across events and stops horizontal jitter from dropping vertical frames.
//
// BUG-870 extends this: POPUP_WHEEL_PIXEL_FACTOR is a coarse-mouse-notch
// taming; applying it to a fine device (small pixel deltas) made scrolling ~4x too
// slow ("very hard to scroll"). Fine-device frames now scroll ~1:1 (factor 1.0,
// still zoom-corrected); a mouse notch (deltaY≈100) uses the 0.48 step. A gesture
// latches to its device class so a large mid-fling touchpad frame is not mis-tamed.

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

// A. BUG-870: a precision touchpad's small pixel-mode frames scroll ~1:1 (natural),
// NOT downscaled by the 0.48 mouse-notch factor. deltaY=2 (< MOUSE_NOTCH_PX 60) is a
// fine-device frame => factor 1.0 => 2 layout px/frame at zoom 1.
test('slow touchpad frames scroll ~1:1 natural, not the coarse-mouse taming (zoom 1)', () => {
  const ctx = loadPopup();
  clockMs = 1000;
  let prevCount = 0;
  for (let i = 0; i < 12; i++) {
    clockMs += 16; // ~60fps, well within the idle window
    if (fireWheel(ctx, { deltaY: 2, deltaX: 1, deltaMode: 0 })) prevCount++;
  }
  // 12 frames x 2px (factor 1.0) = 24px. Pre-BUG-870 this was 5px (0.24 factor):
  // "very hard to scroll". A 4x speed-up restores natural touchpad feel.
  assert.equal(ctx.__win.scrollY, 24,
    'fine touchpad frames must scroll ~1:1 (24px after 12x deltaY=2), got ' + ctx.__win.scrollY);
  assert.ok(ctx.__win.scrollY > 5,
    'BUG-870 regression guard: 0.24 taming would give only 5px (sluggish)');
  assert.equal(prevCount, 12, 'every accepted vertical frame must preventDefault');
});

// Sub-pixel carry still matters for a fine device UNDER zoom>1 (each frame divides
// by zoom into a fraction of a layout px). deltaY=1 => x1.0 => /3 zoom = 0.333/frame.
test('fine-device sub-pixel carry is lossless under zoom (deltaY 1, zoom 3)', () => {
  const ctx = loadPopup();
  ctx.__setZoom(3);
  clockMs = 5000;
  // 30 frames x (1 / 3) = 10.0 => 10 whole layout px (residual accumulates the third).
  for (let i = 0; i < 30; i++) { clockMs += 10; fireWheel(ctx, { deltaY: 1, deltaMode: 0 }); }
  assert.equal(ctx.__win.scrollY, 10,
    'fine-device sub-pixel carry must reach 10px after 30 frames, got ' + ctx.__win.scrollY);
});

// BUG-870 latch: a gesture that starts fine (small frame) stays fine even when an
// occasional larger mid-fling frame (>= MOUSE_NOTCH_PX) arrives — it must NOT be
// suddenly downscaled by the coarse-mouse factor as if it were a mouse notch.
test('touchpad gesture latches fine: a large mid-fling frame is not mouse-tamed', () => {
  const ctx = loadPopup();
  clockMs = 1000; clockMs += 16;
  fireWheel(ctx, { deltaY: 4, deltaMode: 0 });   // small first frame => latch fine (4px)
  clockMs += 16;
  fireWheel(ctx, { deltaY: 80, deltaMode: 0 });  // big fling frame, still fine => 80px (not 38)
  assert.equal(ctx.__win.scrollY, 84,
    'latched fine device must scroll the fling frame ~1:1 (4+80=84), got ' + ctx.__win.scrollY);
});

// B. Mouse-wheel large-delta path uses the calibrated 48px visual step.
test('mouse notch (large delta) moves the calibrated full step every notch, zoom 1', () => {
  const ctx = loadPopup();
  clockMs = 1000;
  // A Windows WebView2 mouse notch: deltaMode=PIXEL, deltaY=100 => x0.48=48 (< cap).
  for (let n = 1; n <= 3; n++) {
    clockMs += 200; // notch-to-notch; even crossing idle the whole step is intact
    fireWheel(ctx, { deltaY: 100, deltaMode: 0 });
    assert.equal(ctx.__win.scrollY, 48 * n,
      'mouse notch ' + n + ' must move a full 48px, got ' + ctx.__win.scrollY);
  }
});

test('mouse notch under zoom keeps a zoom-independent 48px visual step', () => {
  const ctx = loadPopup();
  ctx.__setZoom(2);
  clockMs = 1000; clockMs += 16;
  fireWheel(ctx, { deltaY: 100, deltaMode: 0 }); // 48 visual / 2 zoom = 24 layout px
  assert.equal(ctx.__win.scrollY, 24,
    'mouse notch at zoom 2 must move 24 layout px, got ' + ctx.__win.scrollY);
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

// E. Idle reset clears a stale sub-pixel remainder (no delayed jump). Under zoom 3
// a fine-device deltaY=1 frame is 0.333 layout px — sub-pixel — so the carry and
// its idle reset are exercised exactly as before BUG-870 (which only changed the
// per-frame factor, not the residual mechanism).
test('stale sub-pixel carry is reset after an idle gap (zoom 3)', () => {
  const ctx = loadPopup();
  ctx.__setZoom(3);
  clockMs = 1000; clockMs += 16;
  fireWheel(ctx, { deltaY: 1, deltaMode: 0 }); // residual 0.333, scrollY 0
  clockMs += 16;
  fireWheel(ctx, { deltaY: 1, deltaMode: 0 }); // residual 0.666, scrollY 0
  assert.equal(ctx.__win.scrollY, 0, 'two 0.333 frames stay sub-pixel');
  clockMs += 500; // long idle (> POPUP_WHEEL_RESIDUAL_IDLE_MS)
  fireWheel(ctx, { deltaY: 1, deltaMode: 0 }); // reset first => residual 0.333, still 0
  assert.equal(ctx.__win.scrollY, 0,
    'after idle reset the stale 0.666 must NOT combine into a delayed 1px jump');
});

let failed = 0;
for (const entry of tests) {
  const name = entry[0], fn = entry[1];
  try { fn(); console.log('  ok - ' + name); }
  catch (e) { failed++; console.error('  FAIL - ' + name + ': ' + (e && e.message)); }
}
if (failed) { console.error(failed + ' assertion group(s) failed'); process.exit(1); }
console.log('all assertions passed');
