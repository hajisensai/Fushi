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
//   6  拉丁词拖选                      -> 拖动端点保持字符级
//   7  拉丁词长按                      -> 原地长按即选中整词
//   8  拉丁词拖动                      -> 可缩进长按锚词内部，不锁在词边界
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
const { spawnSync } = require('child_process');
const mutation = process.argv[2] || null;
assert.ok(!mutation || mutation.startsWith('--mutant='), 'unknown harness argument');

// Mutate only the production payload in memory; assert the expected match
// count at each site. Demand behavioral witness failures, not syntax/load errors.
const mutations = {
  early_restore: [
    '      return this.resolveSelectionEndpoint(x, y, hit, refNode, refOffset);',
    `      if (handles) {
        handles.start.style.pointerEvents = savedStartPe;
        handles.end.style.pointerEvents = savedEndPe;
      }
      return this.resolveSelectionEndpoint(x, y, hit, refNode, refOffset);`,
    '23_no_stack_endpoint_window',
  ],
  bypass_text_window: [
    'this.selectionEndpointAtPoint(x, y, anchor.node, anchor.offset)',
    'this.resolveSelectionEndpoint(x, y, this.getSelectableCharacterAtPoint(x, y), anchor.node, anchor.offset)',
    '23_no_stack_endpoint_window',
  ],
  skip_range_fallback: ['api < 2', 'api < (document.caretPositionFromPoint ? 1 : 2)', '17_native_api_fallback_order'],
  raw_endpoint_fallback: [
    'var endpoint = this.normalizeEndpoint(node, offset, forward);',
    'var endpoint = this.normalizeEndpoint(node, offset, forward) || { node: node, offset: offset };',
    '19_normalization_failure_is_not_a_raw_endpoint',
  ],
  one_direction_only: ['attempt < 2', 'attempt < 1', '18_normalization_direction_and_boundary'],
  reset_to_anchor: [
    '    if (!endpoint) return null;\n    var built = endpoint.forward',
    `    if (!endpoint) {
      this.selection = this.collectRangeBetween(anchor.node, anchor.offset, anchor.endNode, anchor.endOffset);
      return null;
    }
    var built = endpoint.forward`,
    '20_failed_drag_preserves_current_selection',
  ],
  drop_release: [
    'if (this.dragAnchor && this.dragAnchor.moved) this.updateRangeSelection(x, y);',
    '/* ignore release */', '22_drag_release_uses_last_coordinate',
  ],
  lose_stationary_word: [
    'if (!anchor.moved) return this.selection ? this.selection.text : null;',
    '/* truncate even on unchanged touchmove */', '21_stationary_longpress_keeps_word',
  ],
  restore_auto: [
    'handles.start.style.pointerEvents = savedStartPe;',
    "handles.start.style.pointerEvents = savedStartPe || 'auto';", '24_window_restores_exact_style_even_on_throw',
  ],
  clear_busy_viewport: [
    'if (this.dragAnchor || this.activeHandle) return;',
    '/* clear while dragging */', '25_viewport_clear_and_bridge_order',
  ],
  skip_empty_notification: [
    "window.flutter_inappwebview.callHandler('onSelectionCleared');",
    "if (this.selection) window.flutter_inappwebview.callHandler('onSelectionCleared');", '25_viewport_clear_and_bridge_order',
  ],
  hide_until_release: [
    '      this.showSelectionHandles();',
    '      /* hidden until release */', '28_longpress_live_coordinates_each_move',
  ],
  freeze_text_handles: [
    '    this.positionSelectionHandles();\n    return built.text;',
    '    return built.text;', '28_longpress_live_coordinates_each_move',
  ],
  freeze_handle_handles: [
    '    this.renderSelectionHighlight();\n    this.positionSelectionHandles();\n  },',
    '    this.renderSelectionHighlight();\n  },', '29_handle_listener_live_coordinates_and_bridge',
  ],
  skip_drag_bridge: [
    "      window.flutter_inappwebview.callHandler('onSelectionDragStarted');",
    '      /* stale menu stays up */', '29_handle_listener_live_coordinates_and_bridge',
  ],
  late_end_without_session: [
    '    if (!this.dragAnchor) return false;',
    '    /* no drag session required */', '30_clear_then_late_end_does_not_revive_menu',
  ],
  ignore_detached_nodes: [
    'node.nodeType === Node.TEXT_NODE && node.isConnected &&',
    'node.nodeType === Node.TEXT_NODE &&', '31_detached_dom_cancels_drag_and_late_end',
  ],
  reuse_pre_normalize_hit: [
    '    if (hadWrappers) hit = this.getSelectableCharacterAtPoint(x, y);',
    '    /* reuse the detached pre-clear hit */', '32_begin_resolves_after_wrapper_normalize',
  ],
  skip_handles_rect_payload: [
    '    payload.handlesRect = this.selectionHandlesRect();',
    '    /* toolbar has only glyph bounds */', '33_handles_rect_and_legacy_top_layer_contract',
  ],
  skip_touch_box_clamp: [
    'return Math.max(half, Math.min(extent - half, value));',
    'return value;', '34_edge_touch_boxes_bounded_and_independently_grabbable',
  ],
  overlap_clamped_grips: [
    'if (edgeClamped && Math.abs(sx - ex) < SIZE && Math.abs(sy - ey) < SIZE)',
    'if (false)', '34_edge_touch_boxes_bounded_and_independently_grabbable',
  ],
  displace_interior_anchors: [
    'var GAP = 8;', 'var GAP = 20;',
    '37_interior_handles_keep_endpoint_anchors',
  ],
  clamp_offscreen_endpoints: [
    '!this.charRangeVisible(this.charRangeAt(eps.startNode, eps.startOffset), box) ||',
    'false ||', '35_offscreen_endpoints_are_not_clamped_into_view',
  ],
  reopen_live_touch_target: [
    "typeof el.showPopover === 'function' && !el.matches(':popover-open')",
    "typeof el.showPopover === 'function'", '28_longpress_live_coordinates_each_move',
  ],
};
function mutateSource(source) {
  if (!mutation) return source;
  const name = mutation.slice('--mutant='.length);
  assert.ok(Object.hasOwn(mutations, name), `unknown mutation ${name}`);
  const [before, after] = mutations[name];
  if (name === 'late_end_without_session') {
    assert.strictEqual(source.split(before).length - 1, 2);
    return source.replaceAll(before, after).replace(
      'if (!this.liveDragAnchor()) { this.clearSelection(); return false; }',
      'if (this.dragAnchor && !this.liveDragAnchor()) { this.clearSelection(); return false; }');
  }
  assert.strictEqual(source.split(before).length - 1, 1, `${name} must match exactly once`);
  return source.replace(before, after);
}


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
  return mutateSource(dart.substring(bodyStart, end));
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
    get isConnected() { return !!(this.parentElement && this.parentElement.isConnected); },
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
    contains(candidate) {
      for (let node = candidate; node; node = node.parentElement) {
        if (node === el) return true;
      }
      return false;
    },
    __listeners: {},
    __styleWrites: [],
    addEventListener(name, fn) { el.__listeners[name] = fn; },
    getBoundingClientRect() {
      if (attrs['data-fushi-sel-handle']) {
        if (el.style.display === 'none') return rect(0, 0, 0, 0);
        const x = parseFloat(el.style.left), y = parseFloat(el.style.top);
        return rect(x - 16, y - 16, x + 16, y + 16);
      }
      return el.__rect;
    },
  };
  el.__attrs = attrs;
  el.style = new Proxy({}, {
    set(style, key, value) {
      el.__styleWrites.push({ key, value });
      style[key] = value;
      if (key === 'cssText') {
        for (const declaration of value.split(';')) {
          const [property, val] = declaration.split(':');
          if (val !== undefined) style[property.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = val;
        }
      }
      return true;
    },
  });
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

  const root = makeElement('html');
  root.clientWidth = body.__rect.right;
  root.clientHeight = body.__rect.bottom;
  root.appendChild(body);
  const doc = {
    body,
    documentElement: root,
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
    createElement: (tag) => {
      const el = makeElement(tag, null);
      if (spec.popover) {
        el.__popoverOpen = false;
        el.__popoverShows = 0;
        el.showPopover = () => {
          assert.strictEqual(el.getAttribute('popover'), 'manual');
          assert.strictEqual(el.style.display, 'block');
          el.__popoverOpen = true; el.__popoverShows++;
        };
        el.hidePopover = () => { el.__popoverOpen = false; };
        el.matches = (selector) => selector === ':popover-open' && el.__popoverOpen;
      }
      return el;
    },
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

function loadSelection(dom, realHandles = false) {
  const literal = selectionObjectLiteral(selectionSource());
  const factory = new Function(
    'window',
    'document',
    'Node',
    'NodeFilter',
    'JAPANESE_RANGES', 'CSS', 'Highlight',
    `return (${literal});`,
  );
  const sel = factory(dom.win, dom.doc, NodeStub, NodeFilterStub, [
    [0x3040, 0x309f],
    [0x30a0, 0x30ff],
    [0x4e00, 0x9fff],
  ], { highlights: new Map() }, class Highlight extends Array {});
  dom.win.fushiSelection = sel;
  if (realHandles) return sel;
  // The grips are created lazily through ensureSelectionHandles (real DOM work);
  // pre-seeding a connected pair keeps this harness on the hit-testing logic under
  // test while positionSelectionHandles still runs for real. They are element-shaped
  // (tag + `data-fushi-sel-handle` + closest) so a scenario can register them as
  // occluding overlays and the geometric fallback can recognise them as grips.
  const makeGrip = (which) => {
    const el = {
      nodeType: ELEMENT_NODE,
      tagName: 'DIV',
      style: { pointerEvents: 'auto' },
      getBoundingClientRect() {
        const x = parseFloat(el.style.left), y = parseFloat(el.style.top);
        return rect(x - 16, y - 16, x + 16, y + 16);
      },
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
  // Stack-enabled case: the new no-stack matrix independently locks ordering.
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
  // Defensive overlap: normal long-press begin hides handles until release.
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

// Execute the actual generated gesture script, replacing only Dart numeric parameters.
function gestureDriver(dom) {
  const dart = fs.readFileSync(path.resolve(__dirname, '../../lib/src/reader/reader_selection_scripts.dart'), 'utf8');
  const method = dart.indexOf('static String longPressDragGestureScript({');
  const start = dart.indexOf("return '''", method) + "return '''".length;
  const end = dart.indexOf("''';", start);
  assert.ok(method >= 0 && start > method && end > start);
  const script = dart.slice(start, end).replace('$delayMs', '400').replace('$slopSq', '100');
  const listeners = {};
  const timers = new Map();
  let id = 0;
  dom.doc.addEventListener = (name, fn) => { listeners[name] = fn; };
  dom.win.matchMedia = () => ({ matches: true });
  new Function('window', 'document', 'setTimeout', 'clearTimeout', script)(dom.win, dom.doc,
    (fn) => { timers.set(++id, fn); return id; }, (key) => timers.delete(key));
  return {
    fire(name, x, y) {
      const t = { clientX: x, clientY: y };
      assert.ok(listeners[name], `missing actual gesture listener ${name}`);
      listeners[name]({ target: dom.blocks[0].el, touches: name === 'touchend' ? [] : [t],
        changedTouches: [t], cancelable: true, preventDefault() {}, stopPropagation() {} });
    },
    hold() {
      assert.strictEqual(timers.size, 1, 'long-press must really arm');
      for (const [key, fn] of [...timers]) { timers.delete(key); fn(); }
    },
  };
}
function glyphPoint(dom, index) {
  const r = dom.textNodes[0].__rects[index];
  return [r.left + 4, verticalCenter(r)];
}

scenario('17_native_api_fallback_order', () => {
  const modes = ['null', 'element', 'absent', 'throws', 'invisible', 'valid'];
  for (const mode of modes) {
    const dom = cjkDom();
    const sel = loadSelection(dom);
    const node = dom.textNodes[0];
    const calls = [];
    dom.doc.caretPositionFromPoint = () => {
      calls.push('position');
      if (mode === 'throws') throw new Error('unsupported native API');
      if (mode === 'null') return null;
      return { offsetNode: mode === 'element' ? dom.blocks[0].el : node, offset: mode === 'invisible' ? 999 : 6 };
    };
    if (mode === 'absent') delete dom.doc.caretPositionFromPoint;
    dom.doc.caretRangeFromPoint = () => { calls.push('range'); return { startContainer: node, startOffset: 6 }; };
    // Disable geometric rescue: test the native contract, not a lucky final result.
    dom.doc.elementFromPoint = () => null;
    dom.doc.elementsFromPoint = () => [];
    const hit = sel.caretPositionAtPoint(189, 40);
    assert.ok(hit, `${mode}: range fallback must remain reachable`);
    assert.strictEqual(hit.node, node);
    assert.strictEqual(hit.offset, 6);
    assert.deepStrictEqual(calls, mode === 'absent' ? ['range'] : mode === 'valid' ? ['position'] : ['position', 'range']);
  }
  return { modes };
});

function spacedDom(parts) {
  let x = 20;
  return buildDocument({ bodyRect: rect(0, 0, 400, 300), blocks: [{ rect: rect(20, 20, 380, 80),
    textNodes: parts.map((text) => ({ text,
      rects: Array.from(text, () => { const r = rect(x, 20, x + 20, 60); x += 20; return r; }),
    })),
  }] });
}
scenario('18_normalization_direction_and_boundary', () => {
  const dom = spacedDom(['  ', 'AB', '  ', 'CD', '  ']);
  const sel = loadSelection(dom);
  const [leading, first, middle, last, trailing] = dom.textNodes;
  for (const [node, forward, expectedNode, offset] of [
    [middle, true, last, 0], [middle, false, first, 1],
    [leading, false, first, 0], [leading, true, first, 0],
    [trailing, true, last, 1], [trailing, false, last, 1],
  ]) assert.deepStrictEqual(sel.normalizeEndpoint(node, 0, forward), { node: expectedNode, offset });
  // Real reverse drag onto preserved leading whitespace: use the first body
  // character, not a raw filtered whitespace node. No balloon claim is needed.
  assert.ok(sel.beginRangeSelection(145, 40));
  sel.updateRangeSelection(165, 40);
  assert.strictEqual(sel.updateRangeSelection(25, 40), 'ABCD');
  assert.strictEqual(sel.selection.startNode, first);
  return { leadingReverse: textOf(sel), directions: 6 };
});
scenario('19_normalization_failure_is_not_a_raw_endpoint', () => {
  const dom = spacedDom(['  ']);
  const sel = loadSelection(dom);
  const node = dom.textNodes[0];
  for (const forward of [true, false]) assert.strictEqual(sel.normalizeEndpoint(node, 0, forward), null);
  for (const offset of [0, 1]) assert.strictEqual(
    sel.resolveSelectionEndpoint(25, 40, { node, offset }, node, 0), null,
    'failed normalization must not resurrect the filtered raw endpoint');
  // Normalization can move a visible whitespace hit onto an off-page glyph.
  // Recheck the normalized character, not just the original caret neighbour.
  const clipped = spacedDom(['  ', 'AB']);
  const clippedSel = loadSelection(clipped);
  clipped.textNodes[1].__rects = [rect(500, 20, 520, 60), rect(520, 20, 540, 60)];
  assert.strictEqual(clippedSel.resolveSelectionEndpoint(25, 40,
    { node: clipped.textNodes[0], offset: 1 }, clipped.textNodes[0], 0), null);
  return { rejected: true, clippedNormalizedEndpointRejected: true };
});
scenario('20_failed_drag_preserves_current_selection', () => {
  const dom = cjkDom({ disableCaretApis: true, blocks: [
    { rect: rect(20, 20, 340, 130), textNodes: [{ text: CJK, rects: cjkRects() }] },
    { tag: 'div', rect: rect(20, 150, 340, 200), textNodes: [] },
  ] });
  const sel = loadSelection(dom);
  sel.beginRangeSelection(...glyphPoint(dom, 0));
  sel.updateRangeSelection(...glyphPoint(dom, 4));
  const previous = sel.selection;
  assert.strictEqual(sel.updateRangeSelection(60, 170), null);
  assert.strictEqual(sel.selection, previous, 'empty block must preserve expanded selection, not anchor');
  // Also isolate normalization failure after a genuine strict glyph hit.
  const normalize = sel.normalizeEndpoint;
  sel.normalizeEndpoint = () => null;
  assert.strictEqual(sel.updateRangeSelection(...glyphPoint(dom, 6)), null);
  assert.strictEqual(sel.selection, previous);
  sel.normalizeEndpoint = normalize;
  const collect = sel.collectRangeBetween;
  sel.collectRangeBetween = () => null;
  assert.strictEqual(sel.updateRangeSelection(...glyphPoint(dom, 6)), null);
  assert.strictEqual(sel.selection, previous, 'range build failure must also preserve current selection');
  sel.collectRangeBetween = collect;
  assert.strictEqual(sel.endRangeSelection(60, 170), true);
  assert.strictEqual(sel.selection, previous, 'failed final release keeps the last valid range');
  assert.strictEqual(sel.dragAnchor, null);
  return { text: textOf(sel) };
});
scenario('21_stationary_longpress_keeps_word', () => {
  const dom = latinDom();
  const sel = loadSelection(dom);
  const driver = gestureDriver(dom);
  const point = glyphPoint(dom, LATIN.indexOf('quick') + 2);
  driver.fire('touchstart', ...point);
  driver.hold();
  assert.strictEqual(textOf(sel), 'quick');
  driver.fire('touchmove', ...point); // same coordinates are not a drag
  driver.fire('touchend', ...point);
  assert.strictEqual(textOf(sel), 'quick');
  assert.strictEqual(sel.dragAnchor, null);
  return { text: textOf(sel) };
});
scenario('22_drag_release_uses_last_coordinate', () => {
  const outputs = [];
  for (const latin of [false, true]) {
    const dom = latin ? latinDom() : cjkDom();
    const sel = loadSelection(dom);
    const driver = gestureDriver(dom);
    const start = latin ? LATIN.indexOf('quick') + 2 : 0;
    const move = latin ? LATIN.indexOf('brown') : 2;
    const release = latin ? LATIN.indexOf('quick') + 1 : 3;
    const expected = latin ? 'qu' : CJK.slice(0, 4);
    const bridge = [];
    dom.win.flutter_inappwebview.callHandler = (name, payload) => bridge.push({ name, payload });
    driver.fire('touchstart', ...glyphPoint(dom, start));
    driver.hold();
    driver.fire('touchmove', ...glyphPoint(dom, move));
    assert.notStrictEqual(textOf(sel), expected);
    driver.fire('touchend', ...glyphPoint(dom, release));
    assert.strictEqual(textOf(sel), expected);
    const menu = bridge.find((e) => e.name === 'onSelectionMenu');
    assert.ok(menu, 'release must publish a real menu');
    assert.strictEqual(JSON.parse(menu.payload).text, expected);
    outputs.push(expected);
  }
  return { outputs };
});
scenario('23_no_stack_endpoint_window', () => {
  const outputs = [];
  for (const disableCaretApis of [false, true]) for (const kind of ['end', 'start', 'text']) {
    const dom = cjkDom({ disableCaretApis });
    delete dom.doc.elementsFromPoint;
    const sel = loadSelection(dom);
    const anchor = kind === 'start' ? 9 : 0;
    sel.beginRangeSelection(...glyphPoint(dom, anchor));
    if (kind !== 'text') sel.endRangeSelection(...glyphPoint(dom, anchor));
    else sel.showSelectionHandles(); // defensive overlap, not the normal lifecycle
    const r = dom.textNodes[0].__rects[5];
    const points = [[r.right + 12, verticalCenter(r)], [kind === 'start' ? 10 : 335, verticalCenter(r)]];
    for (let i = 0; i < points.length; i++) {
      const [x, y] = points[i];
      dom.addOverlay(sel.selectionHandles.end, rect(x - 16, y - 16, x + 16, y + 16));
      if (kind !== 'text') sel.moveSelectionHandle(kind, x, y);
      else sel.updateRangeSelection(x, y);
      assert.strictEqual(textOf(sel), (kind === 'start' ? CJK.slice(i === 0 ? 6 : 0, 10) : CJK.slice(0, i === 0 ? 6 : 10)), `${kind}, native=${!disableCaretApis}, step=${i}`);
      assert.strictEqual(sel.selectionHandles.end.style.pointerEvents, 'auto');
      assert.strictEqual(sel.selectionHandles.end.style.display, 'block');
    }
    outputs.push({ kind, native: !disableCaretApis, text: textOf(sel) });
  }
  return { outputs };
});
scenario('24_window_restores_exact_style_even_on_throw', () => {
  let checked = 0;
  for (const pe of ['', 'auto', 'none']) for (const failAt of [null, 'strict', 'resolve']) {
    const dom = cjkDom();
    const sel = loadSelection(dom);
    const { start, end } = sel.selectionHandles;
    Object.assign(start.style, { pointerEvents: pe, display: 'block', visibility: 'visible' });
    Object.assign(end.style, { pointerEvents: 'inherit', display: 'block', visibility: 'visible' });
    const sentinel = new Error('endpoint failure');
    for (const [method, stage] of [['getSelectableCharacterAtPoint', 'strict'], ['resolveSelectionEndpoint', 'resolve']]) {
      const original = sel[method];
      sel[method] = function(...args) {
        assert.strictEqual(start.style.pointerEvents, 'none', `${stage} must be inside the window`);
        assert.strictEqual(end.style.pointerEvents, 'none');
        assert.strictEqual(start.style.display, 'block', 'hit window must stay visually visible');
        assert.strictEqual(end.style.visibility, 'visible');
        if (failAt === stage) throw sentinel;
        return original.apply(this, args);
      };
    }
    const action = () => sel.selectionEndpointAtPoint(...glyphPoint(dom, 3), dom.textNodes[0], 0);
    if (failAt) assert.throws(action, (e) => e === sentinel);
    else assert.ok(action());
    assert.strictEqual(start.style.pointerEvents, pe, 'restore exact inline value, including empty string');
    assert.strictEqual(end.style.pointerEvents, 'inherit');
    checked++;
  }
  return { checked };
});
scenario('25_viewport_clear_and_bridge_order', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const calls = [];
  dom.win.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'onSelectionCleared') {
      assert.strictEqual(sel.selection, null, 'notify only AFTER local cleanup');
      assert.strictEqual(sel.dragAnchor, null);
      assert.strictEqual(sel.activeHandle, null);
      assert.strictEqual(sel.selectionHandles.start.style.display, 'none');
    }
    calls.push({ name, payload });
  };
  sel.beginRangeSelection(...glyphPoint(dom, 0));
  const before = sel.selection;
  assert.deepStrictEqual(calls.map((e) => e.name), ['onSelectionCleared', 'onSelectionDragStarted']);
  sel.clearSelectionOnViewportChange();
  assert.strictEqual(sel.selection, before, 'anchor owns viewport changes');
  assert.strictEqual(calls.length, 2);
  sel.endRangeSelection(...glyphPoint(dom, 0));
  assert.deepStrictEqual(calls.map((e) => e.name), ['onSelectionCleared', 'onSelectionDragStarted', 'onSelectionMenu']);
  sel.activeHandle = 'end';
  sel.clearSelectionOnViewportChange();
  assert.strictEqual(sel.selection, before, 'handle owns viewport changes');
  assert.strictEqual(calls.length, 3);
  sel.activeHandle = null;
  sel.clearSelectionOnViewportChange();
  assert.strictEqual(sel.selection, null);
  sel.clearSelectionOnViewportChange(); // empty JS state must still reconcile host UI
  assert.deepStrictEqual(calls.map((e) => e.name), [
    'onSelectionCleared', 'onSelectionDragStarted', 'onSelectionMenu', 'onSelectionCleared', 'onSelectionCleared',
  ]);
  delete dom.win.flutter_inappwebview;
  assert.doesNotThrow(() => sel.clearSelection());
  dom.win.flutter_inappwebview = { callHandler: null };
  assert.doesNotThrow(() => sel.clearSelection());
  return { order: calls.map((e) => e.name) };
});
scenario('26_handle_release_uses_last_coordinate', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  sel.beginRangeSelection(...glyphPoint(dom, 0));
  sel.endRangeSelection(...glyphPoint(dom, 0));
  const listeners = {};
  const grip = sel.selectionHandles.end;
  grip.addEventListener = (name, fn) => { listeners[name] = fn; };
  sel._wireHandle(grip, 'end');
  const event = (i) => {
    const [clientX, clientY] = glyphPoint(dom, i);
    const t = { clientX, clientY };
    return { touches: [t], changedTouches: [t], cancelable: true, preventDefault() {}, stopPropagation() {} };
  };
  listeners.touchstart(event(0));
  listeners.touchmove(event(2));
  listeners.touchend(event(6));
  assert.strictEqual(textOf(sel), CJK.slice(0, 7));
  assert.strictEqual(sel.activeHandle, null);
  return { text: textOf(sel) };
});
scenario('27_cancelled_drag_does_not_block_viewport_clear', () => {
  const dom = cjkDom();
  const sel = loadSelection(dom);
  const driver = gestureDriver(dom);
  driver.fire('touchstart', ...glyphPoint(dom, 0));
  driver.hold();
  assert.ok(sel.dragAnchor);
  driver.fire('touchcancel', ...glyphPoint(dom, 0));
  assert.strictEqual(sel.dragAnchor, null);
  sel.clearSelectionOnViewportChange();
  assert.strictEqual(sel.selection, null);
  return { cancelled: true };
});


// Actual DOM listeners + production ensure/position/highlight code. Geometry is
// deterministic; this does NOT model WebView compositor frames or prove clipping.
function liveDom(vertical, popover = true) {
  const glyphs = Array.from(CJK, (_, i) => vertical
    ? rect(240 - Math.floor(i / 6) * 40, 40 + (i % 6) * 24,
      264 - Math.floor(i / 6) * 40, 64 + (i % 6) * 24)
    : rect(40 + (i % 6) * 24, 40 + Math.floor(i / 6) * 40,
      64 + (i % 6) * 24, 64 + Math.floor(i / 6) * 40));
  return buildDocument({ vertical, popover, bodyRect: rect(0, 0, 400, 300), blocks: [
    { rect: rect(20, 20, 340, 240), textNodes: [{ text: CJK, rects: glyphs }] },
  ] });
}
// Rollback contract: bound edge hit targets, but do not relocate interior
// handles to free whitespace. Text-avoidance candidates were rejected by user.
function rectanglesOverlap(a, b) {
  return Math.min(a.right, b.right) > Math.max(a.left, b.left) &&
    Math.min(a.bottom, b.bottom) > Math.max(a.top, b.top);
}
function assertTouchBoxesClear(sel, width, height, context = '') {
  const boxes = ['start', 'end'].map(which => {
    const el = sel.selectionHandles[which], box = el.getBoundingClientRect();
    assert.strictEqual(el.style.display, 'block', context);
    assert.deepStrictEqual([box.width, box.height], [32, 32]);
    assert.ok(box.left >= 0 && box.top >= 0 && box.right <= width && box.bottom <= height,
      context + ': full touch box must stay inside viewport');
    return box;
  });
  assert.ok(!rectanglesOverlap(...boxes), context + ': two touch boxes must not overlap');
  return boxes;
}
function assertLiveHandles(sel, vertical, pair = sel.selectionHandles) {
  assert.strictEqual(sel.selectionHandles, pair, 'retain target identity');
  const eps = sel.selectionEndpoints(); assert.ok(eps);
  const start = eps.startNode.__rects[eps.startOffset], end = eps.endNode.__rects[eps.endOffset];
  const centers = vertical
    ? [[start.left + start.width / 2, start.top - 8], [end.left + end.width / 2, end.bottom + 8]]
    : [[start.left, start.bottom + 8], [end.right, end.bottom + 8]];
  [pair.start,pair.end].forEach((el,i) => {
    assert.strictEqual(el.style.display,'block','visible before release');
    assert.strictEqual(el.style.pointerEvents,'auto');
    assert.deepStrictEqual([parseFloat(el.style.left),parseFloat(el.style.top)], centers[i],
      'interior handles must stay anchored to current endpoint, not jump to blank space');
    assert.deepStrictEqual(el.__styleWrites.filter(w=>w.key==='display').map(w=>w.value),['block']);
    if(el.showPopover){assert.strictEqual(el.__popoverOpen,true);assert.strictEqual(el.__popoverShows,1);}
  });
  return centers;
}
function handleEvent(el, name, dom, i) {
  const [clientX, clientY] = glyphPoint(dom, i);
  const t = { clientX, clientY, identifier: 1 };
  let stopped = false, prevented = false;
  el.__listeners[name]({ touches: name === 'touchend' ? [] : [t], changedTouches: [t],
    cancelable: true, preventDefault() { prevented = true; }, stopPropagation() { stopped = true; } });
  return { stopped, prevented };
}
scenario('28_longpress_live_coordinates_each_move', () => {
  const frames = [];
  for (const vertical of [false, true]) for (const cssHighlights of [false, true]) {
    const dom = liveDom(vertical);
    dom.win.__fushiCssHighlightsSupported = cssHighlights;
    const sel = loadSelection(dom, true), calls = [];
    dom.win.flutter_inappwebview.callHandler = (name) => calls.push(name);
    const driver = gestureDriver(dom);
    driver.fire('touchstart', ...glyphPoint(dom, 0)); driver.hold();
    const pair = sel.selectionHandles;
    assert.ok(pair, 'longpress creates handles before the first move');
    let previous = assertLiveHandles(sel, vertical, pair);
    for (const i of [2, 5, 7, 9]) {
      driver.fire('touchmove', ...glyphPoint(dom, i));
      assert.strictEqual(textOf(sel), CJK.slice(0, i + 1));
      const current = assertLiveHandles(sel, vertical, pair);
      assert.notDeepStrictEqual(current[1], previous[1], 'end grip follows each changed text endpoint');
      previous = current;
      frames.push(current);
      assert.deepStrictEqual(calls, ['onSelectionCleared', 'onSelectionDragStarted']);
      assert.strictEqual(sel.highlightWrappers.length, 0, 'live fallback must not mutate source nodes');
    }
    driver.fire('touchend', ...glyphPoint(dom, 10));
    const released = assertLiveHandles(sel, vertical, pair);
    assert.notDeepStrictEqual(released[1], previous[1], 'release consumes its final text endpoint');
    assert.strictEqual(calls.at(-1), 'onSelectionMenu');
  }
  return { synchronousFrames: frames.length, frames };
});
scenario('29_handle_listener_live_coordinates_and_bridge', () => {
  const frames = [];
  for (const vertical of [false, true]) for (const which of ['start', 'end']) {
    const dom = liveDom(vertical), sel = loadSelection(dom, true), calls = [];
    dom.win.flutter_inappwebview.callHandler = (name) => calls.push(name);
    sel.beginRangeSelection(...glyphPoint(dom, 0));
    sel.updateRangeSelection(...glyphPoint(dom, 10));
    sel.endRangeSelection(...glyphPoint(dom, 10));
    const pair = sel.selectionHandles, grip = pair[which];
    calls.length = 0;
    assert.deepStrictEqual(handleEvent(grip, 'touchstart', dom, which === 'start' ? 0 : 10),
      { stopped: true, prevented: true });
    assert.deepStrictEqual(calls, ['onSelectionDragStarted'], 'hide old host menu at touchstart');
    let previous = assertLiveHandles(sel, vertical, pair);
    for (const i of which === 'start' ? [1, 2, 4] : [8, 6, 5]) {
      assert.deepStrictEqual(handleEvent(grip, 'touchmove', dom, i), { stopped: true, prevented: true });
      assert.strictEqual(sel.activeHandle, which);
      const current = assertLiveHandles(sel, vertical, pair);
      const moving = which === 'start' ? 0 : 1;
      assert.notDeepStrictEqual(current[moving], previous[moving], 'active grip follows each changed endpoint');
      previous = current;
      frames.push(current);
      assert.deepStrictEqual(calls, ['onSelectionDragStarted'], 'no menu during move');
    }
    handleEvent(grip, 'touchend', dom, which === 'start' ? 5 : 4);
    const released = assertLiveHandles(sel, vertical, pair);
    const moving = which === 'start' ? 0 : 1;
    assert.notDeepStrictEqual(released[moving], previous[moving], 'release consumes its final handle endpoint');
    assert.deepStrictEqual(calls, ['onSelectionDragStarted', 'onSelectionMenu']);
  }
  return { synchronousFrames: frames.length };
});
scenario('30_clear_then_late_end_does_not_revive_menu', () => {
  for (const kind of ['text', 'handle']) {
    const dom = liveDom(false), sel = loadSelection(dom, true), calls = [];
    dom.win.flutter_inappwebview.callHandler = (name) => calls.push(name);
    const driver = gestureDriver(dom);
    driver.fire('touchstart', ...glyphPoint(dom, 0)); driver.hold();
    const grip = sel.selectionHandles.end;
    if (kind === 'handle') {
      driver.fire('touchend', ...glyphPoint(dom, 0));
      handleEvent(grip, 'touchstart', dom, 0);
    }
    const unrelatedLookup = { ...sel.selection };
    sel.clearSelection(); calls.length = 0;
    sel.selection = unrelatedLookup; // lookup can establish a DIFFERENT selection
    if (kind === 'text') driver.fire('touchend', ...glyphPoint(dom, 4));
    else handleEvent(grip, 'touchend', dom, 4);
    assert.deepStrictEqual(calls, [], 'an ended session cannot confirm another selection');
    assert.strictEqual(sel.selection, unrelatedLookup);
    assert.strictEqual(sel.selectionHandlesRect(), null);
    assert.strictEqual(sel.endRangeSelection(...glyphPoint(dom, 4)), false);
  }
  return { sessions: 2 };
});
scenario('31_detached_dom_cancels_drag_and_late_end', () => {
  for (const kind of ['text', 'handle']) for (const moveFirst of [false, true]) {
    const dom = liveDom(false), sel = loadSelection(dom, true), calls = [];
    dom.win.flutter_inappwebview.callHandler = (name) => calls.push(name);
    sel.beginRangeSelection(...glyphPoint(dom, 0));
    const grip = sel.selectionHandles.end;
    if (kind === 'handle') {
      sel.endRangeSelection(...glyphPoint(dom, 0));
      handleEvent(grip, 'touchstart', dom, 0);
    }
    calls.length = 0;
    dom.blocks[0].el.isConnected = false; // VN / chapter source subtree removed
    if (kind === 'text') {
      if (moveFirst) sel.updateRangeSelection(...glyphPoint(dom, 3));
      assert.strictEqual(sel.endRangeSelection(...glyphPoint(dom, 4)), false);
    } else {
      if (moveFirst) handleEvent(grip, 'touchmove', dom, 3);
      handleEvent(grip, 'touchend', dom, 4);
    }
    assert.strictEqual(sel.selection, null);
    assert.strictEqual(sel.dragAnchor, null);
    assert.strictEqual(sel.activeHandle, null);
    assert.ok(!calls.includes('onSelectionMenu'));
    assert.strictEqual(grip.style.display, 'none');
    assert.strictEqual(grip.__popoverOpen, false);
  }
  return { cases: 4 };
});
scenario('32_begin_resolves_after_wrapper_normalize', () => {
  const dom = liveDom(false), sel = loadSelection(dom, true);
  const old = dom.textNodes[0], block = dom.blocks[0].el;
  // Run real clearHighlightWrappers: extraction/normalization detaches the hit
  // text and the hit API now resolves against the replacement merged text.
  const fresh = makeTextNode(old.textContent, old.__rects, block);
  fresh.__order = old.__order;
  const wrapper = { parentNode: block, firstChild: null };
  block.removeChild = (child) => assert.strictEqual(child, wrapper);
  block.normalize = () => {
    old.parentElement = null;
    block.childNodes = [fresh];
    dom.textNodes[0] = fresh;
    dom.blocks[0].textNodes[0] = fresh;
  };
  sel.highlightWrappers = [wrapper];
  assert.ok(sel.beginRangeSelection(...glyphPoint(dom, 1)));
  assert.strictEqual(sel.dragAnchor.node, fresh, 'pre-clear hit must never be retained');
  assert.strictEqual(sel.selection.ranges[0].node, fresh);
  sel.updateRangeSelection(...glyphPoint(dom, 4));
  assert.strictEqual(textOf(sel), CJK.slice(1, 5));
  assertLiveHandles(sel, false);
  return { oldDetached: !old.isConnected, text: textOf(sel) };
});
scenario('33_handles_rect_and_legacy_top_layer_contract', () => {
  const bounds = [];
  for (const vertical of [false, true]) for (const popover of [false, true]) {
    const dom = liveDom(vertical, popover), sel = loadSelection(dom, true), menus = [];
    dom.win.flutter_inappwebview.callHandler = (name, payload) => {
      if (name === 'onSelectionMenu') menus.push(JSON.parse(payload));
    };
    assert.strictEqual(sel.selectionHandlesRect(), null);
    sel.beginRangeSelection(...glyphPoint(dom, 0));
    sel.updateRangeSelection(...glyphPoint(dom, 8));
    sel.endRangeSelection(...glyphPoint(dom, 8));
    const pair = sel.selectionHandles;
    assertLiveHandles(sel, vertical, pair);
    const r = unionRects([pair.start.getBoundingClientRect(), pair.end.getBoundingClientRect()]);
    const expected = { x: r.left, y: r.top, width: r.width, height: r.height };
    assert.deepStrictEqual(sel.selectionHandlesRect(), expected);
    assert.deepStrictEqual(menus[0].handlesRect, expected);
    const first = dom.textNodes[0].__rects[0];
    assert.deepStrictEqual(sel.getSelectionRect(...glyphPoint(dom, 0)),
      { x: first.left, y: first.top, width: first.width, height: first.height }, 'lookup anchor remains a glyph');
    sel.clearSelection();
    assert.strictEqual(sel.selectionHandlesRect(), null);
    if (popover) assert.strictEqual(pair.start.__popoverOpen, false);
    bounds.push(expected);
  }
  return { bounds };
});
// Edge fixtures deliberately include one glyph only: moving the grips must not
// invent a larger selection to make space. Real compositor hit-tests are covered
// separately by the headless probe; here both actual listener targets are tested.
scenario('34_edge_touch_boxes_bounded_and_independently_grabbable', () => {
  let cases = 0;
  for (const vertical of [false, true]) for (const popover of [false, true]) {
    for (const size of [8, 24]) for (const [x, y] of [[0, 0], [400 - size, 0],
      [0, 300 - size], [400 - size, 300 - size]]) {
      const glyph = rect(x, y, x + size, y + size);
      const dom = buildDocument({ vertical, popover, bodyRect: rect(0, 0, 400, 300),
        blocks: [{ rect: glyph, textNodes: [{ text: '春', rects: [glyph] }] }] });
      const sel = loadSelection(dom, true);
      assert.ok(sel.beginRangeSelection(x + size / 2, y + size / 2));
      sel.endRangeSelection(x + size / 2, y + size / 2);
      const pair = sel.selectionHandles, before = sel.selection;
      const boxes = assertTouchBoxesClear(sel, 400, 300,
        `edge vertical=${vertical}, popover=${popover}, glyph=${JSON.stringify(glyph)}`);
      for (const r of boxes) {
        assert.deepStrictEqual([r.width, r.height], [32, 32], 'do not shrink the touch target');
        assert.ok(r.left >= 0 && r.top >= 0 && r.right <= 400 && r.bottom <= 300,
          `vertical=${vertical}, glyph=${JSON.stringify(glyph)}, box=${JSON.stringify(r)}`);
      }
      const [a, b] = boxes;
      assert.ok(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top,
        'clamping a single glyph must not stack the two touch boxes');
      assert.strictEqual(sel.selection, before, 'positioning must not replace the range');
      assert.strictEqual(textOf(sel), '春');
      for (const which of ['start', 'end']) {
        const el = pair[which], r = el.getBoundingClientRect();
        // Check either DOM stacking order: no other grip can cover this center.
        const cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        const other = pair[which === 'start' ? 'end' : 'start'].getBoundingClientRect();
        assert.ok(cx < other.left || cx > other.right || cy < other.top || cy > other.bottom);
        el.__listeners.touchstart({ cancelable: true, touches: [{ clientX: cx, clientY: cy }],
          preventDefault() {}, stopPropagation() {} });
        assert.strictEqual(sel.activeHandle, which);
        el.__listeners.touchcancel();
        assert.strictEqual(sel.selection, before, 'grabbing/cancelling does not expand a single glyph');
        assert.strictEqual(sel.selectionHandles, pair, 'retain live target identity');
        if (popover) assert.strictEqual(el.__popoverShows, 1);
      }
      cases++;
    }
  }
  return { cases };
});
scenario('35_offscreen_endpoints_are_not_clamped_into_view', () => {
  let cases = 0;
  for (const vertical of [false, true]) for (const which of ['start', 'end']) {
    for (const hidden of [rect(-24, 40, 0, 64), rect(400, 40, 424, 64),
      rect(40, -24, 64, 0), rect(40, 300, 64, 324), rect(0, 40, 19, 64)]) {
      const dom = liveDom(vertical), sel = loadSelection(dom, true);
      sel.beginRangeSelection(...glyphPoint(dom, 0));
      sel.updateRangeSelection(...glyphPoint(dom, 2));
      sel.endRangeSelection(...glyphPoint(dom, 2));
      const before = sel.selection, pair = sel.selectionHandles;
      // Last fixture is inside the viewport but outside the visible content box.
      dom.win.getComputedStyle = () => ({ paddingLeft: '20px' });
      dom.textNodes[0].__rects[which === 'start' ? 0 : 2] = hidden;
      sel.positionSelectionHandles();
      assert.strictEqual(pair.start.style.display, 'none');
      assert.strictEqual(pair.end.style.display, 'none');
      assert.strictEqual(sel.selectionHandlesRect(), null);
      assert.strictEqual(sel.selection, before, 'do not truncate or expand offscreen text');
      cases++;
    }
  }
  // A partly clipped glyph remains a real visible endpoint (same hit-test rule).
  const dom = buildDocument({ vertical: true, bodyRect: rect(0, 0, 400, 300), blocks: [
    { rect: rect(380, 0, 410, 24), textNodes: [{ text: '春', rects: [rect(380, -8, 410, 24)] }] },
  ] });
  const sel = loadSelection(dom, true);
  assert.ok(sel.beginRangeSelection(390, 8));
  assert.strictEqual(sel.selectionHandles.start.style.display, 'block');
  return { cases, partialGlyphVisible: true };
});
scenario('36_edge_small_viewport_has_explicit_geometry_limit', () => {
  for (const vertical of [false, true]) for (const [width, height, shown] of
    [[32, 96, true], [96, 32, true], [48, 48, false], [31, 96, false]]) {
    const glyph = rect(0, 0, 8, 8);
    const dom = buildDocument({ vertical, bodyRect: rect(0, 0, width, height), blocks: [
      { rect: glyph, textNodes: [{ text: '春', rects: [glyph] }] },
    ] });
    const sel = loadSelection(dom, true);
    assert.ok(sel.beginRangeSelection(4, 4));
    const bounds = sel.selectionHandlesRect();
    if (shown) {
      assert.ok(bounds && bounds.x >= 0 && bounds.y >= 0 &&
        bounds.x + bounds.width <= width && bounds.y + bounds.height <= height);
      const [a, b] = assertTouchBoxesClear(sel, width, height, 'small viewport');
      assert.ok(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top);
    } else assert.strictEqual(bounds, null, 'do not fake usable overlapping or shrunken targets');
    assert.strictEqual(textOf(sel), '春');
  }
  return { cases: 8 };
});
scenario('37_interior_handles_keep_endpoint_anchors', () => {
  let cases = 0;
  for (const vertical of [false,true]) for (const popover of [false,true]) {
    for (const end of [0,1,3,5,6,7,9,11]) {
      const dom=liveDom(vertical,popover), sel=loadSelection(dom,true);
      assert.ok(sel.beginRangeSelection(...glyphPoint(dom,0)));
      const pair=sel.selectionHandles;
      assertLiveHandles(sel,vertical,pair);
      sel.updateRangeSelection(...glyphPoint(dom,end));
      assertLiveHandles(sel,vertical,pair);
      sel.endRangeSelection(...glyphPoint(dom,end));
      assertLiveHandles(sel,vertical,pair);
      const before=sel.selection;
      sel.positionSelectionHandles();
      assert.strictEqual(sel.selection,before);
      assertLiveHandles(sel,vertical,pair);
      cases++;
    }
  }
  return {cases};
});
// ---------------------------------------------------------------- summary
const failures = results.filter((r) => !r.ok);
console.log(`passed ${results.length - failures.length} cases`);
if (failures.length) {
  for (const failure of failures) console.error(`FAILED ${failure.name}: ${failure.detail}`);
  process.exit(1);
}
if (!mutation) {
  for (const [name, [, , witness, diagnostic]] of Object.entries(mutations)) {
    const run = spawnSync(process.execPath, [__filename, `--mutant=${name}`], { encoding: 'utf8', timeout: 30000 });
    assert.ifError(run.error);
    assert.strictEqual(run.status, 1, `${name} must be killed, not survive or crash: ${run.stdout}\n${run.stderr}`);
    assert.ok(run.stdout.includes(`SCENARIO ${witness} :: FAILED`), `${name}: missing behavioral witness ${witness}\n${run.stdout}\n${run.stderr}`);
    if (diagnostic) {
      const failureLine = run.stdout.split('\n').find(line => line.startsWith(`SCENARIO ${witness} :: FAILED`));
      assert.ok(failureLine.includes(diagnostic), `${name}: wrong failure reason\n${failureLine}`);
    }
    assert.strictEqual((run.stdout.match(/^SCENARIO /gm) || []).length, 37,
      `${name}: every scenario must execute even after a witnessed failure`);
    assert.ok(run.stdout.includes('SCENARIO 37_interior_handles_keep_endpoint_anchors ::'), 'mutant must execute the full suite');
    console.log(`MUTATION ${name} :: KILLED (${witness})`);
  }
  console.log(`killed ${Object.keys(mutations).length} mutations`);
}
console.log('all assertions passed');
console.log('OK');
