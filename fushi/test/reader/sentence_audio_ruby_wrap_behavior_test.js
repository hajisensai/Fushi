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

function extractMethod(name, from) {
  const re = new RegExp('\\n  ' + name + ': function\\([\\s\\S]*?\\n  \\},');
  // `.map(extractMethod)` passes the array index as the second argument.
  const m = (typeof from === 'string' ? from : source).match(re);
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
    super(); this.nodeType = 1; this.tagName = tag.toUpperCase(); this.className = ''; this.style = {};
    this.rects = [];
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
  querySelector(sel) {
    for (const c of this.childNodes) {
      if (c.nodeType !== 1) continue;
      if (c.tagName === sel.toUpperCase()) return c;
      const hit = c.querySelector(sel);
      if (hit) return hit;
    }
    return null;
  }
  getClientRects() { return this.rects; }
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
    'eraseSentenceAudioRubyGaps', 'clearSentenceAudioRubyGaps', '_setReanchorPending']
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
  assert.strictEqual(ws.map((w) => w.textContent).join('|'), '学校で会話自体が|稀|なんだから。');
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
    document: { createRange: () => new Range(), createElement: (t) => new Element(t), documentElement: {}, head: {} },
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
      'clearSentenceAudioRubyGaps'].map((n) => extractMethod(n, gapSource)))
    .join(',\n');
  vm.runInContext('var R = {\n' + methods + '\n};', sandbox);
  const R = sandbox.R;
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

console.log('all assertions passed');
