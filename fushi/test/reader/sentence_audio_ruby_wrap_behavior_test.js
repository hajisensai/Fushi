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
// base text is wrapped IN PLACE inside the ruby, text groups stop at rubies, and the
// gap a non-overhanging annotation leaves is filled at highlight time with a
// box-shadow (paint only, no layout).
//
// This test EXECUTES the real applySentenceAudioCues / sentenceAudioWrapItems /
// sentenceAudioInlineGap / rubyForNode / fillSentenceAudioRubyGaps /
// clearSentenceAudioRubyGaps, extracted verbatim from reader_pagination_scripts.dart,
// on a minimal fake DOM.
//
// Run: node fushi/test/reader/sentence_audio_ruby_wrap_behavior_test.js
// (driven from sentence_audio_ruby_wrap_behavior_test.dart inside `flutter test`).
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const readSrc = (f) => fs.readFileSync(path.resolve(__dirname, '../../lib/src/reader/' + f), 'utf8');
// The grouping + ruby-gap fill is one shared snippet inserted into every shell's
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
    'fillSentenceAudioRubyGaps', 'watchSentenceAudioRubyGapLayout', 'paintSentenceAudioRubyGaps',
    'eraseSentenceAudioRubyGaps', 'clearSentenceAudioRubyGaps', '_setReanchorPending',
    'sentenceAudioLineRects', 'sentenceAudioSameLine', 'sentenceAudioJoinGap', 'splitSentenceAudioJoinLines',
    'splitSentenceAudioWrapper', 'wrapSentenceAudioGroup']
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

// ── 7. gap fill: box-shadow bridges the gap a long annotation leaves, only while active ──
{
  const r = ruby('漢', 'かんじかんじ');
  const p = el('p', ['ほら', r, '字だ']);
  const R = makeReader({ c7: p });
  R.applySentenceAudioCues([{ id: 'c7' }]);
  const ws = R.cueWrappers.get('c7');
  assert.strictEqual(ws.length, 3);
  // vertical-rl: same column (x overlaps), base sits 14px below 「ほら」 and above 「字だ」.
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 44 }];
  ws[1].rects = [{ left: 100, right: 122, top: 58, bottom: 80 }];
  ws[2].rects = [{ left: 100, right: 122, top: 94, bottom: 138 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.strictEqual(ws[1].style.boxShadow,
    '0px -14px 0 0 var(--fushi-sentence-audio-background-color), ' +
    '0px 14px 0 0 var(--fushi-sentence-audio-background-color)',
    'the in-ruby wrapper bridges both gaps (towards 「ほら」 and 「字だ」)');
  assert.strictEqual(ws[0].style.boxShadow, undefined, 'plain text wrappers are not touched when the ruby side can bridge');
  R.clearSentenceAudioRubyGaps();
  assert.strictEqual(ws[1].style.boxShadow, '', 'cleared when the cue is no longer active');
}

// ── 8. gap fill never bridges across columns, and contiguous boxes get nothing ──
{
  const r = ruby('釈', 'しゃく');
  const p = el('p', ['会', r, 'をする']);
  const R = makeReader({ c8: p });
  R.applySentenceAudioCues([{ id: 'c8' }]);
  const ws = R.cueWrappers.get('c8');
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 22 }];
  ws[1].rects = [{ left: 100, right: 122, top: 22, bottom: 44 }];
  ws[2].rects = [{ left: 60, right: 82, top: 0, bottom: 66 }];
  R.fillSentenceAudioRubyGaps(ws);
  ws.forEach((w) => assert.ok(!w.style.boxShadow, 'no shadow for overhanging / cross-column neighbours'));
}

