// Algorithm-level behavior regression, NOT a browser/Android reproduction.
//
// The Dart driver generates an ordinary installer function from the original
// paginatedShellSource() and kStudyUnitJs, then passes it to this exported runner.
// This harness installs the entire production shell factory, including the
// separately assigned updatePageSize. No production reader method is replaced.
// Only its browser boundary is modeled: ideal vertical multicol glyph geometry,
// Range fragments, caret hit-testing, CSS properties, and a deterministic frame /
// timer queue. It does not model Android lifecycle, native persistence, actual
// font shaping, ruby, image loading, or DPR rounding. A dedicated race case explicitly
// injects a transient zero scroll reading at the modeled DOM boundary.
//
// Synthetic 0 -> 24 -> 0 geometry changes exercise character-capacity changes.
// Separately settled frames and coalesced changes are both tested; no device
// logs or device-specific timings are required by the fixture. Assertions inspect
// final visible text and public pageInfo(), not private implementation fields.
//
// Run through geometry_reanchor_roundtrip_behavior_test.dart.
const assert = require('node:assert/strict');
const WIDTH = 400;
const HEIGHT = 824;
const GAP = 22;
const TOTAL_CHARS = 40000;
const NODE_CHARS = 200;

function createModel(installProductionShell, initialTop = 0,
  { trailingMediaPages = 0, hidden = false } = {}) {
  const frames = [];
  const timers = [];
  const events = [];
  const properties = new Map([
    ['--chrome-top-inset', initialTop + 'px'],
    ['--chrome-bottom-inset', '0px'],
    ['--reader-viewport-height', HEIGHT + 'px'],
    ['--page-width', WIDTH + 'px'],
  ]);
  let font = 20;
  let caretReads = 0;
  const style = {
    setProperty(name, value) { properties.set(name, String(value)); },
    getPropertyValue(name) { return properties.get(name) || ''; },
  };
  const number = name => parseFloat(style.getPropertyValue(name));
  const top = () => number('--chrome-top-inset');
  const bottom = () => number('--chrome-bottom-inset');
  const height = () => number('--reader-viewport-height');
  const width = () => number('--page-width');
  const columnHeight = () => height() - top() - bottom();
  const rows = () => Math.floor(columnHeight() / font);
  const lines = () => Math.floor(width() / (font * 2));
  const capacity = () => rows() * lines();
  const pitch = () => columnHeight() + GAP;
  const parent = { closest() { return null; } };
  // Multiple nodes let the real pagination/progress builder exercise its normal
  // node-based progress stops instead of a one-node all-or-nothing progress.
  const nodes = Array.from({ length: TOTAL_CHARS / NODE_CHARS }, (_, i) => ({
    nodeType: 3, textContent: '永'.repeat(NODE_CHARS), length: NODE_CHARS,
    parentElement: parent, parentNode: parent, modelStart: i * NODE_CHARS,
  }));
  const body = {
    scrollTop: 0, scrollLeft: 0,
    get clientWidth() { return width(); },
    get clientHeight() { return height(); },
    get scrollHeight() { return (Math.ceil(TOTAL_CHARS / capacity()) + trailingMediaPages) * pitch(); },
    getBoundingClientRect() {
      return { left: 0, top: 0, right: width(), bottom: height(), width: width(), height: height() };
    },
    addEventListener() {},
  };
  const root = { style, scrollTop: 0, scrollLeft: 0 };
  function glyph(index) {
    const page = Math.floor(index / capacity());
    const local = index % capacity();
    const y = top() + page * pitch() + (local % rows()) * font - body.scrollTop;
    const x = width() - (Math.floor(local / rows()) + 1) * font * 2;
    return { top: y, bottom: y + font, left: x, right: x + font, width: font, height: font };
  }
  function fragments(start, end) {
    const rects = [];
    // One rect per contiguous run on a vertical text line. All rectangles,
    // including off-screen ones, derive from the same glyph grid as hit-tests.
    for (let i = start; i < Math.max(start + 1, end);) {
      const rect = glyph(i);
      const length = Math.min(rows() - i % rows(), Math.max(start + 1, end) - i);
      rect.height = length * font;
      rect.bottom = rect.top + rect.height;
      rects.push(rect);
      i += length;
    }
    return rects;
  }
  function range() {
    return {
      startContainer: nodes[0], endContainer: nodes[0], startOffset: 0, endOffset: 0,
      setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
      setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
      collapse() { this.endContainer = this.startContainer; this.endOffset = this.startOffset; },
      selectNodeContents(node) {
        if (node.nodeType === 3) {
          this.setStart(node, 0);
          this.setEnd(node, node.length);
        } else {
          this.setStart(nodes[Math.floor(node.modelStart / NODE_CHARS)], node.modelStart % NODE_CHARS);
          const end = node.modelEnd;
          this.setEnd(nodes[Math.floor((end - 1) / NODE_CHARS)], (end - 1) % NODE_CHARS + 1);
        }
      },
      getClientRects() {
        return fragments(this.startContainer.modelStart + this.startOffset,
          this.endContainer.modelStart + this.endOffset);
      },
      getBoundingClientRect() {
        const rects = this.getClientRects();
        const left = Math.min(...rects.map(r => r.left));
        const right = Math.max(...rects.map(r => r.right));
        const top = Math.min(...rects.map(r => r.top));
        const bottom = Math.max(...rects.map(r => r.bottom));
        return { left, right, top, bottom, width: right - left, height: bottom - top };
      },
      cloneRange() { return Object.assign(range(), this); },
    };
  }
  function element(start, end = start + 20) {
    const classes = new Set();
    return {
      nodeType: 1, modelStart: start, modelEnd: end, style: {},
      closest() { return null; },
      classList: { add(c) { classes.add(c); }, remove(c) { classes.delete(c); }, contains(c) { return classes.has(c); } },
      getClientRects() { return fragments(start, end); },
      getBoundingClientRect() { const r = range(); r.selectNodeContents(this); return r.getBoundingClientRect(); },
    };
  }
  // Optional already-laid-out trailing illustrations. Their page rectangles
  // are synthetic; these cases exercise textless-anchor semantics, not image
  // decoding, lazy loading, or real browser fragmentation.
  const media = Array.from({ length: trailingMediaPages }, (_, i) => ({
    nodeType: 1,
    getBoundingClientRect() {
      const y = top() + (Math.ceil(TOTAL_CHARS / capacity()) + i) * pitch() - body.scrollTop;
      return { top: y, bottom: y + columnHeight(), left: 0, right: width(),
        width: width(), height: columnHeight() };
    },
    getClientRects() { return [this.getBoundingClientRect()]; },
  }));
  const targets = new Map();
  const document = {
    body, documentElement: root, hidden, readyState: 'loading', createRange: range,
    createTreeWalker() { let i = 0; return { nextNode() { return nodes[i++] || null; } }; },
    caretRangeFromPoint(x, y) {
      caretReads++;
      const absoluteY = body.scrollTop + y - top();
      const page = Math.max(0, Math.floor(absoluteY / pitch()));
      if (media.length && page >= Math.ceil(TOTAL_CHARS / capacity())) {
        return { startContainer: media[Math.min(page - Math.ceil(TOTAL_CHARS / capacity()), media.length - 1)], startOffset: 0 };
      }
      const row = Math.max(0, Math.min(rows() - 1, Math.floor((absoluteY - page * pitch()) / font)));
      const line = Math.max(0, Math.min(lines() - 1, Math.floor((width() - x) / (font * 2))));
      const index = Math.min(TOTAL_CHARS - 1, page * capacity() + line * rows() + row);
      const r = range();
      r.setStart(nodes[Math.floor(index / NODE_CHARS)], index % NODE_CHARS);
      r.collapse(true);
      return r;
    },
    getElementById(id) { return targets.get(id) || null; },
    getElementsByName() { return []; },
    querySelectorAll(selector) { return selector === 'img, svg, image, video, canvas' ? media : []; },
    fonts: { ready: Promise.resolve() },
  };
  function getComputedStyle() {
    return {
      writingMode: 'vertical-rl', columnWidth: String(columnHeight()),
      columnGap: String(GAP), columnCount: '1', fontSize: String(font),
      paddingTop: String(top()), paddingBottom: String(bottom()), paddingLeft: '0', paddingRight: '0',
    };
  }
  const requestAnimationFrame = fn => frames.push(fn);
  const setTimeout = fn => timers.push(fn);
  const window = {
    __fushiShells: {}, innerWidth: WIDTH, innerHeight: HEIGHT, scrollX: 0, scrollY: 0,
    CSS: {}, getComputedStyle, requestAnimationFrame, setTimeout,
    addEventListener() {}, scrollTo() {},
    // Host margin application is the only external setup callback. This model
    // has zero reader margins, so there is no margin CSS to recompute.
    __fushiApplyReaderMargins() {},
    flutter_inappwebview: { callHandler(name) { events.push(name); return Promise.resolve(); } },
  };
  installProductionShell(window, document, getComputedStyle, { TEXT_NODE: 3 },
    { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 },
    requestAnimationFrame, setTimeout, {}, function Highlight() {});
  window.__fushiShells.paginated({ perfTraceEnabled: false });
  const reader = window.fushiReader;
  // DOM setup, not initialize(): startup image loading and native restore are
  // outside this harness. Everything exercised below is the production method.
  reader.viewportHeight = HEIGHT;
  reader.pageHeight = HEIGHT + GAP;
  reader.pageWidth = WIDTH;
  reader.didInitialize = true;
  reader.buildNodeOffsets();
  reader._resetImageMaxVars();
  reader.setPagePosition(reader.getScrollContext(), 20 * pitch());

  function flush(afterCallback) {
    let count = 0;
    while (frames.length || timers.length) {
      assert.ok(++count < 100, 'modeled callbacks must settle');
      while (frames.length) { frames.shift()(); if (afterCallback) afterCallback(); }
      while (timers.length) { timers.shift()(); if (afterCallback) afterCallback(); }
    }
    assert.notEqual(reader.pageInfo(), null, 'reader must expose a settled page');
  }
  function snapshot() {
    const context = reader.getScrollContext();
    return {
      first: reader.getFirstVisibleCharOffset(),
      page: reader.pageInfo().currentPage,
      scroll: reader.getPagePosition(context), pitch: context.pageSize,
      capacity: capacity(), top: top(), bottom: bottom(), height: height(),
    };
  }
  function inset(t, b = 0) { reader.setChromeInsets(t, b); flush(); return snapshot(); }
  function resize(h) { reader.updatePageSize(WIDTH, h); flush(); return snapshot(); }
  return {
    reader, frames, timers, events, snapshot, flush, inset, resize, capacity, glyph,
    resetDomScroll() { body.scrollTop = 0; },
    get caretReads() { return caretReads; },
    element, targets,
    styleElement: { set textContent(css) {
      const match = /font-size:\s*(\d+(?:\.\d+)?)px/.exec(css);
      assert.ok(match, 'modeled stylesheet requires an explicit font-size');
      font = Number(match[1]);
    } },
  };
}

