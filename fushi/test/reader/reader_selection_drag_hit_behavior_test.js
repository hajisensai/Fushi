// 阅读器移动端选区拖动命中行为 harness。
//
// 执行**生产代码**（verbatim 从 `lib/src/reader/reader_selection_scripts.dart` 的
// `source()` 原始字符串里抽出的 `window.fushiSelection` 对象字面量）对着一个最小 DOM
// 回放「长按定锚 -> 拖选扩展 / 拖手柄」的坐标序列，断言「坐标 -> 文本位置」的解析结果。
//
// 为什么必须这样做：真机触屏 WebView（Android/iOS long-press + pointer:coarse）离屏测不了
// （`flutter test` 不触发 coarse、也拿不到真字符矩形），而纯源码扫描守卫照不出「手柄卡住」
// 这类几何行为——BUG-765 的教训就是守卫全绿而真机仍拖不动。故这里用 Node 真跑那段 JS，
// 配一个复现真实 WebView 几何的 fake DOM：
//   * 每个字符有真实 client rect（line-height 高度的行盒，与 Chrome 的命中/高亮矩形一致）；
//   * `caretPositionFromPoint` **复现 clamp 语义**（永远返回最近 caret，绝不返回 null）
//     —— 老实现把「落在字缝/行距/行尾空白」的点判成 miss 正是手柄冻结的根因；
//   * 可以把 `caretPositionFromPoint` / `caretRangeFromPoint` 摘掉，跑几何兜底那条路。
//
// 覆盖（每条都对应问题描述里的一个症状）：
//   1  字缝（两端对齐撑开的字间空白）  -> 端点必须继续前进，不得停在锚点
//   2  行尾空白（短行右侧）            -> clamp 到本行末字，且**不得**跳到下一行
//   3  下一行右侧空白                  -> 归最近的一行
//   4  段末之后（段间 margin）         -> clamp 到本段末字
//   5  几何兜底（无原生 caret API）    -> 与 1/2 同样不卡住
//   6  拉丁词的换行处                  -> 吸附到词末（词跨行也不丢）
//   7  拉丁词长按                      -> 原地长按即选中整词
//   8  拉丁词拖动                      -> 端点吸附到词边界（Android WordIterator 语义）
//   9  CJK                             -> 保持字符级（不吸附、不退化成词选择）
//   10 竖排 vertical-rl                -> 轴向互换后同样不卡住
//   11 分页页边距带（BUG-1797）        -> 绝不选中被 clip 掉的相邻页字符
//   12 严格命中零回归                  -> 手指压在字上时端点还是那个字
//   13 手柄横扫（跨越字缝/行尾/行距）  -> 端点单调前进、手柄永不冻结
//   14 纯空白文本节点                  -> 端点规范化，不许把选区撑到文末
//
// Run: node fushi/test/reader/reader_selection_drag_hit_behavior_test.js
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- production JS
function selectionSource() {
  const dartPath = path.resolve(
    __dirname,
    '../../lib/src/reader/reader_selection_scripts.dart',
  );
  const dart = fs.readFileSync(dartPath, 'utf8');
  const marker = 'static String source() => r"""';
  const start = dart.indexOf(marker);
  assert.ok(start >= 0, 'reader_selection_scripts.dart source() raw string missing');
  const bodyStart = start + marker.length;
  const end = dart.indexOf('""";', bodyStart);
  assert.ok(end > bodyStart, 'source() raw string terminator missing');
  return dart.substring(bodyStart, end);
}

function selectionObjectLiteral(source) {
  const marker = 'window.fushiSelection = {';
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'window.fushiSelection object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  assert.ok(end >= 0, 'window.fushiSelection terminator missing');
  return source.slice(brace, end + 2);
}

// ---------------------------------------------------------------- fake DOM
const TEXT_NODE = 3;
const ELEMENT_NODE = 1;
const DOCUMENT_POSITION_FOLLOWING = 4;
const FILTER_ACCEPT = 1;
const FILTER_REJECT = 2;
const NodeStub = {
  TEXT_NODE,
  ELEMENT_NODE,
  DOCUMENT_POSITION_FOLLOWING,
  DOCUMENT_POSITION_PRECEDING: 2,
};
const NodeFilterStub = { SHOW_TEXT: 4, FILTER_ACCEPT, FILTER_REJECT };

function rect(left, top, right, bottom) {
  return {
    left,
    top,
    right,
    bottom,
    width: right - left,
    height: bottom - top,
    x: left,
    y: top,
  };
}

function unionRects(rects) {
  let left = Infinity;
  let top = Infinity;
  let right = -Infinity;
  let bottom = -Infinity;
  for (const r of rects) {
    left = Math.min(left, r.left);
    top = Math.min(top, r.top);
    right = Math.max(right, r.right);
    bottom = Math.max(bottom, r.bottom);
  }
  return rect(left, top, right, bottom);
}

