// BUG-2780 / BUG-2806 behavior test: the audiobook follow highlight must paint one
// continuous block across <ruby> elements WITHOUT changing the layout.
//
// BUG-2780: applySentenceAudioCues wrapped every plain-text segment in its own
// span and highlighted each <ruby> separately via a class background. The spacing
// a long annotation opens around its base (しゃく is wider than 釈) belongs to
// whichever box the engine decides: on the user's iPhone it fell outside the ruby
// background (gaps), on iOS 26.5 it overlapped the following span (a darker band).
// The first fix moved whole rubies into the wrapper span.
//
// BUG-2806: a <ruby> inside a span loses WebKit's annotation overhang, so moving it
// re-laid the text out after the chapter was already on screen (「自嘲気味」: 気 jumped
// 8px away right after turning into the new chapter). Now a ruby never moves: the
// base text is wrapped IN PLACE inside the ruby and text groups stop at rubies. The
// gap a non-overhanging annotation leaves between wrappers is no longer filled per
// wrapper: since 2026-10-15 every highlight background is painted by the lane layer
// (__fushiLanes, reader_selection_scripts.dart), which joins one sentence's pieces on
// a line into a single 1em lane (covered in real Chrome by highlight_lanes_test).
//
// This test EXECUTES the real applySentenceAudioCues / sentenceAudioWrapItems /
// sentenceAudioInlineGap / rubyForNode / wrapSentenceAudioGroup, extracted verbatim
// from reader_pagination_scripts.dart, on a minimal fake DOM.
//
// Run: node fushi/test/reader/sentence_audio_ruby_wrap_behavior_test.js
// (driven from sentence_audio_ruby_wrap_behavior_test.dart inside `flutter test`).
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const readSrc = (f) => fs.readFileSync(path.resolve(__dirname, '../../lib/src/reader/' + f), 'utf8');
// The grouping is one shared snippet inserted into every shell's
// `window.fushiReader` literal (BUG-2917); each shell is tested with it attached.
const gapSource = readSrc('reader_sentence_audio_ruby_gap_script.dart');
const source = readSrc('reader_pagination_scripts.dart') + '\n' + gapSource;
const vnSource = readSrc('reader_visual_novel_scripts.dart') + '\n' + gapSource;
const selectionSource = readSrc('reader_selection_scripts.dart');

// 阅读器共享的切开 / 搬移保护（reader_selection_scripts.dart 的 __fushiLiveRanges 安装器），
// 从工作区源码原样切出，与查词选区的 noteTextNodeSplit 一起装进每个 fake 阅读器。
const liveRangesInstaller = (() => {
  const src = selectionSource.replace(/\r/g, '');
  const start = src.indexOf('if (!window.__fushiLiveRanges) {');
  assert.ok(start >= 0, 'missing __fushiLiveRanges installer');
  const endMarker = '\n  };\n}';
  const end = src.indexOf(endMarker, start);
  assert.ok(end > start, 'missing end of the __fushiLiveRanges installer');
  return src.slice(start, end + endMarker.length);
})();

function extractMethod(name, from) {
  const re = new RegExp('\\n  ' + name + ': function\\([\\s\\S]*?\\n  \\},');
  // `.map(extractMethod)` passes the array index as the second argument.
  const m = (typeof from === 'string' ? from : source).match(re);
  assert.ok(m, 'missing method ' + name);
  return m[0].trim().replace(/,$/, '');
}

// ── fake DOM ────────────────────────────────────────────────────────────────

