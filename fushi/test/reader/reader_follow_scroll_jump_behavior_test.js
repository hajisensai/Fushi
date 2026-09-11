// BUG-2466 行为测试：连续模式听书跟随滚动 `scrollToTarget`——一个视口之内保持
// smooth（TODO-825 用户点名要的跟读动画），超过一个视口的「跟随」是跳、瞬时落地
//（smooth 补间会连续多帧滚过中间所有页，settle 窗关了之后每次 scroll 回传都把途中
// 视口 arrive 进阅读账本 = 字数虚增 / 字/时爆表）；墨水屏模式一律瞬时。
//
// 从 reader_pagination_scripts.dart 原样切出 `scrollToTarget` 方法体在 node vm 里
// 执行，配一个最小假 window / document，记录 scrollBy 收到的 behavior。
//
// Run: node fushi/test/reader/reader_follow_scroll_jump_behavior_test.js
// (also driven from reader_follow_scroll_jump_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const scriptsPath = path.resolve(
  __dirname,
  '../../lib/src/reader/reader_pagination_scripts.dart',
);
const source = fs.readFileSync(scriptsPath, 'utf8').replace(/\r\n/g, '\n');

const startMarker = '  scrollToTarget: function(target) {';
const endMarker = '\n  revealElement: function(element) {';
const start = source.indexOf(startMarker);
assert.ok(start >= 0, 'scrollToTarget not found');
const end = source.indexOf(endMarker, start);
assert.ok(end > start, 'revealElement not found after scrollToTarget');
// `scrollToTarget: function(target) { ... },` → strip trailing comma.
const method = source.slice(start, end).trim().replace(/,$/, '');

function run({ rect, writingMode, eink, innerWidth = 400, innerHeight = 800 }) {
  const calls = [];
  const ctx = {
    console,
    Math,
    document: {
      body: {},
      documentElement: {},
    },
  };
  ctx.window = ctx;
  ctx.innerWidth = innerWidth;
  ctx.innerHeight = innerHeight;
  ctx.scrollBy = (opts) => calls.push(opts);
  ctx.getComputedStyle = (el) => ({
    writingMode: el === ctx.document.body ? writingMode : '',
    getPropertyValue: (name) =>
      name === '--fushi-reader-eink-mode' ? (eink ? '1' : '') : '',
  });
  vm.createContext(ctx);
  const engine = vm.runInContext(
    `({ getRect: function() { return ${JSON.stringify(rect)}; }, ${method} })`,
    ctx,
  );
  const scrolled = engine.scrollToTarget({});
  return { scrolled, calls };
}

// 横排：视口 800 高，安全边 15% = 120。
// 1) 下一屏内（目标 top=900 → 位移 780 < 800）：smooth。
{
  const r = run({ rect: { top: 900, bottom: 940, left: 0, right: 0 }, writingMode: 'horizontal-tb', eink: false });
  assert.strictEqual(r.scrolled, true);
  assert.strictEqual(r.calls.length, 1);
  assert.strictEqual(r.calls[0].top, 780);
  assert.strictEqual(r.calls[0].behavior, 'smooth', 'one-viewport follow keeps smooth');
}
// 2) 几十页外（top=40000）：瞬时。
{
  const r = run({ rect: { top: 40000, bottom: 40040, left: 0, right: 0 }, writingMode: 'horizontal-tb', eink: false });
  assert.strictEqual(r.calls[0].behavior, 'auto', 'multi-page jump must be instant');
}
// 3) 往回跳几十页（top=-40000）：同样瞬时（绝对值判）。
{
  const r = run({ rect: { top: -40000, bottom: -39960, left: 0, right: 0 }, writingMode: 'horizontal-tb', eink: false });
  assert.strictEqual(r.calls[0].behavior, 'auto');
}
// 4) 已在安全区内：不滚。
{
  const r = run({ rect: { top: 300, bottom: 340, left: 0, right: 0 }, writingMode: 'horizontal-tb', eink: false });
  assert.strictEqual(r.scrolled, false);
  assert.strictEqual(r.calls.length, 0);
}
// 5) 墨水屏：短距离也瞬时。
{
  const r = run({ rect: { top: 900, bottom: 940, left: 0, right: 0 }, writingMode: 'horizontal-tb', eink: true });
  assert.strictEqual(r.calls[0].behavior, 'auto');
}
// 6) 竖排 rl：视口宽 400，安全边 60，位移 = right - 340。目标 right=-3000（左边几页外）
//    → 位移 -3340 → 瞬时；right=100（越出安全区一点）→ 位移 -240 → smooth。
{
  const far = run({ rect: { top: 0, bottom: 0, left: -3040, right: -3000 }, writingMode: 'vertical-rl', eink: false });
  assert.strictEqual(far.calls[0].left, -3000 - 340);
  assert.strictEqual(far.calls[0].behavior, 'auto');
  const near = run({ rect: { top: 0, bottom: 0, left: 0, right: 100 }, writingMode: 'vertical-rl', eink: false });
  assert.strictEqual(near.calls[0].left, -240);
  assert.strictEqual(near.calls[0].behavior, 'smooth');
}
// 7) 竖排 lr：位移 = left - 60。left=900 → 840 > 400 → 瞬时；left=350（right 越出
//    安全区）→ 290 → smooth。
{
  const far = run({ rect: { top: 0, bottom: 0, left: 900, right: 940 }, writingMode: 'vertical-lr', eink: false });
  assert.strictEqual(far.calls[0].behavior, 'auto');
  const near = run({ rect: { top: 0, bottom: 0, left: 350, right: 390 }, writingMode: 'vertical-lr', eink: false });
  assert.strictEqual(near.calls[0].left, 290);
  assert.strictEqual(near.calls[0].behavior, 'smooth');
}

console.log('reader_follow_scroll_jump_behavior_test: ok');
