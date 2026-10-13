'use strict';
// BUG-3323: executes the production __fushiEnsureHighlightPaintable installer from
// reader_selection_scripts.dart (read from the worktree, never a pinned copy)
// against a fake DOM whose computed styles are declared per element / pseudo.
// Layout itself cannot run in node; the WebKit painting fact the helper encodes
// (no ::highlight() on text laid out in an anonymous block) is recorded with
// Playwright WebKit + iOS 26.5 simulator pixel evidence in the bug file.
// Run from any cwd: node <path>/reader_highlight_paintable_bug3277_test.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.resolve(__dirname, '../../lib/src/reader/reader_selection_scripts.dart'),
  'utf8').replace(/\r/g, '');
const startMarker =
  "if (typeof window.__fushiEnsureHighlightPaintable !== 'function') {";
const start = source.indexOf(startMarker);
assert(start >= 0, 'missing production installer for __fushiEnsureHighlightPaintable');
const end = source.indexOf('\n  })();\n}', start);
assert(end > start, 'missing end of the installer');
const installer = source.slice(start, end + '\n  })();\n}'.length);

const TEXT_NODE = 3;
const ELEMENT_NODE = 1;

class Text {
  constructor(data) { this.nodeType = TEXT_NODE; this.data = data; this.parentNode = null; }
}
class Element {
  constructor(localName, style = {}, pseudo = {}) {
    this.nodeType = ELEMENT_NODE;
    this.localName = localName;
    this.childNodes = [];
    this.parentNode = null;
    this.computed = Object.assign({display: 'inline', position: 'static', cssFloat: 'none'}, style);
    this.pseudo = pseudo;
  }
  get firstElementChild() {
    return this.childNodes.find(n => n.nodeType === ELEMENT_NODE) || null;
  }
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    for (let i = siblings.indexOf(this) + 1; i < siblings.length; i++) {
      if (siblings[i].nodeType === ELEMENT_NODE) return siblings[i];
    }
    return null;
  }
  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    this.childNodes.push(node);
    node.parentNode = this;
    return node;
  }
  removeChild(node) {
    assert.equal(node.parentNode, this);
    this.childNodes.splice(this.childNodes.indexOf(node), 1);
    node.parentNode = null;
  }
  insertBefore(node, before) {
    if (node.parentNode) node.parentNode.removeChild(node);
    const index = this.childNodes.indexOf(before);
    assert(index >= 0, 'insertBefore reference is not a child');
    this.childNodes.splice(index, 0, node);
    node.parentNode = this;
    return node;
  }
}

function makeWindow(userAgent) {
  const window = {
    navigator: {userAgent: userAgent || ''},
    getComputedStyle(el, pseudo) {
      if (pseudo) {
        return Object.assign({display: 'inline', position: 'static', cssFloat: 'none', content: 'none'},
          el.pseudo[pseudo] || {});
      }
      return el.computed;
    },
  };
  window.window = window;
  const context = vm.createContext({
    window,
    Node: {TEXT_NODE, ELEMENT_NODE},
    document: {createElement: name => new Element(name)},
  });
  vm.runInContext(installer, context);
  assert.equal(typeof window.__fushiEnsureHighlightPaintable, 'function');
  return window;
}

function paragraph(style, pseudo, ...children) {
  const p = new Element('p', Object.assign({display: 'block'}, style), pseudo);
  for (const child of children) p.appendChild(child);
  return p;
}

const BLOCK_AFTER = {'::after': {content: '""', display: 'block'}};
let checks = 0;

// 1. The BUG-2761 WebKit paginated reserve: block p::after. Text must be moved,
//    unchanged and with the same identity, into the unstyled inline wrapper.
{
  const win = makeWindow();
  const text = new Text('妹の手には絵日記帳の表紙があった。');
  const ruby = new Element('ruby');
  const p = paragraph({}, BLOCK_AFTER, text, ruby);
  win.__fushiEnsureHighlightPaintable(text);
  const wrapper = p.childNodes[0];
  assert.equal(wrapper.localName, 'fushi-hl-text', 'text in an anonymous block must be wrapped');
  assert.equal(wrapper.childNodes.length, 1);
  assert.equal(wrapper.childNodes[0], text, 'the same Text node is moved, not copied');
  assert.equal(text.data, '妹の手には絵日記帳の表紙があった。');
  assert.equal(p.childNodes[1], ruby, 'sibling order is preserved');
  assert.equal(p.childNodes.length, 2, 'the wrapper replaces the text in place');
  // Idempotent: a second call on the already-wrapped node is a no-op.
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode, wrapper);
  assert.equal(p.childNodes[0], wrapper);
  checks++;
}