// Lays `text` out like a browser line box: code units wrap at `lineWidth`, every
// unit carries the rect of the *code point* it belongs to, and the rect height is
// the full line height (Chrome's hit/selection rects are line-box based). A space
// that does not fit stays at the end of the current line (trailing space), exactly
// like a browser's wrap point. `gapAfter[i]` inserts empty justification space
// after unit i — that empty band is the inter-character gap the bug report is about.
function layoutText(text, options) {
  const o = Object.assign(
    { x0: 20, y0: 20, lineWidth: 360, charWidth: 20, spaceWidth: 20, lineHeight: 40 },
    options || {},
  );
  const rects = new Array(text.length);
  let line = 0;
  let x = o.x0;
  for (let i = 0; i < text.length; ) {
    const codePoint = text.codePointAt(i);
    const len = codePoint > 0xffff ? 2 : 1;
    const width = codePoint === 32 ? o.spaceWidth : o.charWidth;
    if (x + width > o.x0 + o.lineWidth) {
      if (codePoint === 32) {
        const r = rect(x, o.y0 + line * o.lineHeight, x + width, o.y0 + (line + 1) * o.lineHeight);
        for (let k = i; k < i + len; k++) rects[k] = r;
        i += len;
        line += 1;
        x = o.x0;
        continue;
      }
      line += 1;
      x = o.x0;
    }
    const r = rect(x, o.y0 + line * o.lineHeight, x + width, o.y0 + (line + 1) * o.lineHeight);
    for (let k = i; k < i + len; k++) rects[k] = r;
    x += width + (o.gapAfter && o.gapAfter[i] ? o.gapAfter[i] : 0);
    i += len;
  }
  return rects;
}

function makeTextNode(text, rects, parent) {
  return {
    nodeType: TEXT_NODE,
    textContent: text,
    nodeValue: text,
    parentElement: parent,
    __rects: rects,
    __order: -1,
    compareDocumentPosition(other) {
      if (this.__order === other.__order) return 0;
      return other.__order > this.__order
        ? DOCUMENT_POSITION_FOLLOWING
        : 2 /* DOCUMENT_POSITION_PRECEDING */;
    },
  };
}

function makeElement(tag, parent) {
  const attrs = {};
  const el = {
    nodeType: ELEMENT_NODE,
    tagName: tag.toUpperCase(),
    parentElement: parent || null,
    childNodes: [],
    style: {},
    classList: { contains: () => false, add() {}, remove() {} },
    isConnected: true,
    __rect: rect(0, 0, 0, 0),
    // Tag selectors (`p, div, span, ruby, a`) plus the bare attribute selector
    // `[data-fushi-sel-handle]` that the grip-skip needs. Attribute matching is what
    // lets the geometric fallback recognise a grip element for what it is instead of
    // treating its `div` tag as a text block.
    closest(selector) {
      let node = el;
      while (node) {
        const hit = selector.split(',').some((raw) => {
          const s = raw.trim();
          if (s.startsWith('[') && s.endsWith(']')) {
            return !!node.__attrs && node.__attrs[s.slice(1, -1)] !== undefined;
          }
          return !!node.tagName && s.toUpperCase() === node.tagName;
        });
        if (hit) return node;
        node = node.parentElement;
      }
      return null;
    },
    appendChild(child) {
      el.childNodes.push(child);
      child.parentElement = el;
      return child;
    },
    getAttribute(name) {
      return attrs[name] === undefined ? null : attrs[name];
    },
    setAttribute(name, value) {
      attrs[name] = String(value);
    },
    addEventListener() {},
    getBoundingClientRect() {
      return el.__rect;
    },
  };
  el.__attrs = attrs;
  return el;
}

function makeRange() {
  const r = {
    startContainer: null,
    startOffset: 0,
    endContainer: null,
    endOffset: 0,
    setStart(node, offset) {
      r.startContainer = node;
      r.startOffset = offset;
    },
    setEnd(node, offset) {
      r.endContainer = node;
      r.endOffset = offset;
    },
    collapse(toStart) {
      if (toStart === undefined || toStart) {
        r.endContainer = r.startContainer;
        r.endOffset = r.startOffset;
      }
    },
    selectNodeContents() {},
    getClientRects() {
      if (!r.startContainer || r.startContainer !== r.endContainer) return [];
      if (r.startContainer.nodeType !== TEXT_NODE) return [];
      const units = r.startContainer.__rects.slice(r.startOffset, r.endOffset);
      const lines = [];
      for (const unit of units) {
        if (!unit) continue;
        const line = lines.find((l) => l[0].top === unit.top && l[0].bottom === unit.bottom);
        if (line) {
          line.push(unit);
        } else {
          lines.push([unit]);
        }
      }
      return lines.map(unionRects);
    },
    getBoundingClientRect() {
      const rects = r.getClientRects();
      return rects.length ? unionRects(rects) : rect(0, 0, 0, 0);
    },
  };
  return r;
}

