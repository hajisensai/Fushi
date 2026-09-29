// BUG-2780 behavior test: the audiobook follow highlight must paint one continuous
// block across <ruby> elements.
//
// Root cause: applySentenceAudioCues wrapped every plain-text segment in its own
// span and highlighted each <ruby> separately via a class background. The spacing
// a long annotation opens around its base (しゃく is wider than 釈) belongs to
// whichever box the engine decides: on the user's iPhone it fell outside the ruby
// background (the highlight broke into 「会|釈|をす」 with gaps), on iOS 26.5 it
// overlapped the following span by 7.7px (a darker band with translucent colors).
// Fix: consecutive segments under the same parent — text AND whole rubies — are
// moved into ONE wrapper span, which paints the background once.
//
// This test EXECUTES the real applySentenceAudioCues / sentenceAudioWrapItems /
// sentenceAudioInlineGap / rubyForNode, extracted verbatim from
// reader_pagination_scripts.dart, on a minimal fake DOM.
//
// Run: node fushi/test/reader/sentence_audio_ruby_wrap_behavior_test.js
// (driven from sentence_audio_ruby_wrap_behavior_test.dart inside `flutter test`).
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(
  path.resolve(__dirname, '../../lib/src/reader/reader_pagination_scripts.dart'),
  'utf8',
);

function extractMethod(name) {
  const re = new RegExp('\\n  ' + name + ': function\\([\\s\\S]*?\\n  \\},');
  const m = source.match(re);
  assert.ok(m, 'missing method ' + name);
  return m[0].trim().replace(/,$/, '');
}

// ── fake DOM ────────────────────────────────────────────────────────────────

class Node {
  constructor() { this.parentNode = null; this.childNodes = []; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; }
  appendChild(n) {
    if (n.nodeType === 11) { n.childNodes.slice().forEach((c) => this.appendChild(c)); return n; }
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this; this.childNodes.push(n); return n;
  }
  insertBefore(n, ref) {
    if (n.nodeType === 11) { n.childNodes.slice().forEach((c) => this.insertBefore(c, ref)); return n; }
    if (n.parentNode) n.parentNode.removeChild(n);
    const i = ref ? this.childNodes.indexOf(ref) : this.childNodes.length;
    n.parentNode = this; this.childNodes.splice(i, 0, n); return n;
  }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  get textContent() { return this.childNodes.map((c) => c.textContent).join(''); }
}

class Text extends Node {
  constructor(v) { super(); this.nodeType = 3; this.nodeValue = v; }
  get textContent() { return this.nodeValue; }
}

class Element extends Node {
  constructor(tag, display) {
    super(); this.nodeType = 1; this.tagName = tag.toUpperCase(); this.className = '';
    this.display = display || (tag === 'p' || tag === 'div' ? 'block' : tag === 'ruby' ? 'ruby' : 'inline');
    const self = this;
    this.classList = {
      add(c) { const s = new Set(self.className.split(' ').filter(Boolean)); s.add(c); self.className = [...s].join(' '); },
      remove(c) { self.className = self.className.split(' ').filter((x) => x && x !== c).join(' '); },
      contains(c) { return self.className.split(' ').includes(c); },
    };
  }
  closest(sel) {
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (n.tagName === sel.toUpperCase()) return n;
    return null;
  }
}

class Fragment extends Node { constructor() { super(); this.nodeType = 11; } }

