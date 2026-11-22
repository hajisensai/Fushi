// 拍板台 6uasoIUvSR behavior test: in the lookup popup the kanji cards stay above
// the terms but sit in ONE <details> block that is collapsed by default to a
// single line ("Kanji · 粉  <dictionary names>"), opens on click, and honours the
// per-dictionary three-state from 词典管理's 「汉字」 section
// (window.kanjiExpandedDictionaryNames / kanjiCollapsedDictionaryNames) plus the
// global "collapse dictionaries" switch -- the same precedence as term
// dictionaries (BUG-2158), minus the auto-expand window.
//
// This EXECUTES the real popup.js buildKanjiCards against a minimal fake DOM.
// Reverting to the old always-open <div> section turns it red.
//
// Run: node fushi/test/pages/popup_kanji_collapse_test.js
// (also driven from popup_kanji_collapse_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const dictMediaPath = path.resolve(__dirname, '../../assets/popup/dict-media.js');
const dictMediaSource = fs.readFileSync(dictMediaPath, 'utf8');
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
    listeners: {},
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
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function loadPopup(win) {
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
  const windowObj = Object.assign({
    audioSources: [],
    lookupEntries: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: [],
    innerWidth: 1200,
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
  }, win);
  documentObj.defaultView = windowObj;
  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: makeElement('body'), querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return { getPropertyValue() { return ''; } }; },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(dictMediaSource, sandbox, { filename: 'dict-media.js' });
  vm.runInContext(source + '\n;window.__test = { build: buildKanjiCards };', sandbox, { filename: 'popup.js' });
  return sandbox;
}

const KANJI = [
  { character: '粉', onyomi: 'フン', kunyomi: 'こな', meanings: ['flour'], dictName: 'KANJIDIC' },
  { character: '粉', onyomi: 'フン', kunyomi: 'こ', meanings: ['powder'], dictName: 'Mixed' },
];

// Default: the lookup also has term entries (the kanji block sits above them).
const TERMS = [{ expression: '粉', reading: 'こな', glossaries: [] }];

function build(win) {
  const sb = loadPopup(Object.assign({ kanjiResults: KANJI, lookupEntries: TERMS }, win));
  return sb.window.__test.build();
}

function summaryText(section) {
  return section.children[0].children.map((c) => c.textContent).join(' ');
}

// 1. Default (global collapse on, no per-dict decision): one collapsed <details>
//    whose summary is a single line with the kanji and every dictionary name.
{
  const section = build({ collapseDictionaries: true });
  assert.ok(section, 'kanji results must still build a section');
  assert.strictEqual(section.tagName, 'DETAILS', 'kanji block must be a <details>');
  const classes = section.className.split(' ');
  assert.ok(classes.includes('kanji-card-section'),
    'root keeps .kanji-card-section (tap-outside predicate keys off it)');
  assert.ok(classes.includes('glossary-group'), 'kanji block reuses the dictionary card skin');
  assert.strictEqual(section.open, false, 'kanji block is collapsed by default');
  const summary = section.children[0];
  assert.strictEqual(summary.tagName, 'SUMMARY');
  const text = summaryText(section);
  assert.ok(text.startsWith('Kanji · 粉'), 'summary starts with label + kanji: ' + text);
  assert.strictEqual((text.match(/粉/g) || []).length, 1, 'duplicate characters are listed once: ' + text);
  assert.ok(text.includes('KANJIDIC') && text.includes('Mixed'), 'summary lists the dictionaries: ' + text);
  assert.ok(summary.listeners.mousedown && summary.listeners.mousedown.length === 1,
    'summary cancels mouse focus (BUG-2447)');
  const body = section.children[1];
  assert.strictEqual(body.children.length, 2, 'every kanji card is inside the collapsible body');
  assert.ok(body.children.every((c) => c.className === 'kanji-card'));
}

// 2. collapseDictionaries missing (bare shell) -> treated as the default: collapsed.
assert.strictEqual(build({}).open, false, 'missing collapseDictionaries means the default: collapsed');

// 3. Any dictionary in the block explicitly expanded -> open, even with global collapse on.
assert.strictEqual(
  build({ collapseDictionaries: true, kanjiExpandedDictionaryNames: ['Mixed'] }).open, true,
  'an explicitly expanded kanji dictionary opens the block');

// 4. Global collapse off -> open unless every dictionary is explicitly collapsed.
assert.strictEqual(build({ collapseDictionaries: false }).open, true, 'global collapse off opens the block');
assert.strictEqual(
  build({ collapseDictionaries: false, kanjiCollapsedDictionaryNames: ['KANJIDIC'] }).open, true,
  'one collapsed dictionary does not close a block that still holds an inherit one');
assert.strictEqual(
  build({ collapseDictionaries: false, kanjiCollapsedDictionaryNames: ['KANJIDIC', 'Mixed'] }).open, false,
  'every dictionary explicitly collapsed keeps it closed');

// 5. Term-dictionary lists do not leak into the kanji block (BUG-3573: a mixed
//    dictionary's term part has its own state).
assert.strictEqual(
  build({ collapseDictionaries: true, expandedDictionaryNames: ['Mixed', 'KANJIDIC'] }).open, false,
  'the term expand list must not open the kanji block');

// 6. Injected label + renamed dictionary display names are used.
{
  const text = summaryText(build({
    i18nKanjiSection: '汉字',
    dictionaryDisplayNames: { KANJIDIC: '漢字辞典' },
  }));
  assert.ok(text.startsWith('汉字 · 粉'), 'label prefix: ' + text);
  assert.ok(text.includes('漢字辞典'), 'display name used: ' + text);
}

// 7. Kanji-only result (finished lookup, no term entries): the block is the only
//    result, so it opens like the first term dictionary would -- unless every
//    dictionary is explicitly collapsed. While the lookup is still pending it stays
//    collapsed so arriving terms do not snap it shut.
assert.strictEqual(build({ collapseDictionaries: true, lookupEntries: [] }).open, true,
  'kanji-only finished lookup opens the block');
assert.strictEqual(
  build({ collapseDictionaries: true, lookupEntries: [], kanjiCollapsedDictionaryNames: ['KANJIDIC', 'Mixed'] }).open,
  false, 'explicit collapse still wins for a kanji-only result');
assert.strictEqual(
  build({ collapseDictionaries: true, lookupEntries: [], lookupPending: true }).open, false,
  'pending lookup keeps the block collapsed');

// 8. No kanji -> no block.
assert.strictEqual(loadPopup({ kanjiResults: [] }).window.__test.build(), null);

console.log('popup_kanji_collapse_test.js: all assertions passed');
