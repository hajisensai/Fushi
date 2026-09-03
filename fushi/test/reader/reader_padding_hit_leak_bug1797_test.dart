// BUG-1797：阅读器页边距（横排左右间距 / 竖排上下间距）能点到相邻页的词查词，而那块
// 明明什么都没显示。
//
// 根因：分页模式把整章内容当**一根** multicol，靠移动 scrollLeft/scrollTop 看每一页，
// 相邻页的列在几何上就落在 body 的 padding 带里；遮住它的 clip-path 与 html::before
// 覆盖条都是**绘制期**机制，而命中测试是**布局期**的（caretPositionFromPoint 把落点
// clamp 到最近字符，getClientRects 无视 clip-path）——「看不见」和「点得到」是两套真相。
//
// 这个测试不是源码扫描守卫：它把生产的 window.fushiSelection 对象字面量抽出来，在 node
// 里对着一个**真的复现 clamp 行为**的 fake DOM 跑 getCharacterAtPoint，断言页边距带里
// 的相邻页字符点不中、而正文内的字符照常命中。删掉 charRangeVisible 的接入点即转红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

void main() {
  test(
      'BUG-1797: getCharacterAtPoint rejects chars clipped into the page-margin '
      'band and still hits visible body text', () {
    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi-bug1797-hit-leak-',
    );
    final File payloadFile = File('${temp.path}/payload.json')
      ..writeAsStringSync(
        jsonEncode(<String, String>{
          'selection': ReaderSelectionScripts.source(),
        }),
      );
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>['-e', _runner, payloadFile.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason: 'padding hit-leak runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

const String _runner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));

function assert(value, message) {
  if (!value) throw new Error(typeof message === 'function' ? message() : message);
}
// hits carry live DOM nodes; never JSON.stringify them (circular parentElement).
function describeHit(hit) {
  return hit ? ('{text=' + hit.node.textContent + ', offset=' + hit.offset + '}') : 'null';
}

// ---- minimal DOM that reproduces the two things that matter -----------------
// 1) per-character client rects (so the visibility test has real geometry)
// 2) caretPositionFromPoint CLAMPING to the nearest character, exactly like a
//    real engine -- that clamp is the whole reason a margin tap resolves to a
//    neighbouring page's word.

function rect(left, top, right, bottom) {
  return {
    left: left, top: top, right: right, bottom: bottom,
    width: right - left, height: bottom - top,
  };
}

function makeElement(tag) {
  const el = {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    parentElement: null,
    children: [],
    closest: function (sel) {
      // Only the queries the production code actually issues matter here.
      if (sel === 'rt, rp') return null;
      let node = el;
      while (node) {
        if (sel.split(',').some((s) => s.trim().toUpperCase() === node.tagName)) {
          return node;
        }
        node = node.parentElement;
      }
      return null;
    },
  };
  return el;
}

// text node whose i-th character occupies rects[i]
function makeTextNode(text, rects, parent) {
  const node = {
    nodeType: 3,
    textContent: text,
    nodeValue: text,
    parentElement: parent,
    __rects: rects,
  };
  parent.children.push(node);
  return node;
}

function distanceSq(r, x, y) {
  const cx = x < r.left ? r.left : (x > r.right ? r.right : x);
  const cy = y < r.top ? r.top : (y > r.bottom ? r.bottom : y);
  return (cx - x) * (cx - x) + (cy - y) * (cy - y);
}

function buildDom(bodyRect, padding, textNodesSpec) {
  const body = makeElement('body');
  const paragraphs = [];
  const textNodes = [];
  for (const spec of textNodesSpec) {
    const p = makeElement('p');
    p.parentElement = body;
    body.children.push(p);
    paragraphs.push(p);
    textNodes.push(makeTextNode(spec.text, spec.rects, p));
  }
  body.getBoundingClientRect = () => bodyRect;

  const doc = {
    body: body,
    documentElement: { clientWidth: bodyRect.right, clientHeight: bodyRect.bottom },
    createRange: function () {
      const r = {
        startContainer: null, startOffset: 0, endContainer: null, endOffset: 0,
        setStart: function (n, o) { r.startContainer = n; r.startOffset = o; },
        setEnd: function (n, o) { r.endContainer = n; r.endOffset = o; },
        collapse: function () { r.endContainer = r.startContainer; r.endOffset = r.startOffset; },
        getClientRects: function () {
          if (!r.startContainer || r.startContainer !== r.endContainer) return [];
          return r.startContainer.__rects.slice(r.startOffset, r.endOffset);
        },
        getBoundingClientRect: function () {
          const rects = r.getClientRects();
          if (!rects.length) return rect(0, 0, 0, 0);
          return rect(
            Math.min(...rects.map((q) => q.left)),
            Math.min(...rects.map((q) => q.top)),
            Math.max(...rects.map((q) => q.right)),
            Math.max(...rects.map((q) => q.bottom)),
          );
        },
      };
      return r;
    },
    // The engine behaviour under test: ALWAYS resolve to the nearest character,
    // even when the point is far outside every glyph (that is the clamp).
    caretPositionFromPoint: function (x, y) {
      let best = null;
      let bestDist = Infinity;
      for (const node of textNodes) {
        for (let i = 0; i < node.__rects.length; i++) {
          const d = distanceSq(node.__rects[i], x, y);
          if (d < bestDist) { bestDist = d; best = { offsetNode: node, offset: i }; }
        }
      }
      return best;
    },
    elementFromPoint: function () { return body; },
    createTreeWalker: function (root, whatToShow, filter) {
      const collected = [];
      (function walk(n) {
        for (const child of (n.children || [])) {
          if (child.nodeType === 3) {
            if (!filter || filter.acceptNode(child) === 1) collected.push(child);
          } else {
            walk(child);
          }
        }
      })(root === body ? body : root);
      let i = -1;
      return {
        currentNode: null,
        nextNode: function () { i++; return i < collected.length ? collected[i] : null; },
      };
    },
  };

  const win = {
    innerWidth: bodyRect.right,
    innerHeight: bodyRect.bottom,
    getComputedStyle: function () {
      return {
        paddingLeft: padding.left + 'px',
        paddingRight: padding.right + 'px',
        paddingTop: padding.top + 'px',
        paddingBottom: padding.bottom + 'px',
        borderLeftWidth: '0px', borderRightWidth: '0px',
        borderTopWidth: '0px', borderBottomWidth: '0px',
      };
    },
  };
  return { doc: doc, win: win, textNodes: textNodes };
}

// ---- load the production object ---------------------------------------------
function selectionObjectLiteral(source) {
  const marker = 'window.fushiSelection = {';
  const start = source.indexOf(marker);
  assert(start >= 0, 'window.fushiSelection object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  assert(end >= 0, 'window.fushiSelection terminator missing');
  return source.slice(brace, end + 2);
}

function loadSelection(dom) {
  const literal = selectionObjectLiteral(data.selection);
  const factory = new Function(
    'window', 'document', 'Node', 'NodeFilter', 'JAPANESE_RANGES',
    'return (' + literal + ');',
  );
  return factory(
    dom.win,
    dom.doc,
    { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    [[0x3040, 0x309f], [0x30a0, 0x30ff], [0x4e00, 0x9fff]],
  );
}

// ---- the scenario ------------------------------------------------------------
// Horizontal paged layout, 400x800 viewport, 40px left/right page margins and
// 40px top/bottom. Visible content box is therefore (40,40)-(360,760).
//   * "本" sits at x 100..120 -> inside the box, a normal word.
//   * "隣" sits at x 8..28 -> entirely inside the LEFT margin band: this is the
//     neighbouring page's column, painted over by clip-path / html::before, so
//     the user sees nothing there.
const bodyRect = rect(0, 0, 400, 800);
const padding = { left: 40, right: 40, top: 40, bottom: 40 };
const dom = buildDom(bodyRect, padding, [
  { text: '本文', rects: [rect(100, 100, 120, 120), rect(120, 100, 140, 120)] },
  { text: '隣頁', rects: [rect(8, 100, 28, 120), rect(-12, 100, 8, 120)] },
]);
const sel = loadSelection(dom);
dom.win.fushiSelection = sel;

// Sanity: the fake engine really does clamp a margin tap onto the hidden
// neighbouring-page character. Without that, this test would prove nothing.
const clamped = dom.doc.caretPositionFromPoint(18, 110);
assert(clamped && clamped.offsetNode === dom.textNodes[1] && clamped.offset === 0,
  'fake engine must clamp the margin tap onto the hidden neighbour char');

// 1) A tap in the left page-margin band must NOT resolve to a word.
const marginHit = sel.getCharacterAtPoint(18, 110);
assert(marginHit === null,
  () => 'tap in the page-margin band must not look up the clipped neighbour page word, got ' +
  describeHit(marginHit));

// 2) Same for a point that is outside every glyph but still in the margin band
//    (pure clamp, no glyph anywhere near).
assert(sel.getCharacterAtPoint(2, 110) === null,
  'far margin tap must stay blank');

// 3) Real body text still looks up (no regression on the normal path).
const bodyHit = sel.getCharacterAtPoint(110, 110);
assert(bodyHit && bodyHit.node === dom.textNodes[0] && bodyHit.offset === 0,
  () => 'visible body character must still be looked up, got ' + describeHit(bodyHit));
const bodyHit2 = sel.getCharacterAtPoint(130, 110);
assert(bodyHit2 && bodyHit2.node === dom.textNodes[0] && bodyHit2.offset === 1,
  () => 'second visible character must still be looked up, got ' + describeHit(bodyHit2));

// 4) A character straddling the clip edge is still visible -> still clickable.
const straddle = buildDom(bodyRect, padding, [
  { text: '半', rects: [rect(30, 100, 50, 120)] },
]);
const sel2 = loadSelection(straddle);
straddle.win.fushiSelection = sel2;
const straddleHit = sel2.getCharacterAtPoint(45, 110);
assert(straddleHit && straddleHit.offset === 0,
  () => 'a glyph straddling the content-box edge stays clickable, got ' + describeHit(straddleHit));

// 5) No body padding (VN layout / unstyled) -> the guard must be a no-op.
const vn = buildDom(bodyRect, { left: 0, right: 0, top: 0, bottom: 0 }, [
  { text: '端', rects: [rect(2, 100, 22, 120)] },
]);
const sel3 = loadSelection(vn);
vn.win.fushiSelection = sel3;
assert(sel3.getCharacterAtPoint(10, 110) !== null,
  'with zero body padding every on-screen glyph stays clickable');

// 6+7) The caret fast-path is not the only way in: when caretPositionFromPoint
// returns null (ruby / image / collapsed-box pages -- BUG-765, TODO-916),
// getCaretRange falls back to elementFromPoint + a per-character scan of the
// block, first exact-containment then nearest-character-within-tolerance. Both
// of those scans walk the WHOLE block, neighbouring-page columns included, so
// both need the same visibility judgement or the margin leak just moves.
function withoutCaretApi(dom) {
  dom.doc.caretPositionFromPoint = function () { return null; };
  const sel = loadSelection(dom);
  dom.win.fushiSelection = sel;
  return sel;
}

// 6) exact-containment pass: the point is literally inside the hidden glyph's
//    rect, so only the visibility test can reject it.
const noCaret = buildDom(bodyRect, padding, [
  { text: '本', rects: [rect(100, 100, 120, 120)] },
  { text: '隣', rects: [rect(8, 100, 28, 120)] },
]);
const sel4 = withoutCaretApi(noCaret);
assert(sel4.getCharacterAtPoint(18, 110) === null,
  () => 'exact-containment fallback must not hit a clipped neighbour glyph, got ' +
  describeHit(sel4.getCharacterAtPoint(18, 110)));
const sel4Body = sel4.getCharacterAtPoint(110, 110);
assert(sel4Body && sel4Body.node === noCaret.textNodes[0],
  () => 'exact-containment fallback must still hit visible text, got ' + describeHit(sel4Body));

// 7) nearest-character pass: the point sits in the margin band just outside the
//    hidden glyph. Without the visibility filter the hidden glyph wins the
//    "nearest" contest (it is 4px away) over the visible one (72px away) and the
//    tap looks up the neighbouring page's word.
const nearest = buildDom(bodyRect, padding, [
  { text: '本', rects: [rect(100, 100, 120, 120)] },
  { text: '隣', rects: [rect(8, 100, 24, 120)] },
]);
const sel5 = withoutCaretApi(nearest);
assert(sel5.getCharacterAtPoint(28, 110) === null,
  () => 'nearest-character fallback must not adopt a clipped neighbour glyph, got ' +
  describeHit(sel5.getCharacterAtPoint(28, 110)));

// 8) The visibility judgement must run INSIDE both fallback scans, not only as a
//    final veto. A tap right on the seam: the point sits inside a hidden
//    neighbouring-page glyph (16..38, entirely left of the content box at x=40)
//    and 4px away from the first visible glyph of this page (40..60).
//    - filtering inside the scans -> the hidden glyph is skipped, the visible one
//      wins the nearest-character contest, the user looks up THIS page's word.
//    - filtering only at the end -> the hidden glyph wins (it contains the point),
//      gets vetoed, and the tap resolves to nothing: the leak turns into a dead
//      zone along the whole inner edge of the page margin.
const seam = buildDom(bodyRect, padding, [
  { text: '端', rects: [rect(40, 100, 60, 120)] },
  { text: '隣', rects: [rect(16, 100, 38, 120)] },
]);
const sel6 = withoutCaretApi(seam);
const seamHit = sel6.getCharacterAtPoint(36, 110);
assert(seamHit && seamHit.node === seam.textNodes[0] && seamHit.offset === 0,
  () => 'a tap on the margin seam must fall back to this page\'s nearest VISIBLE ' +
  'glyph, not be swallowed by the hidden neighbour, got ' + describeHit(seamHit));

console.log('OK');
''';