// 测试登记的 live Range（LiveRange）：按 DOM 规范随节点插入 / 移除 / splitText 调整边界，
// 才能复现「搬移节点把 live Range 塌到父节点上」（BUG-3326 审查）。没登记时不影响任何用例。
const liveRanges = [];
function liveRangesOnRemove(parent, index, node) {
  liveRanges.forEach((r) => ['s', 'e'].forEach((k) => {
    const p = r[k];
    if (node.contains(p.node)) r[k] = { node: parent, offset: index };
    else if (p.node === parent && p.offset > index) r[k] = { node: parent, offset: p.offset - 1 };
  }));
}
function liveRangesOnInsert(parent, index) {
  liveRanges.forEach((r) => ['s', 'e'].forEach((k) => {
    const p = r[k];
    if (p.node === parent && p.offset > index) r[k] = { node: parent, offset: p.offset + 1 };
  }));
}

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
    liveRangesOnInsert(this, i);
    n.parentNode = this; this.childNodes.splice(i, 0, n); return n;
  }
  removeChild(n) {
    const i = this.childNodes.indexOf(n);
    liveRangesOnRemove(this, i, n);
    this.childNodes.splice(i, 1); n.parentNode = null; return n;
  }
  get textContent() { return this.childNodes.map((c) => c.textContent).join(''); }
  get previousSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) - 1] || null;
  }
  contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
}

class Text extends Node {
  constructor(v) { super(); this.nodeType = 3; this.nodeValue = v; this.charRects = null; }
  get textContent() { return this.nodeValue; }
  get data() { return this.nodeValue; }
  // BUG-3326：逐字矩形随拆分一起切开，供折行处切分的测试按字定位。
  splitText(k) {
    const tail = new Text(this.nodeValue.slice(k));
    if (this.charRects) { tail.charRects = this.charRects.slice(k); this.charRects = this.charRects.slice(0, k); }
    this.nodeValue = this.nodeValue.slice(0, k);
    const parent = this.parentNode;
    parent.insertBefore(tail, this.nextSibling);
    // DOM「split a Text node」：本节点里偏移 > k 的边界移进新节点；父节点上紧跟本节点的边界后移一位。
    const after = parent.childNodes.indexOf(this) + 1;
    liveRanges.forEach((r) => ['s', 'e'].forEach((key) => {
      const p = r[key];
      if (p.node === this && p.offset > k) r[key] = { node: tail, offset: p.offset - k };
      else if (p.node === parent && p.offset === after) r[key] = { node: parent, offset: after + 1 };
    }));
    return tail;
  }
}

// 只做被测代码用到的那几个 Range 成员；构造即登记为 live。
class LiveRange {
  constructor(sn, so, en, eo) { this.s = { node: sn, offset: so }; this.e = { node: en, offset: eo }; liveRanges.push(this); }
  get startContainer() { return this.s.node; }
  get startOffset() { return this.s.offset; }
  get endContainer() { return this.e.node; }
  get endOffset() { return this.e.offset; }
  setStart(n, o) { this.s = { node: n, offset: o }; }
  setEnd(n, o) { this.e = { node: n, offset: o }; }
}

const withSize = (r) => Object.assign({ width: r.right - r.left, height: r.bottom - r.top }, r);

