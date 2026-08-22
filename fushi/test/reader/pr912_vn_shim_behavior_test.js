// PR#912 / BUG-1742·1743：VN host-compat shim 的行为级跑手（由
// pr912_vn_shim_behavior_test.dart 用 node 执行，argv[2] = payload.json）。
//
// 断言依赖的生产字面量（供变异实测对照）：
// - var charOffset = seg.entry.startChar + countChars(prefix);   （坐标换算）
// - CSS.highlights.set('fushi-search', new Highlight(range));     （搜索高亮）
// - await this.ensureReady();                （highlightSelectorCue 的就绪等待）
// - this.screenIndexForProgress(this.totalChapterChars           （restore 兜底）
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

// 抠出 host-compat shim 的 IIFE（生成物里 (function() { / })(); 各只有一处、都在行首）。
const shell = data.shell;
const startMarker = '\n(function() {\n  var vn = window.fushiReader;';
const endMarker = '\n})();';
const start = shell.indexOf(startMarker);
assert(start >= 0, 'host-compat shim IIFE not found in the generated VN shell');
const end = shell.indexOf(endMarker, start);
assert(end > start, 'host-compat shim IIFE has no terminator');
const shim = shell.slice(start + 1, end + endMarker.length);

// ── minimal DOM doubles ───────────────────────────────────────────────
function textNode(text) {
  return {nodeType: 3, textContent: text, childNodes: []};
}
function element(children, attrs) {
  const el = {
    nodeType: 1,
    childNodes: children || [],
    _attrs: attrs || {},
    classList: {
      _set: new Set(),
      add(c) { this._set.add(c); },
      remove(c) { this._set.delete(c); },
      contains(c) { return this._set.has(c); }
    },
    querySelector(sel) { return el._attrs[sel] || null; },
    querySelectorAll() { return []; }
  };
  return el;
}
function collectTextNodes(root) {
  const out = [];
  (function walk(n) {
    (n.childNodes || []).forEach(function(c) {
      if (c.nodeType === 3) out.push(c); else walk(c);
    });
  })(root);
  return out;
}
const highlightsSet = [];
const CSS = {
  highlights: {
    set(name, hl) { highlightsSet.push({name: name, highlight: hl}); },
    delete(name) { highlightsSet.push({name: name, highlight: null}); }
  }
};
function Highlight(range) { this.range = range; }
const NodeFilter = {SHOW_TEXT: 4};
const document = {
  createTreeWalker(root) {
    const nodes = collectTextNodes(root);
    let i = -1;
    return {nextNode() { i++; return i < nodes.length ? nodes[i] : null; }};
  },
  createRange() {
    return {
      setStart(n, o) { this.startContainer = n; this.startOffset = o; },
      setEnd(n, o) { this.endContainer = n; this.endOffset = o; }
    };
  },
  documentElement: {style: {setProperty() {}}},
  body: element([])
};
const window = {__fushiCssHighlightsSupported: true};

// ── VN 对象替身：只补 shim 依赖的协作者，shim 自己装的方法一律不预定义 ──
function countChars(t) { return String(t || '').replace(/\s+/g, '').length; }
function makeVn(options) {
  const opts = options || {};
  const log = {render: [], charOffsets: [], progressFallback: [], restored: 0};
  const vn = {
    log: log,
    screens: opts.screens || [],
    currentScreenIndex: opts.currentScreenIndex || 0,
    revealComplete: true,
    totalChapterChars: opts.totalChapterChars || 0,
    screen: opts.screen || null,
    sourceRoot: opts.sourceRoot || null,
    contentStream: opts.contentStream || null,
    ensureReady: opts.ensureReady || function() { return Promise.resolve(); },
    screenContainsCharOffset(s, t) { return t >= s.start && t < s.end; },
    screenEndCharCount(s) { return s.end; },
    screenIndexForProgress(p) { log.progressFallback.push(p); return 0; },
    renderScreen(i) { log.render.push(i); vn.currentScreenIndex = i; },
    calculateProgress() { return 0.5; },
    completeCurrentReveal() { vn.revealComplete = true; },
    notifyRestoreComplete() { log.restored++; }
  };
  window.fushiReader = vn;
  new Function('window', 'document', 'CSS', 'Highlight', 'NodeFilter', shim)(
    window, document, CSS, Highlight, NodeFilter);
  const real = vn.screenIndexForCharOffset;
  assert(typeof real === 'function',
    'shim did not install screenIndexForCharOffset');
  vn.screenIndexForCharOffset = function(o) {
    log.charOffsets.push(o);
    return real.call(this, o);
  };
  return vn;
}

// 章节文本：两个 entry，raw 坐标与 countChars 坐标故意不一致（含空白）。
//   entry0 raw 长 5 / countChars 3，startChar 0
//   entry1 raw 长 6 / countChars 5，startChar 3
// 拼接后命中串的 raw 下标 = 8，正确的 char 坐标 = 3 + 2 = 5。
function chapterStream() {
  return {
    countChars: countChars,
    textEntries: [
      {text: 'あ い う', startChar: 0},
      {text: 'えお かきく', startChar: 3}
    ]
  };
}

