// BUG-732 behavior test: the shared lookup popup wheel handler must NOT hijack a
// normal web page's scrolling when Hibiki's browser extension is installed.
//
// Root cause it locks: popup.js is injected as a content script on <all_urls>.
// Its document 'wheel' listener re-implements scrolling for the *dictionary
// popup* (scaled by POPUP_WHEEL_PIXEL_FACTOR = 0.24, with preventDefault). When
// the wheel is over the host page (not the popup shadow) the handler used to fall
// through to `window.scrollBy` — commandeering every normal page's scroll at 24%
// speed. The fix: in the extension content-script context (chrome.runtime.id
// present) a wheel that is NOT over the popup shadow must fall through to native
// scrolling (no preventDefault). The in-app popup (flutter_inappwebview, no
// chrome) and wheels over the popup itself keep the custom scaled scroll.
//
// BUG-1078 extends this: even a cheap non-passive document wheel listener makes
// the browser abandon the compositor fast-scroll path on EVERY page the content
// script touches. So in the extension context popup.js must NOT attach to
// document at all — it exposes the handler as window.__hibikiPopupWheelListener
// and content.js lazily mounts it on the popup shadow host for the popup's
// lifetime. The in-app popup (no chrome.runtime) keeps the resident document
// listener ({passive:false}) — there the document IS the popup.
//
// This EXECUTES the real popup.js wheel handler against a minimal fake DOM and
// asserts preventDefault / scrollBy per surface. Reverting the guard turns it red.
//
// Run: node hibiki/test/lookup/browser_extension_page_scroll_bug732_test.js
// (also driven from browser_extension_page_scroll_bug732_test.dart inside
//  `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// Build a sandbox, load popup.js, and return the captured wheel handler plus
// recorders for the behaviours we assert on.
function loadWheelHandler(opts) {
  const calls = {
    prevented: false,
    windowScrollBy: [],
    hostScrollBy: [],
  };

  const documentWheelRegs = [];

  const hostEl = {
    style: {},
    scrollBy(arg) { calls.hostScrollBy.push(arg); },
  };

  const documentObj = {
    documentElement: { style: {} },
    body: { tagName: 'BODY' },
    addEventListener(type, handler, options) {
      if (type === 'wheel') documentWheelRegs.push({ handler, options });
    },
  };

  const windowObj = {
    innerHeight: 800,
    addEventListener() {},
    scrollBy(arg) { calls.windowScrollBy.push(arg); },
    getSelection() { return { toString() { return ''; } }; },
    getComputedStyle() { return {}; },
  };
  // __hibikiRoot.host is the shadow host; only present when a popup is open.
  windowObj.__hibikiRoot = opts.popupOpen ? { host: hostEl } : undefined;
  if (opts.flutter) {
    windowObj.flutter_inappwebview = { callHandler() { return Promise.resolve(false); } };
  }

  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, Number, Boolean,
    String, console,
    performance: { now() { return 1000; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: {}, querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
  };
  if (opts.extension) {
    sandbox.chrome = { runtime: { id: 'hibiki-extension-id' } };
  }
  sandbox.globalThis = sandbox;

  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: 'popup.js' });

  let wheelHandler = null;
  if (opts.extension) {
    // BUG-1078: extension context must leave document COMPLETELY free of wheel
    // listeners (a resident non-passive listener kills compositor fast scroll on
    // every page). The handler is exposed for content.js to mount on the shadow
    // host for the popup's lifetime.
    assert.strictEqual(documentWheelRegs.length, 0,
      'extension context must NOT attach any document wheel listener (BUG-1078)');
    wheelHandler = windowObj.__hibikiPopupWheelListener;
    assert.ok(typeof wheelHandler === 'function',
      'extension context must expose window.__hibikiPopupWheelListener for ' +
      'content.js to lazily mount on the popup shadow host');
  } else {
    // In-app popup WebView: the document IS the popup — the resident document
    // listener must stay, and stay non-passive (it preventDefault()s).
    assert.strictEqual(documentWheelRegs.length, 1,
      'in-app popup must keep exactly one resident document wheel listener');
    assert.ok(documentWheelRegs[0].options &&
      documentWheelRegs[0].options.passive === false,
      'in-app document wheel listener must be {passive:false} (it preventDefaults)');
    wheelHandler = documentWheelRegs[0].handler;
  }

  return { wheelHandler, calls, hostEl };
}

