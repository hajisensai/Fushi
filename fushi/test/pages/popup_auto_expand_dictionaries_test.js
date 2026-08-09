// TODO-845 behavior test: the lookup popup auto-expands the leading
// `window.autoExpandRows` ROWS of dictionary blocks (force-open <details>) even
// when "collapse dictionaries" is on. The unit is rows, not blocks: the expanded
// count is `rows × effective columns` (popup.js autoExpandCount), so the expanded
// region is always whole top rows of the --dict-columns masonry. At the default
// single column that is identical to the historical absolute block count, so
// rows=1 still reproduces "only the first dictionary is expanded"; 0 collapses
// all. This test EXECUTES the real popup.js createGlossarySection against a
// minimal fake DOM and asserts the resulting <details>.open state per dictionary
// index. Reverting the fix (hardcoding the expand to dictIdx===0 / a bare false,
// or dropping the column multiplier back to a column-blind block count) turns
// this red.
//
// Run: node fushi/test/pages/popup_auto_expand_dictionaries_test.js
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
    autoExpandRows: opts.autoExpandRows,
    // effectiveDictColumns() converges the configured column count against the
    // viewport (each column needs >= DICT_COLUMN_MIN_WIDTH=170px). Default wide
    // so `dictColumns` alone decides unless a case pins a narrow viewport.
    innerWidth: opts.innerWidth === undefined ? 1200 : opts.innerWidth,
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

