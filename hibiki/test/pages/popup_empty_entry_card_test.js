// TODO-833 behavior test: when the hidden-dictionary filter (BUG-419) strips a
// term entry's only glossary, the entry must NOT render as a header-only shell
// card ("标题+频率徽章但正文空白"). The whole card is skipped.
//
// Root cause: buildEntryElement (popup.js) used to unconditionally append the
// entry header (+ frequency / pitch badges) and only *optionally* append the
// glossary. createGlossarySectionWrapper returns null when every dictionary for
// the entry is hidden (or it has no glossary), so the body vanished but the
// header + frequency shell stayed — an empty duplicate card. Same expression
// with two readings split into two cards, one of them this empty shell.
//
// Fix (TODO-833): buildEntryElement returns null when the glossary wrapper is
// null; renderPopup / updatePopupIncremental skip null cards and keep a
// _entryDomIndex map so the DOM `.entry` nodes (now sparse vs `entries`) stay
// aligned — otherwise an incremental load-more would pour entry A's definitions
// into entry B's card.
//
// This EXECUTES the real popup.js against a fake DOM rich enough to build the
// entry tree, run renderPopup / updatePopupIncremental, and count `.entry` cards.
// Reverting the fix turns these red.
//
// Run: node hibiki/test/pages/popup_empty_entry_card_test.js
// (also driven from popup_empty_entry_card_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// A fake DOM node that supports the subset of operations popup.js exercises when
// building entry trees and rendering: children tree, className, textContent,
// attributes, append/appendChild, and a tiny querySelectorAll understanding the
// few selectors popup.js uses (':scope > .entry', '.glossary-section .category-body',
// ':scope > .glossary-group > [data-dictionary]', '.glossary-content ruby').
function makeElement(tag) {
  const node = {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    nodeType: 1,
    _innerHTML: '',
    style: {},
    dataset: {},
    children: [],
    childNodes: [],
    attributes: {},
    parentElement: null,
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    get innerHTML() { return this._innerHTML; },
    set innerHTML(v) {
      this._innerHTML = v;
      if (v === '') {
        this.children = [];
        this.childNodes = [];
      }
    },
    appendChild(child) {
      if (child && child.tagName === 'DOCUMENTFRAGMENT') {
        for (const c of child.children) { this.appendChild(c); }
        return child;
      }
      this.children.push(child);
      this.childNodes.push(child);
      if (child && typeof child === 'object') child.parentElement = this;
      return child;
    },
    append(...nodes) {
      for (const n of nodes) {
        if (typeof n === 'string') {
          this.children.push({ nodeType: 3, textContent: n });
        } else {
          this.appendChild(n);
        }
      }
    },
    setAttribute(k, v) { this.attributes[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    removeAttribute(k) { delete this.attributes[k]; },
    addEventListener() {},
    closest() { return null; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; },
    querySelector(sel) {
      const all = this.querySelectorAll(sel);
      return all.length ? all[0] : null;
    },
    querySelectorAll(sel) {
      // Walk all descendants and match a handful of selectors used by popup.js.
      const out = [];
      const matchClass = (el, cls) => {
        if (!el) return false;
        if (el.classList && el.classList.contains(cls)) return true;
        const cn = typeof el.className === 'string' ? el.className : '';
        return cn.split(/\s+/).indexOf(cls) >= 0;
      };
      if (sel === ':scope > .entry') {
        for (const c of this.children) { if (matchClass(c, 'entry')) out.push(c); }
        return out;
      }
      const collectDesc = (el, pred) => {
        for (const c of (el.children || [])) {
          if (c && c.nodeType === 1) {
            if (pred(c)) out.push(c);
            collectDesc(c, pred);
          }
        }
      };
      if (sel === '.glossary-section .category-body') {
        // descendant category-body whose ancestor chain includes glossary-section
        const find = (el, underGlossary) => {
          for (const c of (el.children || [])) {
            if (c && c.nodeType === 1) {
              const ug = underGlossary || matchClass(c, 'glossary-section');
              if (ug && matchClass(c, 'category-body')) out.push(c);
              find(c, ug);
            }
          }
        };
        find(this, false);
        return out;
      }
      if (sel === ':scope > .glossary-group > [data-dictionary]') {
        for (const g of this.children) {
          if (matchClass(g, 'glossary-group')) {
            for (const d of (g.children || [])) {
              if (d && d.getAttribute && d.getAttribute('data-dictionary') != null) out.push(d);
            }
          }
        }
        return out;
      }
      if (sel === '.glossary-content ruby') {
        return out; // no ruby in these fixtures
      }
      // Generic className selector fallback (e.g. unknown) → empty.
      collectDesc(this, () => false);
      return out;
    },
  };
  return node;
}

function makeSandbox(hiddenNames) {
  const fragmentFactory = () => {
    const f = makeElement('documentfragment');
    f.tagName = 'DOCUMENTFRAGMENT';
    return f;
  };
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement('body'),
    _byId: {},
    getElementById(id) { return this._byId[id] || null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) {
      if ((tag || '').toLowerCase() === 'fragment') return fragmentFactory();
      return makeElement(tag);
    },
    createDocumentFragment() { return fragmentFactory(); },
    createTextNode(text) { return { nodeType: 3, textContent: String(text) }; },
    addEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    kanjiResults: [],
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
      build: function(entry, idx) { return buildEntryElement(entry, idx); },
      wrap: function(entry) { return entryGlossaryWrapperOrNull(entry); },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function gloss(dictionary) {
  return { dictionary: dictionary, content: '"def"', definitionTags: '', termTags: '' };
}

// entry with the given dictionary names; reading defaults differ so callers can
// model "same expression, two readings".
function entry(dictNames, opts) {
  const o = opts || {};
  return {
    expression: o.expression || '猫',
    reading: o.reading || 'ねこ',
    glossaries: dictNames.map(gloss),
    frequencies: o.frequencies || [],
    pitches: o.pitches || [],
  };
}

function hasClass(node, cls) {
  if (!node) return false;
  if (node.classList && node.classList.contains(cls)) return true;
  const cn = typeof node.className === 'string' ? node.className : '';
  return cn.split(/\s+/).indexOf(cls) >= 0;
}

function countEntryCards(sb) {
  const container = sb.document.getElementById('entries-container');
  return container.querySelectorAll(':scope > .entry').length;
}

function setupContainer(sb) {
  const container = makeElementFromSandbox(sb);
  container.id = 'entries-container';
  sb.document._byId['entries-container'] = container;
  return container;
}

// reuse the same makeElement shape the sandbox uses (so classList works)
function makeElementFromSandbox(sb) {
  return sb.document.createElement('div');
}

function waitMicroAndTimers() {
  // renderPopup defers rest-entries via setTimeout(...,0); flush them.
  return new Promise((resolve) => setTimeout(resolve, 5));
}

(async function run() {
  // Test 1: two entries, same expression different reading. entry0's only dict is
  // hidden (+ has a frequency badge), entry1 is normal → only ONE .entry card, and
  // no leading/dangling <hr>.
  {
    const sb = loadPopup(['JPDBv2']);
    setupContainer(sb);
    sb.window.lookupEntries = [
      entry(['JPDBv2'], { reading: 'おおかた', frequencies: [{ dictionary: 'JPDBv2', frequencies: [{ value: '15199' }] }] }),
      entry(['Meikyo'], { reading: 'おおがた' }),
    ];
    sb.window.renderPopup();
    await waitMicroAndTimers();
    assert.strictEqual(countEntryCards(sb), 1,
      'an all-hidden entry must not render a shell card; expected 1 card, got '
        + countEntryCards(sb));
    // No <hr> should precede the single surviving card (it became the first card).
    const container = sb.document.getElementById('entries-container');
    const hrCount = container.children.filter(c => c.tagName === 'HR').length;
    assert.strictEqual(hrCount, 0,
      'no separator hr should remain when one of two entries is skipped; got ' + hrCount);
  }

  // Test 2: single normal entry → exactly one card (no regression).
  {
    const sb = loadPopup([]);
    setupContainer(sb);
    sb.window.lookupEntries = [entry(['JMdict'])];
    sb.window.renderPopup();
    await waitMicroAndTimers();
    assert.strictEqual(countEntryCards(sb), 1,
      'a normal single entry must render one card; got ' + countEntryCards(sb));
  }

  // Test 3: kanji-only result (no term entries) → kanji card path unaffected
  // (buildEntryElement is never reached). Assert buildEntryElement isn't what
  // gates kanji and that a normal kanji card still produces a kanji-card-section.
  {
    const sb = loadPopup([]);
    setupContainer(sb);
    sb.window.lookupEntries = [];
    sb.window.kanjiResults = [{ character: '猫', onyomi: 'ビョウ', kunyomi: 'ねこ', meanings: ['cat'] }];
    sb.window.renderPopup();
    await waitMicroAndTimers();
    const container = sb.document.getElementById('entries-container');
    const kanjiSections = container.children.filter(c => hasClass(c, 'kanji-card-section'));
    assert.strictEqual(kanjiSections.length, 1,
      'kanji-only result must still render its kanji card; got ' + kanjiSections.length);
    assert.strictEqual(countEntryCards(sb), 0,
      'kanji-only result has no term cards; got ' + countEntryCards(sb));
  }

  // Test 4: entry has visible glossary AND frequencies → the freq badge still
  // shows (must NOT degrade into "has freq, keep the shell"). The card renders
  // and contains a frequency section.
  {
    const sb = loadPopup([]);
    const card = sb.window.__test.build(
      entry(['JMdict'], { frequencies: [{ dictionary: 'JPDBv2', frequencies: [{ value: '15199' }] }] }), 0);
    assert.notStrictEqual(card, null, 'an entry with a visible glossary must render');
    const hasFreq = card.children.some(c => hasClass(c, 'frequency-section'));
    assert.ok(hasFreq, 'a visible entry with frequencies must keep its frequency section');
  }

  // Test 4b: pure predicate — an entry whose only dictionary is hidden yields a
  // null card (the skip judgement is exactly "glossaryWrapper === null").
  {
    const sb = loadPopup(['JMdict']);
    const card = sb.window.__test.build(entry(['JMdict']), 0);
    assert.strictEqual(card, null,
      'an entry whose only glossary is hidden must produce no card (return null)');
    assert.strictEqual(sb.window.__test.wrap(entry(['JMdict'])), null,
      'entryGlossaryWrapperOrNull must be null when every dict is hidden');
  }

  // Test 5 (incremental alignment, the highest-risk path): three entries rendered
  // where the MIDDLE one is skipped (all-hidden). A load-more then attaches a new
  // glossary to the LAST entry. The new definition must land in the LAST card, not
  // be mis-indexed into another card. With the bug (raw existingEntries[idx]) the
  // skipped middle shifts indices and the wrong card gets the definition.
  {
    const sb = loadPopup(['Hidden']);
    setupContainer(sb);
    const e0 = entry(['JMdict'], { reading: 'a' });
    const e1 = entry(['Hidden'], { reading: 'b' }); // skipped (all hidden)
    const e2 = entry(['Daijirin'], { reading: 'c' });
    sb.window.lookupEntries = [e0, e1, e2];
    sb.window.renderPopup();
    await waitMicroAndTimers();
    assert.strictEqual(countEntryCards(sb), 2,
      'two visible entries (middle skipped) → 2 cards; got ' + countEntryCards(sb));

    // Now a load attaches a SECOND dictionary's glossary to e2 (the last entry).
    e2.glossaries = [gloss('Daijirin'), gloss('Kojien')];
    sb.window.updatePopupIncremental();

    const container = sb.document.getElementById('entries-container');
    const cards = container.querySelectorAll(':scope > .entry');
    assert.strictEqual(cards.length, 2, 'still 2 cards after incremental; got ' + cards.length);
    // The e2 card is the SECOND visible card. Its glossary body must now hold both
    // dictionaries. The e0 card (first) must still hold exactly one.
    const dictNamesIn = (cardEl) => {
      const body = cardEl.querySelector('.glossary-section .category-body');
      if (!body) return [];
      return body.querySelectorAll(':scope > .glossary-group > [data-dictionary]')
        .map(d => d.getAttribute('data-dictionary'));
    };
    const e0Dicts = dictNamesIn(cards[0]);
    const e2Dicts = dictNamesIn(cards[1]);
    assert.deepStrictEqual(e0Dicts.sort(), ['JMdict'],
      'e0 card must keep exactly its own dictionary; got ' + JSON.stringify(e0Dicts));
    assert.deepStrictEqual(e2Dicts.sort(), ['Daijirin', 'Kojien'],
      'the new glossary must land in the e2 card (alignment via _entryDomIndex); got '
        + JSON.stringify(e2Dicts));
  }

  console.log('popup_empty_entry_card_test.js: all assertions passed');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