// ── ① 坐标换算：交给屏索引的必须是 countChars 坐标 5，而不是原始下标 8 ──
{
  const left = textNode('あ い う');
  const right = textNode('えお かきく');
  const screenDom = element([left, right]);
  const vn = makeVn({
    contentStream: chapterStream(),
    // 屏边界故意卡在 5 与 8 之间：算错就会翻到另一屏。
    screens: [{start: 0, end: 6}, {start: 6, end: 9}],
    currentScreenIndex: 1,
    screen: screenDom
  });
  highlightsSet.length = 0;
  const progress = vn.scrollToSearchMatch('かきく', 0);
  assert(vn.log.charOffsets.length === 1,
    'scrollToSearchMatch must ask the shared helper exactly once, got ' +
    JSON.stringify(vn.log.charOffsets));
  assert(vn.log.charOffsets[0] === 5,
    'the raw match index (8) must be converted through countChars to 5, got ' +
    vn.log.charOffsets[0]);
  assert(JSON.stringify(vn.log.render) === '[0]',
    'the countChars offset 5 lives on screen 0, got renders ' +
    JSON.stringify(vn.log.render));
  assert(progress === 0.5, 'a landed search must return the new progress');

  // ── ② 搜索命中必须建高亮，且 Range 落在正确的屏内文本节点与偏移上 ──
  assert(highlightsSet.length === 1,
    'a landed search must create exactly one highlight, got ' +
    highlightsSet.length);
  assert(highlightsSet[0].name === 'fushi-search',
    'the highlight name must match the CSS highlight rule, got ' +
    highlightsSet[0].name);
  const range = highlightsSet[0].highlight.range;
  assert(range.startContainer === right && range.startOffset === 3,
    'the range must start inside the second text node at offset 3, got ' +
    JSON.stringify([range.startOffset, range.endOffset]));
  assert(range.endContainer === right && range.endOffset === 6,
    'the range must end at offset 6 of the same node, got ' +
    JSON.stringify([range.startOffset, range.endOffset]));
}

// ── 搜不到就什么都不做（不许瞎翻屏）──
{
  const vn = makeVn({
    contentStream: chapterStream(),
    screens: [{start: 0, end: 6}, {start: 6, end: 9}],
    currentScreenIndex: 1,
    screen: element([textNode('あ い うえお かきく')])
  });
  highlightsSet.length = 0;
  assert(vn.scrollToSearchMatch('さしす', 0) === null, 'a miss must return null');
  assert(vn.log.render.length === 0, 'a miss must not turn a screen');
  assert(highlightsSet.length === 0, 'a miss must not create a highlight');
}

// ── ④ restoreToCharOffset 走共享 helper，且保留 restore 独有的进度兜底 ──
function runRestoreChecks() {
  const vn = makeVn({
    screens: [{start: 0, end: 6}, {start: 6, end: 12}],
    currentScreenIndex: 0,
    totalChapterChars: 12
  });
  return vn.restoreToCharOffset(7).then(function() {
    assert(JSON.stringify(vn.log.charOffsets) === '[7]',
      'restore must go through the shared helper, got ' +
      JSON.stringify(vn.log.charOffsets));
    assert(JSON.stringify(vn.log.render) === '[1]',
      'char offset 7 restores to screen 1, got ' +
      JSON.stringify(vn.log.render));
    assert(vn.log.progressFallback.length === 0,
      'a resolvable offset must not touch the progress fallback');
    assert(vn.log.restored === 1, 'restore must notify completion');

    const far = makeVn({
      screens: [{start: 0, end: 6}, {start: 6, end: 12}],
      currentScreenIndex: 0,
      totalChapterChars: 12
    });
    return far.restoreToCharOffset(999).then(function() {
      assert(far.log.charOffsets[0] === 999, 'helper is asked first');
      assert(far.log.progressFallback.length === 1,
        'an unresolvable offset must fall back to the progress ratio ' +
        '(restore-only behaviour that must survive the helper extraction)');
      assert(far.log.progressFallback[0] === 999 / 12,
        'the fallback ratio must be charOffset / totalChapterChars, got ' +
        far.log.progressFallback[0]);
      assert(far.log.restored === 1, 'the fallback path still notifies');
    });
  });
}

// ── ③ highlightSelectorCue 必须 await ensureReady()（章节加载期到达的 cue 不丢）──
function runCueReadyChecks() {
  const cueNode = element([]);
  const source = element([], {'[data-cue-id="7"]': cueNode});
  let readyCalls = 0;
  const vn = makeVn({
    screens: [],                       // 就绪之前一屏都还没切出来
    currentScreenIndex: 0,
    sourceRoot: source,
    screen: element([]),
    contentStream: {
      countChars: countChars,
      textEntries: [],
      sourcePositionForNode(node) {
        return node === cueNode ? {startChar: 7} : null;
      }
    },
    ensureReady() {
      readyCalls++;
      const self = this;
      return Promise.resolve().then(function() {
        self.screens = [{start: 0, end: 6}, {start: 6, end: 12}];
      });
    }
  });
  const returned = vn.highlightSelectorCue('[data-cue-id="7"]', true);
  assert(returned && typeof returned.then === 'function',
    'highlightSelectorCue must be async so it can await ensureReady()');
  return returned.then(function(progress) {
    assert(readyCalls === 1, 'ensureReady must be awaited exactly once');
    assert(JSON.stringify(vn.log.render) === '[1]',
      'a cue arriving during chapter load must still land on its screen, ' +
      'got renders ' + JSON.stringify(vn.log.render));
    assert(progress === 0.5, 'a cue that turned a screen returns progress');
  });
}

runCueReadyChecks()
  .then(runRestoreChecks)
  .then(function() { process.stdout.write('OK'); })
  .catch(function(e) {
    console.error((e && e.stack) || String(e));
    process.exit(1);
  });