function loadPopup(opts) {
  const sandbox = makeSandbox(opts);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      section: function(dictName, dictIdx, totalDicts) {
        return createGlossarySection(dictName, [{ content: '"def"', definitionTags: '', termTags: '' }], dictIdx, 0, totalDicts);
      },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

// Return whether the <details> block for a dictionary at `dictIdx` is open,
// given collapse on/off, the auto-expand ROW count and the entry's total block
// count (which caps the effective column count exactly like masonry does).
function isOpen(opts, dictName, dictIdx, totalDicts) {
  const sb = loadPopup(opts);
  const details = sb.window.__test.section(
    dictName || 'JMdict', dictIdx, totalDicts === undefined ? 8 : totalDicts);
  return details.open === true;
}

(function run() {
  // --- collapse OFF: every dictionary opens regardless of the row count. ---
  {
    const opts = { collapseDictionaries: false, autoExpandRows: 1 };
    assert.strictEqual(isOpen(opts, 'JMdict', 0), true, 'collapse off: idx0 open');
    assert.strictEqual(isOpen(opts, 'Daijirin', 3), true, 'collapse off: idx3 open');
  }

  // --- 1 column (default): rows === the historical absolute block count. ---
  // This is the backward-compatibility contract — an existing user who never
  // touched the column slider must see exactly the old behaviour.
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 1, dictColumns: 1 };
    assert.strictEqual(isOpen(opts, 'JMdict', 0), true, '1col rows=1: idx0 open');
    assert.strictEqual(isOpen(opts, 'Daijirin', 1), false, '1col rows=1: idx1 collapsed');
    assert.strictEqual(isOpen(opts, 'Other', 5), false, '1col rows=1: idx5 collapsed');
  }
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 3, dictColumns: 1 };
    assert.strictEqual(isOpen(opts, 'D0', 0), true, '1col rows=3: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1), true, '1col rows=3: idx1 open');
    assert.strictEqual(isOpen(opts, 'D2', 2), true, '1col rows=3: idx2 open');
    assert.strictEqual(isOpen(opts, 'D3', 3), false, '1col rows=3: idx3 collapsed');
  }

  // --- rows=0: nothing auto-expands, whatever the column count. ---
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 0, dictColumns: 3 };
    assert.strictEqual(isOpen(opts, 'D0', 0), false, 'rows=0: idx0 collapsed');
    assert.strictEqual(isOpen(opts, 'D1', 1), false, 'rows=0: idx1 collapsed');
  }

  // --- missing window.autoExpandRows falls back to 1 row. ---
  {
    const opts = { collapseDictionaries: true, autoExpandRows: undefined, dictColumns: 1 };
    assert.strictEqual(isOpen(opts, 'D0', 0), true, 'fallback rows=1: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1), false, 'fallback rows=1: idx1 collapsed');
  }

  // --- THE FIX: the expanded region follows the column count (rows × columns). ---
  // 2 columns, 1 row -> the whole TOP ROW expands (2 blocks), not a lone block
  // that would leave one column a tall card and the other a stack of collapsed
  // bars. This is the case the old column-blind block count got wrong.
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 1, dictColumns: 2 };
    assert.strictEqual(isOpen(opts, 'D0', 0, 6), true, '2col rows=1: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1, 6), true, '2col rows=1: idx1 open (same top row)');
    assert.strictEqual(isOpen(opts, 'D2', 2, 6), false, '2col rows=1: idx2 collapsed');
  }
  // 2 columns, 2 rows -> first two rows (4 blocks) expand.
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 2, dictColumns: 2 };
    assert.strictEqual(isOpen(opts, 'D3', 3, 6), true, '2col rows=2: idx3 open');
    assert.strictEqual(isOpen(opts, 'D4', 4, 6), false, '2col rows=2: idx4 collapsed');
  }
  // 3 columns, 1 row -> 3 blocks.
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 1, dictColumns: 3 };
    assert.strictEqual(isOpen(opts, 'D2', 2, 9), true, '3col rows=1: idx2 open');
    assert.strictEqual(isOpen(opts, 'D3', 3, 9), false, '3col rows=1: idx3 collapsed');
  }

  // --- columns are capped by the entry's real block count, exactly like masonry
  //     (layoutMasonry: cols = min(configured, items.length)). A 4-column setting
  //     on a 2-dictionary entry must not pretend there are 4 cards to expand. ---
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 1, dictColumns: 4 };
    assert.strictEqual(isOpen(opts, 'D0', 0, 2), true, 'cap: idx0 open (2 cards -> 2 cols)');
    assert.strictEqual(isOpen(opts, 'D1', 1, 2), true, 'cap: idx1 open (2 cards -> 2 cols)');
    // Single-dictionary entry collapses to 1 column -> only the first expands.
    assert.strictEqual(isOpen(opts, 'Solo', 0, 1), true, 'cap: solo idx0 open');
    assert.strictEqual(isOpen(opts, 'Solo', 1, 1), false, 'cap: solo idx1 collapsed');
  }

  // --- the viewport convergence in effectiveDictColumns() also applies: a narrow
  //     panel that only fits one 170px column must expand one block per row, even
  //     with a 4-column setting (otherwise a narrow popup over-expands). ---
  {
    const opts = {
      collapseDictionaries: true, autoExpandRows: 1, dictColumns: 4, innerWidth: 300,
    };
    assert.strictEqual(isOpen(opts, 'D0', 0, 8), true, 'narrow: idx0 open');
    assert.strictEqual(isOpen(opts, 'D1', 1, 8), false, 'narrow: idx1 collapsed (1 fitted column)');
  }

  // --- BUG-1264: an explicit per-dictionary collapse OUTRANKS auto-expand. ---
  // 词典管理 的每行折叠开关是用户对该本书的显式决定；autoExpandRows 只是给
  // 「没有显式决定」的词典用的批量默认值。让批量默认压过显式决定，等于把折叠
  // 开关在前 rows×columns 本上变成空操作 —— 用户实际配置 3 行 × 3 列 时，前 9 本
  // 无论点多少次折叠都照样展开。
  {
    const opts = {
      collapseDictionaries: true,
      autoExpandRows: 3,
      dictColumns: 3,
      collapsedDictionaryNames: ['Meikyou', 'Shougakukan'],
    };
    // Inside the auto-expand region (idx 0..8 at 3x3) — the flag must still win.
    assert.strictEqual(isOpen(opts, 'Meikyou', 0, 9), false,
      'per-dict collapsed beats auto-expand at idx0');
    assert.strictEqual(isOpen(opts, 'Shougakukan', 4, 9), false,
      'per-dict collapsed beats auto-expand mid-region');
    // Books WITHOUT the flag keep the old auto-expand behaviour (no regression).
    assert.strictEqual(isOpen(opts, 'Daijirin', 0, 9), true,
      'unflagged dictionary still auto-expands at idx0');
    assert.strictEqual(isOpen(opts, 'Daijirin', 8, 9), true,
      'unflagged dictionary still auto-expands at the last expanded slot');
    assert.strictEqual(isOpen(opts, 'Daijirin', 9, 12), false,
      'unflagged dictionary past the region stays collapsed');
  }
  // The flag also wins when the GLOBAL collapse switch is off — that path used to
  // be the only one honouring it, and must keep honouring it.
  {
    const opts = {
      collapseDictionaries: false,
      autoExpandRows: 1,
      dictColumns: 1,
      collapsedDictionaryNames: ['Meikyou'],
    };
    assert.strictEqual(isOpen(opts, 'Meikyou', 0, 4), false,
      'global collapse off: per-dict flag still collapses');
    assert.strictEqual(isOpen(opts, 'Meikyou', 3, 4), false,
      'global collapse off: per-dict flag collapses outside the region too');
    assert.strictEqual(isOpen(opts, 'Daijirin', 3, 4), true,
      'global collapse off: unflagged dictionary stays open');
  }
  // rows=0 + no flags must stay collapsed (guards against the fix accidentally
  // inverting into "anything unflagged opens").
  {
    const opts = { collapseDictionaries: true, autoExpandRows: 0, dictColumns: 3 };
    assert.strictEqual(isOpen(opts, 'D0', 0, 9), false,
      'rows=0 unflagged: still collapsed after the precedence fix');
  }

  console.log('popup_auto_expand_dictionaries_test.js: all assertions passed');
})();