// Distance between a point and a rect on the cross axis (line pitch direction) and
// the inline axis (reading direction). Line-first (cross) is what the resolver must
// do: a point in the line pitch belongs to the *nearest line*, not to the glyph that
// happens to be inline-adjacent on the next line.
function axisDistances(r, x, y, vertical) {
  const crossCoord = vertical ? x : y;
  const inlineCoord = vertical ? y : x;
  const crossLo = vertical ? r.left : r.top;
  const crossHi = vertical ? r.right : r.bottom;
  const inlineLo = vertical ? r.top : r.left;
  const inlineHi = vertical ? r.bottom : r.right;
  return {
    cross: crossCoord < crossLo ? crossLo - crossCoord : crossCoord > crossHi ? crossCoord - crossHi : 0,
    inline:
      inlineCoord < inlineLo ? inlineLo - inlineCoord : inlineCoord > inlineHi ? inlineCoord - inlineHi : 0,
    inlineLo,
    inlineHi,
    inlineCoord,
  };
}

function buildDocument(spec) {
  let order = 0;
  const body = makeElement('body');
  body.__rect = spec.bodyRect || rect(0, 0, 400, 300);

  const blocks = [];
  for (const blockSpec of spec.blocks) {
    const block = makeElement(blockSpec.tag || 'p', body);
    block.__rect = blockSpec.rect;
    body.appendChild(block);
    const nodes = [];
    for (const nodeSpec of blockSpec.textNodes) {
      const node = makeTextNode(nodeSpec.text, nodeSpec.rects, block);
      block.appendChild(node);
      nodes.push(node);
    }
    blocks.push({ el: block, textNodes: nodes });
  }

  const allTextNodes = blocks.flatMap((b) => b.textNodes);
  [body].concat(blocks.map((b) => b.el)).concat(allTextNodes).forEach((node, index) => {
    node.__order = index;
  });
  order += 1;

  // Overlay elements (the selection grips), registered by a scenario through
  // `dom.addOverlay`. They occlude the point exactly like the real 32x32 grip touch box
  // does: hit-testing returns the grip *unless* its `pointer-events` is `none` — which is
  // precisely the state the production code puts the grips in while it resolves a drag
  // endpoint. Without this the harness cannot see the grip-occlusion regression at all.
  const overlays = [];

  function overlayAt(x, y) {
    for (const overlay of overlays) {
      const r = overlay.rect;
      const pe = overlay.el.style && overlay.el.style.pointerEvents;
      if (pe === 'none') continue;
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return overlay.el;
    }
    return null;
  }

  function elementsFromPoint(x, y) {
    const stack = [];
    const grip = overlayAt(x, y);
    if (grip) stack.push(grip);
    for (const el of blocks.map((b) => b.el).concat([body])) {
      const r = el.__rect;
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        stack.push(el);
        break;
      }
    }
    if (!stack.length) stack.push(body);
    return stack;
  }

  function elementFromPoint(x, y) {
    // Innermost containing element wins; nothing contains the point -> body (which
    // is exactly what a real hit test returns for the document background).
    return elementsFromPoint(x, y)[0];
  }

  // Chromium-like `caretPositionFromPoint`: ALWAYS resolves to a caret clamped to
  // the nearest text position; never null. Line boxes win over inline distance.
  function caretPositionFromPoint(x, y) {
    // A grip under the finger is what Chromium's caret hit test resolves to as well: an
    // ELEMENT_NODE (the production fast path only trusts text nodes, so it must fall
    // through). Modelling this — rather than always returning a text node — is what makes
    // the grip-occlusion regression observable in this harness.
    const grip = overlayAt(x, y);
    if (grip) return { offsetNode: grip, offset: 0 };
    let best = null;
    for (const node of allTextNodes) {
      const text = node.textContent;
      for (let i = 0; i < text.length; ) {
        const codePoint = text.codePointAt(i);
        const len = codePoint > 0xffff ? 2 : 1;
        const r = node.__rects[i];
        i += len;
        if (!r) continue;
        const d = axisDistances(r, x, y, spec.vertical === true);
        const better = !best || d.cross < best.cross || (d.cross === best.cross && d.inline < best.inline);
        if (better) {
          const after =
            d.inlineCoord > d.inlineHi ||
            (d.inlineCoord >= d.inlineLo && d.inlineCoord >= (d.inlineLo + d.inlineHi) / 2);
          best = { offsetNode: node, offset: after ? i : i - len, cross: d.cross, inline: d.inline };
        }
      }
    }
    return best ? { offsetNode: best.offsetNode, offset: best.offset } : null;
  }

  const doc = {
    body,
    documentElement: {
      clientWidth: body.__rect.right,
      clientHeight: body.__rect.bottom,
      appendChild() {},
    },
    createRange: () => makeRange(),
    createTreeWalker(root, whatToShow, filter) {
      const accepted = [];
      (function walk(node) {
        for (const child of node.childNodes || []) {
          if (child.nodeType === TEXT_NODE) {
            if (!filter || filter.acceptNode(child) === FILTER_ACCEPT) accepted.push(child);
          } else {
            walk(child);
          }
        }
      })(root);
      const walker = {
        currentNode: null,
        nextNode() {
          const current = walker.currentNode;
          const currentOrder = current ? current.__order : -1;
          for (const node of accepted) {
            if (node.__order > currentOrder) {
              walker.currentNode = node;
              return node;
            }
          }
          return null;
        },
        previousNode() {
          const current = walker.currentNode;
          const currentOrder = current ? current.__order : Infinity;
          let found = null;
          for (const node of accepted) {
            if (node.__order < currentOrder) found = node;
          }
          if (found) {
            walker.currentNode = found;
            return found;
          }
          return null;
        },
      };
      return walker;
    },
    elementFromPoint,
    elementsFromPoint,
    getElementById: () => null,
    createElement: (tag) => makeElement(tag, null),
    caretPositionFromPoint,
    caretRangeFromPoint(x, y) {
      const pos = caretPositionFromPoint(x, y);
      if (!pos) return null;
      const range = makeRange();
      range.setStart(pos.offsetNode, pos.offset);
      range.collapse(true);
      return range;
    },
  };
  if (spec.disableCaretApis) {
    delete doc.caretPositionFromPoint;
    delete doc.caretRangeFromPoint;
  }

  const win = {
    innerWidth: body.__rect.right,
    innerHeight: body.__rect.bottom,
    getSelection: () => null,
    __fushiCssHighlightsSupported: false,
    // endRangeSelection hands Dart the confirm menu; nothing in this harness needs
    // to observe it, but the call must not throw.
    flutter_inappwebview: { callHandler() {} },
    getComputedStyle: () => ({
      paddingLeft: `${(spec.padding && spec.padding.left) || 0}px`,
      paddingRight: `${(spec.padding && spec.padding.right) || 0}px`,
      paddingTop: `${(spec.padding && spec.padding.top) || 0}px`,
      paddingBottom: `${(spec.padding && spec.padding.bottom) || 0}px`,
      borderLeftWidth: '0px',
      borderRightWidth: '0px',
      borderTopWidth: '0px',
      borderBottomWidth: '0px',
      writingMode: spec.vertical ? 'vertical-rl' : 'horizontal-tb',
    }),
  };

  return {
    doc,
    win,
    textNodes: allTextNodes,
    blocks,
    // Register an occluding overlay on this document (a selection grip).
    addOverlay(el, r) {
      overlays.push({ el, rect: r });
    },
  };
}

