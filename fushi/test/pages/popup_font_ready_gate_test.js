// The popup layer is hidden until popupRendered. With a configured custom font,
// that signal must wait for FontFaceSet.ready; otherwise a cold nested lookup
// reveals one fallback-font frame.
//
// Run: node fushi/test/pages/popup_font_ready_gate_test.js

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

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function makeSandbox(fontReady, configured) {
  const calls = { rendered: 0, relayout: 0, layoutReads: 0, renderedArgs: null };
  const body = {};
  Object.defineProperty(body, 'offsetWidth', {
    get() { calls.layoutReads += 1; return 640; },
  });
  const windowObj = {
    _renderGeneration: 1,
    _renderInProgress: true,
    __fushiDictionaryFontsConfigured: configured,
    flutter_inappwebview: {
      callHandler(name, ...args) {
        if (name === 'popupRendered') {
          calls.rendered += 1;
          calls.renderedArgs = args;
        }
        return Promise.resolve();
      },
    },
    innerHeight: 280,
    fushiRelayoutDictionaries() { calls.relayout += 1; },
  };
  const sandbox = {
    Promise,
    document: { body, documentElement: { scrollHeight: 100 }, fonts: { ready: fontReady } },
    window: windowObj,
    __fushiScrollHeight() { return 100; },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(renderSignalSource, sandbox, { filename: 'popup-render-signal.js' });
  return { sandbox, calls };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
}

(async function run() {
  {
    const ready = deferred();
    const { sandbox, calls } = makeSandbox(ready.promise, true);
    sandbox._firePopupRendered(false);
    assert.strictEqual(calls.layoutReads, 1,
      'layout must be forced so the browser discovers the injected font');
    assert.strictEqual(calls.rendered, 0,
      'a cold custom-font popup must remain hidden before fonts.ready');
    ready.resolve();
    await flushPromises();
    assert.strictEqual(calls.rendered, 1,
      'the host reveal signal must fire after fonts.ready');
    assert.strictEqual(calls.relayout, 1,
      'masonry layout must run after the font metrics are final');
    assert.deepStrictEqual(calls.renderedArgs, [100, 0, 280],
      'popupRendered must report content height, render token, and viewport height');
  }

  {
    const { sandbox, calls } = makeSandbox(Promise.resolve(), false);
    sandbox._firePopupRendered(false);
    assert.strictEqual(calls.rendered, 1,
      'without a configured custom font, reveal remains synchronous');
  }

  {
    const ready = deferred();
    const { sandbox, calls } = makeSandbox(ready.promise, true);
    sandbox._firePopupRendered(false);
    sandbox.window._renderGeneration = 2;
    ready.resolve();
    await flushPromises();
    assert.strictEqual(calls.rendered, 0,
      'a stale font waiter must never reveal a newer nested lookup');
  }

  console.log('popup_font_ready_gate_test.js: all assertions passed');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