// Range restricted to what the wrap code needs: both boundaries under the same
// parent (a text node child or an element-child index of that parent).
class Range {
  _point(node, offset) {
    if (node.nodeType === 3) return { parent: node.parentNode, text: node, offset };
    return { parent: node, index: offset };
  }
  setStart(n, o) { this.s = this._point(n, o); }
  setEnd(n, o) { this.e = this._point(n, o); }
  setStartBefore(n) { this.s = { parent: n.parentNode, index: n.parentNode.childNodes.indexOf(n) }; }
  setEndAfter(n) { this.e = { parent: n.parentNode, index: n.parentNode.childNodes.indexOf(n) + 1 }; }
  // Split a text node at offset; returns the node holding the text after offset.
  _split(t, offset) {
    const tail = new Text(t.nodeValue.slice(offset));
    t.nodeValue = t.nodeValue.slice(0, offset);
    t.parentNode.insertBefore(tail, t.nextSibling);
    return tail;
  }
  extractContents() {
    assert.strictEqual(this.s.parent, this.e.parent, 'fake Range only supports same-parent boundaries');
    const parent = this.s.parent;
    // Normalize end first so start indices stay valid.
    const endText = this.e.text; const endOffset = this.e.offset;
    let endIdx;
    if (endText && endText === this.s.text) {
      const t = endText;
      const mid = new Text(t.nodeValue.slice(this.s.offset, endOffset));
      const tail = new Text(t.nodeValue.slice(endOffset));
      t.nodeValue = t.nodeValue.slice(0, this.s.offset);
      const kids = parent.childNodes; const i = kids.indexOf(t);
      parent.insertBefore(tail, kids[i + 1] || null);
      const f = new Fragment(); f.appendChild(mid);
      this.insertAt = { parent, before: tail };
      return f;
    }
    // Resolve both boundaries to node references (end first: splitting it keeps
    // the head node's identity, so the start boundary stays valid).
    let before;
    if (this.e.text) {
      const t = this.e.text;
      before = endOffset >= t.nodeValue.length ? t.nextSibling : this._split(t, endOffset);
    } else {
      before = parent.childNodes[this.e.index] || null;
    }
    let first;
    if (this.s.text) {
      const t = this.s.text;
      first = this.s.offset <= 0 ? t : (this.s.offset >= t.nodeValue.length ? t.nextSibling : this._split(t, this.s.offset));
    } else {
      first = parent.childNodes[this.s.index];
    }
    const kids = parent.childNodes;
    endIdx = before ? kids.indexOf(before) : kids.length;
    const moved = kids.slice(kids.indexOf(first), endIdx);
    const f = new Fragment();
    moved.forEach((n) => f.appendChild(n));
    this.insertAt = { parent, before };
    return f;
  }
  insertNode(n) { this.insertAt.parent.insertBefore(n, this.insertAt.before); }
}

function el(tag, children, display) {
  const e = new Element(tag, display);
  (children || []).forEach((c) => e.appendChild(typeof c === 'string' ? new Text(c) : c));
  return e;
}
function ruby(base, rt) { return el('ruby', [base, el('rt', [rt])]); }

function baseTextNodes(root) {
  const out = [];
  (function walk(n) {
    if (n.nodeType === 3) { if (!n.parentNode.closest('rt') && n.nodeValue) out.push(n); return; }
    n.childNodes.forEach(walk);
  })(root);
  return out;
}

function makeReader(cueRoots) {
  const sandbox = {
    document: { createRange: () => new Range(), createElement: (t) => new Element(t), documentElement: {} },
    getComputedStyle: (n) => ({ display: n.display || 'inline', getPropertyValue: () => '' }),
    Node: { TEXT_NODE: 3 },
    window: {},
    console: { log() {} },
  };
  vm.createContext(sandbox);
  const methods = ['applySentenceAudioCues', 'sentenceAudioWrapItems', 'sentenceAudioInlineGap', 'rubyForNode']
    .map(extractMethod).join(',\n');
  vm.runInContext('var R = {\n' + methods + '\n};', sandbox);
  const R = sandbox.R;
  R.cueWrappers = new Map();
  R.cueRubyElements = new Map();
  R.resetSentenceAudioCues = () => {};
  R.buildNodeOffsets = () => {};
  R.collectSentenceAudioCueRanges = (cues) => cues.map((c) => ({
    id: c.id,
    ranges: baseTextNodes(cueRoots[c.id]).map((n) => ({ node: n, start: 0, end: n.nodeValue.length })),
  }));
  return R;
}

