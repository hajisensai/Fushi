const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1132 回归守卫：浏览器扩展的「按住 Shift 悬停查词」是查词主路径。用户复诉「在浏览器按
// Shift 没反应」。历史上 5657c55d1（TODO-1132 v40）把发查词逻辑从 mousemove 处理器里抽成
// fushiSendLookup()，1219 P1-P3 又在 content.js 前后加了字幕拦截/面板脚本——任何一次重构都可能
// 悄悄把 mousemove→shiftKey→fushiSelection.selectFromPosition→chrome.runtime.sendMessage('lookup')
// 这条接线拆断而无人察觉（源码扫描守不住「是否真的被触发」）。这里在受控 vm 里真加载 content.js、
// 捕获它注册的 document mousemove 监听器、用带 shiftKey 的事件触发，断言最终真的发出了 lookup 消息。
// 只 stub 浏览器全局，不改 content.js；fushiSelection 用最小桩返回一个命中字与一个词。

const CONTENT = path.join(__dirname, 'content.js');

// options.respond=false 模拟 MV3 background service worker 在消息在途时被系统终止：
// sendMessage 的回调永不触发（BUG-1024 死锁场景）。options 缺省保持历史行为（同步回调）。
function loadContentAndFireShift(options) {
  options = options || {};
  const respond = !options || options.respond !== false;
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const winListeners = Object.create(null);
  const storageListeners = [];
  const sent = [];
  const dataset = {};
  const video = {
    paused: false,
    pauseCount: 0,
    pause() { this.paused = true; this.pauseCount++; },
  };
  // 可控时钟：BUG-1024 的在途闸超时兜底按 Date.now() 判定，测试需要推进虚拟时间。
  const nowRef = { value: 1000000 };
  const RealDate = Date;
  function FakeDate(...args) {
    return new RealDate(...args);
  }
  FakeDate.now = () => nowRef.value;
  FakeDate.prototype = RealDate.prototype;

  const sandbox = {
    Date: FakeDate,
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: {
      hostname: 'example.com',
      href: 'https://example.com/page',
      pathname: '/page',
    },
  };
  sandbox.document = {
    documentElement: { dataset, setAttribute() {} },
    body: { appendChild() {} },
    fullscreenElement: null,
    addEventListener: (t, fn) => {
      (docListeners[t] = docListeners[t] || []).push(fn);
    },
    getElementById: () => null,
    querySelector: (selector) => selector === 'video' ? video : null,
    querySelectorAll: () => [],
    createElement: () => ({
      style: {},
      addEventListener() {},
      appendChild() {},
      setAttribute() {},
      classList: { add() {} },
    }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        sent.push(msg);
        if (cb && respond) {
          cb({
            ok: true,
            data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] },
          });
        }
      },
    },
    storage: {
      local: {
        get: (_keys, cb) => {
          const saved = options.stored || {};
          if (typeof cb === 'function') cb(saved);
          return Promise.resolve(saved);
        },
        set: async () => {},
      },
      onChanged: { addListener: (fn) => storageListeners.push(fn) },
    },
  };
  sandbox.window = {
    addEventListener: (t, fn) => {
      (winListeners[t] = winListeners[t] || []).push(fn);
    },
    innerWidth: 1200,
    innerHeight: 800,
    // 与 Flutter app 同款 vendor/selection.js 的最小行为桩：命中一个字、扩成一个词。
    fushiSelection: {
      getCharacterAtPoint: () => ({ node: { textContent: '世界です', nodeType: 3 }, offset: 0 }),
      selectFromPosition: () => '世界',
      getSelectionRect: () => ({ x: 100, y: 100, width: 20, height: 16 }),
      highlightSelection: () => ({ x: 100, y: 100, width: 20, height: 16 }),
      clearSelection() {},
    },
  };
  sandbox.window.window = sandbox.window;

  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'content.js' });

  return {
    docListeners,
    sent,
    dataset,
    nowRef,
    video,
    windowObj: sandbox.window,
    storageListeners,
  };
}

test('content.js 在加载时注册了顶层 document mousemove 监听器', () => {
  const { docListeners } = loadContentAndFireShift();
  assert.ok(
    docListeners.mousemove && docListeners.mousemove.length >= 1,
    'content.js 未注册 mousemove 监听器：Shift 悬停查词永远不会触发',
  );
});

test('Shift + mousemove 命中日文时真的发出 lookup 查词消息', () => {
  const { docListeners, sent, dataset } = loadContentAndFireShift();
  const ev = { shiftKey: true, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);

  assert.strictEqual(dataset.fushiTerm, '世界', 'mousemove 未把命中的词写进诊断 dataset');
  const lookups = sent.filter((m) => m && m.type === 'lookup');
  assert.strictEqual(lookups.length, 1, 'Shift 悬停未发出恰好一次 lookup 查词');
  assert.strictEqual(lookups[0].term, '世界', 'lookup 携带的词不对');
});

test('未按 Shift 的 mousemove 不发查词（不刷爆服务器）', () => {
  const { docListeners, sent } = loadContentAndFireShift();
  const ev = { shiftKey: false, clientX: 300, clientY: 400 };
  for (const fn of docListeners.mousemove) fn(ev);
  assert.strictEqual(
    sent.filter((m) => m && m.type === 'lookup').length,
    0,
    '未按 Shift 也发了查词',
  );
});