// 2. A real in-flow block child element (book markup) triggers the same wrap.
{
  const win = makeWindow();
  const text = new Text('本文');
  const div = new Element('div', {display: 'block'});
  div.appendChild(text);
  div.appendChild(new Element('div', {display: 'block'}));
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode.localName, 'fushi-hl-text');
  checks++;
}

// 3. A flex / grid container makes direct text an anonymous item.
{
  const win = makeWindow();
  const text = new Text('本文');
  paragraph({display: 'flex'}, {}, text);
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode.localName, 'fushi-hl-text');
  checks++;
}

// 4. Cases the engine already lays out under a real element: untouched.
{
  const cases = [
    ['plain block paragraph', () => paragraph({}, {}, new Text('a'))],
    ['inline-only children', () => paragraph({}, {}, new Text('a'), new Element('ruby'), new Element('span'))],
    ['inline ::after', () => paragraph({}, {'::after': {content: '""', display: 'inline'}}, new Text('a'))],
    ['inline-block ::after', () => paragraph({}, {'::after': {content: '""', display: 'inline-block'}}, new Text('a'))],
    ['::after without content', () => paragraph({}, {'::after': {content: 'none', display: 'block'}}, new Text('a'))],
    ['absolutely positioned ::after', () => paragraph({}, {'::after': {content: '""', display: 'block', position: 'absolute'}}, new Text('a'))],
    ['floated block child', () => paragraph({}, {}, new Text('a'), new Element('img', {display: 'block', cssFloat: 'left'}))],
    ['display:none block child', () => paragraph({}, {}, new Text('a'), new Element('div', {display: 'none'}))],
  ];
  for (const [name, build] of cases) {
    const win = makeWindow();
    const p = build();
    const text = p.childNodes[0];
    win.__fushiEnsureHighlightPaintable(text);
    assert.equal(text.parentNode, p, `${name}: must not be wrapped`);
    checks++;
  }
}

// 5. Text whose parent is inline (a span inside the block) already paints.
{
  const win = makeWindow();
  const text = new Text('a');
  const span = new Element('span', {display: 'inline'});
  span.appendChild(text);
  paragraph({}, BLOCK_AFTER, span);
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode, span);
  checks++;
}

// 6. Non-text / detached input never throws or mutates.
{
  const win = makeWindow();
  win.__fushiEnsureHighlightPaintable(null);
  win.__fushiEnsureHighlightPaintable(new Text('detached'));
  const el = paragraph({}, BLOCK_AFTER);
  win.__fushiEnsureHighlightPaintable(el);
  assert.equal(el.childNodes.length, 0);
  checks++;
}

// 7. The installer is idempotent: an existing implementation is kept.
{
  const window = {};
  window.window = window;
  const existing = () => 'kept';
  window.__fushiEnsureHighlightPaintable = existing;
  vm.runInContext(installer, vm.createContext({window, Node: {TEXT_NODE, ELEMENT_NODE}, document: {}}));
  assert.equal(window.__fushiEnsureHighlightPaintable, existing);
  checks++;
}

// 8. Blink paints highlights in anonymous blocks: the helper must be a no-op there
//    (Android WebView and WebView2 user agents), even for the BUG-2761 shape.
for (const ua of [
  'Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.0.0 Mobile Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0',
]) {
  const win = makeWindow(ua);
  const text = new Text('本文');
  const p = paragraph({}, BLOCK_AFTER, text);
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode, p, `Blink must not be wrapped: ${ua}`);
  checks++;
}
// WebKit user agents (iOS WKWebView, WPE) still wrap.
{
  const win = makeWindow('Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148');
  const text = new Text('本文');
  paragraph({}, BLOCK_AFTER, text);
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode.localName, 'fushi-hl-text');
  checks++;
}

// 9. Wrapping must not end `p > img:only-child` (reader CSS centres a lone image
//    as display:block); the text beside a lone <img> stays put. With a second
//    element sibling :only-child never matched, so wrapping is fine.
{
  const win = makeWindow();
  const text = new Text('挿絵の説明');
  const img = new Element('img', {display: 'block'});
  const p = paragraph({}, BLOCK_AFTER, text, img);
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode, p, 'text beside a lone img must not be wrapped');
  assert.equal(p.childNodes.length, 2);
  checks++;
}
{
  const win = makeWindow();
  const text = new Text('本文');
  const p = paragraph({}, BLOCK_AFTER, text, new Element('img'), new Element('ruby'));
  win.__fushiEnsureHighlightPaintable(text);
  assert.equal(text.parentNode.localName, 'fushi-hl-text');
  checks++;
}

console.log(`${checks} checks, all assertions passed`);