// ── 9. a settled relayout (reanchor flag true→false) re-measures the active gap fill ──
// (page size / chrome insets / UI scale all end in _setReanchorPending(false); a paused
// cue is never re-highlighted, so without this the stale shadow would stay forever.
// Stylesheet swaps and font loads are covered in real Chrome by
// reader_audio_cue_identity_harness.mjs — a fake DOM has no layout to observe.)
{
  const r = ruby('漢', 'かんじかんじ');
  const p = el('p', ['ほら', r, '字だ']);
  const R = makeReader({ c9: p });
  R.applySentenceAudioCues([{ id: 'c9' }]);
  const ws = R.cueWrappers.get('c9');
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 44 }];
  ws[1].rects = [{ left: 100, right: 122, top: 58, bottom: 80 }];
  ws[2].rects = [{ left: 100, right: 122, top: 94, bottom: 138 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.ok(ws[1].style.boxShadow, 'gap filled initially');
  // relayout: furigana hidden, the ruby collapses to its base.
  ws[1].rects = [{ left: 100, right: 122, top: 44, bottom: 66 }];
  ws[2].rects = [{ left: 100, right: 122, top: 66, bottom: 110 }];
  R._setReanchorPending(true);
  assert.ok(ws[1].style.boxShadow, 'nothing repaints while the reanchor is in flight');
  R._setReanchorPending(false);
  assert.ok(!ws[1].style.boxShadow, 'stale shadow removed once the relayout settles');
  // furigana back with a different gap.
  ws[1].rects = [{ left: 100, right: 122, top: 50, bottom: 72 }];
  ws[2].rects = [{ left: 100, right: 122, top: 78, bottom: 122 }];
  R._setReanchorPending(true);
  R._setReanchorPending(false);
  assert.strictEqual(ws[1].style.boxShadow,
    '0px -6px 0 0 var(--fushi-sentence-audio-background-color), ' +
    '0px 6px 0 0 var(--fushi-sentence-audio-background-color)',
    'shadow re-measured to the new gap');
  R.clearSentenceAudioRubyGaps();
  assert.strictEqual(ws[1].style.boxShadow, '');
  R._setReanchorPending(true);
  R._setReanchorPending(false);
  assert.strictEqual(ws[1].style.boxShadow, '', 'a settle after the cue is cleared paints nothing');
}

// ── 10. VN shell (BUG-2917): same grouping + gap fill as the paginated shell ──
// VN used to wrap every segment on its own and never fill gaps, so a vertical
// sentence highlight broke into pieces around every annotated kanji.
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
  const methods = ['wrapSentenceAudioCueRanges', 'clearInlineSentenceAudioCue', 'applyInlineSentenceAudioCue',
    'clearCurrentSentenceAudioScreenTargets']
    .map((n) => extractMethod(n, vnSource))
    .concat(['sentenceAudioWrapItems', 'sentenceAudioInlineGap', 'rubyForNode', 'fillSentenceAudioRubyGaps',
      'watchSentenceAudioRubyGapLayout', 'paintSentenceAudioRubyGaps', 'eraseSentenceAudioRubyGaps',
      'clearSentenceAudioRubyGaps', 'sentenceAudioLineRects', 'sentenceAudioSameLine', 'sentenceAudioJoinGap',
      'splitSentenceAudioJoinLines', 'splitSentenceAudioWrapper', 'wrapSentenceAudioGroup']
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

  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 132 }];
  ws[1].rects = [{ left: 100, right: 122, top: 146, bottom: 168 }];
  ws[2].rects = [{ left: 100, right: 122, top: 182, bottom: 314 }];
  assert.strictEqual(R.applyInlineSentenceAudioCue('v1'), true);
  ws.forEach((w) => assert.ok(w.classList.contains('fushi-sentence-audio-active')));
  assert.strictEqual(ws[1].style.boxShadow,
    '0px -14px 0 0 var(--fushi-sentence-audio-background-color), ' +
    '0px 14px 0 0 var(--fushi-sentence-audio-background-color)',
    'VN highlight bridges the ruby gaps like the paginated shell');
  R.clearInlineSentenceAudioCue('v1');
  assert.strictEqual(ws[1].style.boxShadow, '', 'gap fill cleared with the highlight');
  ws.forEach((w) => assert.ok(!w.classList.contains('fushi-sentence-audio-active')));

  R.applyInlineSentenceAudioCue('v1');
  assert.ok(ws[1].style.boxShadow);
  R.clearCurrentSentenceAudioScreenTargets();
  assert.strictEqual(ws[1].style.boxShadow, '', 'screen-target reset also drops the gap fill');
  assert.strictEqual(R.cueWrappers.size, 0);
}

// ── BUG-3326：整句高亮在同一行里是一整条，只有每一行两端是圆角 ──
const JOIN_S = 'fushi-sentence-audio-join-start';
const JOIN_E = 'fushi-sentence-audio-join-end';
const joins = (w) => (w.classList.contains(JOIN_S) ? 'S' : '-') + (w.classList.contains(JOIN_E) ? 'E' : '-');