test('查词时暂停默认关闭；开启后任意视频站点只在发起查词时暂停', () => {
  const off = loadContentAndFireShift();
  for (const fn of off.docListeners.mousemove) {
    fn({ shiftKey: true, clientX: 300, clientY: 400 });
  }
  assert.strictEqual(off.video.pauseCount, 0, '默认关闭时查词不得暂停视频');

  const on = loadContentAndFireShift({ stored: { subtitlePauseOnLookup: true } });
  for (const fn of on.docListeners.mousemove) {
    fn({ shiftKey: true, clientX: 300, clientY: 400 });
  }
  assert.strictEqual(on.video.pauseCount, 1, '开启后发起查词应暂停当前视频');
});

test('查词暂停兼容旧 subtitleHoverPause，但新键显式 false 优先', () => {
  const legacy = loadContentAndFireShift({ stored: { subtitleHoverPause: true } });
  for (const fn of legacy.docListeners.mousemove) {
    fn({ shiftKey: true, clientX: 300, clientY: 400 });
  }
  assert.strictEqual(legacy.video.pauseCount, 1, '旧开关为 true 的用户升级后应保留选择');

  const overridden = loadContentAndFireShift({
    stored: { subtitleHoverPause: true, subtitlePauseOnLookup: false },
  });
  for (const fn of overridden.docListeners.mousemove) {
    fn({ shiftKey: true, clientX: 300, clientY: 400 });
  }
  assert.strictEqual(overridden.video.pauseCount, 0, '新键显式 false 必须覆盖旧 true');
});

test('查词暂停经 storage.onChanged 热更新启停，无需刷新页面', () => {
  const h = loadContentAndFireShift({
    stored: { subtitlePauseOnLookup: false },
  });
  assert.ok(h.storageListeners.length > 0, 'content.js 应注册 storage.onChanged');

  fireShiftLookup(h.docListeners, 300, 400);
  assert.strictEqual(h.video.pauseCount, 0, '初始关闭时不得暂停');

  for (const listener of h.storageListeners) {
    listener({ subtitlePauseOnLookup: { newValue: true } }, 'local');
  }
  fireShiftLookup(h.docListeners, 500, 600);
  assert.strictEqual(h.video.pauseCount, 1, '热更新开启后下一次查词必须暂停');

  for (const listener of h.storageListeners) {
    listener({ subtitlePauseOnLookup: { newValue: false } }, 'local');
  }
  fireShiftLookup(h.docListeners, 700, 650);
  assert.strictEqual(h.video.pauseCount, 1, '热更新关闭后不得继续暂停');
});

test('悬浮字幕自动查词复用同词去重，移开复位后可重查', () => {
  const h = loadContentAndFireShift();
  const cue = { startMs: 1000, endMs: 2000, text: '世界です' };
  h.windowObj.fushiLookupAtPoint(300, 400, cue, { auto: true });
  h.windowObj.fushiLookupAtPoint(310, 400, cue, { auto: true });
  assert.strictEqual(
    h.sent.filter((m) => m && m.type === 'lookup').length,
    1,
    '同一句同一词的自动悬停不得重复发请求',
  );
  h.windowObj.fushiResetAutoLookupDedupe();
  h.windowObj.fushiLookupAtPoint(310, 400, cue, { auto: true });
  assert.strictEqual(
    h.sent.filter((m) => m && m.type === 'lookup').length,
    2,
    '移开复位后再次悬停同词应可重新查词',
  );
});

// BUG-1024 回归守卫：在途闸（fushiPending）过去是裸 bool，只在 sendMessage 回调里复位。
// MV3 background service worker 若在消息在途时被系统终止，回调永不触发 → fushiPending
// 永久停在 true → 此后所有 Shift 悬停被在途闸整条吞掉（用户报「Shift 查词弹窗不敏感」）。
// 这两条锁死：① 超过截止时间必须放行新查词（死锁不可复活）；② 截止时间内仍然拦截（防洪不退化）。
function fireShiftLookup(docListeners, x, y) {
  // 先松开 Shift：复位同词去重（fushiLastTerm=''），使同一个桩词可以再次触发查词。
  for (const fn of docListeners.mousemove) fn({ shiftKey: false, clientX: x, clientY: y });
  for (const fn of docListeners.mousemove) fn({ shiftKey: true, clientX: x, clientY: y });
}

test('BUG-1024 回调永不触发时，超过截止时间必须放行后续 Shift 查词（在途闸不得永久死锁）', () => {
  const { docListeners, sent, nowRef } = loadContentAndFireShift({ respond: false });

  fireShiftLookup(docListeners, 300, 400);
  assert.strictEqual(
    sent.filter((m) => m && m.type === 'lookup').length,
    1,
    '第一次 Shift 悬停应发出查词',
  );

  // worker 被杀，回调永不来；虚拟时间推过在途闸截止时间。
  nowRef.value += 5000;
  fireShiftLookup(docListeners, 500, 600);

  assert.strictEqual(
    sent.filter((m) => m && m.type === 'lookup').length,
    2,
    '在途闸超时后仍不放行 = 永久死锁复活：Shift 悬停查词将彻底失灵',
  );
});

test('BUG-1024 截止时间内仍拦截在途重复查词（防洪未退化）', () => {
  const { docListeners, sent, nowRef } = loadContentAndFireShift({ respond: false });

  fireShiftLookup(docListeners, 300, 400);
  nowRef.value += 100; // 远小于截止时间
  fireShiftLookup(docListeners, 500, 600);

  assert.strictEqual(
    sent.filter((m) => m && m.type === 'lookup').length,
    1,
    '截止时间内不应放行第二次查词（在途闸防洪失效）',
  );
});