const cases = [];
async function test(name, body) {
  try { await body(); cases.push({ name, pass: true }); }
  catch (error) { cases.push({ name, pass: false, error: error.message }); }
}
function samePlace(actual, expected, message) {
  assert.deepEqual({ first: actual.first, page: actual.page },
    { first: expected.first, page: expected.page }, message);
}

async function runCases(installProductionShell) {
  const model = createModel.bind(null, installProductionShell);
  await test('unchanged inset and viewport size do not reanchor', () => {
    const m = model(24);
    const before = m.snapshot();
    const reads = m.caretReads;
    m.reader.setChromeInsets(24, 0);
    m.reader.updatePageSize(WIDTH, HEIGHT);
    assert.equal(m.caretReads, reads, 'unchanged geometry must not sample an anchor');
    assert.equal(m.frames.length, 0);
    assert.equal(m.events.length, 0);
    assert.deepEqual(m.snapshot(), before);
  });
  await test('coalesced 0 -> 24 -> 0 before the first frame', () => {
    const m = model(); const before = m.snapshot();
    m.reader.setChromeInsets(24, 0);
    m.reader.setChromeInsets(0, 0);
    m.flush();
    assert.deepEqual(m.snapshot(), before);
  });
  await test('same pitch with top/bottom padding redistributed', () => {
    const m = model(24); const before = m.snapshot();
    m.inset(0, 24); m.inset(24, 0);
    assert.deepEqual(m.snapshot(), before);
  });
  await test('changed pitch with unchanged text capacity', () => {
    const m = model(24); const before = m.snapshot();
    const temporary = m.inset(20);
    assert.notEqual(temporary.pitch, before.pitch);
    assert.equal(temporary.capacity, before.capacity);
    m.inset(24);
    assert.deepEqual(m.snapshot(), before);
  });
  for (const initialTop of [0, 24]) {
    await test(`three settled ${initialTop} -> ${24 - initialTop} -> ${initialTop} cycles`, () => {
      const m = model(initialTop); const before = m.snapshot();
      const history = [before];
      for (let cycle = 0; cycle < 3; cycle++) {
        history.push(m.inset(24 - initialTop));
        assert.notEqual(history.at(-1).capacity, before.capacity,
          '24px change must cross a glyph-row boundary in this regression');
        history.push(m.inset(initialTop));
      }
      for (let i = 2; i < history.length; i += 2) {
        samePlace(history[i], before, 'settled geometry round trip loses content: ' + JSON.stringify(history));
      }
    });
  }
  for (const initialTop of [0, 24]) {
    await test(`hidden document: three settled ${initialTop} -> ${24 - initialTop} -> ${initialTop} cycles`, () => {
      const m = model(initialTop, { hidden: true });
      const before = m.snapshot();
      for (let cycle = 0; cycle < 3; cycle++) {
        m.reader.setChromeInsets(24 - initialTop, 0);
        assert.equal(m.frames.length, 0, 'hidden geometry must not wait for a frozen animation frame');
        assert.ok(m.timers.length > 0, 'the production hidden-document timer path must run');
        assert.equal(m.reader.pageInfo(), null, 'geometry remains pending until its timer runs');
        m.flush();
        m.inset(initialTop);
        samePlace(m.snapshot(), before, 'hidden timer-settled round trip must preserve the reading position');
      }
    });
  }
  for (const order of ['inset first', 'height first', 'coalesced']) {
    await test(`height/inset round trip: ${order}`, () => {
      const m = model(); const before = m.snapshot();
      if (order === 'inset first') {
        m.inset(24); m.resize(800); m.inset(0); m.resize(HEIGHT);
      } else if (order === 'height first') {
        m.resize(800); m.inset(24); m.resize(HEIGHT); m.inset(0);
      } else {
        m.reader.setChromeInsets(24, 0); m.reader.updatePageSize(WIDTH, 800); m.flush();
        m.reader.updatePageSize(WIDTH, HEIGHT); m.reader.setChromeInsets(0, 0); m.flush();
      }
      samePlace(m.snapshot(), before, 'height and inset changes must share a semantic anchor');
    });
  }
  const navigations = {
    'paginate forward': async m => {
      assert.equal(m.reader.paginate('forward'), 'scrolled');
    },
    'precise restore': async m => { await m.reader.restoreToCharOffset(12000); },
    'progress restore': async m => { await m.reader.restoreProgress(0.3); },
    'audio cue reveal': async m => {
      const wrapper = m.element(12000);
      // Cue segmentation/wrapping is outside this geometry test. The actual
      // highlighter -> revealElement -> scrollToRange chain runs unmodified.
      m.reader.cueWrappers.set('test-cue', [wrapper]);
      m.reader.highlightSentenceAudioCue('test-cue', true);
      assert.equal(wrapper.classList.contains('fushi-sentence-audio-active'), true);
    },
    'fragment jump': async m => {
      m.targets.set('chapter-heading', m.element(12000));
      assert.equal(await m.reader.jumpToFragment('chapter-heading'), true);
    },
  };
  for (const [name, navigate] of Object.entries(navigations)) {
    for (const pending of [false, true]) {
      await test(`${name} supersedes a ${pending ? 'pending' : 'settled'} geometry anchor`, async () => {
        const m = model();
        m.reader.setChromeInsets(24, 0);
        if (!pending) m.flush();
        await navigate(m);
        // pageInfo deliberately returns null during reanchor, so observe the
        // actual position through public geometry methods before flushing.
        const context = m.reader.getScrollContext();
        const destinationPage = name === 'paginate forward' ? 21 : Math.floor(12000 / m.capacity());
        const wanted = { first: destinationPage * m.capacity(), page: destinationPage + 1 };
        const checkPosition = () => samePlace({
          first: m.reader.getFirstVisibleCharOffset(),
          page: Math.round(m.reader.getPagePosition(context) / context.pageSize) + 1,
        }, wanted, 'each queued callback must preserve the explicit navigation');
        checkPosition();
        m.flush(checkPosition);
        samePlace(m.snapshot(), wanted, 'old callback must not undo explicit navigation');
        for (let cycle = 0; cycle < 3; cycle++) { m.inset(0); m.inset(24); }
        samePlace(m.snapshot(), wanted, 'later geometry must preserve the newly navigated position');
      });
    }
  }
  for (const [name, navigate] of Object.entries(navigations)) {
    if (name === 'paginate forward') continue;
    await test(`late-image reapply of ${name} supersedes pending geometry`, async () => {
      const m = model();
      await navigate(m);
      m.flush();
      m.reader.setChromeInsets(24, 0);
      assert.equal(m.reader.pageInfo(), null, 'fixture must have a pending geometry callback');
      // No image decode is simulated here. Invoke its actual production
      // reapply entry point, using the anchor registered by real navigation.
      assert.equal(m.reader.reapplyImageLateAnchor(), true);
      const context = m.reader.getScrollContext();
      const destinationPage = Math.floor(12000 / m.capacity());
      const wanted = { first: destinationPage * m.capacity(), page: destinationPage + 1 };
      const checkPosition = () => samePlace({
        first: m.reader.getFirstVisibleCharOffset(),
        page: Math.round(m.reader.getPagePosition(context) / context.pageSize) + 1,
      }, wanted, 'pending geometry must not overwrite the re-applied semantic target');
      checkPosition();
      m.flush(checkPosition);
      samePlace(m.snapshot(), wanted, 'the late-image target must remain the final visible page');
    });
  }
  await test('late-image reapply without an anchor leaves pending geometry intact', () => {
    const m = model();
    m.reader.setChromeInsets(24, 0);
    const queued = m.frames.length;
    assert.ok(queued > 0);
    assert.equal(m.reader.reapplyImageLateAnchor(), false);
    assert.equal(m.frames.length, queued);
    assert.equal(m.reader.pageInfo(), null, 'absent late-image target must not cancel the geometry owner');
    m.flush();
    samePlace(m.snapshot(), { first: 20 * m.capacity(), page: 21 },
      'the still-owned geometry callback must finish normally');
  });
  for (const direction of ['forward', 'backward']) {
    await test(`pending geometry with transient zero DOM scroll then paginate ${direction}`, () => {
      const m = model();
      m.reader.setChromeInsets(24, 0);
      m.resetDomScroll();
      assert.equal(m.reader.paginate(direction), 'scrolled');
      const wantedPage = direction === 'forward' ? 21 : 19;
      m.flush();
      samePlace(m.snapshot(), { first: wantedPage * m.capacity(), page: wantedPage + 1 },
        'relative navigation must settle the old anchor before using transient scroll');
    });
  }
  await test('navigation plus a new geometry request before an older callback settles', async () => {
    const m = model();
    m.reader.setChromeInsets(24, 0);
    await m.reader.restoreToCharOffset(12000);
    m.flush();
    const wanted = m.snapshot();
    m.reader.setChromeInsets(0, 0);
    assert.equal(m.reader.paginate('forward'), 'scrolled');
    const context = m.reader.getScrollContext();
    const newFirst = m.reader.getFirstVisibleCharOffset();
    const newPage = Math.round(m.reader.getPagePosition(context) / context.pageSize) + 1;
    assert.ok(newFirst > wanted.first, 'navigation must actually advance');
    m.reader.setChromeInsets(24, 0);
    m.flush();
    m.inset(0);
    samePlace(m.snapshot(), { first: newFirst, page: newPage },
      'stale frame must not consume or overwrite the newer geometry operation');
  });
  await test('trailing illustration endpoint survives height change and transient zero scroll', async () => {
    const m = model(0, { trailingMediaPages: 3 });
    await m.reader.restoreProgress(0.99);
    m.flush();
    const before = m.snapshot();
    assert.equal(before.first, TOTAL_CHARS, 'page after all text must expose the text-end sentinel');
    assert.equal(m.reader.isAtEnd(), true);
    m.reader.updatePageSize(WIDTH, 800);
    m.resetDomScroll();
    m.flush();
    assert.equal(m.reader.isAtEnd(), true, 'a textless terminal anchor must follow the true content end');
    assert.equal(m.snapshot().first, TOTAL_CHARS);
    m.resize(HEIGHT);
    samePlace(m.snapshot(), before, 'restoring geometry must preserve the trailing illustration endpoint');
  });
  await test('intermediate trailing illustration preserves its logical page', async () => {
    const m = model(0, { trailingMediaPages: 3 });
    await m.reader.restoreProgress(0.99);
    m.flush();
    assert.equal(m.reader.paginate('backward'), 'scrolled');
    const before = m.snapshot();
    assert.equal(before.first, TOTAL_CHARS);
    assert.equal(m.reader.isAtEnd(), false, 'fixture must start on an intermediate textless page');
    m.reader.updatePageSize(WIDTH, 800);
    m.resetDomScroll();
    m.flush();
    assert.equal(m.snapshot().page, before.page, 'unresolvable text-end anchor needs its logical-page fallback');
    m.resize(HEIGHT);
    samePlace(m.snapshot(), before, 'logical-page fallback must round-trip without jumping to the last page');
  });
  await test('BUG-2205: increasing capacity must not skip the original anchor', () => {
    const m = model(24);
    const before = m.snapshot();
    // First create a retained geometry anchor, then perform the real style
    // reanchor sequence. Its hint must not pin a later page past the old text.
    m.inset(0); m.inset(24);
    const anchor = m.reader.beginStyleReanchor(m.styleElement, 'body { font-size: 19px; }');
    assert.equal(m.reader.commitStyleReanchor(), true);
    m.flush();
    const after = m.snapshot();
    assert.ok(after.capacity > before.capacity);
    assert.ok(after.first <= anchor,
      `BUG-2205: first char ${after.first} must not pass anchor ${anchor}`);
    assert.ok(anchor < after.first + after.capacity, 'original anchor must remain on the visible page');
  });
  await test('style change retires the earlier geometry anchor', () => {
    const m = model(24);
    m.inset(0); m.inset(24);
    m.reader.beginStyleReanchor(m.styleElement, 'body { font-size: 19px; }');
    assert.equal(m.reader.commitStyleReanchor(), true);
    m.flush();
    const after = m.snapshot();
    m.inset(0); m.inset(24);
    samePlace(m.snapshot(), after, 'subsequent geometry must not resurrect a pre-style anchor');
  });
  console.log(JSON.stringify({
    kind: 'modeled ideal DOM; NOT a browser or Android reproduction', cases,
  }, null, 2));
  const failures = cases.filter(c => !c.pass);
  assert.equal(failures.length, 0,
    failures.length + ' geometry regression case(s) failed: ' + failures.map(c => c.name).join('; '));
  console.log(`all assertions passed (${cases.length} cases)`);
}
module.exports = runCases;
