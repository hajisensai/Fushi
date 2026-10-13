// BUG-3274：视频页换词时查词弹窗先闪「未找到」、结果多时滑动掉帧。
//
// 用 Node 真执行 popup.js（vm + 极简假 DOM，见 _popup_dom_host.js），守三件事：
//   1. 宿主推的空闲占位（lookupIdle=true，热槽 seed / 换词复位）只画空占位盒，绝不画
//      「未找到」——换词时隐藏层先收到它，结果一慢、宿主兜底强制翻可见就露出假空态。
//      查询真结束且为空（lookupIdle=false、pending=false）仍画「未找到」。
//   2. 浏览器跳过渲染的屏外词条（content-visibility 的 skipped 态）masonry 一律不碰：
//      读它的几何会把整棵子树强制排版，按需渲染就白做了。滚进视口的事件到来时就地铺好。
//   3. 列数从 documentElement 的内联 --dict-columns 读，不调 getComputedStyle（整页
//      样式重算；masonry 每帧都要问一次列数）。
//
// Run: node fushi/test/pages/popup_lookup_perf_bug3274_test.js
// (also driven from popup_lookup_perf_bug3274_test.dart inside `flutter test`).

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('./_popup_dom_host.js');

function withContainer(sandbox) {
  const container = sandbox.document.createElement('div');
  container.id = 'entries-container';
  sandbox.document.getElementById = (id) => (id === 'entries-container' ? container : null);
  return container;
}

function renderEmpty({ pending, idle }) {
  const sandbox = loadPopup();
  const container = withContainer(sandbox);
  sandbox.window.lookupEntries = [];
  sandbox.window.kanjiResults = [];
  sandbox.window.lookupPending = pending;
  sandbox.window.lookupIdle = idle;
  vm.runInContext('window.renderPopup()', sandbox);
  return container.innerHTML;
}

// 1. 空闲占位不是「没有结果」。
{
  const idleHtml = renderEmpty({ pending: false, idle: true });
  assert.ok(!idleHtml.includes('no-results'),
    '空闲占位（换词复位）画成了「未找到」：兜底强制翻可见时就是用户看到的假空态');
  assert.ok(idleHtml.includes('popup-loading'), '空闲占位应留空占位盒');

  const pendingHtml = renderEmpty({ pending: true, idle: false });
  assert.ok(!pendingHtml.includes('no-results'), '查询中不得画「未找到」');

  const emptyHtml = renderEmpty({ pending: false, idle: false });
  assert.ok(emptyHtml.includes('no-results'), '查询真结束且为空仍应画「未找到」');
}

function makeMasonryBody(sandbox, skipped) {
  const doc = sandbox.document;
  const entry = doc.createElement('div');
  entry.className = 'entry';
  entry.__fushiRenderSkipped = skipped;
  entry.isConnected = true;
  const body = doc.createElement('div');
  let geometryReads = 0;
  Object.defineProperty(body, 'clientWidth', { get() { geometryReads++; return 600; } });
  body.closest = (sel) => (sel === '.entry' ? entry : null);
  const items = [0, 1, 2].map((i) => {
    const item = doc.createElement('details');
    item.classList.add('glossary-group');
    item.open = true;
    Object.defineProperty(item, 'offsetHeight', { get() { geometryReads++; return 100 + i * 10; } });
    body.appendChild(item);
    return item;
  });
  entry.querySelectorAll = (sel) => (sel === '.glossary-section > .category-body' ? [body] : []);
  return { entry, body, items, reads: () => geometryReads };
}

// 2. 跳过渲染的词条不铺；滚进视口（skipped=false）时就地铺好。
{
  const sandbox = loadPopup();
  withContainer(sandbox);
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '2' : '');
  sandbox.window.innerWidth = 900;
  const skipped = makeMasonryBody(sandbox, true);
  sandbox.__body = skipped.body;
  vm.runInContext('layoutMasonry([__body])', sandbox);
  assert.strictEqual(skipped.reads(), 0, '被跳过渲染的词条被读了几何：会强制排版整棵屏外子树');
  assert.strictEqual(skipped.body.style.position, undefined, '被跳过渲染的词条不应被 masonry 改写');

  sandbox.__entry = skipped.entry;
  vm.runInContext(
    '__fushiOnLazyEntryVisibility({ currentTarget: __entry, skipped: false })', sandbox);
  assert.strictEqual(skipped.entry.__fushiRenderSkipped, false);
  assert.ok(skipped.reads() > 0, '滚进视口后应当就地铺 masonry');
  assert.strictEqual(skipped.body.style.position, 'relative');
  assert.ok(skipped.items.every((it) => it.style.position === 'absolute' && it.style.transform),
    '滚进视口的词条每张卡都应被摆位');
}

// 3. 列数读内联值，不触发 getComputedStyle。
{
  let computedCalls = 0;
  const sandbox = loadPopup((sb) => {
    sb.getComputedStyle = () => { computedCalls++; return { getPropertyValue() { return '1'; } }; };
  });
  sandbox.document.documentElement.style.getPropertyValue = (k) => (k === '--dict-columns' ? '3' : '');
  sandbox.window.innerWidth = 1200;
  computedCalls = 0;
  const cols = vm.runInContext('effectiveDictColumns()', sandbox);
  assert.strictEqual(cols, 3);
  assert.strictEqual(computedCalls, 0, '内联值存在时不应调 getComputedStyle（整页样式重算）');
}

console.log('all assertions passed');
