// BUG-4836：无缝衔接模块启动失败后的行为，在真 Chrome 里跑生产安装脚本。
// 由 seamless_start_failure_test.dart 执行，payload（kSeamlessChaptersInstallJs 的 JSON）经 stdin 送入。
//
// 修前：S.start 在 `_starting = true` 之后的任何一步 reject / 抛异常都不复位，
// claimBoundaryTurn 的 `if (!S.started) return S._starting === true` 从此恒真，连续 shell 的
// 三条「拉过边界换章」通道（按键 paginate、触摸边界拉动、滚轮）全部被认领，用户在这一章里
// 翻不到下一章。同一个根的第二处：epubStylesOf 逐张 `await fetch(href)`，一张样式表请求失败
// 就让整次启动（或整次邻章挂载）失败。
//
// 页面里 fetch 由替身接管（按 URL 决定成功 / 404 / reject / 挂起），DOMParser、shadow DOM、
// 样式改写都是真浏览器的。引擎只给模块实际调用到的最小替身。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const config = {
  seamlessChapters: true,
  seamlessChapterIndex: 0,
  seamlessChapterOrder: [
    { index: 0, url: 'http://book.test/ch0.xhtml' },
    { index: 1, url: 'http://book.test/ch1.xhtml' },
  ],
  navigationGeneration: 1,
};
const chapterHtml = (n) => '<!doctype html><html><head>' +
  '<link rel="stylesheet" href="good.css"><link rel="stylesheet" href="bad.css">' +
  '</head><body class="ch' + n + '"><p>chapter ' + n + ' text</p></body></html>';
const page = '<!doctype html><html><head><meta charset="utf-8">' +
  '<style id="fushi-reader-style">body{margin:0}</style>' +
  '<link rel="stylesheet" href="http://book.test/good.css">' +
  '<link rel="stylesheet" href="http://book.test/bad.css">' +
  '<script>' +
  // url → 'ok' | 'reject' | 'hang'；没登记的一律 404。
  'window.__routes = {};' +
  'window.__bodies = ' + JSON.stringify({
    'http://book.test/ch0.xhtml': chapterHtml(0),
    'http://book.test/ch1.xhtml': chapterHtml(1),
    'http://book.test/good.css': 'p{color:rgb(1,2,3)}',
    'http://book.test/bad.css': 'p{margin:7px}',
  }) + ';' +
  'window.__hung = [];' +
  'window.fetch = function(url) {' +
  '  var mode = window.__routes[url];' +
  '  if (mode === "reject") return Promise.reject(new TypeError("Failed to fetch"));' +
  '  if (mode === "hang") return new Promise(function(resolve, reject) { window.__hung.push(reject); });' +
  '  if (mode !== "ok") return Promise.resolve(new Response("", {status: 404}));' +
  '  return Promise.resolve(new Response(window.__bodies[url], {status: 200}));' +
  '};' +
  'window.__errors = [];' +
  'var origError = console.error;' +
  'console.error = function() { window.__errors.push(String(arguments[0])); return origError.apply(console, arguments); };' +
  'window.addEventListener("unhandledrejection", function(e) { window.__errors.push("unhandled:" + e.reason); });' +
  'window.fushiReader = {' +
  '  _reanchorPending: false,' +
  '  isVertical: function() { return false; },' +
  '  notifyRestoreComplete: function() {},' +
  '  claimBoundaryTurn: function() { return false; },' +
  '  chapterTurnEpoch: function() { return 0; }' +
  '};' +
  'window.__install = function(C) {' + scripts.seamless + '};' +
  '</script></head><body class="ch0"><p>chapter 0 text</p></body></html>';