function loadSelection(dom) {
  const literal = selectionObjectLiteral(selectionSource());
  const factory = new Function(
    'window',
    'document',
    'Node',
    'NodeFilter',
    'JAPANESE_RANGES',
    `return (${literal});`,
  );
  const sel = factory(dom.win, dom.doc, NodeStub, NodeFilterStub, [
    [0x3040, 0x309f],
    [0x30a0, 0x30ff],
    [0x4e00, 0x9fff],
  ]);
  dom.win.fushiSelection = sel;
  // The grips are created lazily through ensureSelectionHandles (real DOM work);
  // pre-seeding a connected pair keeps this harness on the hit-testing logic under
  // test while positionSelectionHandles still runs for real. They are element-shaped
  // (tag + `data-fushi-sel-handle` + closest) so a scenario can register them as
  // occluding overlays and the geometric fallback can recognise them as grips.
  const makeGrip = (which) => {
    const el = {
      nodeType: ELEMENT_NODE,
      tagName: 'DIV',
      style: {},
      isConnected: true,
      __attrs: { 'data-fushi-sel-handle': which },
      // Mirrors makeElement.closest. A real grip IS a `div`, so the geometric fallback's
      // `closest('p, div, span, ruby, a')` must match the grip itself — that is precisely
      // why the grip cannot serve as the text-block root. The attribute selector is what
      // the grip-skip looks for. Returning null for both would silently let the walker
      // fall back to `document.body` and resolve anyway, hiding the regression.
      closest(selector) {
        const parts = selector.split(',').map((s) => s.trim());
        if (parts.includes('[data-fushi-sel-handle]')) return el;
        if (parts.some((s) => s.toUpperCase() === 'DIV')) return el;
        return null;
      },
    };
    return el;
  };
  sel.selectionHandles = { start: makeGrip('start'), end: makeGrip('end') };
  return sel;
}

// ---------------------------------------------------------------- fixtures
const LATIN = 'The quick brown fox jumps over the lazy dog';
const CJK = '文学少女は静かに本を読んでいる';

function latinRects(extra) {
  return layoutText(
    LATIN,
    Object.assign(
      {
        x0: 20,
        y0: 20,
        lineWidth: 300,
        charWidth: 20,
        spaceWidth: 20,
        lineHeight: 40,
        gapAfter: { 9: 30 },
      },
      extra || {},
    ),
  );
}

function latinDom(extra) {
  return buildDocument(
    Object.assign(
      {
        bodyRect: rect(0, 0, 400, 300),
        blocks: [
          { tag: 'p', rect: rect(20, 20, 340, 200), textNodes: [{ text: LATIN, rects: latinRects() }] },
        ],
      },
      extra || {},
    ),
  );
}

