const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 制卡快捷键（用户诉求：「点那个加号的动作」要能用键盘触发）的**行为**测试。
//
// 为什么必须是行为测试：这段逻辑此前只有 Dart 侧一条源码字符串扫描守卫
// （popup_mine_key_binding_test 的「popup.js：读注入表…」），而那条扫的是**含注释的**
// 全文——popup.js 的注释里正好写着 `e.isComposing`、`__fushiPopupKeyBindings` 这些被
// 断言的名字，所以把实现整段删掉、只留注释也照样绿。变异实测证实过：删掉
// `e.isComposing`（= 日语输入法组字中按 Ctrl+Enter 会误制卡）后那条守卫仍然 PASSED。
//
// 这里从**真源码**切出键盘监听那一段丢进 vm 真执行，直接对着 window.__fushiPopupKeyListener
// 发事件。切片而不是整文件加载，是因为 popup.js 有 2800+ 行、依赖大量 DOM/宿主全局；
// 切片的两个锚点都断言过，源码重排会让本测试红而不是静默失效。
const POPUP = path.join(__dirname, 'vendor', 'popup.js');

function loadKeyListener(bindings) {
  const src = fs.readFileSync(POPUP, 'utf8');
  const START = 'const FUSHI_POPUP_KEY_DEFAULT_BINDINGS';
  const END = "document.addEventListener('keydown'";
  const start = src.indexOf(START);
  // keydown 注册被包在 `try {` 里，切到 addEventListener 之前会把 try 断成半截语法错，
  // 故回退到那个 try 之前——切片必须是自洽可执行的一段。
  const kd = src.indexOf(END, start);
  const end = kd < 0 ? -1 : src.lastIndexOf('try {', kd);
  assert.ok(start >= 0, '切片起点锚失效：popup.js 里找不到 FUSHI_POPUP_KEY_DEFAULT_BINDINGS');
  assert.ok(end > start, '切片终点锚失效：找不到 keydown 注册');
  const slice = src.slice(start, end);
  // 真的切到了监听体，而不是切出一段空壳。
  assert.ok(slice.includes('__fushiPopupKeyListener'), '切片里没有键盘监听函数');

  const mineCalls = [];
  const moveCalls = [];
  const audioCalls = [];
  const win = {
    fushiPopupMineFirstEntry: async () => { mineCalls.push(1); return true; },
    fushiFocusDictionaryEntryMove: (dir) => { moveCalls.push(dir); return 'moved'; },
    fushiPopupPlayFirstAudio: async () => { audioCalls.push(1); return true; },
  };
  if (bindings !== undefined) win.__fushiPopupKeyBindings = bindings;
  const ctx = { window: win, document: { addEventListener() {} } };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(slice, ctx);
  return { win, mineCalls, moveCalls, audioCalls };
}

function ev(over) {
  let prevented = false;
  return Object.assign({
    key: 'Enter',
    ctrlKey: true,
    altKey: false,
    shiftKey: false,
    metaKey: false,
    isComposing: false,
    repeat: false,
    target: { tagName: 'DIV', isContentEditable: false },
    preventDefault() { prevented = true; },
    stopPropagation() {},
    get _prevented() { return prevented; },
  }, over || {});
}

test('Ctrl+Enter 触发制卡（内置默认，浏览器扩展没有注入通道）', async () => {
  const { win, mineCalls } = loadKeyListener(undefined);
  await win.__fushiPopupKeyListener(ev());
  assert.strictEqual(mineCalls.length, 1, 'Ctrl+Enter 应该点到加号');
});

test('IME 组字中绝不制卡（日语输入法的 Enter 是确认候选词，抢了就把输入法打坏）', async () => {
  const { win, mineCalls } = loadKeyListener(undefined);
  await win.__fushiPopupKeyListener(ev({ isComposing: true }));
  assert.strictEqual(mineCalls.length, 0,
    'isComposing 期间必须放行——这是日语学习工具，误制卡是不可接受的回归');
});