// ── 1. text + mono rubies + text under one <p> → ONE wrapper, no ruby class ──
{
  const r1 = ruby('会', 'え'); const r2 = ruby('釈', 'しゃく'); const r0 = ruby('平塚', 'ひらつか');
  const p = el('p', [r0, '先生に促されて、俺は', r1, r2, 'をする。']);
  const R = makeReader({ c1: p });
  R.applySentenceAudioCues([{ id: 'c1' }]);
  const ws = R.cueWrappers.get('c1');
  assert.strictEqual(ws.length, 1, 'whole sentence must be one wrapper, got ' + ws.length);
  assert.strictEqual(R.cueRubyElements.has('c1'), false, 'rubies inside the wrapper must not also get the ruby class');
  assert.strictEqual(p.childNodes.length, 1, 'paragraph now holds exactly the wrapper');
  assert.strictEqual(ws[0].className, 'fushi-sentence-audio-cue');
  assert.strictEqual(r1.parentNode, ws[0], 'ruby moved (not cloned) into the wrapper');
  assert.strictEqual(r2.parentNode, ws[0]);
  assert.strictEqual(p.textContent, '平塚ひらつか先生に促されて、俺は会え釈しゃくをする。', 'text preserved in order');
}

// ── 2. cue covering part of a text node: boundaries split, neighbours stay out ──
{
  const r = ruby('稀', 'まれ');
  const t = new Text('前の文。学校で会話自体が');
  const p = el('p', [t, r, 'なんだから。次の文。']);
  const R = makeReader({});
  R.cueWrappers = new Map(); R.cueRubyElements = new Map();
  R.collectSentenceAudioCueRanges = () => [{
    id: 'c2',
    ranges: [
      { node: t, start: 4, end: t.nodeValue.length },
      { node: r.childNodes[0], start: 0, end: 1 },
      { node: p.childNodes[2], start: 0, end: 6 },
    ],
  }];
  R.applySentenceAudioCues([{ id: 'c2' }]);
  const ws = R.cueWrappers.get('c2');
  assert.strictEqual(ws.length, 1, 'partial text + ruby + partial text is one wrapper');
  assert.strictEqual(ws[0].textContent, '学校で会話自体が稀まれなんだから。');
  assert.strictEqual(p.textContent, '前の文。学校で会話自体が稀まれなんだから。次の文。');
  assert.strictEqual(p.childNodes[0].textContent, '前の文。');
}

// ── 3. different parents (ruby inside a book <a>) → separate groups, ruby still wrapped ──
{
  const r = ruby('貫禄', 'かんろく');
  const a = el('a', [r]);
  const p = el('p', ['彼には', a, 'がある。']);
  const R = makeReader({ c3: p });
  R.applySentenceAudioCues([{ id: 'c3' }]);
  const ws = R.cueWrappers.get('c3');
  assert.strictEqual(ws.length, 3, 'text / <a>-nested ruby / text are three groups');
  assert.strictEqual(r.parentNode, ws[1], 'the nested ruby is wrapped inside its own parent');
  assert.strictEqual(ws[1].parentNode, a, 'wrapper stays inside the book element (no splitting of <a>)');
  assert.strictEqual(R.cueRubyElements.has('c3'), false);
}

// ── 4. a block element between two same-parent segments is never swallowed ──
{
  const block = el('p', ['（本文外）']);
  const div = el('div', ['一行目', block, '二行目']);
  const R = makeReader({});
  R.collectSentenceAudioCueRanges = () => [{
    id: 'c4',
    ranges: [
      { node: div.childNodes[0], start: 0, end: 3 },
      { node: div.childNodes[2], start: 0, end: 3 },
    ],
  }];
  R.applySentenceAudioCues([{ id: 'c4' }]);
  const ws = R.cueWrappers.get('c4');
  assert.strictEqual(ws.length, 2, 'block sibling splits the group');
  assert.strictEqual(block.parentNode, div, 'block <p> stays a direct child of the div');
  ws.forEach((w) => assert.strictEqual(w.textContent.indexOf('本文外'), -1, 'no wrapper swallows the block'));
}

// ── 5. multi-pair ruby (会<rt>え</rt>釈<rt>しゃく</rt>) counts once ──
{
  const r = el('ruby', ['会', el('rt', ['え']), '釈', el('rt', ['しゃく'])]);
  const p = el('p', ['俺は', r, 'をする。']);
  const R = makeReader({ c5: p });
  R.applySentenceAudioCues([{ id: 'c5' }]);
  const ws = R.cueWrappers.get('c5');
  assert.strictEqual(ws.length, 1);
  assert.strictEqual(r.parentNode, ws[0]);
  assert.strictEqual(ws[0].childNodes.filter((n) => n === r).length, 1, 'ruby appears once');
}

console.log('all assertions passed');