const driver = await launchChromeDriver();
try {
  const r = await driver.evalOnPage(page, `(async () => {
    const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0)); };
    const routes = window.__routes;
    window.__install(${JSON.stringify(config)});
    const S = window.__fushiSeamless;
    const reader = window.fushiReader;
    const out = {};

    // ① 章节请求在途：模块正在启动，这一侧归它（修前修后都应为 true）。
    routes['http://book.test/ch0.xhtml'] = 'hang';
    reader.notifyRestoreComplete();
    await settle();
    out.claimWhileStarting = reader.claimBoundaryTurn('forward');
    // ② 请求 reject（不是 404）：启动失败 → 不再认领，退回整章重载。
    window.__hung.splice(0).forEach((reject) => reject(new TypeError('Failed to fetch')));
    await settle();
    out.afterReject = {
      started: S.started,
      starting: S._starting === true,
      claimForward: reader.claimBoundaryTurn('forward'),
      claimBackward: reader.claimBoundaryTurn('backward'),
      logged: window.__errors.some((e) => e.indexOf('[seamless] start failed') === 0),
      unhandled: window.__errors.filter((e) => e.indexOf('unhandled:') === 0),
    };
    // ③ 失败不是终态：下一次恢复完成再启动。这次章节与 good.css 正常，bad.css 请求 reject——
    //    只丢这一张，启动与邻章挂载都照常完成。
    routes['http://book.test/ch0.xhtml'] = 'ok';
    routes['http://book.test/ch1.xhtml'] = 'ok';
    routes['http://book.test/good.css'] = 'ok';
    routes['http://book.test/bad.css'] = 'reject';
    reader.notifyRestoreComplete();
    for (let i = 0; i < 100 && S.mountedChapters().indexOf(1) < 0; i++) {
      await new Promise((r) => setTimeout(r, 20));
    }
    const data = S.chapterData[0] || { styles: [] };
    const host = document.querySelector('fushi-seamless-chapter');
    const epubStyle = host && host.shadowRoot ? host.shadowRoot.querySelector('style[data-role="epub"]') : null;
    out.afterSheetFailure = {
      started: S.started,
      starting: S._starting === true,
      styles: data.styles.map((s) => [s.href, s.text]),
      claimedHeadLinks: Array.from(document.head.querySelectorAll('[data-fushi-seamless-css]'))
        .map((el) => el.getAttribute('data-fushi-seamless-css')),
      mounted: S.mountedChapters(),
      mountFailed: S.mountFailures[1] === true,
      neighbourCss: epubStyle ? epubStyle.textContent : null,
    };
    return out;
  })()`);
  const dump = JSON.stringify(r);
  assert.equal(r.claimWhileStarting, true, 'an in-flight start owns the boundary ' + dump);
  assert.equal(r.afterReject.started, false, 'a rejected chapter fetch leaves the module not started ' + dump);
  assert.equal(r.afterReject.starting, false, 'a failed start must reset _starting ' + dump);
  assert.equal(r.afterReject.claimForward, false, 'after a failed start the forward boundary falls back to a reload ' + dump);
  assert.equal(r.afterReject.claimBackward, false, 'after a failed start the backward boundary falls back to a reload ' + dump);
  assert.equal(r.afterReject.logged, true, 'the failure is reported on the console ' + dump);
  assert.deepEqual(r.afterReject.unhandled, [], 'no unhandled rejection ' + dump);

  assert.equal(r.afterSheetFailure.started, true, 'one failed stylesheet must not fail the start ' + dump);
  assert.equal(r.afterSheetFailure.starting, false, dump);
  assert.deepEqual(r.afterSheetFailure.styles, [
    ['http://book.test/good.css', 'p{color:rgb(1,2,3)}'],
    ['http://book.test/bad.css', ''],
  ], 'only the failed sheet is dropped (registered empty, signature kept) ' + dump);
  assert.deepEqual(r.afterSheetFailure.claimedHeadLinks, [
    'L:http://book.test/good.css',
    'L:http://book.test/bad.css',
  ], 'both head links are still recognised as this chapter\'s sheets ' + dump);
  assert.deepEqual(r.afterSheetFailure.mounted, [1], 'the neighbour chapter still mounts ' + dump);
  assert.equal(r.afterSheetFailure.mountFailed, false, 'one failed stylesheet must not fail the mount ' + dump);
  assert.ok(String(r.afterSheetFailure.neighbourCss).includes('rgb(1,2,3)'),
    'the neighbour keeps the sheets that did load ' + dump);
  console.log('PASS seamless start failure');
} finally {
  driver.close();
}
