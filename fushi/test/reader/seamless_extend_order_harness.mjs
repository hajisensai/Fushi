// novel-d6：网页小说书阅读中途 spine 末尾长出新章，已装文档的无缝阅读序要能接上。
// 由 seamless_extend_order_test.dart 执行，payload（kSeamlessChaptersInstallJs 与
// readerSeamlessExtendOrderInvocation 生成的调用）经 stdin 送入。
//
// 阅读序只在装页时随配置下发一次。正读着原来的末章（ORDER 里最后一项）时，宿主在 spine
// 末尾并进新章后调用 extendOrder：新章要接到 ORDER 末尾并被当作下一章挂上；章号不大于
// 现有末章的项（重复下发 / 已在序里）一律忽略。修前模块没有 extendOrder，调用即抛错，
// 末章后面永远挂不上新章。
//
// 页面里 fetch 由替身接管，DOMParser、shadow DOM 都是真浏览器的。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './vn_shell_harness_support.mjs';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const config = {
  seamlessChapters: true,
  // 正读着末章（第 1 章）：它后面原本没有章。
  seamlessChapterIndex: 1,
  seamlessChapterOrder: [
    { index: 0, url: 'http://book.test/ch0.xhtml' },
    { index: 1, url: 'http://book.test/ch1.xhtml' },
  ],
  navigationGeneration: 1,
};
const chapterHtml = (n) => '<!doctype html><html><head></head>' +
  '<body class="ch' + n + '"><p>chapter ' + n + ' text</p></body></html>';
const page = '<!doctype html><html><head><meta charset="utf-8">' +
  '<style id="fushi-reader-style">body{margin:0}</style>' +
  '<script>' +
  'window.__bodies = ' + JSON.stringify({
    'http://book.test/ch0.xhtml': chapterHtml(0),
    'http://book.test/ch1.xhtml': chapterHtml(1),
    'http://book.test/ch2.xhtml': chapterHtml(2),
  }) + ';' +
  'window.__fetched = [];' +
  'window.fetch = function(url) {' +
  '  window.__fetched.push(url);' +
  '  var body = window.__bodies[url];' +
  '  if (body === undefined) return Promise.resolve(new Response("", {status: 404}));' +
  '  return Promise.resolve(new Response(body, {status: 200}));' +
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
  'window.__extend = function() {' + scripts.extend + '};' +
  'window.__extendStale = function() {' + scripts.extendStale + '};' +
  '</script></head><body class="ch1"><p>chapter 1 text</p></body></html>';

const driver = await launchChromeDriver();
try {
  const r = await driver.evalOnPage(page, `(async () => {
    const waitFor = async (pred) => {
      for (let i = 0; i < 100 && !pred(); i++) await new Promise((r) => setTimeout(r, 20));
    };
    window.__install(${JSON.stringify(config)});
    const S = window.__fushiSeamless;
    const out = {};
    window.fushiReader.notifyRestoreComplete();
    await waitFor(() => S.started && S.mountedChapters().indexOf(0) >= 0);
    // 启动完成：只挂了前一章，末章后面没有章。
    out.beforeExtend = { started: S.started, mounted: S.mountedChapters().slice().sort() };

    // 宿主并进第 2 章后下发的调用（readerSeamlessExtendOrderInvocation 生成）。
    let threw = null;
    try { window.__extend(); } catch (e) { threw = String(e); }
    await waitFor(() => S.mountedChapters().indexOf(2) >= 0);
    out.afterExtend = {
      threw: threw,
      mounted: S.mountedChapters().slice().sort(),
      fetched: window.__fetched.filter((u) => u.indexOf('ch2') >= 0).length,
    };

    // 重复 / 过期的下发（章号不大于现有末章）：不改阅读序、不重复挂。
    try { window.__extendStale(); } catch (e) { threw = String(e); }
    await new Promise((r) => setTimeout(r, 100));
    out.afterStale = {
      threw: threw,
      mounted: S.mountedChapters().slice().sort(),
      fetched: window.__fetched.filter((u) => u.indexOf('ch2') >= 0).length,
    };
    out.unhandled = window.__errors.filter((e) => e.indexOf('unhandled:') === 0);
    return out;
  })()`);
  const dump = JSON.stringify(r);
  assert.equal(r.beforeExtend.started, true, 'the module starts on the last chapter ' + dump);
  assert.deepEqual(r.beforeExtend.mounted, [0], 'only the previous chapter is mounted before the spine grows ' + dump);
  assert.equal(r.afterExtend.threw, null, 'extendOrder exists and does not throw ' + dump);
  assert.deepEqual(r.afterExtend.mounted, [0, 2], 'the appended chapter mounts as the next neighbour ' + dump);
  assert.equal(r.afterExtend.fetched, 1, dump);
  assert.equal(r.afterStale.threw, null, dump);
  assert.deepEqual(r.afterStale.mounted, [0, 2], 'a stale extension changes nothing ' + dump);
  assert.equal(r.afterStale.fetched, 1, 'a stale extension does not refetch ' + dump);
  assert.deepEqual(r.unhandled, [], 'no unhandled rejection ' + dump);
  console.log('PASS seamless extend order');
} finally {
  driver.close();
}
