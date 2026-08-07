// TODO-804 behavior test: a dictionary disabled in 词典管理 (its show/hide switch
// turned off → added to hiddenDictionaryNames by the host) must NOT have its
// definitions surface in the lookup popup.
//
// Root cause: term dictionaries stay registered in the native FFI engine even
// when hidden (AppModel.bucketDictPaths keeps hidden term dicts in the bucket
// because filtering is meant to happen at render time). The lookup popup renders
// the FFI glossaries directly and previously had NO hidden filter, so a disabled
// dictionary's entries still showed. The host now injects
// window.hiddenDictionaryNames and popup.js drops them in
// createGlossarySectionWrapper — the single grouping point shared by every
// term-glossary render path.
//
// This test EXECUTES the real popup.js createGlossarySectionWrapper against a
// minimal fake DOM and asserts hidden dictionaries are excluded from the grouped
// term glossaries (and that an entry whose only glossary is hidden yields no
// glossary section at all). Reverting the fix turns this red.
//
// Run: node hibiki/test/pages/popup_hidden_dictionary_filter_test.js
// (also driven from popup_hidden_dictionary_filter_test.dart so it executes
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
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function makeSandbox(hiddenNames) {
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
    hiddenDictionaryNames: hiddenNames || [],
    collapsedDictionaryNames: [],
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

function loadPopup(hiddenNames) {
  const sandbox = makeSandbox(hiddenNames);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      wrap: function(entry) { return createGlossarySectionWrapper(entry); },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function gloss(dictionary) {
  return { dictionary: dictionary, content: '"def"', definitionTags: '', termTags: '' };
}

function entryWith(dictNames) {
  return {
    expression: '猫', reading: 'ねこ',
    glossaries: dictNames.map(gloss),
    frequencies: [], pitches: [],
  };
}

(function run() {
  // Test 1: with no hidden dicts, every dictionary's glossary is grouped.
  {
    const sb = loadPopup([]);
    const out = sb.window.__test.wrap(entryWith(['JMdict', 'Daijirin']));
    assert.notStrictEqual(out, null, 'expected a glossary wrapper');
    assert.deepStrictEqual(out.dictNames.sort(), ['Daijirin', 'JMdict'],
      'with no hidden dicts both must be grouped; got ' + JSON.stringify(out.dictNames));
  }

  // Test 2: a hidden dictionary is excluded; remaining ones survive.
  {
    const sb = loadPopup(['Daijirin']);
    const out = sb.window.__test.wrap(entryWith(['JMdict', 'Daijirin']));
    assert.notStrictEqual(out, null, 'expected a glossary wrapper');
    assert.deepStrictEqual(out.dictNames, ['JMdict'],
      'a disabled dictionary must be filtered out of the popup; got '
        + JSON.stringify(out.dictNames));
    assert.strictEqual(out.grouped['Daijirin'], undefined,
      'the hidden dictionary must not appear in grouped glossaries');
  }

  // Test 3: an entry whose only glossary is hidden yields NO glossary section
  // (no empty card), not an empty grouping.
  {
    const sb = loadPopup(['JMdict']);
    const out = sb.window.__test.wrap(entryWith(['JMdict']));
    assert.strictEqual(out, null,
      'an entry whose only glossary is hidden must produce no glossary section; '
        + 'got ' + JSON.stringify(out));
  }

  console.log('popup_hidden_dictionary_filter_test.js: all assertions passed');
})();
