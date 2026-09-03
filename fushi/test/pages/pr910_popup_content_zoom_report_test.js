// PR#910 审查必修 ①（BUG-1651 单位不匹配）：popupRendered 报的内容高度必须是
// **host CSS px**，与同一次调用里报的 window.innerHeight 同单位。
//
// 根因：__fushiScrollHeight() 读容器 scrollHeight，CSS zoom 不改它，返回未乘 z 的
// layout px；window.innerHeight 是视口高度，不随元素 zoom 变。宿主
// （dictionary_popup_layer.resolveAutoFitPopupHeight）拿两者作差增减弹窗外壳高，
// 差一个 z 就按 z 倍收错。默认（界面 100% + 词典字号 16）z=1 恰好正确 —— 这就是
// 只用 z=1 断言的测试抓不到它的原因，所以这里的用例全部围绕 z != 1。
//
// Run: node fushi/test/pages/pr910_popup_content_zoom_report_test.js

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');
const start = source.indexOf('function _reportPopupHeight()');
const end = source.indexOf('// ===== N 列 masonry', start);
assert(start >= 0 && end > start, 'popup render-signal source block must exist');
const renderSignalSource = source.slice(start, end);

// scrollHeight 是容器 layout px；zoom 是施加在它祖先上的 CSS zoom。
function makeSandbox(options) {
  const scrollHeight = options.scrollHeight;
  const rootZoom = options.rootZoom;
  const shadowHostZoom = options.shadowHostZoom;
  const calls = { renderedArgs: null };
  const sandbox = {
    Promise,
    document: {
      body: { offsetWidth: 640 },
      documentElement: {
        scrollHeight: scrollHeight,
        clientHeight: 0,
        style: rootZoom === undefined ? {} : { zoom: rootZoom },
      },
      fonts: { ready: Promise.resolve() },
    },
    window: {
      _renderGeneration: 1,
      _renderInProgress: false,
      __fushiRenderToken: 0,
      __fushiRoot: shadowHostZoom === undefined
        ? null
        : { host: { style: { zoom: shadowHostZoom } } },
      innerHeight: 280,
      flutter_inappwebview: {
        callHandler(name, ...args) {
          if (name === 'popupRendered') calls.renderedArgs = args;
          return Promise.resolve();
        },
      },
      fushiRelayoutDictionaries() {},
    },
    __fushiScrollHeight() { return scrollHeight; },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(renderSignalSource, sandbox, { filename: 'popup-render-signal.js' });
  return { sandbox: sandbox, calls: calls };
}

function reportedArgs(options) {
  const made = makeSandbox(options);
  made.sandbox._reportPopupHeight();
  assert(made.calls.renderedArgs, 'popupRendered must fire');
  return made.calls.renderedArgs;
}

(function run() {
  // z = 1（默认：界面大小 100% + 词典字号 16）：恒等变换，行为不变。
  assert.deepStrictEqual(
    reportedArgs({ scrollHeight: 100 }),
    [100, 0, 280],
    'no zoom set at all -> identity (and viewport still reported)');
  assert.strictEqual(
    reportedArgs({ scrollHeight: 100, rootZoom: '1.0000' })[0], 100,
    'zoom=1 -> identity');

  // z > 1（用户调大界面大小或词典字号）：不换算会少报 z 倍 -> 弹窗收得过狠。
  // 100 layout px * 1.25 = 125 host CSS px。旧实现报 100，宿主按
  // shell + 100 - 280 收缩，比正确的 shell + 125 - 280 少 25px -> 内容被裁。
  assert.strictEqual(
    reportedArgs({ scrollHeight: 100, rootZoom: '1.2500' })[0], 125,
    'zoom=1.25 -> 100 layout px must be reported as 125 host CSS px');

  // z < 1（词典字号调小）：不换算会多报 -> 原 bug 收不干净。
  assert.strictEqual(
    reportedArgs({ scrollHeight: 100, rootZoom: '0.8000' })[0], 80,
    'zoom=0.8 -> 100 layout px must be reported as 80 host CSS px');

  // 子像素只向上取整一格，绝不向下少报（少报=底部被裁）。
  assert.strictEqual(
    reportedArgs({ scrollHeight: 297, rootZoom: '1.2500' })[0], 372,
    'ceil(297 * 1.25) = 372');

  // 扩展浮窗：zoom 落在 shadow host 上（content.js fushiRender），不是 documentElement。
  assert.strictEqual(
    reportedArgs({ scrollHeight: 100, shadowHostZoom: '1.5' })[0], 150,
    'extension popup zooms the shadow host; that zoom must be honoured too');

  // 非法/缺失 zoom 一律回落 1，绝不产出 NaN/0 高度。
  ['', 'abc', '0', '-1', 'none'].forEach(function (bad) {
    assert.strictEqual(
      reportedArgs({ scrollHeight: 100, rootZoom: bad })[0], 100,
      'invalid zoom ' + JSON.stringify(bad) + ' must fall back to 1');
  });

  // 视口高度必须原样上报（它已经是 host CSS px，绝不能也乘 z）。
  assert.strictEqual(
    reportedArgs({ scrollHeight: 100, rootZoom: '1.2500' })[2], 280,
    'window.innerHeight is already host CSS px - never scale it');

  console.log('pr910_popup_content_zoom_report_test.js: all assertions passed');
})();
