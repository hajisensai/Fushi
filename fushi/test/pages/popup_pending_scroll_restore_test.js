// 弹窗内原地跳转：后退 / 前进回到历史页时的滚动位恢复（`__fushiApplyPendingScrollTop`）。
//
// Dart 在 renderPopup() 之前把该页离开时的 scrollTop 写进 window.__fushiPendingScrollTop；
// 内容分批进 DOM，所以 popup.js 在三处应用它：首发 popupRendered（仍在渲染，够高才滚）、
// 每个尾批切片后（够高才滚）、尾批完成（final，兜底必滚、浏览器自行夹紧）。
//
// 用 Node 真执行 popup.js（vm + 极简假 DOM，见 _popup_dom_host.js），直接驱动这个函数：
//   1. pending = 0 / 负数 → 什么都不动。
//   2. 非 final 且文档还不够高 → 不滚、pending 保留（等下一片）。
//   3. 非 final 且够高 → 滚到位、pending 清零（同一份 pending 不会影响下一次渲染）。
//   4. final 且不够高 → 照样写 scrollTop（浏览器夹紧）、pending 清零。
//
// Run: node fushi/test/pages/popup_pending_scroll_restore_test.js
// (also driven from popup_pending_scroll_restore_test.dart inside `flutter test`).

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('./_popup_dom_host.js');

function makeScroller(scrollHeight, clientHeight) {
  return { scrollHeight, clientHeight, scrollTop: 0 };
}

function run(pending, scroller, isFinal) {
  const sandbox = loadPopup();
  sandbox.document.scrollingElement = scroller;
  sandbox.window.__fushiPendingScrollTop = pending;
  vm.runInContext(`__fushiApplyPendingScrollTop(${isFinal ? 'true' : 'false'})`, sandbox);
  return { scrollTop: scroller.scrollTop, pending: sandbox.window.__fushiPendingScrollTop };
}

// 1. 没有待恢复位：不动。
{
  const r = run(0, makeScroller(2000, 400), true);
  assert.strictEqual(r.scrollTop, 0);
  assert.strictEqual(r.pending, 0);
  const neg = run(-5, makeScroller(2000, 400), true);
  assert.strictEqual(neg.scrollTop, 0);
}

// 2. 非 final、还不够高：不滚，pending 保留给下一片。
{
  const r = run(1200, makeScroller(900, 400), false);
  assert.strictEqual(r.scrollTop, 0, '文档不够高时提前滚会被夹到底、随后又被后续内容顶回去');
  assert.strictEqual(r.pending, 1200, 'pending 必须保留，等下一个切片再试');
}

// 3. 非 final、够高：滚到位并清零。
{
  const r = run(1200, makeScroller(2000, 400), false);
  assert.strictEqual(r.scrollTop, 1200);
  assert.strictEqual(r.pending, 0, '应用后清零：下一次渲染不得再被这份 pending 影响');
}

// 4. final 兜底：不够高也写（浏览器夹紧），并清零。
{
  const r = run(1200, makeScroller(900, 400), true);
  assert.strictEqual(r.scrollTop, 1200, 'final 一律应用（真实浏览器会夹到 scrollHeight-clientHeight）');
  assert.strictEqual(r.pending, 0);
}

// 5. 装载后初值：popup.js 自己把 pending 初始化为 0（热槽跨查词不带脏值）。
{
  const sandbox = loadPopup();
  assert.strictEqual(sandbox.window.__fushiPendingScrollTop, 0);
}

console.log('popup_pending_scroll_restore: all assertions passed');
