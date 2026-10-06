'use strict';
// Ported from the independent pagination-review probe. Read the worktree, never
// git-show a pinned revision. Only geometry/rendering unrelated to lifecycle is
// stubbed: shared methods, scroll coordinates, capture/target listeners, paging,
// VN replacement/reveal and selection cleanup execute the production functions.
// Run from any cwd: node <path>/reader_selection_viewport_behavior_test.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sources = Object.fromEntries(Object.entries({
  pagination: 'reader_pagination_scripts.dart',
  selection: 'reader_selection_scripts.dart',
  vn: 'reader_visual_novel_scripts.dart',
}).map(([key, file]) => [key, fs.readFileSync(
  path.resolve(__dirname, '../../lib/src/reader', file), 'utf8').replace(/\r/g, '')]));

function method(source, name, occurrence = 0) {
  const marker = `  ${name}: function(`;
  let start = -1;
  for (let i = 0; i <= occurrence; i++) start = source.indexOf(marker, start + 1);
  assert(start >= 0, `missing production method ${name} #${occurrence}`);
  const end = source.indexOf('\n  }', start);
  assert(end > start, `missing end of ${name}`);
  return source.slice(start + `  ${name}: `.length, end + 4);
}
function iife(marker) {
  const start = sources.pagination.indexOf(marker);
  assert(start >= 0, `missing production installer ${marker}`);
  const end = sources.pagination.indexOf('\n})();', start);
  assert(end > start);
  return sources.pagination.slice(start, end + '\n})();'.length);
}
const intent = iife('(function() {\n  if (window.__fushiUserScrollIntentInstalled)');
const motion = iife('(function() {\n  window.fushiReader.__selectionViewportScroll');

class Element {
  constructor(name) {
    this.name = name; this.parentNode = null; this.children = [];
    this.style = {}; this.listeners = {}; this.scrollTop = this.scrollLeft = 0;
    this.nodeType = name === 'text' ? 3 : 1;
  }
  addEventListener(type, fn, opts = {}) {
    (this.listeners[type] ||= []).push({fn, capture: opts === true || !!opts.capture});
  }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    this.children.push(child); child.parentNode = this; return child;
  }
  removeChild(child) {
    assert.equal(child.parentNode, this);
    this.children.splice(this.children.indexOf(child), 1); child.parentNode = null;
  }
  insertBefore(child, before) {
    if (child.parentNode) child.parentNode.removeChild(child);
    this.children.splice(this.children.indexOf(before), 0, child); child.parentNode = this;
  }
  contains(node) { return node === this || this.children.some(child => child.contains(node)); }
  get firstChild() { return this.children[0] || null; }
  get isConnected() { return this.name === 'document' || !!this.parentNode?.isConnected; }
  replaceChildren() { for (const c of [...this.children]) this.removeChild(c); }
  normalize() {}
}

