// BUG-3139 behavior test: the dictionary popup's effective column count on a
// touch (coarse-pointer) device. A phone held in landscape opens the in-video
// lookup popup about 620 logical px wide (feedback device 384x853@2.81); with
// the user's "max columns" at 3 it must lay out two columns, while a portrait
// phone popup (~380 px) keeps a single column. The old coarse floor (2 x 170 =
// 340 px per column) made landscape phones single-column forever.
//
// EXECUTES the real popup.js effectiveDictColumns() in a vm sandbox.
// Run: node fushi/test/pages/popup_dict_columns_coarse_test.js
// (driven from popup_dict_columns_coarse_test.dart inside `flutter test`).

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
    expandedDictionaryNames: opts.expandedDictionaryNames || [],
    collapseDictionaries: opts.collapseDictionaries,
    autoExpandRows: opts.autoExpandRows,
    // effectiveDictColumns() converges the configured column count against the
    // viewport (each column needs >= DICT_COLUMN_MIN_WIDTH=170px). Default wide
    // so `dictColumns` alone decides unless a case pins a narrow viewport.
    innerWidth: opts.innerWidth === undefined ? 1200 : opts.innerWidth,
    // 宿主（dictionary_popup_webview）注入的 Flutter 布局宽度。
    __fushiPopupViewportWidth: opts.viewportWidth,
    matchMedia(query) {
      return { matches: query === '(pointer: coarse)' && opts.coarse === true };
    },
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
    // The row-based threshold reads the host-injected --dict-columns through
    // effectiveDictColumns(), so the fake style must actually serve it.
    getComputedStyle() {
      return {
        getPropertyValue(name) {
          if (name === '--dict-columns') {
            return String(opts.dictColumns === undefined ? 1 : opts.dictColumns);
          }
          return '';
        },
      };
    },
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

function columns(opts) {
  const sandbox = makeSandbox(opts);
  vm.createContext(sandbox);
  vm.runInContext(dictMediaSource, sandbox, { filename: 'dict-media.js' });
  vm.runInContext(
    source + ';window.__test = { cols: function() { return effectiveDictColumns(); } };',
    sandbox,
    { filename: 'popup.js' },
  );
  return sandbox.window.__test.cols();
}

(function run() {
  // Landscape phone, in-video lookup popup ~620 px: 3 configured -> 2 columns.
  assert.strictEqual(
    columns({ coarse: true, viewportWidth: 620, dictColumns: 3 }), 2,
    'coarse landscape popup (620px) must show 2 columns');
  // Same popup with max 2 columns.
  assert.strictEqual(
    columns({ coarse: true, viewportWidth: 620, dictColumns: 2 }), 2,
    'coarse 620px, max 2 -> 2');
  // Portrait phone popup stays single column.
  assert.strictEqual(
    columns({ coarse: true, viewportWidth: 380, dictColumns: 3 }), 1,
    'coarse portrait popup (380px) stays single column');
  // Tablet landscape popup: up to 3 columns.
  assert.strictEqual(
    columns({ coarse: true, viewportWidth: 900, dictColumns: 3 }), 3,
    'coarse tablet popup (900px) -> 3 columns');
  // Fine pointer (desktop) threshold unchanged: 380 px fits 2 columns.
  assert.strictEqual(
    columns({ coarse: false, viewportWidth: 380, dictColumns: 3 }), 2,
    'fine pointer keeps the 170px floor');
  // The user cap always wins.
  assert.strictEqual(
    columns({ coarse: true, viewportWidth: 1400, dictColumns: 1 }), 1,
    'max 1 column stays 1');
  console.log('popup_dict_columns_coarse_test.js: all assertions passed');
})();