// CJK fixture: 24px glyphs, 40px line pitch, a 26px justification gap after the
// 6th glyph. Keeps endpoints character-exact (no word snapping), so the geometry
// contract (line clamp / line priority) can be asserted to the glyph.
const CJK_GAP_INDEX = 5;
function cjkRects() {
  return layoutText(CJK, {
    x0: 20,
    y0: 20,
    lineWidth: 288,
    charWidth: 24,
    spaceWidth: 24,
    lineHeight: 40,
    gapAfter: { [CJK_GAP_INDEX]: 26 },
  });
}

function cjkDom(extra) {
  return buildDocument(
    Object.assign(
      {
        bodyRect: rect(0, 0, 400, 300),
        blocks: [
          { tag: 'p', rect: rect(20, 20, 340, 200), textNodes: [{ text: CJK, rects: cjkRects() }] },
        ],
      },
      extra || {},
    ),
  );
}

function verticalCenter(r) {
  return (r.top + r.bottom) / 2;
}

function lineIndices(rects, top) {
  const out = [];
  for (let i = 0; i < rects.length; i++) {
    if (rects[i].top === top) out.push(i);
  }
  return out;
}

function secondLineTop(rects) {
  for (let i = 1; i < rects.length; i++) {
    if (rects[i].top !== rects[0].top) return rects[i].top;
  }
  return rects[0].top;
}

function textOf(sel) {
  return sel.selection ? sel.selection.text : null;
}

const results = [];

function scenario(name, fn) {
  try {
    const detail = fn();
    results.push({ name, ok: true, detail });
    console.log(`SCENARIO ${name} :: ${JSON.stringify(detail)}`);
  } catch (error) {
    results.push({ name, ok: false, detail: String((error && error.message) || error) });
    console.log(`SCENARIO ${name} :: FAILED ${(error && error.stack) || error}`);
  }
}

// ---------------------------------------------------------------- scenarios

scenario('1_inter_char_gap_advances', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(
    sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])),
    'long press must arm on a glyph',
  );
  // Middle of the 30px justification gap after the space at index 9: no glyph rect
  // covers that point, so the strict hit misses — the resolver must still advance.
  const gapX = (rects[9].right + rects[10].left) / 2;
  const text = sel.updateRangeSelection(gapX, verticalCenter(rects[9]));
  assert.strictEqual(
    text,
    LATIN.slice(0, 10),
    `dragging into the inter-character gap must keep extending (got ${JSON.stringify(text)})`,
  );
  return { text };
});

scenario('2_line_end_clamps_to_line', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  const line1 = lineIndices(rects, rects[0].top);
  const lastOfLine1 = line1[line1.length - 1];
  const endX = rects[lastOfLine1].right + 12;
  const text = sel.updateRangeSelection(endX, verticalCenter(rects[lastOfLine1]));
  assert.strictEqual(
    text,
    CJK.slice(0, lastOfLine1 + 1),
    `a point in the trailing blank of line 1 belongs to line 1's last glyph (got ${JSON.stringify(text)})`,
  );
  // Further right along line 1: still line 1, must NOT jump to the next line.
  const text2 = sel.updateRangeSelection(rects[lastOfLine1].right + 40, verticalCenter(rects[lastOfLine1]));
  assert.strictEqual(
    text2,
    CJK.slice(0, lastOfLine1 + 1),
    `dragging further right along line 1 must not jump to the next line (got ${JSON.stringify(text2)})`,
  );
  // Moving down into line 2's band does extend onto line 2.
  const firstOfLine2 = lastOfLine1 + 1;
  const text3 = sel.updateRangeSelection(rects[firstOfLine2].left + 2, verticalCenter(rects[firstOfLine2]));
  assert.ok(
    text3.length > text2.length,
    `moving down into line 2 must extend the selection (${JSON.stringify(text2)} -> ${JSON.stringify(text3)})`,
  );
  return { line1: text, stillLine1: text2, line2: text3 };
});

scenario('3_next_line_right_blank_clamps_to_that_line', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  const line2Top = secondLineTop(rects);
  const line2 = lineIndices(rects, line2Top);
  const lastOfLine2 = line2[line2.length - 1];
  const text = sel.updateRangeSelection(rects[lastOfLine2].right + 16, verticalCenter(rects[lastOfLine2]));
  assert.strictEqual(
    text,
    CJK.slice(0, lastOfLine2 + 1),
    `a blank point on line 2 must clamp to line 2's last glyph (got ${JSON.stringify(text)})`,
  );
  return { text };
});

scenario('4_below_paragraph_clamps_to_last_glyph', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  const last = rects[rects.length - 1];
  const text = sel.updateRangeSelection(last.right - 4, last.bottom + 60);
  assert.strictEqual(
    text,
    CJK,
    `dragging below the paragraph must clamp to its end, not freeze (got ${JSON.stringify(text)})`,
  );
  return { text };
});