function fixture({continuous = true, css = true, writingMode = 'horizontal-tb', initial = 0} = {}) {
  const doc = new Element('document');
  const html = doc.appendChild(new Element('html'));
  const body = html.appendChild(new Element('body'));
  Object.assign(doc, {documentElement: html, scrollingElement: html, body,
    createElement: name => new Element(name)});
  const native = {rangeCount: 1, removeAllRanges() { this.rangeCount = 0; }};
  const highlights = new Map();
  const stats = {clear: 0, moves: 0, menus: 0, dragNotifications: [], notifications: [], clearWhileConnected: []};
  const vertical = writingMode !== 'horizontal-tb';
  html.scrollTop = vertical ? 0 : initial;
  const window = {scrollX: vertical ? initial : 0, scrollY: 0, innerWidth: 100, innerHeight: 100,
    __fushiCssHighlightsSupported: css, getSelection: () => native,
    getComputedStyle: () => ({writingMode}),
    scrollBy({top = 0, left = 0}) {
      html.scrollTop = Math.max(0, Math.min(300, html.scrollTop + top));
      window.scrollX = writingMode === 'vertical-rl'
        ? Math.max(-300, Math.min(0, window.scrollX + left))
        : Math.max(0, Math.min(300, window.scrollX + left));
    },
    flutter_inappwebview: {callHandler(name) {
      if (name === 'onSelectionDragStarted') { stats.dragNotifications.push(name); return; }
      assert.equal(name, 'onSelectionCleared'); stats.notifications.push(name);
      assert.equal(selection.selection, null, 'notify only after clearing JS state');
      assert.equal(native.rangeCount, 0);
      assert.equal(end.style.display, 'none');
    }},
  };
  const frames = [], timers = [];
  const sandbox = vm.createContext({window, document: doc, CSS: {highlights}, Node: {TEXT_NODE: 3}, console, Date,
    requestAnimationFrame: callback => frames.push(callback), setTimeout: callback => timers.push(callback)});
  const fn = (kind, name, n = 0) => vm.runInContext(`(${method(sources[kind], name, n)})`, sandbox);  // NOSONAR: harness 在本地 Node 沙箱里执行从 Dart 源文件抽出的生产 JS，输入来自仓库自身、无用户可控数据（S1523 误报）
  const reader = window.fushiReader = {isVertical: () => vertical};
  for (const name of ['clearImageLateAnchor', '_setRestoreCharAnchor', '_isContinuousShell',
    'noteUserScroll', '_clearSelectionOnViewportChange', '_readContinuousScroll',
    '_onContinuousViewportScroll',
    // 上游 2026-10-05 起 paginate 会调几何重锚收口；漏掉它 harness 会在第一次翻页就
    // TypeError（this._settleGeometryReanchor is not a function）。
    '_settleGeometryReanchor', '_reanchorFrame']) reader[name] = fn('pagination', name);
  if (continuous) reader.scrollToChapterEnd = () => {};
  const start = html.appendChild(new Element('start-grip'));
  const end = html.appendChild(new Element('end-grip'));
  const selection = window.fushiSelection = {
    dragAnchor: null, activeHandle: null, selectionHandles: {start, end}, highlightWrappers: [],
    clearSelectionRubyHighlights() {}, moveSelectionHandle() { stats.moves++; },
    showSelectionHandles() {}, positionSelectionHandles() {}, updateRangeSelection() {},
    fireSelectionMenu() { stats.menus++; },
  };
  for (const name of ['hideSelectionHandles', 'clearHighlightWrappers',
    'clearSelectionOnViewportChange', 'endRangeSelection', 'liveSelectionPoint',
    'selectionEndpoints', 'liveDragAnchor', 'notifySelectionDragStarted']) selection[name] = fn('selection', name);
  const clear = fn('selection', 'clearSelection');
  selection.clearSelection = function() {
    stats.clear++;
    stats.clearWhileConnected.push(this.selection?.ranges[0].node.isConnected ?? null);
    return clear.call(this);
  };
  function select(parent = body) {
    const text = new Element('text'); text.textContent = 'selected';
    if (css) { parent.appendChild(text); highlights.set('fushi-selection', text); }
    else {
      const wrapper = parent.appendChild(new Element('highlight'));
      wrapper.appendChild(text); selection.highlightWrappers.push(wrapper);
    }
    selection.selection = {text: 'selected', ranges: [{node: text, start: 0, end: 8}]};
    native.rangeCount = 1; start.style.display = end.style.display = 'block';
    return text;
  }
  select();
  fn('selection', '_wireHandle').call(selection, start, 'start');
  fn('selection', '_wireHandle').call(selection, end, 'end');
  function install() {
    vm.runInContext(intent, sandbox);  // NOSONAR: harness 在本地 Node 沙箱里执行从 Dart 源文件抽出的生产 JS，输入来自仓库自身、无用户可控数据（S1523 误报）
    if (window.fushiReader._isContinuousShell()) vm.runInContext(motion, sandbox);  // NOSONAR: harness 在本地 Node 沙箱里执行从 Dart 源文件抽出的生产 JS，输入来自仓库自身、无用户可控数据（S1523 误报）
  }
  install();
  function dispatch(type, target = doc, fields = {}) {
    const event = Object.assign({type, target, cancelable: true, bubbles: type !== 'scroll',
      touches: [{clientX: 40, clientY: 40}], changedTouches: [{clientX: 40, clientY: 40}],
      defaultPrevented: false, stopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; }}, fields);
    const chain = []; for (let n = target; n; n = n.parentNode) chain.push(n);
    const visit = (node, capture) => {
      for (const l of node.listeners[type] || []) if (l.capture === capture) l.fn(event);
    };
    for (const node of [...chain].reverse()) { visit(node, true); if (event.stopped) return event; }
    for (const node of chain) {
      visit(node, false); if (event.stopped || !event.bubbles) break;
    }
    return event;
  }
  function move(position) {
    if (vertical) window.scrollX = position; else html.scrollTop = position;
    dispatch('scroll');
  }
  function paged(position = 0, pageSize = 100) {
    delete reader.scrollToChapterEnd;
    body.scrollLeft = body.scrollTop = position;
    const context = {vertical, scrollEl: body, physicalMaxScroll: 200, pageSize};
    Object.assign(reader, {getScrollContext: () => context,
      paginationMetrics: {minScroll: 0, maxScroll: 200}, pageStepPosition: x => x});
    for (const name of ['getPagePosition', 'lockRootViewport', 'assignPagePosition',
      'setPagePosition', 'paginate']) reader[name] = fn('pagination', name);
    return context;
  }
  function beginDrag(guard) {
    if (guard === 'dragAnchor') {
      const range = selection.selection.ranges[0];
      selection.dragAnchor = {node: range.node, offset: range.start,
        endNode: range.node, endOffset: range.end - 1, startX: 40, startY: 40, moved: false};
      assert.equal(selection.liveDragAnchor(), true);
    } else {
      dispatch('touchstart', end);
      assert.equal(selection.activeHandle, 'end');
      assert.deepEqual(stats.dragNotifications, ['onSelectionDragStarted']);
    }
  }
  function vn(index = 0, fallback = false) {
    delete reader.scrollToChapterEnd;
    const screen = body.appendChild(new Element('vn-screen'));
    if (fallback) screen.replaceChildren = undefined;
    // Move the selected range (including its fallback wrapper) onto the old screen.
    const text = selection.selection.ranges[0].node;
    screen.appendChild(css ? text : text.parentNode);
    const remove = screen.removeChild;
    screen.removeChild = function(child) {
      if (child.contains(text)) {
        // This runs at the destructive DOM boundary, not at entry to clear().
        // Unwrapping the fallback highlight leaves text connected until here.
        assert.equal(text.isConnected, true);
        cleared({selection, native, start, end, highlights, stats});
      }
      return remove.call(this, child);
    };
    Object.assign(reader, {screen, screens: [0, 1].map(i => ({render: () => new Element('screen-' + i)})),
      currentScreenIndex: index, revealComplete: true, revealSpeed: 0, nativeSelectionActive: false,
      clearRevealTimer() {}, clearCurrentSentenceAudioScreenTargets() {}, centerScreenInk() {},
      setupReaderImages() {}, buildNodeOffsets() {}, applyCurrentScreenHighlights() {},
      refreshSentenceAudioCuePresentation() {}});
    for (const name of ['paginate', 'renderScreen', 'completeCurrentReveal']) reader[name] = fn('vn', name);
    return text;
  }
  return {window, doc, html, body, native, highlights, stats, reader, selection, start, end,
    fn, sandbox, select, install, dispatch, move, paged, vn, beginDrag, frames, timers};
}
function preserved(f) {
  assert(f.selection.selection); assert.equal(f.native.rangeCount, 1);
  assert.equal(f.end.style.display, 'block'); assert.equal(f.stats.clear, 0);
  assert.deepEqual(f.stats.notifications, []);
}
function cleared(f) {
  assert.equal(f.selection.selection, null); assert.equal(f.native.rangeCount, 0);
  assert.equal(f.selection.dragAnchor, null); assert.equal(f.selection.activeHandle, null);
  assert.equal(f.end.style.display, 'none'); assert.equal(f.start.style.display, 'none');
  assert.equal(f.highlights.has('fushi-selection'), false);
  assert.equal(f.selection.highlightWrappers.length, 0);
  assert.equal(f.stats.clear, 1);
  assert.deepEqual(f.stats.notifications, ['onSelectionCleared']);
}
let count = 0;
function test(name, run) {
  try { run(); } catch (error) { console.error(`not ok - ${name}`); throw error; }
  console.log(`ok ${++count} - ${name}`);
}

