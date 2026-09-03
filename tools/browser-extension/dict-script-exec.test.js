const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Behaviour guard for runDictScripts (dict-media.js): MDX dictionaries ship
// their own <script> tags, which never execute when the entry HTML is inserted
// via innerHTML. Executing them is what brings back NLT's frequency bars and
// OALDPEX's config UI — but they are written as if each entry were its own
// document, so they must not be able to reach another dictionary's DOM.
//
// Loaded into a fresh VM context with a hand-rolled minimal DOM (no jsdom), the
// same way dict-media.test.js does it.
const VENDOR = path.join(__dirname, 'vendor', 'dict-media.js');
const src = fs.readFileSync(VENDOR, 'utf8');

// --- minimal DOM ------------------------------------------------------------

function makeEl(tag, attrs = {}, textContent = '') {
  const el = {
    tagName: String(tag).toUpperCase(),
    children: [],
    parent: null,
    dataset: {},
    textContent,
    _attrs: { ...attrs },
    removed: false,
    _listeners: [],
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
    },
    setAttribute(name, value) {
      this._attrs[name] = value;
    },
    append(child) {
      child.parent = this;
      this.children.push(child);
      return child;
    },
    remove() {
      this.removed = true;
      if (this.parent) {
        const i = this.parent.children.indexOf(this);
        if (i >= 0) this.parent.children.splice(i, 1);
        this.parent = null;
      }
    },
    addEventListener(type, fn) {
      this._listeners.push([type, fn]);
    },
    removeEventListener() {},
    _walk(out) {
      for (const c of this.children) {
        out.push(c);
        c._walk(out);
      }
      return out;
    },
    // Only tag selectors and "#id" are needed by these tests.
    querySelectorAll(selector) {
      const all = this._walk([]);
      if (selector.startsWith('#')) {
        return all.filter((e) => e.getAttribute('id') === selector.slice(1));
      }
      const want = selector.toUpperCase();
      return all.filter((e) => e.tagName === want);
    },
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    },
    getElementsByClassName() {
      return [];
    },
    getElementsByTagName(name) {
      return this.querySelectorAll(name);
    },
  };
  return el;
}

function makeContext({ assets = {}, calls = [] } = {}) {
  const realDocument = {
    __isRealDocument: true,
    createElement: (t) => makeEl(t),
    querySelectorAll: () => {
      throw new Error('dictionary script reached the REAL document');
    },
    querySelector: () => {
      throw new Error('dictionary script reached the REAL document');
    },
    addEventListener: () => {
      throw new Error('dictionary script reached the REAL document');
    },
    body: { __isRealBody: true },
    documentElement: { __isRealHtml: true },
    readyState: 'loading',
  };

  const windowObj = {
    flutter_inappwebview: {
      callHandler: async (name, args) => {
        calls.push([name, args]);
        if (name === 'getDictAsset') {
          const key = `${args.dictionary}|${args.path}`;
          return Object.prototype.hasOwnProperty.call(assets, key) ? assets[key] : null;
        }
        return null;
      },
    },
  };

  const ctx = {
    window: windowObj,
    document: realDocument,
    CSS: { escape: (s) => String(s) },
    Event: class Event {
      constructor(type) {
        this.type = type;
      }
    },
    Promise,
    console,
    calls,
  };
  ctx.self = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx;
}

function dictRoot(dictName, scripts, extraChildren = []) {
  const root = makeEl('div', { 'data-dictionary': dictName });
  root.dataset.dictionary = dictName;
  for (const child of extraChildren) root.append(child);
  for (const s of scripts) {
    root.append(makeEl('script', s.src ? { src: s.src } : {}, s.code || ''));
  }
  return root;
}

// --- tests ------------------------------------------------------------------

test('inline scripts execute against the dictionary subtree', async () => {
  const ctx = makeContext();
  const row = makeEl('tr');
  const root = dictRoot('NLT', [{ code: "document.querySelectorAll('tr').forEach(r => r.setAttribute('marked','1'));" }], [row]);

  await ctx.runDictScripts(root, 'NLT');

  assert.strictEqual(row.getAttribute('marked'), '1', 'inline script did not run');
});

