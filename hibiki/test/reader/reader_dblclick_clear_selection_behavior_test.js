// TODO-1028 / BUG-481 behavior test: a native double-click that establishes a
// text selection must NOT hijack lookup or block the furigana whole-page toggle.
//
// Root cause: the WebView native double-click builds a (blue) text selection that
// covers the single-tap lookup CSS Highlight and trips the furigana dblclick
// toggle handler, whose guard `if (sel && !sel.isCollapsed) return` bails out when
// it sees the selection the double-click itself just produced. The fix adds a
// CAPTURE-phase dblclick listener that removeAllRanges() the native selection
// BEFORE the (bubble-phase) furigana handler runs, so the furigana toggle sees a
// collapsed selection and fires normally.
//
// This test EXECUTES both real handlers, extracted verbatim from
// webview.part.dart: (1) the new capture-phase clear-selection dblclick listener
// inside _buildReaderSetupScript, and (2) the 'toggle' furigana dblclick handler
// from _buildFuriganaJs. It dispatches a dblclick capture-then-bubble (browser
// order) over a non-collapsed selection and asserts the selection is cleared
// (isCollapsed === true) AND show-all-rt was still toggled (furigana preserved).
// Reverting the fix (dropping removeAllRanges) leaves the selection non-collapsed,
// so the furigana guard bails and show-all-rt is NOT toggled -> red.
//
// Run: node hibiki/test/reader/reader_dblclick_clear_selection_behavior_test.js
// (also driven from reader_dblclick_clear_selection_behavior_test.dart so it runs
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const readerPath = path.resolve(
  __dirname,
  '../../lib/src/pages/implementations/reader_hibiki/webview.part.dart',
);
const source = fs.readFileSync(readerPath, 'utf8');

// (1) Extract the capture-phase clear-selection dblclick listener from
// _buildReaderSetupScript. Anchor on the TODO-1028 comment and capture the whole
// addEventListener('dblclick', ..., true) statement.
const captureMatch = source.match(
  /document\.addEventListener\('dblclick',\s*function\(\)\s*\{\s*var sel = window\.getSelection && window\.getSelection\(\);\s*if \(sel && !sel\.isCollapsed\) sel\.removeAllRanges\(\);\s*\},\s*true\);/,
);
assert.ok(captureMatch, 'missing TODO-1028 capture-phase clear-selection dblclick listener');
const captureListener = captureMatch[0];

// (2) Extract the furigana 'toggle' dblclick handler from _buildFuriganaJs. It is
// inside a Dart triple-quoted string; grab the addEventListener statement only.
const toggleMatch = source.match(
  /document\.addEventListener\('dblclick',\s*function\(\)\s*\{\s*var sel = window\.getSelection\(\);\s*if \(sel && !sel\.isCollapsed\) return;\s*document\.body\.classList\.toggle\('show-all-rt'\);\s*\}\);/,
);
assert.ok(toggleMatch, "missing _buildFuriganaJs 'toggle' dblclick handler");
const furiganaListener = toggleMatch[0];

function makeHarness() {
  // capture-phase listeners run before bubble-phase ones (browser order). The
  // fake document records (listener, useCapture) and dispatch() replays capture
  // listeners first, then bubble.
  const captureListeners = [];
  const bubbleListeners = [];

  // A live, mutable selection model: starts non-collapsed (the double-click just
  // selected a word); removeAllRanges() collapses it.
  const selection = {
    isCollapsed: false,
    removeAllRanges() { this.isCollapsed = true; },
  };

  const bodyClassList = {
    _set: new Set(),
    toggle(name) {
      if (this._set.has(name)) { this._set.delete(name); } else { this._set.add(name); }
    },
    has(name) { return this._set.has(name); },
  };

  const documentObj = {
    body: { classList: bodyClassList },
    addEventListener(name, fn, useCapture) {
      if (name !== 'dblclick') { return; }
      (useCapture ? captureListeners : bubbleListeners).push(fn);
    },
  };

  const windowObj = {
    getSelection() { return selection; },
  };

  const sandbox = {
    document: documentObj,
    window: windowObj,
  };

  // Register BOTH handlers in source order (capture listener appears first in the
  // setup script; furigana toggle is appended via _buildFuriganaJs). Registration
  // order is irrelevant — dispatch order is governed by useCapture.
  const prepared = '(function(){\n' + captureListener + '\n' + furiganaListener + '\n})();';
  vm.createContext(sandbox);
  vm.runInContext(prepared, sandbox, { filename: 'reader-dblclick-handlers.js' });

  function dispatchDblclick() {
    // Browser phase order: capture listeners first, then bubble listeners.
    for (const fn of captureListeners) { fn(); }
    for (const fn of bubbleListeners) { fn(); }
  }

  return { dispatchDblclick, selection, bodyClassList };
}

// Test 1: a double-click with a live (non-collapsed) selection -> the capture
// listener clears it, and because it ran first the furigana toggle still fires.
(function () {
  const h = makeHarness();
  assert.strictEqual(h.selection.isCollapsed, false, 'precondition: selection starts non-collapsed (the dblclick selected a word)');
  h.dispatchDblclick();
  assert.strictEqual(
    h.selection.isCollapsed, true,
    'native double-click selection must be cleared (removeAllRanges) so it stops hijacking lookup',
  );
  assert.strictEqual(
    h.bodyClassList.has('show-all-rt'), true,
    'furigana whole-page toggle must still fire on double-click (the capture clear runs first so the !isCollapsed guard no longer bails)',
  );
})();

// Test 2: a second double-click toggles show-all-rt back off (proves it is a real
// toggle, not a one-way set), and the now-collapsed selection stays collapsed.
(function () {
  const h = makeHarness();
  h.dispatchDblclick(); // on -> show-all-rt added
  // Simulate the browser re-establishing a selection on the next double-click.
  h.selection.isCollapsed = false;
  h.dispatchDblclick(); // off -> show-all-rt removed
  assert.strictEqual(h.selection.isCollapsed, true, 'second double-click selection must also be cleared');
  assert.strictEqual(
    h.bodyClassList.has('show-all-rt'), false,
    'second double-click must toggle show-all-rt back off',
  );
})();

console.log('reader_dblclick_clear_selection_behavior_test.js: all assertions passed');
