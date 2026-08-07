// Redirect-only dictionary records should not occupy result cards. This executes
// the real popup.js grouping function against the shapes reported for LDOCE5 and
// OALD10, while protecting an ordinary definition that happens to use the word
// "redirect".
//
// Run: node hibiki/test/pages/popup_redirect_entry_filter_test.js

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

function loadPopup() {
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
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: [],
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
  };
  documentObj.defaultView = windowObj;
  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, Promise, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class {
      parseFromString() {
        return {
          body: makeElement('body'),
          querySelectorAll() { return []; },
        };
      }
    },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source + `
    ;window.__test = {
      isRedirect: function(glossary) { return isRedirectGlossary(glossary); },
      wrap: function(entry) { return createGlossarySectionWrapper(entry); },
    };
  `, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function structured(...content) {
  return { tag: 'div', content };
}

function glossary(dictionary, content, termTags = '', definitionTags = '') {
  return { dictionary, content, termTags, definitionTags };
}

(function run() {
  const sb = loadPopup();
  const ldoceRedirect = glossary(
    'LDOCE5',
    structured(
      { tag: 'span', content: 'repair' },
      { tag: 'span', content: 'Redirected from repaired' },
    ),
  );
  const oaldRedirect = glossary(
    'OALD10',
    structured(
      { tag: 'span', content: 'repair' },
      { tag: 'span', content: 'redirect' },
    ),
    'non-lemma',
  );
  const oxfordDefinition = glossary(
    'Oxford Dictionary of English',
    structured({ tag: 'span', content: 'restore something damaged to good condition' }),
  );

  assert.strictEqual(sb.window.__test.isRedirect(ldoceRedirect), true,
    'the LDOCE "Redirected from ..." record must be recognized');
  assert.strictEqual(sb.window.__test.isRedirect(oaldRedirect), true,
    'the OALD non-lemma + redirect record must be recognized');
  assert.strictEqual(sb.window.__test.isRedirect(oxfordDefinition), false,
    'a real definition must remain visible');

  const out = sb.window.__test.wrap({
    expression: 'repaired',
    reading: '',
    glossaries: [ldoceRedirect, oaldRedirect, oxfordDefinition],
    frequencies: [],
    pitches: [],
  });
  assert.notStrictEqual(out, null, 'the surviving Oxford definition needs a wrapper');
  assert.deepStrictEqual(out.dictNames, ['Oxford Dictionary of English'],
    'redirect-only dictionaries must disappear from the grouped results');

  assert.strictEqual(
    sb.window.__test.isRedirect(glossary(
      'Technical English',
      'Use a 301 redirect to move traffic.',
    )),
    false,
    'definitions containing the word redirect must not be filtered',
  );
  assert.strictEqual(
    sb.window.__test.isRedirect(glossary('Technical English', 'redirect')),
    false,
    'a standalone word without redirect metadata must not be guessed away',
  );

  console.log('popup_redirect_entry_filter_test.js: all assertions passed');
})();
