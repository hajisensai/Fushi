// TODO-865 behavior test (BUG-419 sibling): a dictionary disabled in 词典管理
// (its show/hide switch off → added to window.hiddenDictionaryNames by the host)
// must NOT have its definitions written into the Anki mining payload.
//
// Root cause: term dictionaries stay registered in the native FFI engine even when
// hidden (AppModel.bucketDictPaths keeps hidden term dicts in the bucket because
// filtering is meant to happen at render time). BUG-419 only patched the visible
// lookup popup (createGlossarySectionWrapper). The mining field assembly path
// (constructGlossaryHtml / constructSingleGlossaryHtml, consumed by buildMinePayload)
// is independent and previously had NO hidden filter, so a disabled dictionary's
// glossary still ended up in the card's glossary field.
//
// This test EXECUTES the real popup.js constructGlossaryHtml / constructSingleGlossaryHtml
// against a minimal fake DOM and asserts hidden dictionaries are excluded from the
// mining payload (and that an entry whose only glossary is hidden yields an empty
// <ol></ol> / {} — no empty card content). Reverting the fix turns this red.
//
// Run: node hibiki/test/pages/popup_mining_hidden_dictionary_test.js
// (also driven from popup_mining_hidden_dictionary_test.dart so it executes inside
//  `flutter test`).

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
    getAttribute() { return null; },
    hasAttribute() { return false; },
    removeAttribute() {},
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
    get firstChild() { return this.children.length ? this.children[0] : null; },
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
    createTextNode(text) { const n = makeElement('#text'); n.textContent = text; return n; },
    addEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: hiddenNames || [],
    collapsedDictionaryNames: [],
    compactGlossariesAnki: false,
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

function loadPopup(hiddenNames, entry) {
  const sandbox = makeSandbox(hiddenNames);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.lookupEntries = [${JSON.stringify(entry)}];
    ;window.__test = {
      multi: function() { return constructGlossaryHtml(0); },
      single: function() { return constructSingleGlossaryHtml(0); },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function gloss(dictionary) {
  // content is a plain (non-JSON, non-HTML) string so renderStructuredContent
  // treats it as text; the data-dictionary marker is what we assert on.
  return { dictionary: dictionary, content: 'def-' + dictionary, definitionTags: '', termTags: '' };
}

function entryWith(dictNames) {
  return {
    expression: '猫', reading: 'ねこ',
    glossaries: dictNames.map(gloss),
    frequencies: [], pitches: [],
  };
}

(function run() {
  // Test 1: with no hidden dicts, both dictionaries appear in both payload shapes.
  {
    const sb = loadPopup([], entryWith(['JMdict', 'Daijirin']));
    const multi = sb.window.__test.multi();
    assert.ok(multi.includes('data-dictionary="JMdict"'),
      'visible JMdict must be in multi glossary; got ' + multi);
    assert.ok(multi.includes('data-dictionary="Daijirin"'),
      'visible Daijirin must be in multi glossary; got ' + multi);

    const single = sb.window.__test.single();
    assert.deepStrictEqual(Object.keys(single).sort(), ['Daijirin', 'JMdict'],
      'with no hidden dicts both must be in single glossaries; got '
        + JSON.stringify(Object.keys(single)));
  }

  // Test 2: a hidden dictionary is excluded from the mining payload; visible survives.
  {
    const sb = loadPopup(['Daijirin'], entryWith(['JMdict', 'Daijirin']));
    const multi = sb.window.__test.multi();
    assert.ok(multi.includes('data-dictionary="JMdict"'),
      'visible JMdict must remain in multi glossary; got ' + multi);
    assert.ok(!multi.includes('data-dictionary="Daijirin"'),
      'disabled Daijirin must NOT appear in the mining multi glossary; got ' + multi);

    const single = sb.window.__test.single();
    assert.deepStrictEqual(Object.keys(single), ['JMdict'],
      'disabled dictionary must be filtered from single glossaries; got '
        + JSON.stringify(Object.keys(single)));
    assert.strictEqual(single['Daijirin'], undefined,
      'the hidden dictionary must not be a key in single glossaries');
  }

  // Test 3: an entry whose only glossary is hidden yields empty payloads
  // (empty <ol></ol> with no <li>, and {} for single) — no empty card content.
  {
    const sb = loadPopup(['JMdict'], entryWith(['JMdict']));
    const multi = sb.window.__test.multi();
    assert.ok(!multi.includes('<li'),
      'an all-hidden entry must produce no glossary list items; got ' + multi);
    assert.ok(!multi.includes('data-dictionary="JMdict"'),
      'the hidden dictionary must not surface at all; got ' + multi);

    const single = sb.window.__test.single();
    assert.strictEqual(Object.keys(single).length, 0,
      'an all-hidden entry must produce an empty single-glossary map; got '
        + JSON.stringify(single));
  }

  console.log('popup_mining_hidden_dictionary_test.js: all assertions passed');
})();