for (const css of [true, false]) {
  const kind = css ? 'CSS highlights' : 'wrapper fallback';
  for (const grip of ['start', 'end']) test(`${kind}: capture preserves active ${grip} grip until target`, () => {
    const f = fixture({css});
    f.beginDrag('dragAnchor');
    assert.equal(f.selection.endRangeSelection(20, 20), true);
    assert.equal(f.selection.dragAnchor, null);
    f.dispatch('touchstart', f[grip]);
    const event = f.dispatch('touchmove', f[grip]);
    preserved(f); assert.equal(f.stats.moves, 1);
    assert.equal(f.selection.activeHandle, grip); assert.equal(event.defaultPrevented, true);
    assert.equal(f.html.scrollTop, 0);
    f.dispatch('touchend', f[grip]);
    preserved(f); assert.equal(f.stats.moves, 2); assert.equal(f.selection.activeHandle, null);
    assert.equal(f.stats.menus, 2);
  });
  for (const writingMode of ['horizontal-tb', 'vertical-rl', 'vertical-lr']) {
    test(`${kind}/${writingMode}: only actual root-axis scroll clears`, () => {
      const f = fixture({css, writingMode});
      f.dispatch('scroll'); f.body.scrollTop = 30; f.dispatch('scroll', f.body);
      preserved(f);
      f.move(writingMode === 'vertical-rl' ? -0.5 : 0.5);
      cleared(f); assert.deepEqual(f.stats.clearWhileConnected, [true]);
      f.dispatch('scroll'); cleared(f);
    });
    for (const direction of ['forward', 'backward']) {
      test(`${kind}/${writingMode}: continuous ${direction} moves once, pending scroll cannot clear a new selection`, () => {
        const initial = writingMode === 'vertical-rl' ? -100 : 100;
        const f = fixture({css, writingMode, initial});
        f.reader.paginate = f.fn('pagination', 'paginate', 1);
        assert.equal(f.reader.paginate(direction), 'scrolled'); cleared(f);
        assert.notEqual(f.reader._readContinuousScroll(), initial);
        f.select(); f.dispatch('scroll');
        assert(f.selection.selection); assert.equal(f.stats.clear, 1);
      });
      test(`${kind}/${writingMode}: paged ${direction} clears after moving`, () => {
        const f = fixture({css, continuous: false, writingMode});
        const ctx = f.paged(direction === 'forward' ? 0 : 100);
        const before = f.reader.getPagePosition(ctx);
        assert.equal(f.reader.paginate(direction), 'scrolled');
        assert.notEqual(f.reader.getPagePosition(ctx), before); cleared(f);
      });
    }
  }
  for (const fallback of [false, true]) for (const direction of ['forward', 'backward']) {
    test(`${kind}: VN ${direction} clears before detach (removeChild=${fallback})`, () => {
      const f = fixture({css, continuous: false});
      const old = f.vn(direction === 'forward' ? 0 : 1, fallback);
      assert.equal(f.reader.paginate(direction), 'scrolled'); cleared(f);
      assert.equal(old.isConnected, false); assert.deepEqual(f.stats.clearWhileConnected, [true]);
      assert.equal(f.reader.currentScreenIndex, direction === 'forward' ? 1 : 0);
    });
  }
  for (const index of [0, 1, 999]) test(`${kind}: independent VN renderScreen(${index}) clears even same-index rebuild`, () => {
    const f = fixture({css, continuous: false}); const old = f.vn();
    f.reader.renderScreen(index, true); cleared(f);
    assert.equal(old.isConnected, false); assert.deepEqual(f.stats.clearWhileConnected, [true]);
  });
}