// A vertical mouse-notch wheel event over `target`; composedPath is [target,
// ...ancestors]. deltaMode 0 (pixels) so deltaPx === deltaY.
function makeWheelEvent(target, ancestors, calls) {
  const pathArr = [target].concat(ancestors || []);
  return {
    ctrlKey: false,
    deltaY: 100,
    deltaX: 0,
    deltaMode: 0,
    target,
    composedPath() { return pathArr; },
    preventDefault() { calls.prevented = true; },
  };
}

// Case A — the bug: extension installed, wheel over the HOST PAGE (no popup /
// wheel not over the popup). Native scrolling must win: no preventDefault, no
// custom window.scrollBy.
(function extensionHostPageFallsThroughToNative() {
  const { wheelHandler, calls } = loadWheelHandler({ extension: true, popupOpen: false });
  const target = { nodeType: 1, parentElement: null };
  wheelHandler(makeWheelEvent(target, [], calls));

  assert.strictEqual(calls.prevented, false,
    'extension host-page wheel must NOT call preventDefault (native scroll)');
  assert.strictEqual(calls.windowScrollBy.length, 0,
    'extension host-page wheel must NOT run the scaled window.scrollBy');
})();

// Case A2 — the bug persists even while a popup is open, as long as the wheel is
// over the host page (composedPath does not cross the shadow host).
(function extensionHostPageWithPopupOpenStillNative() {
  const { wheelHandler, calls } = loadWheelHandler({ extension: true, popupOpen: true });
  const target = { nodeType: 1, parentElement: null };
  wheelHandler(makeWheelEvent(target, [], calls)); // path never includes hostEl

  assert.strictEqual(calls.prevented, false,
    'wheel over host page (popup open) must still fall through to native');
  assert.strictEqual(calls.windowScrollBy.length, 0,
    'wheel over host page (popup open) must not scroll the window custom');
})();

// Case B — extension, wheel OVER the popup shadow: the custom scaled scroll must
// still drive the shadow host (the popup's real scroll container). Unchanged.
(function extensionWheelOverPopupScrollsHost() {
  const { wheelHandler, calls, hostEl } = loadWheelHandler({ extension: true, popupOpen: true });
  const inner = { nodeType: 1, parentElement: null };
  // composedPath crosses the shadow host -> __hibikiWheelScroller returns it.
  wheelHandler(makeWheelEvent(inner, [hostEl], calls));

  assert.strictEqual(calls.prevented, true,
    'wheel over the popup must preventDefault (custom scaled scroll)');
  assert.strictEqual(calls.hostScrollBy.length, 1,
    'wheel over the popup must scroll the shadow host');
  assert.strictEqual(calls.windowScrollBy.length, 0,
    'wheel over the popup must not scroll the window');
  const step = calls.hostScrollBy[0].top;
  assert.ok(step > 0 && step <= 120,
    'popup scroll step must be the scaled/clamped delta, got ' + step);
})();

// Case C — the in-app popup document (flutter_inappwebview, no chrome): the whole
// document IS the popup, so window.scrollBy custom scroll must keep working. This
// is the regression guard: the fix must not disable in-app popup scrolling.
(function inAppPopupKeepsWindowScroll() {
  const { wheelHandler, calls } = loadWheelHandler({ extension: false, flutter: true, popupOpen: false });
  const target = { nodeType: 1, parentElement: null };
  wheelHandler(makeWheelEvent(target, [], calls));

  assert.strictEqual(calls.prevented, true,
    'in-app popup wheel must preventDefault (custom document scroll)');
  assert.strictEqual(calls.windowScrollBy.length, 1,
    'in-app popup wheel must drive window.scrollBy');
  const step = calls.windowScrollBy[0].top;
  assert.ok(step > 0 && step <= 120,
    'in-app popup scroll step must be the scaled/clamped delta, got ' + step);
})();

console.log('all assertions passed');
