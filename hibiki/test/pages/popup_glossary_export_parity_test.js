// BUG-1062 / BUG-1061 behavior test: the Anki mining payload built by popup.js
// must match upstream Yomitan's exported glossary, in two respects the user hit:
//
// BUG-1061 — `{glossary}` label had a self-invented ordinal. Yomitan's
//   `glossary-single` anki template emits `(definitionTags…, dictionaryAlias)`
//   with NO number, and this repo's own constructSingleGlossaryHtml
//   (`{glossary-first}` / `{single-glossary-*}`) already agreed. Only
//   constructGlossaryHtml prefixed an index, so cards read "(1, 词典名)".
//
// BUG-1062 — exported definition images were pinned to physical pixels. Yomitan's
//   structured-content-generator always writes `width: {usedWidth}em` on the
//   container and lets CSS decide what 1em is: in its own popup a stylesheet
//   squashes it to ~1px, but an Anki card has no such stylesheet, so `em`
//   resolves against the card font size. popup.js instead exported
//   `width: {usedWidth}px` plus an inline `font-size: 1px` (which, being inline,
//   also overrode any note-type CSS) — cards ended up a whole font-size factor
//   smaller than Yomitan's. Export now keeps the `em` semantics; the popup path
//   keeps px (its own CSS is what makes px correct there).
//
// This EXECUTES the real popup.js against a minimal fake DOM. Reverting either
// fix turns this red.
//
// Run: node hibiki/test/pages/popup_glossary_export_parity_test.js
// (also driven from popup_glossary_export_parity_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
// popup.html loads dict-media.js before popup.js; the export path calls into it
// (normalizeDictMediaPath / rewriteDictionaryMediaPath), so load the real thing
// rather than stubbing the media path rules.
const dictMediaPath = path.resolve(__dirname, '../../assets/popup/dict-media.js');
const source = fs.readFileSync(dictMediaPath, 'utf8') + '\n' +
  fs.readFileSync(popupPath, 'utf8');

function makeElement(tag) {
  return {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    innerHTML: '',
    // Real CSSStyleDeclaration semantics that popup.js relies on: individual
    // property writes plus `cssText +=` accumulation.
    style: { cssText: '' },
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

function makeSandbox() {
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
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: [],
    compactGlossariesAnki: false,
    // Mining payload path: dictionary media is embedded, so exported images are
    // <img src="fushi_dict_N.ext"> and go through applyImageStyles.
    embedMedia: true,
    devicePixelRatio: 2,
    innerWidth: 400,
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

function loadPopup(entry) {
  const sandbox = makeSandbox();
  vm.createContext(sandbox);
  const exported = source + `
    ;window.lookupEntries = [${JSON.stringify(entry)}];
    // buildMinePayload normally opens this registry before rendering fields.
    ;currentDictionaryMedia = new Map();
    ;window.__test = {
      multi: function() { return constructGlossaryHtml(0); },
      single: function() { return constructSingleGlossaryHtml(0); },
      image: function(data, exporting) { return createDefinitionImage(data, 'Dict', exporting); },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function gloss(dictionary, text) {
  return { dictionary: dictionary, content: text, definitionTags: '', termTags: '' };
}

function labelsOf(html) {
  const out = [];
  const re = /<i>([^<]*)<\/i>/g;
  let m;
  while ((m = re.exec(html)) !== null) { out.push(m[1]); }
  return out;
}

// The container span is the first child of the returned .gloss-image-link node.
function containerOf(node) {
  assert.ok(node && node.children.length > 0, 'image node must have a container child');
  return node.children[0];
}

(function run() {
  const entry = {
    expression: '猫', reading: 'ねこ',
    glossaries: [gloss('JMdict', 'cat'), gloss('JMdict', 'kitty'), gloss('Daijirin', 'ねこ科の動物')],
    frequencies: [], pitches: [],
  };

  // BUG-1061 (1/2): no ordinal anywhere in the {glossary} labels — the first
  // entry of a dictionary carries just the dictionary name, subsequent entries
  // of the same dictionary carry nothing (tags would go here when present).
  {
    const sb = loadPopup(entry);
    const multi = sb.window.__test.multi();
    assert.deepStrictEqual(labelsOf(multi), ['(JMdict)', '', '(Daijirin)'],
      'the {glossary} labels must be Yomitan-shaped and ordinal-free; got ' + multi);
    assert.ok(!/\(\d+[,)]/.test(multi),
      'no "(1," / "(1)" ordinal may appear in the exported glossary; got ' + multi);
  }

  // BUG-1061 (2/2): the two mining payload builders must agree on the label
  // format — they render the same dictionary for the same card.
  {
    const sb = loadPopup(entry);
    const multi = sb.window.__test.multi();
    const single = sb.window.__test.single();
    for (const dict of ['JMdict', 'Daijirin']) {
      const first = labelsOf(single[dict])[0];
      assert.ok(labelsOf(multi).includes(first),
        `{glossary} must use the same label as {glossary-first} for ${dict}; ` +
        `single=${first} multi=${JSON.stringify(labelsOf(multi))}`);
    }
  }

  // BUG-1062 (1/3): an exported image keeps Yomitan's em sizing, and does not
  // pin an inline 1px font-size (which would also outrank note-type CSS).
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png', width: 10, height: 5 }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '10em',
      'exported image container must size in em like Yomitan; got ' + container.style.width);
    assert.ok(/font-size:1em/.test(container.style.cssText),
      'exported image container must inherit the card font size; got ' + container.style.cssText);
    assert.ok(!/font-size:1px/.test(container.style.cssText),
      'exported image container must not pin font-size:1px (BUG-1062); got ' + container.style.cssText);
    assert.ok(/max-width:100%/.test(container.style.cssText),
      'exported image must still be capped at the card width');
  }

  // BUG-1062 (2/3): the popup path is unchanged — px there is correct because
  // the popup ships the Yomitan stylesheet.
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png', width: 10, height: 5 }, false);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '10px',
      'popup image container must keep px sizing; got ' + container.style.width);
  }

  // BUG-1062 (3/3): dictionaries that declare em units are untouched by the fix
  // (they were already em on both paths).
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image(
      { path: 'gaiji.svg', width: 2, height: 2, sizeUnits: 'em' }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '2em',
      'sizeUnits:em images stay em on export; got ' + container.style.width);
  }

  console.log('popup_glossary_export_parity_test.js: all assertions passed');
})();