for (const [type, fields] of [['wheel', {deltaY: 1}], ['wheel', {deltaY: 0}],
  ['touchmove', {}], ['pointerdown', {}], ['keydown', {key: 'ArrowDown'}],
  ['keydown', {key: 'PageDown'}], ['keydown', {key: 'End'}]]) {
  test(`${type}/${JSON.stringify(fields)} intent with no motion preserves selection and retires anchors`, () => {
    const f = fixture({initial: 300});
    f.reader.__imgReanchorProgress = 0.3; f.reader._setRestoreCharAnchor(123, 124);
    f.dispatch(type, f.html, fields); f.dispatch('scroll'); preserved(f);
    assert.equal(f.reader.__imgReanchorProgress, null);
    assert.equal(f.reader.__restoreCharOffset, null); assert.equal(f.html.scrollTop, 300);
  });
}
test('forwarded popup scroll: note alone preserves; actual scroll clears', () => {
  const f = fixture(); f.reader.noteUserScroll(); preserved(f);
  f.window.scrollBy({top: 60}); f.dispatch('scroll'); cleared(f);
});
for (const guard of ['dragAnchor', 'activeHandle']) test(`${guard}: motion during drag is protected, not replayed after release`, () => {
  const f = fixture(); f.beginDrag(guard);
  f.move(60); preserved(f);
  f.selection[guard] = null; f.dispatch('scroll'); preserved(f);
  f.move(61); cleared(f);
});
for (const writingMode of ['horizontal-tb', 'vertical-rl', 'vertical-lr']) {
  for (const direction of ['forward', 'backward']) test(`${writingMode}/${direction}: continuous and paged limits preserve`, () => {
    const end = writingMode === 'vertical-rl' ? -300 : 300;
    const f = fixture({writingMode, initial: direction === 'forward' ? end : 0});
    f.reader.paginate = f.fn('pagination', 'paginate', 1);
    assert.equal(f.reader.paginate(direction), 'limit'); f.dispatch('scroll'); preserved(f);
    f.paged(direction === 'forward' ? 200 : 0);
    assert.equal(f.reader.paginate(direction), 'limit'); preserved(f);
  });
}
test('invalid paged metrics preserve selection', () => {
  const f = fixture({continuous: false}); f.paged(0, 0);
  assert.equal(f.reader.paginate('forward'), 'limit'); preserved(f);
});
for (const direction of ['forward', 'backward']) test(`VN ${direction} limit preserves connected range`, () => {
  const f = fixture({continuous: false}); const old = f.vn(direction === 'forward' ? 1 : 0);
  assert.equal(f.reader.paginate(direction), 'limit'); preserved(f); assert(old.isConnected);
});
test('VN text reveal keeps selected node and does not clear selection', () => {
  const f = fixture({continuous: false}); const old = f.vn();
  const hidden = f.reader.screen.appendChild(new Element('reveal-hidden'));
  f.reader.revealComplete = false;
  f.reader.revealSegments = [{visible: old, hidden, chars: [...'selected text']}];
  assert.equal(f.reader.paginate('forward'), 'revealed'); preserved(f);
  assert(old.isConnected); assert.equal(old.textContent, 'selected text');
  assert.equal(f.reader.revealComplete, true); assert.equal(hidden.parentNode, null);
});
test('empty VN and native-selection limit do not clear or detach', () => {
  const f = fixture({continuous: false}); const old = f.vn();
  f.reader.nativeSelectionActive = true;
  assert.equal(f.reader.paginate('forward'), 'limit'); preserved(f);
  f.reader.nativeSelectionActive = false; f.reader.screens = [];
  assert.equal(f.reader.paginate('backward'), 'limit');
  f.reader.renderScreen(0, true); preserved(f); assert(old.isConnected);
});
test('native-only desktop selection clears on actual scroll', () => {
  const f = fixture(); f.selection.selection = null;
  f.move(25); cleared(f);
});
test('install is idempotent and snapshots a reinstalled continuous shell', () => {
  const f = fixture({initial: 80}); f.install();
  assert.equal(f.doc.listeners.scroll.length, 1);
  assert.equal(f.doc.listeners.touchmove.length, 1);
  f.move(90); cleared(f); f.select();
  const replacement = {...f.reader}; delete replacement.__selectionViewportScroll;
  f.window.fushiReader = replacement;
  f.html.scrollTop = 200; f.install(); f.dispatch('scroll');
  assert(f.selection.selection); assert.equal(f.stats.clear, 1);
  f.move(201); assert.equal(f.stats.clear, 2);
});
test('old continuous listeners ignore a new paged or VN reader', () => {
  const f = fixture(); f.paged(); f.move(80); f.dispatch('wheel'); preserved(f);
  f.vn(); f.move(90); f.dispatch('touchmove', f.end); preserved(f);
});
// Explicit navigation and destructive rebuilds invalidate the OLD session even
// during a drag. Only genuine continuous scrolling retains that session.
// Do not stub the selection delegate: these assertions must exercise full clear.
function lateReleaseCannotRevive(f) {
  const menus = f.stats.menus;
  const moves = f.stats.moves;
  assert.equal(f.selection.endRangeSelection(40, 40), false);
  f.dispatch('touchmove', f.end); f.dispatch('touchend', f.end);
  cleared(f);
  assert.equal(f.stats.menus, menus); assert.equal(f.stats.moves, moves);
}
for (const css of [true, false]) for (const guard of ['dragAnchor', 'activeHandle']) {
  const label = `css=${css}/${guard}`;
  for (const writingMode of ['horizontal-tb', 'vertical-rl', 'vertical-lr']) {
    test(`${label}/${writingMode}: continuous scroll retains the live drag`, () => {
      const f = fixture({css, writingMode}); f.beginDrag(guard);
      const session = f.selection[guard];
      f.move(writingMode === 'vertical-rl' ? -60 : 60); preserved(f);
      assert.equal(f.selection[guard], session);
      f.selection[guard] = null; f.dispatch('scroll'); preserved(f);
      f.move(writingMode === 'vertical-rl' ? -61 : 61); cleared(f);
    });
    for (const continuous of [true, false]) for (const direction of ['forward', 'backward']) {
      test(`${label}/${writingMode}/continuous=${continuous}: explicit ${direction} ends drag`, () => {
        const f = fixture({css, continuous, writingMode,
          initial: continuous ? (writingMode === 'vertical-rl' ? -100 : 100) : 0});
        if (continuous) f.reader.paginate = f.fn('pagination', 'paginate', 1);
        else f.paged(100);
        f.beginDrag(guard);
        assert.equal(f.reader.paginate(direction), 'scrolled'); cleared(f);
        assert.deepEqual(f.stats.clearWhileConnected, [true]);
        lateReleaseCannotRevive(f);
        f.select(); f.dispatch('scroll');
        assert(f.selection.selection); assert.equal(f.stats.clear, 1);
      });
      test(`${label}/${writingMode}/continuous=${continuous}: ${direction} limit retains drag`, () => {
        const f = fixture({css, continuous, writingMode,
          initial: continuous && direction === 'forward' ? (writingMode === 'vertical-rl' ? -300 : 300) : 0});
        if (continuous) f.reader.paginate = f.fn('pagination', 'paginate', 1);
        else f.paged(direction === 'forward' ? 200 : 0);
        f.beginDrag(guard); const session = f.selection[guard];
        assert.equal(f.reader.paginate(direction), 'limit'); f.dispatch('scroll'); preserved(f);
        assert.equal(f.selection[guard], session);
      });
    }
    test(`${label}/${writingMode}: programmatic setPagePosition clears only actual movement`, () => {
      const f = fixture({css, continuous: false, writingMode}); const ctx = f.paged(200);
      f.beginDrag(guard); const session = f.selection[guard];
      assert.equal(f.reader.setPagePosition(ctx, 999), 200); preserved(f);
      assert.equal(f.selection[guard], session);
      assert.equal(f.reader.setPagePosition(ctx, 100), 100); cleared(f);
      assert.equal(f.reader.getPagePosition(ctx), 100);
      lateReleaseCannotRevive(f);
      f.select(); f.reader.setPagePosition(ctx, 100);
      assert(f.selection.selection); assert.equal(f.stats.clear, 1);
    });
  }
  for (const fallback of [false, true]) {
    for (const direction of ['forward', 'backward']) test(`${label}/fallback=${fallback}: VN ${direction} ends drag before detach`, () => {
      const f = fixture({css, continuous: false}); const old = f.vn(direction === 'forward' ? 0 : 1, fallback);
      f.beginDrag(guard);
      assert.equal(f.reader.paginate(direction), 'scrolled'); cleared(f);
      assert.equal(old.isConnected, false); assert.deepEqual(f.stats.clearWhileConnected, [true]);
      lateReleaseCannotRevive(f);
    });
    for (const index of [0, 1, 999]) test(`${label}/fallback=${fallback}: VN renderScreen(${index}) invalidates drag before detach`, () => {
      const f = fixture({css, continuous: false}); const old = f.vn(0, fallback);
      f.beginDrag(guard); f.reader.renderScreen(index, true); cleared(f);
      assert.equal(old.isConnected, false); assert.deepEqual(f.stats.clearWhileConnected, [true]);
      lateReleaseCannotRevive(f);
    });
  }
  for (const direction of ['forward', 'backward']) test(`${label}: VN ${direction} limit preserves drag`, () => {
    const f = fixture({css, continuous: false}); const old = f.vn(direction === 'forward' ? 1 : 0);
    f.beginDrag(guard); const session = f.selection[guard];
    assert.equal(f.reader.paginate(direction), 'limit'); preserved(f);
    assert.equal(f.selection[guard], session); assert(old.isConnected);
  });
  test(`${label}: VN reveal preserves drag and connected range`, () => {
    const f = fixture({css, continuous: false}); const old = f.vn();
    const hidden = f.reader.screen.appendChild(new Element('reveal-hidden'));
    f.reader.revealComplete = false;
    f.reader.revealSegments = [{visible: old, hidden, chars: [...'selected text']}];
    f.beginDrag(guard); const session = f.selection[guard];
    assert.equal(f.reader.paginate('forward'), 'revealed'); preserved(f);
    assert.equal(f.selection[guard], session); assert(old.isConnected);
    assert.equal(f.reader.revealComplete, true); assert.equal(hidden.parentNode, null);
  });
}
// Exercise the real callers as well as the setter: a fix restricted to paginate
// must not leave progress/character/fragment/audio/settle paths leaking selection.
for (const writingMode of ['horizontal-tb', 'vertical-rl', 'vertical-lr']) {
  for (const guard of ['dragAnchor', 'activeHandle']) {
    for (const entry of ['progress', 'character', 'fragment', 'range', 'settle']) {
      test(`${writingMode}/${guard}: programmatic ${entry} uses forced invalidation`, () => {
        const f = fixture({continuous: false, writingMode}); const ctx = f.paged(100);
        for (const name of ['contentFirstPageScroll', 'contentLastPageScroll', 'alignToPage',
          'scrollToProgressPaged', 'scrollToCharOffset', 'alignToFragmentTarget',
          '_alignRangeToPage', '_settleAndNotify']) f.reader[name] = f.fn('pagination', name);
        // Geometry only: the target is on the preceding page; all navigation,
        // landing, drag validity and cleanup are the current production methods.
        f.reader.getRect = () => ({top: -100, left: -100});
        f.doc.getElementById = id => id === 'target' ? f.selection.selection.ranges[0].node : null;
        f.reader.registerSnapScroll = () => {};
        f.reader.notifyRestoreComplete = () => {};
        f.beginDrag(guard);
        if (entry === 'progress') f.reader.scrollToProgressPaged(ctx, 0);
        if (entry === 'character') f.reader.scrollToCharOffset(0);
        if (entry === 'fragment') assert.equal(f.reader.alignToFragmentTarget('target'), true);
        if (entry === 'range') assert.equal(f.reader._alignRangeToPage({}), true);
        if (entry === 'settle') {
          f.reader._settleAndNotify(ctx, 0); preserved(f);
          assert.equal(f.timers.length, 1); f.timers.shift()();
        }
        assert.equal(f.reader.getPagePosition(ctx), 0); cleared(f);
        lateReleaseCannotRevive(f);
        f.select();
        if (entry === 'range') {
          assert.equal(f.frames.length, 1); f.frames.shift()();
        }
        f.reader._settleAndNotify(ctx, 0); f.timers.shift()();
        assert(f.selection.selection); assert.equal(f.stats.clear, 1);
      });
    }
  }
}
console.log(`all assertions passed (${count} scenarios)`);
