// TODO-845 behavior test: the lookup popup auto-expands the leading
// `window.autoExpandDictionaries` dictionary blocks (force-open <details>) even
// when "collapse dictionaries" is on. Default 1 reproduces the historical
// "only the first dictionary is expanded" behaviour; 0 collapses all; N>1
// expands the first N. This test EXECUTES the real popup.js
// createGlossarySection against a minimal fake DOM and asserts the resulting
// <details>.open state per dictionary index. Reverting the fix (hardcoding the
// expand to dictIdx===0 / a bare false) turns this red.
//
// Run: node hibiki/test/pages/popup_auto_expand_dictionaries_test.js
// (also driven from popup_auto_expand_dictionaries_test.dart so it executes
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

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
    getAttribute() { return null; },
    hasAttribute() { return false; },
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function makeSandbox(opts) {
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement('body'),
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) { return makeElement(tag); },
    createTextNode(text) { return { nodeType: 3, textContent: text }; },
    addEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: opts.collapsedDictionaryNames || [],
    collapseDictionaries: opts.collapseDictionaries,
    autoExpandDictionaries: opts.autoExpandDictionaries,
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

function loadPopup(opts) {
  const sandbox = makeSandbox(opts);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      section: function(dictName, dictIdx) {
        return createGlossarySection(dictName, [{ content: '"def"', definitionTags: '', termTags: '' }], dictIdx, 0);
      },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

// Return whether the <details> block for a dictionary at `dictIdx` is open,
// given collapse on/off and the auto-expand threshold N.
function isOpen(opts, dictName, dictIdx) {
  const sb = loadPopup(opts);
  const details = sb.window.__test.section(dictName || 'JMdict', dictIdx);
  return details.open === true;
}

(function run() {
  // --- collapse OFF: every dictionary opens regardless of N. ---
  {
    const opts = { collapseDictionaries: false, autoExpandDictionaries: 1 };
    assert.strictEqual(isOpen(opts, 'JMdict', 0), true, 'collapse off: idx0 open');
    assert.strictEqual(isOpen(opts, 'Daijirin', 3), true, 'collapse off: idx3 open');
  }

  // --- collapse ON, N=1 (default / backward-compat): only the first opens. ---
  {
    const opts = { collapseDictionaries: true, autoExpandDictionaries: 1 };
    assert.strictEqual(isOpen(opts, 'JMdict', 0), true, 'N=1: idx0 open');
    assert.strictEqual(isOpen(opts, 'Daijirin', 1), false, 'N=1: idx1 collapsed');
    assert.strictEqual(isOpen(opts, 'Other', 5), false, 'N=1: idx5 collapsed');
  }

  // --- collapse ON, N=3: first three open, the rest collapsed. ---
  {
    const opts = { collapseDictionaries: true, autoExpandDictionaries: 3 };
    assert.strictEqual(isOpen(opts, 'D0', 0), true, 'N=3: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1), true, 'N=3: idx1 open');
    assert.strictEqual(isOpen(opts, 'D2', 2), true, 'N=3: idx2 open');
    assert.strictEqual(isOpen(opts, 'D3', 3), false, 'N=3: idx3 collapsed');
  }

  // --- collapse ON, N=0: nothing auto-expands. ---
  {
    const opts = { collapseDictionaries: true, autoExpandDictionaries: 0 };
    assert.strictEqual(isOpen(opts, 'D0', 0), false, 'N=0: idx0 collapsed');
    assert.strictEqual(isOpen(opts, 'D1', 1), false, 'N=0: idx1 collapsed');
  }

  // --- missing window.autoExpandDictionaries falls back to 1 (only first). ---
  {
    const opts = { collapseDictionaries: true, autoExpandDictionaries: undefined };
    assert.strictEqual(isOpen(opts, 'D0', 0), true, 'fallback N=1: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1), false, 'fallback N=1: idx1 collapsed');
  }

  console.log('popup_auto_expand_dictionaries_test.js: all assertions passed');
})();
