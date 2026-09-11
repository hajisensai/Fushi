// BUG-2456 behavior test: a dictionary-body link (惯用句 / 交叉引用) whose text
// carries furigana must send the BASE text as the lookup query, never the
// reading.
//
// Root cause: both link paths in popup.js took the query from `textContent`:
//   - structured-content <a> without `?query=` (renderStructuredContent onclick)
//   - MDX raw-HTML <a href="entry://…"> (handleGlossaryAnchorClick)
// A ruby link `<ruby>足<rt>あし</rt></ruby>が<ruby>棒<rt>ぼう</rt></ruby>になる`
// therefore became「足あしが棒ぼうになる」— and after postProcessRuby, which
// clones every reading into a leading `.ruby-reserve` twin, even
//「あし足あしが棒ぼうになる」. The Dart side runs a longest-prefix scan from
// the head of the string (scan_candidates only yields prefixes), so the only
// hit left is the first kanji「足」→ single-character result → kanji card. That
// is the user-visible「惯用句开头是汉字就进不去，被重定向到那个汉字」.
//
// Fix: `linkVisibleBaseText(el)` collects only base text nodes, skipping
// rt / rp / .ruby-rt / .ruby-reserve; both call sites use it.
//
// This EXECUTES the real popup.js (renderStructuredContent + postProcessRuby +
// the link onclick / handleGlossaryAnchorClick) against a fake-but-sibling-
// correct DOM and asserts the query that reaches `onLinkClick`. A negative
// control asserts the fixture's raw textContent really IS polluted, so the
// test cannot pass hollowly.
//
// Run: node fushi/test/pages/popup_dict_link_query_furigana_test.js
// (also driven from popup_dict_link_query_furigana_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// ---- fake but sibling-correct DOM (same shape as popup_glossary_ruby_element_base_test.js)
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
    get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; },
    appendChild(c) { if (c.parentNode) c.parentNode._remove(c); c.parentNode = this; this.childNodes.push(c); return c; },
    insertBefore(c, ref) { if (c.parentNode) c.parentNode._remove(c); c.parentNode = this; const i = ref ? this.childNodes.indexOf(ref) : -1; if (i >= 0) this.childNodes.splice(i, 0, c); else this.childNodes.push(c); return c; },
    append(...nodes) { for (const n of nodes) this.appendChild(typeof n === 'string' ? mkText(n) : n); },
    _remove(c) { const i = this.childNodes.indexOf(c); if (i >= 0) this.childNodes.splice(i, 1); c.parentNode = null; },
    replaceWith(...nodes) { replaceChild(this, nodes); },
    setAttribute(k, v) { this.attributes[k] = String(v); if (k === 'class') this.className = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); },
    removeAttribute(k) { delete this.attributes[k]; },
    addEventListener() {}, closest() { return null; },
    getBoundingClientRect() { return { left: 1, top: 2, width: 3, height: 4 }; },
    querySelectorAll(sel) {
      const out = [];
      const groups = parseSelectorList(sel);
      if (groups.length === 0) return out;
      const walk = (n, ancestors) => {
        for (const c of (n.childNodes || [])) {
          if (c.nodeType !== 1) continue;
          if (groups.some((chain) => matchesChain(chain, c, ancestors))) out.push(c);
          walk(c, ancestors.concat([c]));
        }
      };
      walk(this, [this]);
      return out;
    },
    querySelector(sel) { const a = this.querySelectorAll(sel); return a[0] || null; },
  };
  return el;
}
function parseSimple(token) {
  const parts = String(token).split('.');
  const tag = parts[0] ? parts[0].toUpperCase() : null;
  return { tag: (!tag || tag === '*') ? null : tag, classes: parts.slice(1).filter(Boolean) };
}
function parseSelectorList(sel) {
  return String(sel || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => part.split(/\s+/).filter(Boolean).map(parseSimple))
    .filter((chain) => chain.length > 0);
}
function matchesSimple(el, simple) {
  if (!el || el.nodeType !== 1) return false;
  if (simple.tag && el.tagName !== simple.tag) return false;
  return simple.classes.every((c) => el.classList && el.classList.contains(c));
}
function matchesChain(chain, node, ancestors) {
  if (!matchesSimple(node, chain[chain.length - 1])) return false;
  let j = ancestors.length - 1;
  for (let i = chain.length - 2; i >= 0; i--) {
    let found = false;
    while (j >= 0) {
      const hit = matchesSimple(ancestors[j], chain[i]);
      j--;
      if (hit) { found = true; break; }
    }
    if (!found) return false;
  }
  return true;
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

const linkCalls = [];
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
  flutter_inappwebview: {
    callHandler(name, ...args) {
      if (name === 'onLinkClick') linkCalls.push(args);
      return Promise.resolve(false);
    },
  },
  getSelection() { return { toString() { return ''; } }; },
};
documentObj.defaultView = windowObj;
const sandbox = {
  Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  Date, Math, URL, URLSearchParams, JSON, RegExp, Set, Map, Object, Array, console,
  performance: { now() { return 0; } }, setTimeout, clearTimeout,
  DOMParser: class { parseFromString() { return { body: mkEl('body'), querySelectorAll() { return []; } }; } },
  document: documentObj, window: windowObj, getComputedStyle() { return {}; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(source + `
  ;window.__t = {
    render: renderStructuredContent,
    post: postProcessRuby,
    anchorClick: handleGlossaryAnchorClick,
    baseText: linkVisibleBaseText,
  };
`, sandbox, { filename: 'popup.js' });

const fakeEvent = { preventDefault() {}, stopPropagation() {} };

// 明鏡 逆引き 惯用句链接的结构化内容形态：每个汉字自带 <ruby>/<rt>。
function idiomLinkNode(href) {
  return {
    tag: 'a', href,
    content: [
      { tag: 'ruby', content: ['足', { tag: 'rt', content: 'あし' }] },
      'が',
      { tag: 'ruby', content: ['棒', { tag: 'rt', content: 'ぼう' }] },
      'になる',
    ],
  };
}

function renderLink(href) {
  const gloss = mkEl('div');
  gloss.classList.add('glossary-content');
  sandbox.window.__t.render(gloss, idiomLinkNode(href), 'ja', '明鏡国語辞典 第三版', false);
  sandbox.window.__t.post(gloss);
  const a = gloss.querySelectorAll('.glossary-content a')[0];
  assert.ok(a, 'renderStructuredContent must produce an <a> under .glossary-content');
  return a;
}

// (1) Structured-content link WITHOUT ?query= (query comes from the link text).
{
  linkCalls.length = 0;
  const a = renderLink('entry://足が棒になる');
  // Negative control: the raw textContent really is polluted by readings (and
  // by the .ruby-reserve twin postProcessRuby inserts BEFORE each base), so the
  // assertion below cannot pass by accident.
  const raw = a.textContent;
  assert.ok(raw.includes('あし') && raw.includes('ぼう'),
    `fixture must carry furigana in textContent, got ${JSON.stringify(raw)}`);
  assert.notStrictEqual(raw, '足が棒になる', 'negative control: raw textContent must differ from the base text');
  assert.strictEqual(typeof a.onclick, 'function', 'structured-content link must install onclick');
  a.onclick(fakeEvent);
  assert.strictEqual(linkCalls.length, 1, 'link click must trigger exactly one onLinkClick');
  assert.strictEqual(linkCalls[0][0], '足が棒になる',
    `structured-content link query must be the base text, got ${JSON.stringify(linkCalls[0][0])}`);
}

// (2) Structured-content link WITH ?query= keeps using the explicit query.
{
  linkCalls.length = 0;
  const a = renderLink('?query=足が棒になる&x=1');
  a.onclick(fakeEvent);
  assert.strictEqual(linkCalls.length, 1);
  assert.strictEqual(linkCalls[0][0], '足が棒になる', '?query= stays authoritative');
}

// (3) ?query= present but empty falls back to the base text, not textContent.
{
  linkCalls.length = 0;
  const a = renderLink('?foo=bar');
  a.onclick(fakeEvent);
  assert.strictEqual(linkCalls.length, 1);
  assert.strictEqual(linkCalls[0][0], '足が棒になる', 'missing query param falls back to base text');
}

// (4) MDX raw-HTML anchor path (handleGlossaryAnchorClick) after postProcessRuby.
{
  linkCalls.length = 0;
  const gloss = mkEl('div');
  gloss.classList.add('glossary-content');
  const a = mkEl('a');
  a.setAttribute('href', 'entry://足が棒になる（あしがぼうになる）');
  const r1 = mkEl('ruby'); r1.append('足'); const t1 = mkEl('rt'); t1.append('あし'); r1.appendChild(t1);
  const r2 = mkEl('ruby'); r2.append('棒'); const t2 = mkEl('rt'); t2.append('ぼう'); r2.appendChild(t2);
  a.appendChild(r1); a.append('が'); a.appendChild(r2); a.append('になる');
  gloss.appendChild(a);
  sandbox.window.__t.post(gloss);
  assert.notStrictEqual(a.textContent, '足が棒になる', 'negative control (MDX): textContent polluted');
  let prevented = false;
  sandbox.window.__t.anchorClick({ preventDefault() { prevented = true; } }, a);
  assert.strictEqual(prevented, true, 'MDX anchor click must preventDefault (BUG-767)');
  assert.strictEqual(linkCalls.length, 1);
  assert.strictEqual(linkCalls[0][0], '足が棒になる',
    `MDX anchor query must be the base text, got ${JSON.stringify(linkCalls[0][0])}`);
}

// (5) Plain (no ruby) links are unchanged; whitespace collapses to one space.
{
  const a = mkEl('a');
  a.append('run '); const s = mkEl('span'); s.append('  away\n'); a.appendChild(s);
  assert.strictEqual(sandbox.window.__t.baseText(a), 'run away');
  assert.strictEqual(sandbox.window.__t.baseText(null), '');
}

console.log('all assertions passed');
