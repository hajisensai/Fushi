// 墨水屏「每 N 页全刷」（拍板台 oF0jVdOTIE）连续模式计数的行为测试。
//
// 回归背景：连续 shell 的 paginate（点击区 / 音量键 / 键盘 / 手柄 / 翻页按钮都走它）在
// scrollBy 之后同步把 __selectionViewportScroll 推进到 after，随后异步到达的 scroll 事件
// 进 _onContinuousViewportScroll 时 position === previous，不走 _noteEinkScroll；Dart 侧
// 连续分支也不计数——于是按键翻页一次都不计，只有手指拖动滚屏才计。
//
// 这里用假 window / document 跑真实的连续 shell 对象，断言：
//   A. 每一次真滚动了的 paginate 回传恰好一页，随后送达的 scroll 事件不再重复计；
//   B. 拖动（原生 scroll 事件）仍按累计滚过一屏计一页；半屏拖动后接一次按键翻页只计一页；
//   C. 滚到尽头没动（返回 "limit"）不计；
//   D. 竖排（vertical-rl）同样每步一页。
//
// Run: node fushi/test/reader/eink_continuous_page_turn_behavior_test.js <payload.json>
// （由 eink_continuous_page_turn_behavior_test.dart 在 `flutter test` 内驱动）

const assert = require('assert');
const fs = require('fs');

const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function objectLiteral(source) {
  const marker = 'window.fushiReader = {';
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'fushiReader object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  assert.ok(end >= 0, 'fushiReader object terminator missing');
  return source.slice(brace, end + 2);
}

function makeEnv(writingMode) {
  const vertical = writingMode === 'vertical-rl';
  const extent = 800;
  const maxScroll = 10000;
  const root = { scrollTop: 0, clientHeight: extent, clientWidth: 1000, style: {} };
  const body = { clientWidth: 1000, clientHeight: extent, scrollTop: 0 };
  const style = { writingMode, getPropertyValue() { return ''; } };
  const getComputedStyle = () => style;
  const handlerCalls = [];
  const window = {
    innerWidth: vertical ? extent : 1000,
    innerHeight: vertical ? 1000 : extent,
    scrollX: 0,
    CSS: {},
    Highlight: function() {},
    getComputedStyle,
    flutter_inappwebview: {
      callHandler(name) { handlerCalls.push(name); },
    },
    scrollBy(opts) {
      if (vertical) {
        // vertical-rl：内容轴向左（负）滚。
        window.scrollX = Math.max(-maxScroll, Math.min(0, window.scrollX + opts.left));
      } else {
        root.scrollTop = Math.max(0, Math.min(maxScroll, root.scrollTop + opts.top));
      }
    },
  };
  const document = {
    documentElement: root,
    body,
    scrollingElement: root,
    caretRangeFromPoint: () => null,
    addEventListener() {},
  };
  return { window, document, getComputedStyle, root, handlerCalls, vertical, maxScroll };
}

function instantiate(env) {
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'requestAnimationFrame',
    'return ' + objectLiteral(data.continuous) + ';'
  );
  const reader = factory(env.window, env.document, { perfTraceEnabled: false }, {},
    env.window.CSS, env.window.Highlight, env.getComputedStyle, { TEXT_NODE: 3 },
    (fn) => fn());
  env.window.fushiReader = reader;
  // 初次快照（setup 时第一次 scroll 事件之前已有数值）。
  reader.__selectionViewportScroll = reader._readContinuousScroll();
  return reader;
}

function einkPages(env) {
  return env.handlerCalls.filter((n) => n === 'onEinkScrollPage').length;
}

// 模拟浏览器在程序化 / 原生滚动后异步送达 scroll 事件。
function deliverScroll(reader) {
  reader._onContinuousViewportScroll();
}

// ── A. 按键翻页：每步一页，scroll 事件不重复计 ─────────────────────────
{
  const env = makeEnv('horizontal-tb');
  const reader = instantiate(env);
  for (let i = 1; i <= 10; i++) {
    assert.strictEqual(reader.paginate('forward'), 'scrolled');
    deliverScroll(reader);
    assert.strictEqual(einkPages(env), i,
      'continuous paginate step ' + i + ' must report exactly one e-ink page');
  }
  assert.strictEqual(reader.paginate('backward'), 'scrolled');
  deliverScroll(reader);
  assert.strictEqual(einkPages(env), 11, 'a backward step is a page too');
}

// ── B. 拖动按累计一屏计；半屏拖动 + 一次按键只计一页 ────────────────────
{
  const env = makeEnv('horizontal-tb');
  const reader = instantiate(env);
  env.root.scrollTop += 300; deliverScroll(reader);
  env.root.scrollTop += 300; deliverScroll(reader);
  assert.strictEqual(einkPages(env), 0, 'less than one screen of drag is not a page');
  env.root.scrollTop += 300; deliverScroll(reader);
  assert.strictEqual(einkPages(env), 1, 'a full screen of drag is one page');

  env.root.scrollTop += 400; deliverScroll(reader);
  assert.strictEqual(einkPages(env), 1);
  reader.paginate('forward'); deliverScroll(reader);
  assert.strictEqual(einkPages(env), 2, 'key step after a half drag counts once');
  env.root.scrollTop += 400; deliverScroll(reader);
  assert.strictEqual(einkPages(env), 2,
    'the key step resets the drag accumulator (no half-page carry-over)');
}

// ── C. 到尽头没动不计 ───────────────────────────────────────────────────
{
  const env = makeEnv('horizontal-tb');
  const reader = instantiate(env);
  env.root.scrollTop = env.maxScroll;
  reader.__selectionViewportScroll = env.maxScroll;
  assert.strictEqual(reader.paginate('forward'), 'limit');
  assert.strictEqual(einkPages(env), 0, 'a turn that did not move is not a page');
}

// ── D. 竖排同口径 ───────────────────────────────────────────────────────
{
  const env = makeEnv('vertical-rl');
  const reader = instantiate(env);
  for (let i = 1; i <= 3; i++) {
    assert.strictEqual(reader.paginate('forward'), 'scrolled');
    deliverScroll(reader);
  }
  assert.strictEqual(einkPages(env), 3, 'vertical-rl continuous steps count one page each');
}

console.log('all assertions passed');
