// BUG-732 behavior test: dictionary glossary furigana whose ruby base is an
// ELEMENT (<rb> / <span> / nested structured-content, as monolingual dicts like
// 明鏡 emit) must still get a per-base <span class="ruby-unit"> so its <rt>
// anchors to — and reserves vertical room above — its own kanji. Before the fix,
// postProcessRuby only wrapped BARE TEXT NODE bases (node.nodeType !== TEXT_NODE
// → continue), so an element base got no .ruby-unit; popup.css's
// rt{position:absolute; top:0} then anchored the reading to the bare <ruby>
// (line-height:1, no padding-top reserve) and the furigana collapsed onto the
// base (the reported "注音重叠上文字了" screenshot).
//
// This EXECUTES the real popup.js renderStructuredContent + postProcessRuby
// against a fake-but-sibling-correct DOM and asserts, per base kind, that the
// <rt> lands INSIDE a .ruby-unit rather than staying a direct child of <ruby>
// (= the overlap signature). Reverting the fix turns the element-base cases red.
//
// Run: node hibiki/test/pages/popup_glossary_ruby_element_base_test.js
// (also driven from popup_glossary_ruby_element_base_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// ---- fake but sibling-correct DOM ----------------------------------------
function mkText(text) {
  return {
    nodeType: 3, _text: String(text), parentNode: null,
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); },
    get nextSibling() { return siblingOf(this, 1); },
    replaceWith(...nodes) { replaceChild(this, nodes); },
  };
}
function mkEl(tag) {
  const el = {
    nodeType: 1, tagName: (tag || 'div').toUpperCase(),
    _className: '', id: '', style: {}, attributes: {},
    childNodes: [], parentNode: null,
    classList: {
      _s: new Set(),
      add(n) { this._s.add(n); el._className = [...this._s].join(' '); },
      remove(n) { this._s.delete(n); el._className = [...this._s].join(' '); },
      contains(n) { return this._s.has(n); },
    },
    get className() { return this._className; },
    set className(v) { this._className = String(v); this.classList._s = new Set(String(v).split(/\s+/).filter(Boolean)); },
    get children() { return this.childNodes.filter((n) => n.nodeType === 1); },
    get textContent() { return this.childNodes.map((n) => n.textContent).join(''); },
    set textContent(v) { this.childNodes = []; if (v !== '') this.appendChild(mkText(v)); },
    get firstChild() { return this.childNodes[0] || null; },
    get nextSibling() { return siblingOf(this, 1); },
    appendChild(c) { if (c.parentNode) c.parentNode._remove(c); c.parentNode = this; this.childNodes.push(c); return c; },
    append(...nodes) { for (const n of nodes) this.appendChild(typeof n === 'string' ? mkText(n) : n); },
    _remove(c) { const i = this.childNodes.indexOf(c); if (i >= 0) this.childNodes.splice(i, 1); c.parentNode = null; },
    replaceWith(...nodes) { replaceChild(this, nodes); },
    setAttribute(k, v) { this.attributes[k] = String(v); if (k === 'class') this.className = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    removeAttribute(k) { delete this.attributes[k]; },
    addEventListener() {}, closest() { return null; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; },
    querySelectorAll(sel) {
      const out = [];
      const selfGloss = this.classList && this.classList.contains('glossary-content');
      const walk = (n, underGloss) => {
        for (const c of (n.childNodes || [])) {
          if (c.nodeType !== 1) continue;
          const ug = underGloss || (c.classList && c.classList.contains('glossary-content'));
          if (sel === '.glossary-content ruby' && ug && c.tagName === 'RUBY') out.push(c);
          walk(c, ug);
        }
      };
      walk(this, selfGloss);
      return out;
    },
    querySelector(sel) { const a = this.querySelectorAll(sel); return a[0] || null; },
  };
  return el;
}
function siblingOf(node, dir) {
  const p = node.parentNode; if (!p) return null;
  const i = p.childNodes.indexOf(node); const j = i + dir;
  return (j >= 0 && j < p.childNodes.length) ? p.childNodes[j] : null;
}
function replaceChild(node, nodes) {
  const p = node.parentNode; if (!p) return;
  const i = p.childNodes.indexOf(node);
  const arr = nodes.map((n) => (typeof n === 'string' ? mkText(n) : n));
  for (const a of arr) { if (a.parentNode) a.parentNode._remove(a); a.parentNode = p; }
  p.childNodes.splice(i, 1, ...arr);
  node.parentNode = null;
}

const documentObj = {
  createElement(tag) { return mkEl(tag); },
  createTextNode(t) { return mkText(t); },
  createDocumentFragment() { const f = mkEl('documentfragment'); f.tagName = 'DOCUMENTFRAGMENT'; return f; },
  documentElement: { style: {}, classList: mkEl().classList },
  head: { appendChild() {} }, body: mkEl('body'),
  getElementById() { return null; }, querySelector() { return null; }, querySelectorAll() { return []; },
  addEventListener() {},
};
const windowObj = {
  flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
  getSelection() { return { toString() { return ''; } }; },
};
documentObj.defaultView = windowObj;
const sandbox = {
  Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
  performance: { now() { return 0; } }, setTimeout, clearTimeout,
  DOMParser: class { parseFromString() { return { body: mkEl('body'), querySelectorAll() { return []; } }; } },
  document: documentObj, window: windowObj, getComputedStyle() { return {}; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(source + `
  ;window.__t = { render: renderStructuredContent, post: postProcessRuby };
`, sandbox, { filename: 'popup.js' });

// Render a structured-content ruby node into a .glossary-content div, run
// postProcessRuby, and report where each <rt> landed.
function analyze(rubyNode) {
  const gloss = mkEl('div');
  gloss.classList.add('glossary-content');
  sandbox.window.__t.render(gloss, rubyNode);
  sandbox.window.__t.post(gloss);
  const ruby = gloss.querySelectorAll('.glossary-content ruby')[0];
  assert.ok(ruby, 'renderStructuredContent must produce a <ruby> under .glossary-content');
  const units = ruby.childNodes.filter((n) => n.nodeType === 1 && n.classList && n.classList.contains('ruby-unit'));
  const rtDirectlyUnderRuby = ruby.childNodes.filter((n) => n.nodeType === 1 && n.tagName === 'RT').length;
  const rtInsideUnits = units.reduce((a, u) => a + u.childNodes.filter((n) => n.nodeType === 1 && n.tagName === 'RT').length, 0);
  return { units: units.length, rtDirectlyUnderRuby, rtInsideUnits, ruby, unitList: units };
}

function ruby(content) { return { tag: 'ruby', content }; }
function rt(reading) { return { tag: 'rt', content: reading }; }

// Case 1 — bare text base (regression: this already worked pre-fix).
{
  const r = analyze(ruby(['未然形', rt('みぜんけい')]));
  assert.strictEqual(r.units, 1, 'bare-text base: one .ruby-unit; got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0, 'bare-text base: no <rt> left directly under <ruby>; got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 1, 'bare-text base: the <rt> must live inside the .ruby-unit; got ' + r.rtInsideUnits);
}

// Case 2 — <rb> element base (明鏡-style). THE bug: pre-fix this had 0 units and
// the <rt> stayed a direct child of <ruby> (collapsed onto the base).
{
  const r = analyze(ruby([{ tag: 'rb', content: '未然形' }, rt('みぜんけい')]));
  assert.strictEqual(r.units, 1, '<rb> element base: must still get one .ruby-unit (BUG-732); got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0,
    '<rb> element base: NO <rt> may remain a direct child of <ruby> — that is the overlap signature (BUG-732); got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 1, '<rb> element base: the <rt> must be moved INTO the .ruby-unit (BUG-732); got ' + r.rtInsideUnits);
  // The <rb> element itself must survive inside the unit (lookup selection stays live).
  const unit = r.unitList[0];
  const hasRb = unit.childNodes.some((n) => n.nodeType === 1 && n.tagName === 'RB');
  assert.ok(hasRb, '<rb> element base: the base element must be moved into the unit, not flattened away');
  assert.ok(unit.textContent.indexOf('未然形') >= 0, '<rb> element base: base text must remain selectable inside the unit');
}

// Case 3 — <span> element base (structured-content wrapper).
{
  const r = analyze(ruby([{ tag: 'span', content: '未然形' }, rt('みぜんけい')]));
  assert.strictEqual(r.units, 1, '<span> element base: must get one .ruby-unit (BUG-732); got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0, '<span> element base: no <rt> may remain under <ruby> (BUG-732); got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 1, '<span> element base: the <rt> must live inside the .ruby-unit (BUG-732); got ' + r.rtInsideUnits);
}

// Case 4 — nested structured-content base ({type:'structured-content'} → <span>).
{
  const r = analyze(ruby([{ type: 'structured-content', content: '未然形' }, rt('みぜんけい')]));
  assert.strictEqual(r.units, 1, 'nested structured-content base: must get one .ruby-unit (BUG-732); got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0, 'nested base: no <rt> may remain under <ruby> (BUG-732); got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 1, 'nested base: the <rt> must live inside the .ruby-unit (BUG-732); got ' + r.rtInsideUnits);
}

// Case 5 — multi-kanji word, bare-text bases (BUG-722 must not regress): each
// base's own <rt> anchors into its own unit; no <rt> superimposes on the whole word.
{
  const r = analyze(ruby(['将', rt('しょう'), '棋', rt('ぎ')]));
  assert.strictEqual(r.units, 2, 'multi-kanji: one .ruby-unit per base (BUG-722); got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0, 'multi-kanji: no <rt> left under <ruby> (BUG-722); got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 2, 'multi-kanji: each <rt> inside its own unit (BUG-722); got ' + r.rtInsideUnits);
  assert.strictEqual(r.unitList[0].childNodes.filter((n) => n.nodeType === 1 && n.tagName === 'RT').length, 1, 'unit 0 holds exactly its own <rt>');
  assert.strictEqual(r.unitList[1].childNodes.filter((n) => n.nodeType === 1 && n.tagName === 'RT').length, 1, 'unit 1 holds exactly its own <rt>');
}

// Case 6 — multi-kanji word, <rb> element bases (both prior bugs at once).
{
  const r = analyze(ruby([
    { tag: 'rb', content: '将' }, rt('しょう'),
    { tag: 'rb', content: '棋' }, rt('ぎ'),
  ]));
  assert.strictEqual(r.units, 2, 'multi-kanji <rb> bases: one .ruby-unit per base; got ' + r.units);
  assert.strictEqual(r.rtDirectlyUnderRuby, 0, 'multi-kanji <rb> bases: no <rt> left under <ruby>; got ' + r.rtDirectlyUnderRuby);
  assert.strictEqual(r.rtInsideUnits, 2, 'multi-kanji <rb> bases: each <rt> inside its own unit; got ' + r.rtInsideUnits);
}

console.log('popup_glossary_ruby_element_base_test.js: all assertions passed');
