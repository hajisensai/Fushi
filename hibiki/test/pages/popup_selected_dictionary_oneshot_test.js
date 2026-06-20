// TODO-645 / BUG-358 behavior test: the popup's per-entry dictionary selection
// (`selectedDictionaries[idx]`, which fills the Anki {selected-glossary} field)
// must be ONE-SHOT — cleared after a successful mine and on word change — so it
// never sticks to the next card mined from the same (reused warm-slot) WebView.
//
// Regression context: `selectedDictionaries[idx]` is set on a long-press of a
// dictionary header and was only ever cleared when the user long-pressed the
// SAME header again to toggle it off. A successful mine (and re-querying a new
// word, which reuses the warm popup WebView at the same entryIdx) left the stale
// selection in place, so the next mined card silently carried the previously
// chosen dictionary. This mirrors the sentence-context-mirror lifecycle, which
// is already zeroed both after mine and on word change.
//
// This test EXECUTES the real popup.js against a minimal fake DOM. It drives the
// real `buildMinePayload` (which reads `selectedDictionaries[idx]?.name` into the
// `selectedDictionary` field) using an entry with no glossaries so the DOM-heavy
// glossary/frequency/pitch builders short-circuit. Reverting the fix (leaving the
// selection sticky / removing the reset helpers) turns this red.
//
// Run: node hibiki/test/pages/popup_selected_dictionary_oneshot_test.js
// (also driven from popup_selected_dictionary_oneshot_test.dart so it executes
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// A throwaway DOM element good enough for the popup helpers that might touch the
// DOM. (With empty glossaries none are actually exercised, but createElement
// must hand back something with the methods popup.js calls.)
function makeElement(tag) {
  return {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    innerHTML: '',
    style: {},
    dataset: {},
    children: [],
    attributes: [],
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    appendChild(child) { this.children.push(child); return child; },
    append(...nodes) { this.children.push(...nodes); },
    setAttribute() {},
    removeAttribute() {},
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function makeSandbox() {
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement('body'),
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) { return makeElement(tag); },
    addEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
  };
  documentObj.defaultView = windowObj;

  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: makeElement('body'), querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

// Load the real popup.js into a fresh sandbox and surface module-scope symbols.
function loadPopup() {
  const sandbox = makeSandbox();
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      buildMinePayload: buildMinePayload,
      getSelected: function(idx) { return selectedDictionaries[idx]; },
      selectDictionary: function(idx, name) {
        selectedDictionaries[idx] = { name: name, label: { classList: { remove: function() {} } } };
      },
      selectedDictionaryNames: function() {
        return Object.keys(selectedDictionaries).map(function(k) {
          return k + '=' + selectedDictionaries[k].name;
        });
      },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function makeEntry(expression, reading) {
  return { expression: expression, reading: reading, glossaries: [], frequencies: [], pitches: [] };
}

async function payloadFor(sandbox, idx) {
  const e = makeEntry('猫', 'ねこ');
  return await sandbox.window.__test.buildMinePayload(
    e.expression, e.reading, e.frequencies, e.pitches, [], '猫', idx, '猫');
}

(async function run() {
  // Test 1: a long-pressed dictionary populates {selected-glossary} (sanity),
  // and after the per-entry mine-success clear the same idx mines empty.
  {
    const sb = loadPopup();
    sb.window.__test.selectDictionary(0, 'Daijirin');
    const before = await payloadFor(sb, 0);
    assert.strictEqual(before.selectedDictionary, 'Daijirin',
      'a long-pressed dictionary must populate {selected-glossary}; got '
        + JSON.stringify(before.selectedDictionary));

    assert.strictEqual(typeof sb.window.resetSelectedDictionaries, 'function',
      'popup.js must expose window.resetSelectedDictionaries (mirror of '
        + 'resetSentenceContextMirror) for the word-change reset path');
    assert.strictEqual(typeof sb.window.resetSelectedDictionariesForEntry, 'function',
      'popup.js must expose window.resetSelectedDictionariesForEntry for the '
        + 'per-entry mine-success clear path');

    sb.window.resetSelectedDictionariesForEntry(0);
    const after = await payloadFor(sb, 0);
    assert.strictEqual(after.selectedDictionary, '',
      'after a successful mine the SAME entry must mine an empty '
        + 'selectedDictionary (one-shot); got ' + JSON.stringify(after.selectedDictionary));
  }

  // Test 2: word change → resetSelectedDictionaries zeros ALL entries.
  {
    const sb = loadPopup();
    sb.window.__test.selectDictionary(0, 'Daijirin');
    sb.window.__test.selectDictionary(1, 'JMdict');
    assert.deepStrictEqual(
      sb.window.__test.selectedDictionaryNames().sort(),
      ['0=Daijirin', '1=JMdict'],
      'precondition: two entries selected');

    sb.window.resetSelectedDictionaries();

    assert.deepStrictEqual(sb.window.__test.selectedDictionaryNames(), [],
      'resetSelectedDictionaries must clear EVERY entry selection on word change');

    const p0 = await payloadFor(sb, 0);
    const p1 = await payloadFor(sb, 1);
    assert.strictEqual(p0.selectedDictionary, '',
      'after word-change reset, idx0 mine must carry empty selectedDictionary; got '
        + JSON.stringify(p0.selectedDictionary));
    assert.strictEqual(p1.selectedDictionary, '',
      'after word-change reset, idx1 mine must carry empty selectedDictionary; got '
        + JSON.stringify(p1.selectedDictionary));
  }

  // Test 3: per-idx independence — clearing one entry must not touch the other.
  {
    const sb = loadPopup();
    sb.window.__test.selectDictionary(0, 'Daijirin');
    sb.window.__test.selectDictionary(1, 'JMdict');

    sb.window.resetSelectedDictionariesForEntry(0);

    const p0 = await payloadFor(sb, 0);
    const p1 = await payloadFor(sb, 1);
    assert.strictEqual(p0.selectedDictionary, '',
      'mining idx0 must clear idx0 selection; got ' + JSON.stringify(p0.selectedDictionary));
    assert.strictEqual(p1.selectedDictionary, 'JMdict',
      'mining idx0 must NOT clear idx1 selection (per-entry independence); got '
        + JSON.stringify(p1.selectedDictionary));
  }

  console.log('popup_selected_dictionary_oneshot_test.js: all assertions passed');
})().catch(function(e) {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});