// 11. 同一列相接的 wrapper：接缝两侧打 join class（CSS 把这一侧改直角），外端不打。
{
  const r = ruby('漢', 'かん');
  const p = el('p', ['ほら', r, '字だ']);
  const R = makeReader({ c11: p });
  R.applySentenceAudioCues([{ id: 'c11' }]);
  const ws = R.cueWrappers.get('c11');
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 44 }];
  ws[1].rects = [{ left: 100, right: 122, top: 44, bottom: 66 }];
  ws[2].rects = [{ left: 100, right: 122, top: 66, bottom: 110 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.deepStrictEqual(Array.from(ws, joins), ['-E', 'SE', 'S-'],
    'joints square on both sides, the sentence ends stay round');
  R.clearSentenceAudioRubyGaps();
  assert.deepStrictEqual(Array.from(ws, joins), ['--', '--', '--'], 'join classes dropped with the highlight');
}

// 12. 换列的相邻 wrapper 不是接缝：两端都保持圆角。
{
  const r = ruby('漢', 'かん');
  const p = el('p', ['ほら', r, '字だ']);
  const R = makeReader({ c12: p });
  R.applySentenceAudioCues([{ id: 'c12' }]);
  const ws = R.cueWrappers.get('c12');
  ws[0].rects = [{ left: 100, right: 122, top: 700, bottom: 744 }];
  ws[1].rects = [{ left: 100, right: 122, top: 744, bottom: 766 }];
  ws[2].rects = [{ left: 60, right: 82, top: 0, bottom: 44 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.deepStrictEqual(Array.from(ws, joins), ['-E', 'S-', '--'], 'a column break is a line end, not a joint');
}

// 13. 长注音悬挂进邻字（Blink：基字盒压进两侧 5px）：ruby 内 wrapper 的背景扣掉重叠段，
//     半透明底色不再叠出深色带；只改背景，不碰排版。
{
  const r = ruby('橙', 'だいだい');
  const p = el('p', ['黄、', r, 'の光']);
  const R = makeReader({ c13: p });
  R.applySentenceAudioCues([{ id: 'c13' }]);
  const ws = R.cueWrappers.get('c13');
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 44 }];
  ws[1].rects = [{ left: 100, right: 122, top: 39, bottom: 71 }];
  ws[2].rects = [{ left: 100, right: 122, top: 66, bottom: 110 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.deepStrictEqual(Array.from(ws, joins), ['-E', 'SE', 'S-']);
  assert.strictEqual(ws[1].style.backgroundColor, 'transparent', 'the in-ruby wrapper paints via the trimmed gradient');
  assert.strictEqual(ws[1].style.backgroundImage,
    'linear-gradient(to bottom, transparent 5.00px, var(--fushi-sentence-audio-background-color) 5.00px, ' +
    'var(--fushi-sentence-audio-background-color) calc(100% - 5.00px), transparent calc(100% - 5.00px))',
    'both overlapping ends are left to the neighbours');
  assert.ok(!ws[0].style.backgroundImage && !ws[2].style.backgroundImage, 'neighbours keep their own background');
  assert.ok(!ws[1].style.boxShadow, 'an overlap is never bridged with a shadow');
  R.clearSentenceAudioRubyGaps();
  assert.strictEqual(ws[1].style.backgroundImage, '', 'trim dropped with the highlight');
  assert.strictEqual(ws[1].style.backgroundColor, undefined);
}

// 14. 跨列的 wrapper 在注音接缝那一列被恰好在折行处切开：clone 下 radius 对每个片段一视同仁，
//     不切的话它在上一列列尾那一端也会被一起改成直角。
{
  const r = ruby('漢', 'かん');
  const p = el('p', ['あいうえおかき', r, 'くけこ']);
  const R = makeReader({ c14: p });
  let rebuilt = 0;
  R.buildNodeOffsets = () => { rebuilt++; };
  R.applySentenceAudioCues([{ id: 'c14' }]);
  rebuilt = 0;
  const ws = R.cueWrappers.get('c14');
  assert.strictEqual(ws.length, 3);
  const col = (left, top) => ({ left, right: left + 22, top, bottom: top + 22 });
  // あいうえ：上一列列尾；おかき・漢・くけこ：下一列列首。
  ws[0].childNodes[0].charRects = [col(100, 656), col(100, 678), col(100, 700), col(100, 722),
    col(60, 0), col(60, 22), col(60, 44)];
  ws[1].childNodes[0].charRects = [col(60, 66)];
  ws[2].childNodes[0].charRects = [col(60, 88), col(60, 110), col(60, 132)];
  // 审查补充：切点（「お」前）之后已有查词选区「かき」（关掉「查词时暂停」边播边点词，词典结果
  // 回来前下一句变成当前句）。它存的是「文本节点 + 数字偏移」，matchedRanges 跨切点；
  // 拖选锚点也在切点之后。另有一个不进 CSS.highlights 的迟到图片重锚目标（搜索命中 cloneRange）。
  const t0 = ws[0].childNodes[0];
  const S = R.testWindow.fushiSelection;
  S.selection = {
    startNode: t0, startOffset: 5, text: 'かき',
    ranges: [{ node: t0, start: 5, end: 7 }],
    matchedRanges: [{ node: t0, start: 3, end: 6 }],
  };
  S.dragAnchor = { node: t0, offset: 5, endNode: t0, endOffset: 6, startX: 0, startY: 0, moved: false };
  R.__imgReanchorTarget = new LiveRange(t0, 5, t0, 7);
  R.fillSentenceAudioRubyGaps(ws);
  assert.strictEqual(R.cueWrappers.get('c14'), ws, 'the stored wrapper list is updated in place');
  const covered = (segs) => segs.map((r) => {
    assert.ok(r.start >= 0 && r.start < r.end && r.end <= r.node.nodeValue.length,
      'segment offsets stay inside their text node: ' + r.node.nodeValue + ' [' + r.start + ',' + r.end + ')');
    return r.node.nodeValue.slice(r.start, r.end);
  }).join('');
  const tailText = ws[1].childNodes[0];
  assert.strictEqual(tailText.nodeValue, 'おかき');
  assert.strictEqual(S.selection.startNode, tailText, 'selection start follows the split into the new text node');
  assert.strictEqual(S.selection.startOffset, 1);
  assert.strictEqual(covered(S.selection.ranges), 'かき', 'selected text unchanged by the split');
  assert.strictEqual(covered(S.selection.matchedRanges), 'えおか', 'a segment across the cut is split in two');
  assert.strictEqual(S.selection.matchedRanges.length, 2);
  assert.deepStrictEqual([S.dragAnchor.node === tailText, S.dragAnchor.offset, S.dragAnchor.endNode === tailText,
    S.dragAnchor.endOffset], [true, 1, true, 2], 'drag anchor glyphs follow the split');
  const target = R.__imgReanchorTarget;
  assert.ok(target.startContainer === tailText && target.endContainer === tailText,
    'the late-image reanchor target is not collapsed onto the wrapper by the move');
  assert.strictEqual(tailText.nodeValue.slice(target.startOffset, target.endOffset), 'かき');
  liveRanges.length = 0;
  assert.deepStrictEqual(Array.from(ws, (w) => w.textContent), ['あいうえ', 'おかき', '漢', 'くけこ'],
    'the wrapper is cut exactly at the column break');
  assert.strictEqual(ws[1].parentNode, p, 'the new piece is a sibling right after the original wrapper');
  assert.strictEqual(p.childNodes.indexOf(ws[1]), p.childNodes.indexOf(ws[0]) + 1);
  assert.ok(ws[1].classList.contains('fushi-sentence-audio-cue'));
  assert.deepStrictEqual(Array.from(ws, joins), ['--', '-E', 'SE', 'S-'],
    'the previous column keeps both round ends, the joints in the next column are square');
  assert.strictEqual(p.textContent, 'あいうえおかき漢かんくけこ', 'text preserved in order');
  assert.strictEqual(rebuilt, 1, 'node offsets rebuilt once after the split');
  // 再次高亮（重排后重量）：已是单列片段，不再切分。
  R.fillSentenceAudioRubyGaps(ws);
  assert.strictEqual(ws.length, 4);
  assert.strictEqual(rebuilt, 1);
}

// 15. 两侧都不在 ruby 里的相邻 wrapper（被 <em> 拆开）：紧贴时是接缝（直角）；量出正缝说明中间
//     夹着不属于本句的内容（内联外字图），不是接缝——两端保持圆角、不补色，也不为它切分。
{
  const em = el('em', ['えお']);
  const p = el('p', ['あいう', el('img'), em]);
  const R = makeReader({ c15: p });
  R.applySentenceAudioCues([{ id: 'c15' }]);
  const ws = R.cueWrappers.get('c15');
  assert.deepStrictEqual(Array.from(ws, (w) => w.textContent), ['あいう', 'えお']);
  ws[0].rects = [{ left: 100, right: 122, top: 0, bottom: 66 }];
  ws[1].rects = [{ left: 100, right: 122, top: 66, bottom: 110 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.deepStrictEqual(Array.from(ws, joins), ['-E', 'S-'], 'touching non-ruby wrappers form one bar');
  ws.forEach((w) => assert.ok(!w.style.boxShadow, 'nothing to bridge'));
  ws[1].rects = [{ left: 100, right: 122, top: 88, bottom: 132 }];
  R.fillSentenceAudioRubyGaps(ws);
  assert.deepStrictEqual(Array.from(ws, joins), ['--', '--'], 'content in between is not a joint');
  ws.forEach((w) => assert.ok(!w.style.boxShadow, 'the in-between image is never painted with the highlight'));
  assert.strictEqual(ws.length, 2);
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

console.log('all assertions passed');
