// BUG-2471 行为测试：`window.__fushiEngine.updateLive(patch)` 必须把 patch 合并进
// 已 install 的 config（同一个对象），并按需重物化派生值——四个边距百分比要用
// `__fushiApplyReaderMargins` 上一次见到的视口重新算成 `--reader-margin-*` 像素，
// `scanNonJapaneseText` 要镜像到 window。边距没变时不重物化、返回 false。
//
// 本测试从 webview.part.dart 的引擎源码里原样切出 `__fushiApplyReaderMargins` 的
// 定义与 `updateLive` 方法在 node vm 里执行，配一个最小假 DOM。
//
// Run: node fushi/test/reader/reader_engine_live_config_behavior_test.js
// (also driven from reader_engine_live_config_test.dart so it runs inside
//  `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const enginePath = path.resolve(
  __dirname,
  '../../lib/src/pages/implementations/reader_fushi/webview.part.dart',
);
const source = fs.readFileSync(enginePath, 'utf8').replace(/\r\n/g, '\n');

function sliceBetween(startMarker, endMarker, label) {
  const start = source.indexOf(startMarker);
  assert.ok(start >= 0, `missing ${label} start: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `missing ${label} end: ${endMarker}`);
  return source.slice(start, end + endMarker.length);
}

// `window.__fushiApplyReaderMargins = function(width, height) { ... };`
const applyMargins = sliceBetween(
  '  window.__fushiApplyReaderMargins = function(width, height) {',
  '\n  };\n',
  '__fushiApplyReaderMargins',
);
// `updateLive: function(patch) { ... }` (up to the object literal's closing).
const updateLiveBody = sliceBetween(
  'updateLive: function(patch) {',
  '\n}\n};',
  'updateLive',
).replace(/\n}\n};$/, '\n}');

function makeStyle() {
  const props = {};
  return {
    props,
    setProperty(name, value) {
      props[name] = value;
    },
  };
}

function makeContext() {
  const style = makeStyle();
  const ctx = {
    console,
    Number,
    Math,
    Object,
    document: { documentElement: { style } },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  return { ctx, style };
}

function boot(ctx, config) {
  ctx.window.__fushiReaderConfig = config;
  // install() runs the apply function with `C` bound to the same object.
  vm.runInContext(
    `(function(C) {\n${applyMargins}\n` +
      `  window.__fushiApplyReaderMargins(C.dartPageWidth, C.dartPageHeight);\n` +
      `  window.scanNonJapaneseText = C.scanNonJapaneseText;\n` +
      `})(window.__fushiReaderConfig);\n` +
      `window.__fushiEngine = { ${updateLiveBody} };`,
    ctx,
  );
}

function px(style, name) {
  return parseFloat(style.props[name]);
}

// ── 1. install materializes margins from C; updateLive re-materializes ──
{
  const { ctx, style } = makeContext();
  boot(ctx, {
    dartPageWidth: 1000,
    dartPageHeight: 800,
    marginTop: 5,
    marginBottom: 4,
    marginLeft: 3,
    marginRight: 2,
    scanNonJapaneseText: true,
    swipeDistThreshold: 44,
  });
  assert.strictEqual(px(style, '--reader-margin-top'), 40);
  assert.strictEqual(px(style, '--reader-margin-bottom'), 32);
  assert.strictEqual(px(style, '--reader-margin-left'), 30);
  assert.strictEqual(px(style, '--reader-margin-right'), 20);
  // (objects cross the vm boundary with a foreign prototype: compare fields.)
  assert.strictEqual(ctx.window.__fushiReaderMarginsLast.w, 1000);
  assert.strictEqual(ctx.window.__fushiReaderMarginsLast.h, 800);

  const changed = vm.runInContext(
    'window.__fushiEngine.updateLive({ marginTop: 10, marginBottom: 4, ' +
      'marginLeft: 3, marginRight: 2, swipeDistThreshold: 66, ' +
      'scanNonJapaneseText: false })',
    ctx,
  );
  assert.strictEqual(changed, true, 'margin change must report true');
  assert.strictEqual(px(style, '--reader-margin-top'), 80,
    'margin-top must be re-materialized from the last viewport (800 * 10%)');
  assert.strictEqual(px(style, '--reader-margin-bottom'), 32);
  assert.strictEqual(ctx.window.__fushiReaderConfig.swipeDistThreshold, 66,
    'non-margin keys are merged into the live config');
  assert.strictEqual(ctx.window.scanNonJapaneseText, false,
    'scanNonJapaneseText must be mirrored onto window');
}

// ── 2. resize between changes: margins follow the newest viewport ────────
{
  const { ctx, style } = makeContext();
  boot(ctx, {
    dartPageWidth: 1000,
    dartPageHeight: 800,
    marginTop: 5,
    marginBottom: 5,
    marginLeft: 5,
    marginRight: 5,
    scanNonJapaneseText: true,
  });
  vm.runInContext('window.__fushiApplyReaderMargins(500, 400)', ctx);
  assert.strictEqual(px(style, '--reader-margin-top'), 20);
  vm.runInContext(
    'window.__fushiEngine.updateLive({ marginTop: 20, marginBottom: 5, ' +
      'marginLeft: 5, marginRight: 5 })',
    ctx,
  );
  assert.strictEqual(px(style, '--reader-margin-top'), 80,
    'must size from the resized viewport (400 * 20%), not the install one');
  assert.strictEqual(px(style, '--reader-margin-left'), 25);
}

// ── 3. unchanged margins: no re-materialization, returns false ───────────
{
  const { ctx, style } = makeContext();
  boot(ctx, {
    dartPageWidth: 1000,
    dartPageHeight: 800,
    marginTop: 5,
    marginBottom: 5,
    marginLeft: 5,
    marginRight: 5,
    scanNonJapaneseText: true,
  });
  let applyCalls = 0;
  const original = ctx.window.__fushiApplyReaderMargins;
  ctx.window.__fushiApplyReaderMargins = function (w, h) {
    applyCalls++;
    return original(w, h);
  };
  const changed = vm.runInContext(
    'window.__fushiEngine.updateLive({ marginTop: 5, marginBottom: 5, ' +
      'marginLeft: 5, marginRight: 5, wheelGestureQuietMs: 300 })',
    ctx,
  );
  assert.strictEqual(changed, false);
  assert.strictEqual(applyCalls, 0, 'unchanged margins must not re-apply');
  assert.strictEqual(ctx.window.__fushiReaderConfig.wheelGestureQuietMs, 300);
  assert.strictEqual(px(style, '--reader-margin-top'), 40);
}

// ── 4. before install (no config) it is a safe no-op ─────────────────────
{
  const { ctx } = makeContext();
  vm.runInContext(`window.__fushiEngine = { ${updateLiveBody} };`, ctx);
  const changed = vm.runInContext(
    'window.__fushiEngine.updateLive({ marginTop: 9 })',
    ctx,
  );
  assert.strictEqual(changed, false);
}

console.log('reader_engine_live_config_behavior_test: ok');