test('a src script is fetched through the bridge by dictionary + path', async () => {
  const calls = [];
  const ctx = makeContext({
    assets: { 'NLT|NLT.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('bar','1'));" },
    calls,
  });
  const row = makeEl('tr');
  const root = dictRoot('NLT', [{ src: 'NLT.js' }], [row]);

  await ctx.runDictScripts(root, 'NLT');

  // Field-by-field: the args object is created inside the VM realm, so its
  // prototype is not reference-equal to this realm's Object.prototype.
  assert.strictEqual(calls[0][0], 'getDictAsset');
  assert.strictEqual(calls[0][1].dictionary, 'NLT');
  assert.strictEqual(calls[0][1].path, 'NLT.js');
  assert.strictEqual(row.getAttribute('bar'), '1', 'fetched script did not run');
});

test('DOMContentLoaded handlers fire even though the popup loaded long ago', async () => {
  const ctx = makeContext({
    assets: {
      'NLT|NLT.js':
        "document.addEventListener('DOMContentLoaded', function(){" +
        "document.querySelectorAll('tr').forEach(r => r.setAttribute('ready','1')); });",
    },
  });
  const row = makeEl('tr');
  const root = dictRoot('NLT', [{ src: 'NLT.js' }], [row]);

  await ctx.runDictScripts(root, 'NLT');
  await new Promise((r) => setImmediate(r)); // let the microtask land

  assert.strictEqual(row.getAttribute('ready'), '1', 'DOMContentLoaded never fired');
});

test('a script cannot reach another dictionary\'s rows', async () => {
  const ctx = makeContext({
    assets: { 'NLT|NLT.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('touched','1'));" },
  });
  const mine = makeEl('tr');
  const theirs = makeEl('tr');
  const otherRoot = dictRoot('OtherDict', [], [theirs]);
  const root = dictRoot('NLT', [{ src: 'NLT.js' }], [mine]);
  // Both dictionaries live in one popup document.
  const page = makeEl('div');
  page.append(otherRoot);
  page.append(root);

  await ctx.runDictScripts(root, 'NLT');

  assert.strictEqual(mine.getAttribute('touched'), '1', 'own row not touched');
  assert.strictEqual(theirs.getAttribute('touched'), null, 'reached another dictionary');
});

test('multiple scripts share one scope, so a var from an earlier one is visible', async () => {
  const ctx = makeContext({
    assets: {
      'OALD|a.js': 'var sharedConfig = { flag: 7 };',
      'OALD|b.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('flag', String(sharedConfig.flag)));",
    },
  });
  const row = makeEl('tr');
  const root = dictRoot('OALD', [{ src: 'a.js' }, { src: 'b.js' }], [row]);

  await ctx.runDictScripts(root, 'OALD');

  assert.strictEqual(row.getAttribute('flag'), '7', 'later script could not see the earlier var');
});

test('a missing asset is skipped and the remaining scripts still run', async () => {
  const ctx = makeContext({
    assets: { 'OALD|present.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('ok','1'));" },
    // 'OALD|missing.js' deliberately absent -> bridge returns null (404-alike)
  });
  const row = makeEl('tr');
  const root = dictRoot('OALD', [{ src: 'missing.js' }, { src: 'present.js' }], [row]);

  await ctx.runDictScripts(root, 'OALD');

  assert.strictEqual(row.getAttribute('ok'), '1', 'a missing script blocked the rest');
});

test('a throwing script does not stop the next one', async () => {
  const ctx = makeContext({
    assets: {
      'OALD|boom.js': 'throw new Error("boom");',
      'OALD|after.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('after','1'));",
    },
  });
  const row = makeEl('tr');
  const root = dictRoot('OALD', [{ src: 'boom.js' }, { src: 'after.js' }], [row]);

  await ctx.runDictScripts(root, 'OALD');

  assert.strictEqual(row.getAttribute('after'), '1', 'a throwing script took down the rest');
});

test('scripts run once per dictionary block and the tags are removed', async () => {
  const ctx = makeContext({
    assets: { 'NLT|count.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('n', String((+(r.getAttribute('n')||0))+1)));" },
  });
  const row = makeEl('tr');
  const root = dictRoot('NLT', [{ src: 'count.js' }], [row]);

  await ctx.runDictScripts(root, 'NLT');
  await ctx.runDictScripts(root, 'NLT');

  assert.strictEqual(row.getAttribute('n'), '1', 'scripts ran more than once for one block');
  assert.strictEqual(root.querySelectorAll('script').length, 0, 'executed <script> tags were left in the DOM');
});

test('the asset source is fetched once and reused across blocks', async () => {
  const calls = [];
  const ctx = makeContext({
    assets: { 'NLT|NLT.js': "document.querySelectorAll('tr').forEach(r => r.setAttribute('x','1'));" },
    calls,
  });
  const rootA = dictRoot('NLT', [{ src: 'NLT.js' }], [makeEl('tr')]);
  const rootB = dictRoot('NLT', [{ src: 'NLT.js' }], [makeEl('tr')]);

  await ctx.runDictScripts(rootA, 'NLT');
  await ctx.runDictScripts(rootB, 'NLT');

  const fetches = calls.filter(([name]) => name === 'getDictAsset');
  assert.strictEqual(fetches.length, 1, `expected one fetch, got ${fetches.length}`);
});

test('document.body inside a dictionary script is the dictionary block', async () => {
  const ctx = makeContext({
    assets: { 'NLT|NLT.js': "if (document.body.__isRealBody) { throw new Error('got real body'); } document.body.setAttribute('scoped','1');" },
  });
  const root = dictRoot('NLT', [{ src: 'NLT.js' }]);

  await ctx.runDictScripts(root, 'NLT');

  assert.strictEqual(root.getAttribute('scoped'), '1', 'document.body was not scoped to the block');
});
