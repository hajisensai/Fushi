// 查词弹窗「瞬时滚动」步长可调（lookup.popup_instant_scroll_{wheel,touch}_step）。
//
// BUG-2284 / BUG-2415 把滚轮 / 触摸的瞬跳步长写死成视口 × 0.5 / × 0.25；本轮改成用户
// 可调：popup.js 读 window.__fushiPopupInstantScroll{Wheel,Touch}Step（占视口比例），
// 缺省 / 非法回退原常量，且与 Dart 侧同界夹在 [0.1, 1]。
//
// 用 Node 真执行 popup.js（vm + 极简假 DOM，见 ../pages/_popup_dom_host.js）驱动真实的
// wheel 监听器与 popupEinkTouchStep，断言 scrollBy 实际收到的距离：
//   1. 未设步长 → 与改前完全一致（滚轮半屏、触摸 1/4 屏）。
//   2. 设了步长 → 距离 = 视口 × 步长；方向跟 deltaY。
//   3. 非法值（NaN / 字符串 / 0 / 负数）→ 回退默认；越界值夹到 [0.1, 1]。
//   4. 滚轮步长仍乘滚轮速度倍率，且永不超过一屏。
//   5. 冷却窗口不受步长影响：一次手势内的连发帧仍只跳一次。
//
// Run: node fushi/test/dictionary/popup_instant_scroll_step_test.js
// (also driven from popup_instant_scroll_step_guard_test.dart inside `flutter test`).

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('../pages/_popup_dom_host.js');

const VIEWPORT = 800;

function makeHost() {
  const sandbox = loadPopup();
  let clock = 10000; // 远离 0：_popupEinkWheelAt 初值 0，首帧不能被冷却窗口吃掉
  sandbox.performance = { now() { return clock; } };
  sandbox.window.innerHeight = VIEWPORT;
  sandbox.window.__fushiPopupInstantScroll = true;
  const calls = [];
  sandbox.window.scrollBy = (opts) => { calls.push(opts); };
  const listener = vm.runInContext('__fushiPopupWheelListener', sandbox);
  const touchStep = vm.runInContext('popupEinkTouchStep', sandbox);
  return {
    sandbox,
    calls,
    tick(ms) { clock += ms; },
    wheel(deltaY) {
      listener({
        deltaY, deltaX: 0, deltaMode: 0,
        ctrlKey: false, altKey: false, shiftKey: false, metaKey: false,
        target: null,
        composedPath() { return []; },
        preventDefault() {},
      });
    },
    touchStep() { return touchStep(null); },
  };
}

function wheelJump(setup) {
  const h = makeHost();
  if (setup) setup(h.sandbox.window);
  h.wheel(100);
  assert.strictEqual(h.calls.length, 1, '瞬时模式下一次滚轮恰好一次 scrollBy');
  return h.calls[0].top;
}

function touchStep(setup) {
  const h = makeHost();
  if (setup) setup(h.sandbox.window);
  return h.touchStep();
}

// 1. 未设步长：与改前完全一致（回退常量）。
assert.strictEqual(wheelJump(), VIEWPORT * 0.5, '滚轮默认半屏');
assert.strictEqual(touchStep(), VIEWPORT * 0.25, '触摸默认 1/4 屏');

// 2. 用户步长生效；方向跟 deltaY。
assert.strictEqual(wheelJump((w) => { w.__fushiPopupInstantScrollWheelStep = 0.8; }), 640);
assert.strictEqual(wheelJump((w) => { w.__fushiPopupInstantScrollWheelStep = 0.25; }), 200);
assert.strictEqual(touchStep((w) => { w.__fushiPopupInstantScrollTouchStep = 0.5; }), 400);
assert.strictEqual(touchStep((w) => { w.__fushiPopupInstantScrollTouchStep = 0.1; }), 80);
{
  const h = makeHost();
  h.sandbox.window.__fushiPopupInstantScrollWheelStep = 0.8;
  h.wheel(-100);
  assert.strictEqual(h.calls[0].top, -640, '向上滚 = 负步长');
}

// 3. 非法值回退默认；越界夹紧。
for (const bad of [NaN, 'abc', 0, -0.5, undefined, null, Infinity]) {
  assert.strictEqual(
    wheelJump((w) => { w.__fushiPopupInstantScrollWheelStep = bad; }), 400,
    `滚轮非法步长 ${String(bad)} 必须回退默认半屏`);
  assert.strictEqual(
    touchStep((w) => { w.__fushiPopupInstantScrollTouchStep = bad; }), 200,
    `触摸非法步长 ${String(bad)} 必须回退默认 1/4 屏`);
}
assert.strictEqual(wheelJump((w) => { w.__fushiPopupInstantScrollWheelStep = 5; }), VIEWPORT,
  '步长 > 1 夹到一屏（永不一步跳过整屏内容）');
assert.strictEqual(wheelJump((w) => { w.__fushiPopupInstantScrollWheelStep = 0.01; }), 80,
  '步长 < 0.1 夹到 0.1（与 Dart 侧 clamp 同界）');
assert.strictEqual(touchStep((w) => { w.__fushiPopupInstantScrollTouchStep = 3; }), VIEWPORT);
assert.strictEqual(touchStep((w) => { w.__fushiPopupInstantScrollTouchStep = 0.001; }), 80);

// 4. 滚轮步长仍乘滚轮速度倍率，且封顶一屏；触摸步长不吃滚轮速度。
assert.strictEqual(wheelJump((w) => {
  w.__fushiPopupInstantScrollWheelStep = 0.25;
  w.__fushiPopupWheelSpeed = 2;
}), 400, '0.25 屏 × 2 倍速 = 半屏');
assert.strictEqual(wheelJump((w) => {
  w.__fushiPopupInstantScrollWheelStep = 0.8;
  w.__fushiPopupWheelSpeed = 3;
}), VIEWPORT, '0.8 × 3 超过一屏 → 封顶');
assert.strictEqual(touchStep((w) => {
  w.__fushiPopupInstantScrollTouchStep = 0.25;
  w.__fushiPopupWheelSpeed = 3;
}), 200, '触摸步长与滚轮速度无关');

// 5. 冷却窗口与步长无关：同一手势的连发帧只跳一次，过了窗口再跳。
{
  const h = makeHost();
  h.sandbox.window.__fushiPopupInstantScrollWheelStep = 0.3;
  h.wheel(100);
  h.tick(50);
  h.wheel(100);
  assert.strictEqual(h.calls.length, 1, '140ms 内的第二帧被合并');
  h.tick(200);
  h.wheel(100);
  assert.strictEqual(h.calls.length, 2, '过了冷却窗口再跳');
  assert.deepStrictEqual(h.calls.map((c) => c.top), [240, 240]);
}

// 6. 开关关闭时步长全局不得改变比例滚动的行为（瞬时分支根本不进）。
{
  const h = makeHost();
  h.sandbox.window.__fushiPopupInstantScroll = false;
  h.sandbox.window.__fushiPopupInstantScrollWheelStep = 1;
  h.wheel(100);
  assert.strictEqual(h.calls.length, 1);
  assert.ok(h.calls[0].top < 100, `关闭瞬时后走比例滚动（粗鼠标一格 ≈ 48px），实得 ${h.calls[0].top}`);
}

console.log('popup_instant_scroll_step: all assertions passed');