scenario('5_geometric_fallback_without_native_caret_api', () => {
  const dom = cjkDom({ disableCaretApis: true });
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  // Inter-character gap (justification).
  const gapX = (rects[CJK_GAP_INDEX].right + rects[CJK_GAP_INDEX + 1].left) / 2;
  const gapText = sel.updateRangeSelection(gapX, verticalCenter(rects[CJK_GAP_INDEX]));
  assert.strictEqual(
    gapText,
    CJK.slice(0, CJK_GAP_INDEX + 1),
    `the DOM geometry fallback must resolve the gap point (got ${JSON.stringify(gapText)})`,
  );
  // Line-end blank.
  const line1 = lineIndices(rects, rects[0].top);
  const lastOfLine1 = line1[line1.length - 1];
  const lineEndText = sel.updateRangeSelection(
    rects[lastOfLine1].right + 12,
    verticalCenter(rects[lastOfLine1]),
  );
  assert.strictEqual(
    lineEndText,
    CJK.slice(0, lastOfLine1 + 1),
    `the DOM geometry fallback must clamp the line-end blank to the line (got ${JSON.stringify(lineEndText)})`,
  );
  return { gap: gapText, lineEnd: lineEndText };
});

scenario('6_latin_drag_is_character_precise', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[4].left + 4, verticalCenter(rects[4])));
  // 拖到 "brown" 中间的 'o'（索引 12）：端点必须停在手指所在的那一个字上，**不能**吸附到
  // 词尾（旧行为会选中整个 "brown"）。锚点是长按定下的 "quick"（索引 4）。
  const target = 12;
  const text = sel.updateRangeSelection(rects[target].left + 4, verticalCenter(rects[target]));
  assert.strictEqual(
    text,
    LATIN.slice(4, target + 1),
    `a drag must land on the character under the finger, never on a word edge (got ${JSON.stringify(text)})`,
  );
  return { text };
});

scenario('7_latin_long_press_selects_word', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[5].left + 4, verticalCenter(rects[5])));
  assert.strictEqual(
    textOf(sel),
    'quick',
    `a stationary long press inside a Latin word must select the whole word (got ${JSON.stringify(textOf(sel))})`,
  );
  return { text: textOf(sel) };
});

scenario('8_latin_drag_can_shrink_into_the_anchor_word', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  // 长按定下整词 "quick"（索引 4..8）：原地不动就是整词（浏览器 / Android 长按语义）。
  assert.ok(sel.beginRangeSelection(rects[5].left + 4, verticalCenter(rects[5])));
  assert.strictEqual(
    textOf(sel),
    'quick',
    `a stationary long press must keep the whole word (got ${JSON.stringify(textOf(sel))})`,
  );
  // 往**词内**拖（'i'，索引 6）：端点逐字跟随 -> 收缩到 "qui"，不再被整词粘住。
  // 这正是「拉丁语言没法随意选择字符」那条反馈要的行为：端点不吸附词边界。
  const shrunk = sel.updateRangeSelection(rects[6].left + 2, verticalCenter(rects[6]));
  assert.strictEqual(
    shrunk,
    LATIN.slice(4, 7),
    `dragging back inside the word must shrink character by character (got ${JSON.stringify(shrunk)})`,
  );
  // 再往词外拖（'b'，索引 10）：越过词尾，同样是逐字扩展。
  const extended = sel.updateRangeSelection(rects[10].left + 2, verticalCenter(rects[10]));
  assert.strictEqual(
    extended,
    LATIN.slice(4, 11),
    `dragging past the word end must extend character by character (got ${JSON.stringify(extended)})`,
  );
  return { shrunk, extended };
});

scenario('9_cjk_stays_character_granular', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  const target = 3;
  const got = sel.updateRangeSelection(rects[target].left + 20, verticalCenter(rects[target]));
  assert.strictEqual(
    got,
    CJK.slice(0, target + 1),
    `CJK must extend character by character, no word snapping (got ${JSON.stringify(got)})`,
  );
  return { text: got };
});

scenario('10_vertical_writing_gap_does_not_freeze', () => {
  const text = 'これは縦書きのテストです';
  // vertical-rl: reading runs top->bottom inside a column, columns advance left.
  const rects = [];
  const columnWidth = 40;
  const x0 = 340;
  let column = 0;
  let y = 20;
  for (const ch of text) {
    if (y + 30 > 300) {
      y = 20;
      column += 1;
    }
    const left = x0 - column * columnWidth;
    rects.push(rect(left, y, left + 32, y + 30));
    y += 30 + (ch === 'の' ? 40 : 0); // justification gap inside the column
  }
  const dom = buildDocument({
    bodyRect: rect(0, 0, 400, 320),
    vertical: true,
    blocks: [{ tag: 'p', rect: rect(200, 20, 360, 300), textNodes: [{ text, rects }] }],
  });
  const sel = loadSelection(dom);
  assert.ok(sel.beginRangeSelection(rects[0].left + 10, rects[0].top + 4));
  const gapIndex = text.indexOf('の');
  const gapY = (rects[gapIndex].bottom + rects[gapIndex + 1].top) / 2;
  const got = sel.updateRangeSelection(rects[gapIndex].left + 10, gapY);
  assert.strictEqual(
    got,
    text.slice(0, gapIndex + 1),
    `vertical-rl: a point in the column gap must clamp to the previous column glyph (got ${JSON.stringify(got)})`,
  );
  return { text: got };
});