class Element extends Node {
  constructor(tag, display) {
    super(); this.nodeType = 1; this.tagName = tag.toUpperCase(); this.className = '';
    this.style = Object.create({
      setProperty(k, v) { this[k.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = v; },
      removeProperty(k) { delete this[k.replace(/-([a-z])/g, (_, c) => c.toUpperCase())]; },
    });
    this.rects = [];
    this.display = display || (tag === 'p' || tag === 'div' ? 'block' : tag === 'ruby' ? 'ruby' : 'inline');
    const self = this;
    this.classList = {
      add(c) { const s = new Set(self.className.split(' ').filter(Boolean)); s.add(c); self.className = [...s].join(' '); },
      remove(...cs) { self.className = self.className.split(' ').filter((x) => x && !cs.includes(x)).join(' '); },
      contains(c) { return self.className.split(' ').includes(c); },
    };
  }
  closest(sel) {
    const tags = sel.split(',').map((x) => x.trim().toUpperCase());
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (tags.includes(n.tagName)) return n;
    return null;
  }
  querySelector(sel) {
    for (const c of this.childNodes) {
      if (c.nodeType !== 1) continue;
      if (c.tagName === sel.toUpperCase()) return c;
      const hit = c.querySelector(sel);
      if (hit) return hit;
    }
    return null;
  }
  // 手设 rects 优先；否则按子孙文本的逐字矩形（charRects）分行合并——竖排一列一个片段。
  getClientRects() {
    if (this.rects.length) return this.rects.map(withSize);
    const lines = [];
    (function walk(n) {
      if (n.nodeType === 3) {
        (n.charRects || []).forEach((r) => {
          const line = lines.find((l) => l.left === r.left);
          if (line) { line.top = Math.min(line.top, r.top); line.bottom = Math.max(line.bottom, r.bottom); }
          else lines.push(Object.assign({}, r));
        });
        return;
      }
      if (n.tagName === 'RT') return;
      n.childNodes.forEach(walk);
    })(this);
    return lines.map(withSize);
  }
  cloneNode() { const e = new Element(this.tagName.toLowerCase(), this.display); e.className = this.className; return e; }
}

class Fragment extends Node { constructor() { super(); this.nodeType = 11; } }

// Range restricted to what the wrap code needs: both boundaries under the same
// parent (a text node child or an element-child index of that parent).
class Range {
  _point(node, offset) {
    if (node.nodeType === 3) return { parent: node.parentNode, text: node, offset };
    return { parent: node, index: offset };
  }
  getBoundingClientRect() {
    const t = this.s.text;
    const r = t && t.charRects ? t.charRects[this.s.offset] : null;
    return withSize(r || { left: 0, right: 0, top: 0, bottom: 0 });
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

function treeWalker(root) {
  const out = [];
  (function walk(n) { if (n.nodeType === 3) out.push(n); else n.childNodes.forEach(walk); })(root);
  let i = 0;
  return { nextNode: () => (i < out.length ? out[i++] : null) };
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

// 选区脚本那一侧：共享的切开 / 搬移保护 + 查词选区的拥有者（只取拆分换算入口；clearSelection
// 照生产语义清掉「节点 + 偏移」状态——分页的 applySentenceAudioCues 包裹前先清选区）。
function installSelectionSide(sandbox) {
  vm.runInContext(liveRangesInstaller, sandbox);
  vm.runInContext('window.fushiSelection = {\n' + extractMethod('noteTextNodeSplit', selectionSource) +
    ',\n  clearSelection: function() { this.selection = null; this.dragAnchor = null; }\n};', sandbox);
}

function makeReader(cueRoots) {
  const sandbox = {
    document: { createRange: () => new Range(), createElement: (t) => new Element(t), documentElement: {},
      createTreeWalker: treeWalker },
    NodeFilter: { SHOW_TEXT: 4 },
    getComputedStyle: (n) => ({
      display: n.display || 'inline', getPropertyValue: () => '',
      writingMode: 'vertical-rl', fontSize: '22px',
    }),
    Map,
    Node: { TEXT_NODE: 3 },
    window: {},
    console: { log() {} },
  };
  vm.createContext(sandbox);
  const methods = ['applySentenceAudioCues', 'sentenceAudioWrapItems', 'sentenceAudioInlineGap', 'rubyForNode',
    'wrapSentenceAudioGroup', 'withLiveRangeBatch']
    .map(extractMethod).join(',\n');
  vm.runInContext('var R = {\n' + methods + '\n};', sandbox);
  installSelectionSide(sandbox);
  const R = sandbox.R;
  sandbox.window.fushiReader = R;
  R.testWindow = sandbox.window;
  R.testSandbox = sandbox;
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

function wrapperOf(textNode) {
  const w = textNode.parentNode;
  return w && w.nodeType === 1 && w.className.split(' ').includes('fushi-sentence-audio-cue') ? w : null;
}
function rtOf(r) { return r.childNodes.filter((n) => n.tagName === 'RT'); }
// Range.extractContents leaves empty text nodes behind (as the real DOM does).
function kids(n) { return n.childNodes.filter((c) => c.nodeType === 1 || c.nodeValue); }

// ── 1. text + rubies + text under one <p>: rubies never move, base text wrapped in place ──
{
  const r1 = ruby('会', 'え'); const r2 = ruby('釈', 'しゃく'); const r0 = ruby('平塚', 'ひらつか');
  const p = el('p', [r0, '先生に促されて、俺は', r1, r2, 'をする。']);
  const R = makeReader({ c1: p });
  R.applySentenceAudioCues([{ id: 'c1' }]);
  const ws = R.cueWrappers.get('c1');
  assert.strictEqual(ws.length, 5, 'ruby base / text / ruby base / ruby base / text, got ' + ws.length);
  [r0, r1, r2].forEach((r) => {
    assert.strictEqual(r.parentNode, p, 'ruby stays a direct child of the paragraph (never moved into a span)');
    assert.strictEqual(kids(r)[0].nodeType, 1, 'base text is wrapped');
    assert.strictEqual(kids(r)[0].className, 'fushi-sentence-audio-cue');
    assert.strictEqual(kids(r)[0].parentNode, r, 'base wrapper lives INSIDE the ruby');
    assert.strictEqual(rtOf(r).length, 1, 'rt stays a direct child of the ruby');
    assert.strictEqual(rtOf(r)[0].parentNode, r);
  });
  assert.strictEqual(ws[0].parentNode, r0);
  assert.strictEqual(ws[1].parentNode, p);
  assert.strictEqual(ws[1].textContent, '先生に促されて、俺は', 'text group stops at the next ruby');
  assert.strictEqual(ws[4].textContent, 'をする。');
  assert.strictEqual(R.cueRubyElements.has('c1'), false, 'no ruby class fallback');
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
  assert.strictEqual(ws.length, 3, 'partial text / ruby base / partial text');
  assert.strictEqual(Array.from(ws, (w) => w.textContent).join('|'), '学校で会話自体が|稀|なんだから。');
  assert.strictEqual(r.parentNode, p, 'ruby not moved');
  assert.strictEqual(ws[1].parentNode, r);
  assert.strictEqual(p.textContent, '前の文。学校で会話自体が稀まれなんだから。次の文。');
  assert.strictEqual(p.childNodes[0].textContent, '前の文。');
}

// ── 3. ruby inside a book <a>: nothing is moved out of / into the <a> ──
{
  const r = ruby('貫禄', 'かんろく');
  const a = el('a', [r]);
  const p = el('p', ['彼には', a, 'がある。']);
  const R = makeReader({ c3: p });
  R.applySentenceAudioCues([{ id: 'c3' }]);
  const ws = R.cueWrappers.get('c3');
  assert.strictEqual(ws.length, 3, 'text / ruby base / text');
  assert.strictEqual(r.parentNode, a, 'ruby stays inside the book <a>');
  assert.strictEqual(a.parentNode, p, '<a> is not swallowed by a text wrapper');
  assert.strictEqual(ws[1].parentNode, r);
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

// ── 5. multi-pair ruby (会<rt>え</rt>釈<rt>しゃく</rt>): each base wrapped, rts untouched ──
{
  const r = el('ruby', ['会', el('rt', ['え']), '釈', el('rt', ['しゃく'])]);
  const p = el('p', ['俺は', r, 'をする。']);
  const R = makeReader({ c5: p });
  R.applySentenceAudioCues([{ id: 'c5' }]);
  const ws = R.cueWrappers.get('c5');
  assert.strictEqual(ws.length, 4, 'text / 会 / 釈 / text');
  assert.strictEqual(r.parentNode, p);
  assert.deepStrictEqual(kids(r).map((n) => n.tagName + ':' + n.textContent),
    ['SPAN:会', 'RT:え', 'SPAN:釈', 'RT:しゃく'], 'no wrapper spans across an rt');
}

// ── 6. same-parent text around an inline element that holds a ruby: group breaks ──
{
  const r = ruby('嘲', 'ちょう');
  const em = el('em', ['自', r]);
  const p = el('p', ['そう', em, '気味に笑う']);
  const R = makeReader({ c6: p });
  R.applySentenceAudioCues([{ id: 'c6' }]);
  assert.strictEqual(em.parentNode, p, 'the <em> holding a ruby is not pulled into a wrapper');
  assert.strictEqual(r.parentNode, em);
  assert.strictEqual(kids(p)[0].textContent, 'そう');
  assert.ok(wrapperOf(kids(kids(p)[0])[0]), 'leading text is wrapped on its own');
}

// ── 10. VN shell (BUG-2917): same grouping as the paginated shell ──
// VN used to wrap every segment on its own, so a vertical sentence highlight broke
// into pieces around every annotated kanji.
function makeVnReader() {
  const sandbox = {
    document: { createRange: () => new Range(), createElement: (t) => new Element(t), documentElement: {}, head: {},
      createTreeWalker: treeWalker },
    NodeFilter: { SHOW_TEXT: 4 },
    getComputedStyle: (n) => ({
      display: n.display || 'inline', getPropertyValue: () => '',
      writingMode: 'vertical-rl', fontSize: '22px',
    }),
    Map,
    Node: { TEXT_NODE: 3 },
    window: {},
    console: { log() {} },
  };
  vm.createContext(sandbox);
  const methods = ['wrapSentenceAudioCueRanges', 'wrapSentenceAudioCueRangesInBatch', 'clearInlineSentenceAudioCue',
    'applyInlineSentenceAudioCue', 'clearCurrentSentenceAudioScreenTargets']
    .map((n) => extractMethod(n, vnSource))
    .concat(['sentenceAudioWrapItems', 'sentenceAudioInlineGap', 'rubyForNode', 'wrapSentenceAudioGroup',
      'withLiveRangeBatch']
      .map((n) => extractMethod(n, gapSource)))
    .join(',\n');
  vm.runInContext('var R = {\n' + methods + '\n};', sandbox);
  installSelectionSide(sandbox);
  const R = sandbox.R;
  sandbox.window.fushiReader = R;
  R.testWindow = sandbox.window;
  R.testSandbox = sandbox;
  R.cueWrappers = new Map();
  R.cueSourceRanges = new Map();
  return R;
}
{
  const r = ruby('縦', 'じゅう');
  const p = el('p', ['コートの中で', r, '横無尽に舞う']);
  const R = makeVnReader();
  const wrapped = R.wrapSentenceAudioCueRanges([{
    id: 'v1',
    ranges: baseTextNodes(p).map((n) => ({ node: n, start: 0, end: n.nodeValue.length })),
  }]);
  const ws = R.cueWrappers.get('v1');
  assert.strictEqual(wrapped.get('v1'), ws);
  assert.strictEqual(ws.length, 3, 'text / ruby base / text, got ' + ws.length);
  assert.deepStrictEqual(Array.from(ws, (w) => w.textContent), ['コートの中で', '縦', '横無尽に舞う']);
  assert.strictEqual(r.parentNode, p, 'ruby not moved');
  assert.strictEqual(ws[1].parentNode, r, 'base wrapper lives inside the ruby');
  assert.strictEqual(rtOf(r).length, 1, 'rt untouched');
  assert.strictEqual(p.textContent, 'コートの中で縦じゅう横無尽に舞う');

  assert.strictEqual(R.applyInlineSentenceAudioCue('v1'), true);
  ws.forEach((w) => assert.ok(w.classList.contains('fushi-sentence-audio-active')));
  ws.forEach((w) => assert.ok(!w.style.boxShadow, 'no per-wrapper gap fill; the lane layer joins the pieces'));
  R.clearInlineSentenceAudioCue('v1');
  ws.forEach((w) => assert.ok(!w.classList.contains('fushi-sentence-audio-active')));

  R.applyInlineSentenceAudioCue('v1');
  R.clearCurrentSentenceAudioScreenTargets();
  assert.strictEqual(R.cueWrappers.size, 0);
}

// ── BUG-3326 审查（#2115 / #2119 同类）：句子包裹不再用 extractContents ──
// extractContents 把切点之后的文字复制进新文本节点、原节点就地截短：查词选区的「节点 + 偏移」越界，
// 落在这段文字里的 live Range 塌到切点上。包裹改为「切开（选区换算）+ 原样搬节点（live Range 写回）」，
// 两步都经选区脚本里共享的 __fushiLiveRanges。
const segText = (segs) => segs.map((s) => {
  assert.ok(s.start >= 0 && s.start < s.end && s.end <= s.node.nodeValue.length,
    'segment offsets stay inside their text node: ' + s.node.nodeValue + ' [' + s.start + ',' + s.end + ')');
  return s.node.nodeValue.slice(s.start, s.end);
}).join('');
const rangeText = (r) => (r.startContainer === r.endContainer
  ? r.startContainer.nodeValue.slice(r.startOffset, r.endOffset)
  : r.startContainer.nodeValue.slice(r.startOffset) + r.endContainer.nodeValue.slice(0, r.endOffset));

// 16. VN 播放中按句懒包裹（ensureSentenceAudioInlineTargetsForCue）时已有查词选区（关掉「查词时暂停」
//     边播边点词）、收藏（高亮桥还没合批登记的 Range 表）与搜索高亮（CSS.highlights）。
{
  const t = new Text('前の文。学校で会話だ');
  const r = ruby('稀', 'まれ');
  const p = el('p', [t, r, 'なんだ。']);
  const R = makeVnReader();
  const S = R.testWindow.fushiSelection;
  S.selection = {
    startNode: t, startOffset: 5, text: '校で',
    ranges: [{ node: t, start: 5, end: 7 }],
    matchedRanges: [{ node: t, start: 2, end: 6 }],
  };
  S.dragAnchor = { node: t, offset: 5, endNode: t, endOffset: 6, startX: 0, startY: 0, moved: false };
  const favorite = new LiveRange(t, 5, t, 9);
  const search = new LiveRange(t, 4, t, 6);
  R.testWindow.__fushiHighlightRangeMap = { fav: { color: 'yellow', ranges: [favorite], rubyElements: [] } };
  R.testSandbox.CSS = { highlights: new Map([['fushi-search', new Set([search])]]) };
  R.wrapSentenceAudioCueRanges([{
    id: 'v2',
    ranges: [{ node: t, start: 4, end: t.nodeValue.length }, { node: r.childNodes[0], start: 0, end: 1 }],
  }]);
  const ws = R.cueWrappers.get('v2');
  assert.deepStrictEqual(Array.from(ws, (w) => w.textContent), ['学校で会話だ', '稀']);
  assert.strictEqual(t.nodeValue, '前の文。', 'the head of the split keeps its identity and stays in place');
  const inWrapper = ws[0].childNodes[0];
  assert.strictEqual(ws[0].childNodes.length, 1, 'the wrapped text is moved, not copied');
  assert.strictEqual(inWrapper.nodeValue, '学校で会話だ');
  assert.strictEqual(S.selection.startNode, inWrapper, 'selection start follows the split into the wrapped node');
  assert.strictEqual(S.selection.startOffset, 1);
  assert.strictEqual(segText(S.selection.ranges), '校で', 'selected text unchanged by the wrap');
  assert.strictEqual(segText(S.selection.matchedRanges), '文。学校', 'a matched segment across the cut is split in two');
  assert.strictEqual(S.selection.matchedRanges.length, 2);
  assert.deepStrictEqual([S.dragAnchor.node === inWrapper, S.dragAnchor.offset, S.dragAnchor.endNode === inWrapper,
    S.dragAnchor.endOffset], [true, 1, true, 2], 'drag anchor follows the split');
  assert.ok(favorite.startContainer === inWrapper && favorite.endContainer === inWrapper,
    'a pending favourite Range is not collapsed onto the paragraph by the move');
  assert.strictEqual(rangeText(favorite), '校で会話');
  assert.strictEqual(search.startContainer, t, 'a boundary outside the moved node keeps its DOM-adjusted position');
  assert.strictEqual(search.endContainer, inWrapper);
  assert.strictEqual(rangeText(search), '学校', 'the search highlight still covers the same text');
  assert.strictEqual(p.textContent, '前の文。学校で会話だ稀まれなんだ。', 'text preserved in order');
  liveRanges.length = 0;
}

// 17. 分页 / 连续：applySentenceAudioCues 包裹前会清掉查词选区，但收藏等 live Range 照样不能塌。
{
  const t = new Text('前の文。学校で会話だ');
  const p = el('p', [t]);
  const R = makeReader({});
  R.collectSentenceAudioCueRanges = () => [{ id: 'c17', ranges: [{ node: t, start: 4, end: 9 }] }];
  const favorite = new LiveRange(t, 2, t, 6);
  R.testWindow.__fushiHighlightRangeMap = { fav: { color: 'yellow', ranges: [favorite], rubyElements: [] } };
  R.applySentenceAudioCues([{ id: 'c17' }]);
  const ws = R.cueWrappers.get('c17');
  assert.strictEqual(ws.length, 1);
  assert.strictEqual(ws[0].textContent, '学校で会話');
  assert.deepStrictEqual(p.childNodes.map((n) => n.textContent), ['前の文。', '学校で会話', 'だ'],
    'both cuts split in place, no empty leftovers');
  assert.strictEqual(favorite.startContainer, t);
  assert.strictEqual(favorite.startOffset, 2);
  assert.strictEqual(favorite.endContainer, ws[0].childNodes[0]);
  assert.strictEqual(rangeText(favorite), '文。学校', 'the favourite across the cut still covers the same text');
  liveRanges.length = 0;
}

// 18. BUG-3432：开章逐句包裹整批只读一次原生选区。DOM 刚改过时读 getSelection().rangeCount 会让
// Blink 对整章同步排版一次；moveNodes 每次都读时，一章 2700 句的有声书开书卡几十秒、超时白屏。
{
  const N = 40;
  const p = el('p', []);
  const nodes = [];
  for (let i = 0; i < N; i++) { const t = new Text('文' + i + '。'); nodes.push(t); p.appendChild(t); }
  const R = makeReader({});
  R.collectSentenceAudioCueRanges = () =>
    nodes.map((t, i) => ({ id: 'c' + i, ranges: [{ node: t, start: 0, end: 2 }] }));
  let reads = 0;
  R.testWindow.getSelection = () => { reads++; return { rangeCount: 0 }; };
  R.applySentenceAudioCues(nodes.map((t, i) => ({ id: 'c' + i })));
  assert.strictEqual(R.cueWrappers.size, N, 'every cue still gets its wrapper');
  assert.strictEqual(reads, 1, 'the native selection is read once per batch, not once per moved group');
  assert.strictEqual(R.testWindow.__fushiLiveRanges.noNativeSelection, false, 'the batch flag is reset afterwards');

  // 有原生选区时照旧逐次钉住、写回（批只在确认没有选区时跳过读取）。
  const t2 = new Text('前の文。学校で会話だ');
  el('p', [t2]);
  const R2 = makeReader({});
  R2.collectSentenceAudioCueRanges = () => [{ id: 'd0', ranges: [{ node: t2, start: 4, end: 9 }] }];
  let reads2 = 0;
  R2.testWindow.getSelection = () => {
    reads2++;
    return { rangeCount: 1, anchorNode: t2, anchorOffset: 0, focusNode: t2, focusOffset: 1, setBaseAndExtent() {} };
  };
  R2.applySentenceAudioCues([{ id: 'd0' }]);
  assert.ok(reads2 >= 2, 'with a live native selection every move still reads and restores it');
  liveRanges.length = 0;
}

// 19. BUG-3432 合并 #2213 后复核：批内一章多句跨段落、跨 ruby 的逐句包裹与整章拆包裹，收藏 live Range
//     （跨两段）照样不塌；包裹与拆包裹各只读一次原生选区。批只省掉原生选区的读取，live Range 的
//     钉住 / 写回仍逐次执行；倒序包裹让前一句的切开不影响后一句的「节点 + 偏移」。
{
  const t1 = new Text('前の文。学校で');
  const r = ruby('稀', 'まれ');
  const p1 = el('p', [t1, r, 'だ。']);
  const t2 = new Text('次の段落です。');
  el('p', [t2]);
  const tail1 = p1.childNodes[2];
  const R = makeReader({});
  R.collectSentenceAudioCueRanges = () => [
    { id: 'a', ranges: [{ node: t1, start: 0, end: 4 }] },
    { id: 'b', ranges: [{ node: t1, start: 4, end: 7 }, { node: r.childNodes[0], start: 0, end: 1 },
      { node: tail1, start: 0, end: 2 }] },
    { id: 'c', ranges: [{ node: t2, start: 0, end: 7 }] },
  ];
  const favorite = new LiveRange(t1, 5, t2, 3);
  R.testWindow.__fushiHighlightRangeMap = { fav: { color: 'yellow', ranges: [favorite], rubyElements: [] } };
  let reads = 0;
  R.testWindow.getSelection = () => { reads++; return { rangeCount: 0 }; };
  R.applySentenceAudioCues([{ id: 'a' }, { id: 'b' }, { id: 'c' }]);
  assert.strictEqual(reads, 1, 'one read for the whole chapter wrap');
  assert.deepStrictEqual(Array.from(R.cueWrappers.get('a'), (w) => w.textContent), ['前の文。']);
  assert.deepStrictEqual(Array.from(R.cueWrappers.get('b'), (w) => w.textContent), ['学校で', '稀', 'だ。']);
  assert.deepStrictEqual(Array.from(R.cueWrappers.get('c'), (w) => w.textContent), ['次の段落です。']);
  assert.strictEqual(R.cueWrappers.get('b')[1].parentNode, r, 'ruby base wrapped in place, ruby not moved');
  assert.strictEqual(p1.textContent, '前の文。学校で稀まれだ。');
  assert.strictEqual(favorite.startContainer.nodeType, 3, 'favourite start not collapsed onto an element');
  assert.strictEqual(favorite.endContainer.nodeType, 3, 'favourite end not collapsed onto an element');
  assert.strictEqual(favorite.startContainer.nodeValue.slice(favorite.startOffset), '校で');
  assert.strictEqual(favorite.endContainer.nodeValue.slice(0, favorite.endOffset), '次の段');
  assert.strictEqual(R.testWindow.__fushiLiveRanges.noNativeSelection, false);

  // 整章拆包裹（分页 / 连续的 resetSentenceAudioCues）同样整批只读一次。合并文本节点不在 fake DOM
  // 里建模（normalize 置空），这里只核读取次数、包裹全拆掉、收藏端点仍落在原文字上。
  vm.runInContext('R.resetSentenceAudioCues = ' +
    extractMethod('resetSentenceAudioCues').replace(/^resetSentenceAudioCues: /, '') +
    ';\nR.unwrap = ' + extractMethod('unwrap').replace(/^unwrap: /, '') + ';', R.testSandbox);
  R.cueRangesMap = new Map();
  const savedNormalize = Element.prototype.normalize;
  Element.prototype.normalize = function() {};
  reads = 0;
  try {
    R.resetSentenceAudioCues();
  } finally {
    Element.prototype.normalize = savedNormalize;
  }
  assert.strictEqual(reads, 1, 'one read for the whole chapter unwrap');
  assert.strictEqual(R.cueWrappers.size, 0);
  assert.ok(!p1.childNodes.some((n) => n.className === 'fushi-sentence-audio-cue'), 'wrappers removed');
  assert.ok(!r.childNodes.some((n) => n.className === 'fushi-sentence-audio-cue'), 'ruby wrapper removed');
  assert.strictEqual(p1.textContent, '前の文。学校で稀まれだ。');
  assert.strictEqual(favorite.startContainer.nodeValue.slice(favorite.startOffset), '校で');
  assert.strictEqual(favorite.endContainer.nodeValue.slice(0, favorite.endOffset), '次の段');
  liveRanges.length = 0;
}

// 20. VN 逐句包裹（wrapSentenceAudioCueRanges）同样整批只读一次原生选区。
{
  const N = 12;
  const p = el('p', []);
  const nodes = [];
  for (let i = 0; i < N; i++) { const t = new Text('句' + i + '。'); nodes.push(t); p.appendChild(t); }
  const R = makeVnReader();
  let reads = 0;
  R.testWindow.getSelection = () => { reads++; return { rangeCount: 0 }; };
  R.wrapSentenceAudioCueRanges(nodes.map((t, i) => ({
    id: 'v' + i, ranges: [{ node: t, start: 0, end: t.nodeValue.length }],
  })));
  assert.strictEqual(R.cueWrappers.size, N);
  assert.strictEqual(reads, 1, 'VN wraps a screen of cues with one selection read');
  liveRanges.length = 0;
}

console.log('all assertions passed');
