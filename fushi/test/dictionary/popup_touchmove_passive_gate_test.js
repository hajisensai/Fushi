// BUG-2877：查词弹窗的非 passive touchmove 只在「瞬时滚动」开着时才挂。
//
// BUG-2415 把 `touchmove`（passive:false）常驻挂在 in-app 弹窗 document 上，而瞬时滚动
// 默认关——关着时回调第一行就 return，却让 Chromium 每次起滑都等主线程应答，词典
// 滑动在主线程忙时跟不住手、惯性被吞。这里用 Node 真执行 popup.js，记录 document 上
// 实际挂着的 touchmove 监听，断言：
//   1. 默认（未注入开关）→ 不挂任何 touchmove；touchstart/touchend 仍是 passive。
//   2. 注入写 true → 挂上恰好一个 passive:false 的 touchmove。
//   3. 同值重复写 → 不重复挂。
//   4. 写回 false → 卸掉，回到零阻塞监听。
//   5. 开关先于 popup.js 注入为 true → 加载时就挂上，且读回的值不变。
//   6. 扩展镜像（chrome.runtime.id）→ 无论开关如何都不挂 document 级触摸监听。
//
// Run: node fushi/test/dictionary/popup_touchmove_passive_gate_test.js
// (also driven from popup_touch_instant_scroll_guard_test.dart inside `flutter test`).

const assert = require('assert');
const { loadPopup } = require('../pages/_popup_dom_host.js');

function load(preset) {
  const listeners = [];
  const sandbox = loadPopup((sb) => {
    sb.document.addEventListener = (type, fn, opts) => {
      listeners.push({ type, fn, passive: !!(opts && opts.passive) });
    };
    sb.document.removeEventListener = (type, fn) => {
      const i = listeners.findIndex((l) => l.type === type && l.fn === fn);
      if (i >= 0) listeners.splice(i, 1);
    };
    if (preset) preset(sb);
  });
  const of = (type) => listeners.filter((l) => l.type === type);
  return { window: sandbox.window, of };
}

// 1. 默认不挂阻塞 touchmove。
{
  const h = load();
  assert.strictEqual(h.of('touchmove').length, 0, '瞬时滚动关着时不得挂 touchmove');
  assert.strictEqual(h.of('touchstart').length, 1);
  assert.strictEqual(h.of('touchstart')[0].passive, true, 'touchstart 必须 passive');
  assert.ok(h.of('touchend').every((l) => l.passive), 'touchend 必须 passive');

  // 2. 打开 → 恰好一个 passive:false。
  h.window.__fushiPopupInstantScroll = true;
  assert.strictEqual(h.of('touchmove').length, 1);
  assert.strictEqual(h.of('touchmove')[0].passive, false,
    '瞬时滚动要 preventDefault 掐惯性，touchmove 必须非 passive');
  assert.strictEqual(h.window.__fushiPopupInstantScroll, true);

  // 3. 同值重复写不重复挂。
  h.window.__fushiPopupInstantScroll = true;
  assert.strictEqual(h.of('touchmove').length, 1);

  // 4. 关掉 → 卸掉。
  h.window.__fushiPopupInstantScroll = false;
  assert.strictEqual(h.of('touchmove').length, 0, '关掉后必须卸掉阻塞 touchmove');
  assert.strictEqual(h.window.__fushiPopupInstantScroll, false);
}

// 5. 注入先于 popup.js：加载时即挂。
{
  const h = load((sb) => { sb.window.__fushiPopupInstantScroll = true; });
  assert.strictEqual(h.of('touchmove').length, 1);
  assert.strictEqual(h.of('touchmove')[0].passive, false);
  assert.strictEqual(h.window.__fushiPopupInstantScroll, true);
}

// 6. 扩展镜像：不挂 document 级触摸监听，开关写入也不会挂。
{
  const h = load((sb) => { sb.chrome = { runtime: { id: 'ext' } }; });
  assert.strictEqual(h.of('touchstart').length, 0);
  h.window.__fushiPopupInstantScroll = true;
  assert.strictEqual(h.of('touchmove').length, 0, '扩展侧不得挂 document 级 touchmove');
  assert.strictEqual(h.window.__fushiPopupInstantScroll, true, '扩展侧开关仍是普通全局');
}

console.log('all assertions passed');