test('输入框 / 可编辑区里放行（宿主页搜索框、弹窗自己的句子编辑框）', async () => {
  for (const target of [
    { tagName: 'INPUT' },
    { tagName: 'TEXTAREA' },
    { tagName: 'SELECT' },
    { tagName: 'DIV', isContentEditable: true },
  ]) {
    const { win, mineCalls } = loadKeyListener(undefined);
    await win.__fushiPopupKeyListener(ev({ target }));
    assert.strictEqual(mineCalls.length, 0, `${target.tagName} 里不该触发制卡`);
  }
});

test('修饰键必须全等：Ctrl+Shift+Enter 不算 Ctrl+Enter', async () => {
  const { win, mineCalls } = loadKeyListener(undefined);
  await win.__fushiPopupKeyListener(ev({ shiftKey: true }));
  assert.strictEqual(mineCalls.length, 0, '多按一个修饰键就不该命中');
});

test('自动重复（长按）不连续制卡', async () => {
  const { win, mineCalls } = loadKeyListener(undefined);
  await win.__fushiPopupKeyListener(ev({ repeat: true }));
  assert.strictEqual(mineCalls.length, 0);
});

test('注入 null（app 内宿主，Dart 侧派发）→ JS 侧整个关掉，不会制出两张卡', async () => {
  const { win, mineCalls } = loadKeyListener(null);
  await win.__fushiPopupKeyListener(ev());
  assert.strictEqual(mineCalls.length, 0,
    'in-app 宿主注入 null 时 JS 必须完全不参与，否则同一次按键会被 Dart 和 JS 各处理一遍');
});

test('用户清空绑定 → 该动作关掉，而不是回退默认（否则「清空」等于没清）', async () => {
  const { win, mineCalls } = loadKeyListener({ mine: [], next: [], prev: [] });
  await win.__fushiPopupKeyListener(ev());
  assert.strictEqual(mineCalls.length, 0);
});

test('用户改键后按新键生效、旧默认键失效', async () => {
  const cfg = { mine: [{ key: 'm', mods: ['alt'] }], next: [], prev: [] };
  const a = loadKeyListener(cfg);
  await a.win.__fushiPopupKeyListener(ev({ key: 'm', ctrlKey: false, altKey: true }));
  assert.strictEqual(a.mineCalls.length, 1, '新键应生效');
  const b = loadKeyListener(cfg);
  await b.win.__fushiPopupKeyListener(ev());
  assert.strictEqual(b.mineCalls.length, 0, '改键后旧的 Ctrl+Enter 不该再触发');
});

test('词条导航绑定命中时走既有移动入口，不碰制卡', async () => {
  const cfg = { mine: [], next: [{ key: 'arrowdown', mods: [] }], prev: [] };
  const { win, mineCalls, moveCalls } = loadKeyListener(cfg);
  await win.__fushiPopupKeyListener(ev({ key: 'ArrowDown', ctrlKey: false }));
  assert.deepStrictEqual(moveCalls, ['next']);
  assert.strictEqual(mineCalls.length, 0);
});

test('没命中任何绑定时不吞按键（网页自己的快捷键照常工作）', async () => {
  const { win } = loadKeyListener(undefined);
  const e = ev({ key: 'a', ctrlKey: true });
  await win.__fushiPopupKeyListener(e);
  assert.strictEqual(e._prevented, false, '未命中就必须原样交还给页面');
});

test('播放发音绑定命中时走 fushiPopupPlayFirstAudio，不碰制卡/导航（P2）', async () => {
  const cfg = { mine: [], next: [], prev: [], audio: [{ key: 'p', mods: [] }] };
  const { win, mineCalls, moveCalls, audioCalls } = loadKeyListener(cfg);
  await win.__fushiPopupKeyListener(ev({ key: 'p', ctrlKey: false }));
  assert.strictEqual(audioCalls.length, 1);
  assert.strictEqual(mineCalls.length, 0);
  assert.strictEqual(moveCalls.length, 0);
});