scenario('11_page_margin_band_never_selects_clipped_neighbour', () => {
  const visible = layoutText('本頁正文', {
    x0: 100,
    y0: 100,
    lineWidth: 300,
    charWidth: 20,
    spaceWidth: 20,
    lineHeight: 40,
  });
  // The neighbouring page's column lives inside the body padding band (x 8..28),
  // painted over by clip-path / html::before: invisible, yet still hit-testable at
  // layout time (BUG-1797).
  const hidden = layoutText('隣頁', {
    x0: 8,
    y0: 100,
    lineWidth: 300,
    charWidth: 20,
    spaceWidth: 20,
    lineHeight: 40,
  });
  const dom = buildDocument({
    bodyRect: rect(0, 0, 400, 300),
    padding: { left: 40, right: 40, top: 40, bottom: 40 },
    blocks: [
      { tag: 'p', rect: rect(40, 40, 360, 260), textNodes: [{ text: '本頁正文', rects: visible }] },
      { tag: 'p', rect: rect(40, 40, 360, 260), textNodes: [{ text: '隣頁', rects: hidden }] },
    ],
  });
  const sel = loadSelection(dom);
  assert.ok(sel.beginRangeSelection(visible[0].left + 4, visible[0].top + 20));
  const before = textOf(sel);
  const moved = sel.updateRangeSelection(18, 110);
  assert.ok(
    moved === null || !moved.includes('隣'),
    `a point in the page-margin band must never select the clipped neighbouring page text (got ${JSON.stringify(moved)})`,
  );
  assert.strictEqual(textOf(sel), before, 'the selection must stay on the visible page');
  return { before, after: textOf(sel) };
});

scenario('12_strict_hit_unchanged', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  const got = sel.updateRangeSelection(rects[5].left + 4, verticalCenter(rects[5]));
  assert.strictEqual(
    got,
    LATIN.slice(0, 6),
    `a finger inside a glyph must still resolve to that glyph, character-precisely (got ${JSON.stringify(got)})`,
  );
  return { text: got };
});

scenario('13_handle_drag_sweep_never_freezes', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  sel.endRangeSelection(rects[1].right, verticalCenter(rects[1]));
  const line1 = lineIndices(rects, rects[0].top);
  const lastOfLine1 = line1[line1.length - 1];
  const line2Top = secondLineTop(rects);
  const line2 = lineIndices(rects, line2Top);
  const lastOfLine2 = line2[line2.length - 1];
  // Sweep the end grip rightwards through blank points on purpose: inside glyphs,
  // into the justification gap, past the end of line 1, down into line 2, and past
  // the end of the paragraph.
  const sweep = [
    { x: rects[3].left + 4, y: verticalCenter(rects[3]) },
    { x: (rects[CJK_GAP_INDEX].right + rects[CJK_GAP_INDEX + 1].left) / 2, y: verticalCenter(rects[CJK_GAP_INDEX]) },
    { x: rects[lastOfLine1].right + 10, y: verticalCenter(rects[lastOfLine1]) },
    { x: rects[line2[0]].left + 2, y: verticalCenter(rects[line2[0]]) },
    { x: rects[lastOfLine2].right + 30, y: verticalCenter(rects[lastOfLine2]) },
  ];
  const steps = [];
  for (const point of sweep) {
    sel.moveSelectionHandle('end', point.x, point.y);
    steps.push(textOf(sel));
  }
  for (const step of steps) {
    assert.ok(step && step.length > 0, 'the grip must keep producing a selection');
  }
  for (let i = 1; i < steps.length; i++) {
    assert.ok(
      steps[i].length >= steps[i - 1].length,
      `the grip sweep must never shrink or freeze (step ${i}: ${JSON.stringify(steps[i - 1])} -> ${JSON.stringify(steps[i])})`,
    );
  }
  assert.strictEqual(
    steps[steps.length - 1],
    CJK.slice(0, lastOfLine2 + 1),
    `the swept grip must land on the last glyph of the paragraph (got ${JSON.stringify(steps[steps.length - 1])})`,
  );
  return { steps };
});

