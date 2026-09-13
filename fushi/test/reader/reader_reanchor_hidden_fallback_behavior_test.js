// 阅读器重锚落定的帧调度 `_reanchorFrame`：页面可见走 requestAnimationFrame（下一帧，
// 与原行为一致）；`document.hidden === true` 时浏览器冻结 rAF（macOS 窗口不可见 /
// 隐藏、Chromium 最小化），必须改走 setTimeout(0)，否则 `_reanchorPending` 永远挂着
//（进度快照恒 null、位置不落库、账本不 arrive）。2026-09-12 Mac 隐藏 runner 探针实测
// raf=0 / hidden=true 抓到的。
//
// 从 reader_pagination_scripts.dart 原样切出 `_reanchorFrame` 在 node vm 里执行。
// Run: node fushi/test/reader/reader_reanchor_hidden_fallback_behavior_test.js

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const src = fs
  .readFileSync(
    path.resolve(__dirname, '../../lib/src/reader/reader_pagination_scripts.dart'),
    'utf8',
  )
  .replace(/\r\n/g, '\n');
const start = src.indexOf('  _reanchorFrame: function(fn) {');
assert.ok(start >= 0, '_reanchorFrame not found');
const end = src.indexOf('\n  },\n', start);
const method = src.slice(start, end + '\n  }'.length).trim();

function run(hidden) {
  const calls = [];
  const ctx = {
    document: { hidden },
    requestAnimationFrame: (fn) => calls.push('raf'),
    setTimeout: (fn, ms) => calls.push('timeout:' + ms),
  };
  vm.createContext(ctx);
  const engine = vm.runInContext(`({ ${method} })`, ctx);
  engine._reanchorFrame(function () {});
  return calls;
}

assert.deepStrictEqual(run(false), ['raf'], 'visible page keeps rAF');
assert.deepStrictEqual(run(true), ['timeout:0'], 'hidden page falls back to setTimeout(0)');
assert.deepStrictEqual(run(undefined), ['raf'], 'unknown visibility (old engines) keeps rAF');

console.log('reader_reanchor_hidden_fallback_behavior_test: ok');
