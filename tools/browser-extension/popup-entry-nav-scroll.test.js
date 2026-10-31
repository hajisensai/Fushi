const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 反馈 3LdKiAjwWa：Alt+滚轮 / 键盘 / 手柄切词条（fushiFocusDictionaryEntryMove）定位不准。
// 旧实现 scrollIntoView({block:'nearest'})：比视口高的词条只滚最小距离、停在释义中间；
// 回到第 0 条也只把它滚进视口，到不了结果区最顶（头部汉字卡等）。对齐 Yomitan：
// 切词 → 词条开头对齐视口顶（block:'start'）；第 0 条 → 弹窗自己的滚动表面全部归零，
// 且扩展里绝不越过 shadow root 去滚宿主网页。
//
// 从真源码切出词条导航 IIFE 放进 vm，配最小 fake DOM 真执行（锚点断言过，重排会红）。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');

function sliceEntryNav() {
  const src = fs.readFileSync(POPUP, 'utf8');
  const marker = "const CONTAINER_ID = 'entries-container';";
  const at = src.indexOf(marker);
  assert.ok(at >= 0, '切片锚失效：找不到词条导航 IIFE');
  const start = src.lastIndexOf('(function() {', at);
  const endMarker = 'window.fushiFocusDictionaryEntryReset = resetEntry;';
  const endAt = src.indexOf(endMarker, at);
  assert.ok(start >= 0 && endAt > at, '切片锚失效：IIFE 首尾');
  const end = src.indexOf('})();', endAt) + '})();'.length;
  return src.slice(start, end);
}

function classList() {
  const set = new Set();
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    contains: (c) => set.has(c),
  };
}

// root: 'document'（in-app）或 'shadow'（扩展：容器之上是 ShadowRoot，再上是宿主页）。
function build(root, n) {
  const calls = [];
  const doc = { nodeType: 9 };
  const scrollingElement = { nodeType: 1, scrollTop: 500 };
  doc.scrollingElement = scrollingElement;
  const hostPage = { nodeType: 1, scrollTop: 900, parentNode: doc }; // 扩展：宿主网页
  const shadowRoot = { nodeType: 11, host: hostPage, parentNode: null };
  const body = { nodeType: 1, scrollTop: 0, parentNode: root === 'shadow' ? shadowRoot : doc };
  const scroller = { nodeType: 1, scrollTop: 300, parentNode: body }; // 内层滚动容器
  const entries = [];
  const container = {
    nodeType: 1,
    scrollTop: 0,
    parentNode: scroller,
    querySelectorAll: () => entries,
  };
  for (let i = 0; i < n; i++) {
    const attrs = {};
    entries.push({
      nodeType: 1,
      parentNode: container,
      classList: classList(),
      setAttribute: (k, v) => { attrs[k] = v; },
      scrollIntoView: (opts) => calls.push({ index: i, opts }),
    });
  }
  const win = {};
  const ctx = { window: win, __fushiContainer: () => container };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(sliceEntryNav(), ctx);
  return { win, calls, scroller, scrollingElement, hostPage, entries };
}

test('切到后续词条：词条开头对齐视口顶（block:start），不是 nearest', () => {
  const { win, calls } = build('document', 3);
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('next'), 'moved'); // → 0
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('next'), 'moved'); // → 1
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(calls[0].index, 1);
  assert.strictEqual(calls[0].opts.block, 'start');
});

test('in-app：回到第 0 条 → 内层与文档滚动表面全部归零（结果区最顶）', () => {
  const { win, calls, scroller, scrollingElement } = build('document', 3);
  win.fushiFocusDictionaryEntry(2);
  scroller.scrollTop = 420;
  scrollingElement.scrollTop = 800;
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('prev'), 'moved'); // → 1
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('prev'), 'moved'); // → 0
  assert.strictEqual(scroller.scrollTop, 0);
  assert.strictEqual(scrollingElement.scrollTop, 0);
  assert.ok(!calls.some((c) => c.index === 0), '第 0 条不靠 scrollIntoView（它只滚进视口、不回顶）');
});

test('扩展：回到第 0 条只滚弹窗 shadow 树内的表面，绝不动宿主网页', () => {
  const { win, scroller, scrollingElement, hostPage } = build('shadow', 2);
  win.fushiFocusDictionaryEntry(1);
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('prev'), 'moved');
  assert.strictEqual(scroller.scrollTop, 0);
  assert.strictEqual(hostPage.scrollTop, 900, '宿主页滚动不得被改');
  assert.strictEqual(scrollingElement.scrollTop, 500, '宿主文档滚动不得被改');
});

test('到首条再往上 → blocked（交还普通滚动），不回绕', () => {
  const { win } = build('document', 2);
  win.fushiFocusDictionaryEntry(0);
  assert.strictEqual(win.fushiFocusDictionaryEntryMove('prev'), 'blocked');
});
