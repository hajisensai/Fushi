// BUG-2261：VN host-compat shim 的样式两阶段重锚行为级跑手（由
// vn_style_reanchor_behavior_test.dart 用 node 执行，argv[2] = payload.json）。
//
// 断言依赖的生产字面量（供变异实测对照）：
// - if (styleEl) styleEl.textContent = css;                （begin 同步换 CSS）
// - this._styleReanchorOffset = charOffset;                 （begin 暂存锚）
// - this.refitScreensToCurrentViewport(off);                （commit 按锚重切屏）
// - var index = this.screenIndexForCharOffset(anchorCharOffset === undefined ? -1 : anchorCharOffset);
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

const shell = data.shell;
const startMarker = '\n(function() {\n  var vn = window.fushiReader;';
const endMarker = '\n})();';
const start = shell.indexOf(startMarker);
assert(start >= 0, 'host-compat shim IIFE not found in the generated VN shell');
const end = shell.indexOf(endMarker, start);
assert(end > start, 'host-compat shim IIFE has no terminator');
const shim = shell.slice(start + 1, end + endMarker.length);

const document = {
  documentElement: {style: {setProperty() {}}},
  body: {nodeType: 1, childNodes: []}
};
const window = {};

// VN 对象替身：只补 shim 依赖的协作者。屏表用 {start,end} 表示可匹配字符区间；
// fitScreensToViewport 的替身按 opts.refit 返回「新 CSS 下」的新屏表。
function makeVn(opts) {
  const log = {render: [], refits: 0, imageVars: 0, anchors: 0, progressFallback: []};
  const vn = {
    log: log,
    screens: opts.screens,
    baseScreens: null,
    currentScreenIndex: opts.currentScreenIndex || 0,
    totalChapterChars: opts.totalChapterChars || 0,
    screenStartCharCount(s) { return s.start; },
    screenEndCharCount(s) { return s.end; },
    screenContainsCharOffset(s, t) { return t >= s.start && t < s.end; },
    calculateProgress() { return opts.progress === undefined ? 0.5 : opts.progress; },
    applyImageMaxVars() { log.imageVars++; },
    assignScreenProgressAnchors() { log.anchors++; },
    fitScreensToViewport(screens) { log.refits++; return opts.refit ? opts.refit(screens) : screens; },
    mergeSentenceAudioCrossScreenScreens(s) { return s; },
    screenIndexForProgress(p) { log.progressFallback.push(p); return 0; },
    renderScreen(i) { log.render.push(i); vn.currentScreenIndex = i; }
  };
  window.fushiReader = vn;
  new Function('window', 'document', shim)(window, document);
  assert(typeof vn.beginStyleReanchor === 'function',
    'shim must install beginStyleReanchor');
  assert(typeof vn.commitStyleReanchor === 'function',
    'shim must install commitStyleReanchor');
  return vn;
}

// ── ① begin：同步换 CSS + 返回当前屏首字符偏移；commit：按新屏表落到同一偏移 ──
{
  // 旧 CSS 下三屏 [0,10) [10,20) [20,30)，用户在第 2 屏（首字符 10）。
  // 新 CSS（字号变大）下每屏只装 6 字：偏移 10 落到新第 1 屏 [6,12)。
  const vn = makeVn({
    screens: [{start: 0, end: 10}, {start: 10, end: 20}, {start: 20, end: 30}],
    currentScreenIndex: 1,
    totalChapterChars: 30,
    refit() {
      return [{start: 0, end: 6}, {start: 6, end: 12}, {start: 12, end: 18},
        {start: 18, end: 24}, {start: 24, end: 30}];
    }
  });
  const styleEl = {textContent: 'old'};
  const returned = vn.beginStyleReanchor(styleEl, 'body{font-size:2em}');
  assert(styleEl.textContent === 'body{font-size:2em}',
    'begin must swap the CSS synchronously, got ' + styleEl.textContent);
  assert(returned === 10, 'begin must return the current screen start offset (10), got ' + returned);
  assert(vn.log.refits === 0, 'begin must not recut screens (layout has not settled yet)');
  assert(vn.log.render.length === 0, 'begin must not turn a screen');

  const committed = vn.commitStyleReanchor();
  assert(committed === true, 'commit with a stored anchor must return true');
  assert(vn.log.refits === 1, 'commit must recut screens exactly once');
  assert(vn.log.imageVars === 1 && vn.log.anchors === 1,
    'commit must go through the shared refit primitive (image vars + progress anchors)');
  assert(JSON.stringify(vn.log.render) === '[1]',
    'offset 10 lives on new screen 1 ([6,12)), got renders ' + JSON.stringify(vn.log.render));
  assert(vn.log.progressFallback.length === 0,
    'a resolvable anchor must not touch the progress fallback');
  assert(vn.commitStyleReanchor() === false,
    'a second commit without a new begin must be a no-op (anchor consumed)');
  assert(vn.log.refits === 1, 'the no-op commit must not recut again');
}

// ── ② 章节还没切出屏（screens 空）：CSS 仍要换，但不暂存锚、commit 不动 ──
{
  const vn = makeVn({screens: [], currentScreenIndex: 0});
  const styleEl = {textContent: 'old'};
  const returned = vn.beginStyleReanchor(styleEl, 'new');
  assert(styleEl.textContent === 'new',
    'CSS must be swapped even before the first screen exists (never drop CSS)');
  assert(returned === -1, 'no screen → no anchor → -1, got ' + returned);
  assert(vn.commitStyleReanchor() === false, 'no anchor → commit is a no-op');
  assert(vn.log.refits === 0 && vn.log.render.length === 0,
    'no anchor → nothing recut, nothing rendered');
}

// ── ③ 锚在新屏表里查无（重切后屏表变短）→ 退回进度比例选屏，不许什么都不渲染 ──
{
  const vn = makeVn({
    screens: [{start: 0, end: 10}, {start: 10, end: 20}],
    currentScreenIndex: 1,
    totalChapterChars: 20,
    progress: 0.75,
    refit() { return [{start: 0, end: 5}]; }
  });
  vn.beginStyleReanchor({textContent: ''}, 'css');
  assert(vn.commitStyleReanchor() === true, 'commit still lands somewhere');
  assert(vn.log.progressFallback.length === 1 && vn.log.progressFallback[0] === 0.75,
    'unresolvable anchor must fall back to the pre-recut progress ratio, got ' +
    JSON.stringify(vn.log.progressFallback));
  assert(JSON.stringify(vn.log.render) === '[0]', 'fallback must render a screen');
}

// ── ④ 无参 refitScreensToCurrentViewport（updatePageSize / setChromeInsets 路径）行为不变 ──
{
  const vn = makeVn({
    screens: [{start: 0, end: 10}, {start: 10, end: 20}],
    currentScreenIndex: 1,
    totalChapterChars: 20,
    progress: 0.4
  });
  vn.refitScreensToCurrentViewport();
  assert(vn.log.progressFallback.length === 1 && vn.log.progressFallback[0] === 0.4,
    'argument-less refit must keep anchoring by progress (BUG-1688 behaviour)');
}

process.stdout.write('OK');
