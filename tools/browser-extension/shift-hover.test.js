const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1132 回归守卫：浏览器扩展的「按住 Shift 悬停查词」是查词主路径。用户复诉「在浏览器按
// Shift 没反应」。历史上 5657c55d1（TODO-1132 v40）把发查词逻辑从 mousemove 处理器里抽成
// hibikiSendLookup()，1219 P1-P3 又在 content.js 前后加了字幕拦截/面板脚本——任何一次重构都可能
// 悄悄把 mousemove→shiftKey→hoshiSelection.selectFromPosition→chrome.runtime.sendMessage('lookup')
// 这条接线拆断而无人察觉（源码扫描守不住「是否真的被触发」）。这里在受控 vm 里真加载 content.js、
// 捕获它注册的 document mousemove 监听器、用带 shiftKey 的事件触发，断言最终真的发出了 lookup 消息。
// 只 stub 浏览器全局，不改 content.js；hoshiSelection 用最小桩返回一个命中字与一个词。

const CONTENT = path.join(__dirname, 'content.js');

function loadContentAndFireShift() {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const docListeners = Object.create(null);
  const winListeners = Object.create(null);
  const sent = [];
  const dataset = {};

  const sandbox = {
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
    querySelector: () => null,
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
        if (cb) {
          cb({
            ok: true,
            data: { popupJson: '[]', result: { bestLength: 2 }, audioSources: [] },
          });
        }
      },
    },
    storage: {
      local: { get: async () => ({}), set: async () => {} },
      onChanged: { addListener() {} },
    },
  };
  sandbox.window = {
    addEventListener: (t, fn) => {
      (winListeners[t] = winListeners[t] || []).push(fn);
    },
    innerWidth: 1200,
    innerHeight: 800,
    // 与 Flutter app 同款 vendor/selection.js 的最小行为桩：命中一个字、扩成一个词。
    hoshiSelection: {
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

  return { docListeners, sent, dataset };
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

  assert.strictEqual(dataset.hibikiTerm, '世界', 'mousemove 未把命中的词写进诊断 dataset');
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