scenario('14_whitespace_only_node_endpoint_normalized', () => {
  // <p>Alpha<b>Beta</b> <i>Gamma</i></p><p>Zeta</p>: the space between the inline
  // elements is a whitespace-only text node, which createWalker REJECTs. A space
  // glyph has a real client rect, so the *strict* hit test can resolve to such a
  // node (it is inside the content box) -- and collectRangeBetween then walks past
  // its end node forever, ballooning the selection to the end of the chapter.
  // The endpoint normalisation layer must map it onto a real text node.
  const alpha = layoutText('Alpha', { x0: 20, y0: 20, lineWidth: 340, charWidth: 20, spaceWidth: 20, lineHeight: 40 });
  const space = layoutText(' ', { x0: 120, y0: 20, lineWidth: 340, charWidth: 20, spaceWidth: 20, lineHeight: 40 });
  const gamma = layoutText('Gamma', { x0: 140, y0: 20, lineWidth: 340, charWidth: 20, spaceWidth: 20, lineHeight: 40 });
  const zeta = layoutText('Zeta', { x0: 20, y0: 80, lineWidth: 340, charWidth: 20, spaceWidth: 20, lineHeight: 40 });
  const dom = buildDocument({
    bodyRect: rect(0, 0, 400, 300),
    blocks: [
      {
        tag: 'p',
        rect: rect(20, 20, 320, 60),
        textNodes: [
          { text: 'Alpha', rects: alpha },
          { text: ' ', rects: space },
          { text: 'Gamma', rects: gamma },
        ],
      },
      { tag: 'p', rect: rect(20, 80, 320, 120), textNodes: [{ text: 'Zeta', rects: zeta }] },
    ],
  });
  const sel = loadSelection(dom);
  const [, spaceNode, gammaNode] = dom.textNodes;
  assert.ok(sel.beginRangeSelection(alpha[1].left + 4, alpha[1].top + 20));
  const got = sel.updateRangeSelection(gamma[1].left + 4, gamma[1].top + 20);
  assert.ok(
    !got.includes('Zeta'),
    `an endpoint inside the whitespace-only node must never balloon past it (got ${JSON.stringify(got)})`,
  );
  assert.strictEqual(
    got,
    'Alpha' + 'Gamma'.slice(0, 2),
    `the whitespace node is skipped by the range walker (existing design), the endpoint still lands on the Gamma character under the finger (got ${JSON.stringify(got)})`,
  );
  // Load-bearing check: without the normalisation the same raw call would never
  // match its end node and would run to the end of the document (this is the
  // pre-existing failure mode the guard removes), so this harness can detect a
  // regression instead of silently passing.
  const raw = sel.collectRangeBetween(dom.textNodes[0], 1, spaceNode, 0);
  assert.ok(
    raw && raw.text.includes('Zeta'),
    `raw collectRangeBetween with a whitespace end node must demonstrate the balloon (got ${JSON.stringify(raw && raw.text)})`,
  );
  return { text: got, rawBalloon: raw.text };
});

scenario('15_handle_drag_under_grip_still_advances', () => {
  // The finger drags the end grip, so the 32x32 transparent grip box sits *under* the
  // finger and a hit test at the raw coordinate resolves to the grip element instead of
  // the glyph. moveSelectionHandle must therefore resolve the endpoint inside the window
  // where the grips are transparent to hit-testing. Resolving after restoring
  // `pointer-events` kills both routes at once: the native caret fast path gets an
  // ELEMENT_NODE (rejected — it only trusts text nodes) and the geometric fallback gets
  // the grip as its walker root (it is a `div`, so closest('div') is itself -> no text),
  // which returns null and leaves the grip frozen under the finger.
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  sel.endRangeSelection(rects[1].right, verticalCenter(rects[1]));
  const target = rects[CJK_GAP_INDEX];
  const next = rects[CJK_GAP_INDEX + 1];
  // The finger sits in the justification gap (no glyph rect covers it, so the strict hit is
  // null and only the "coordinate -> caret" resolver can produce an endpoint) *while* the
  // grip is under it — the exact combination the ordering bug breaks.
  const point = { x: (target.right + next.left) / 2, y: verticalCenter(target) };
  // The real grip is a 32x32 touch box centred on the finger; only the occlusion matters here.
  dom.addOverlay(sel.selectionHandles.end, rect(point.x - 16, point.y - 16, point.x + 16, point.y + 16));
  const before = textOf(sel);
  sel.moveSelectionHandle('end', point.x, point.y);
  const after = textOf(sel);
  assert.ok(
    after.length > before.length,
    `a grip over a gap must not freeze the handle (${JSON.stringify(before)} -> ${JSON.stringify(after)})`,
  );
  return { before, after };
});

scenario('16_text_drag_under_grip_still_advances', () => {
  // updateRangeSelection does not toggle pointer-events, so a grip can still occlude the
  // raw point while the finger drags the text itself. The geometric fallback must look
  // *through* the grip (elementsFromPoint) instead of treating the grip element as the
  // text block.
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const rects = dom.textNodes[0].__rects;
  assert.ok(sel.beginRangeSelection(rects[0].left + 4, verticalCenter(rects[0])));
  sel.updateRangeSelection(rects[1].left + 4, verticalCenter(rects[1]));
  sel.showSelectionHandles();
  const target = rects[5];
  const point = { x: target.left + 4, y: verticalCenter(target) };
  dom.addOverlay(sel.selectionHandles.end, rect(point.x - 16, point.y - 16, point.x + 16, point.y + 16));
  const before = textOf(sel);
  const after = sel.updateRangeSelection(point.x, point.y);
  assert.ok(
    after && after.length > before.length,
    `a grip over the finger must not block the drag endpoint (${JSON.stringify(before)} -> ${JSON.stringify(after)})`,
  );
  return { before, after };
});

// ---------------------------------------------------------------- summary
const failures = results.filter((r) => !r.ok);
console.log(`passed ${results.length - failures.length} cases`);
if (failures.length) {
  for (const failure of failures) {
    console.error(`FAILED ${failure.name}: ${failure.detail}`);
  }
  process.exit(1);
}
console.log('all assertions passed');
console.log('OK');
