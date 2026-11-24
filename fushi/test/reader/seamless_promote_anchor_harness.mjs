// 反馈 cdWxWwe-iz：连续模式无缝衔接在章节交界慢拖，一下跳过整章（第三章 → 第四章 → 终章）。
// 由 seamless_promote_anchor_test.dart 执行，payload（kSeamlessChaptersInstallJs 的 JSON）经 stdin 送入。
//
// 根因：晋升（S.promote）在 preserveViewport 里移除被晋升的宿主、卸掉不再相邻的上上章宿主。
// 视口中心落在下一章章首标题上方的空白（宿主 padding / 标题 margin）时，旧 captureAnchor 的
// 兜底返回 body 的直接子元素——正是这个宿主本身；宿主被移除后 restoreAnchor 见锚点脱离
// 文档就不补偿，上上章的整段高度没补回来，scrollTop 被钳到文档尽头 = 刚晋升那章的章末。
//
// 真 Chrome 里装生产脚本（真 shadow DOM / 布局 / 滚动），fetch 与引擎是替身：活动章 2、
// 邻章 1 与 3 挂好后，把章 3 宿主顶端放到视口中心上方一点（中心落在章 3 标题上方的空白），
// 记下章 2 末段的位置，再按用户滚动晋升章 3。断言晋升发生、章 1 被卸载、章 2 末段在
// 视口里纹丝不动。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const CHAPTERS = 5;
const PARAS = 40;
const config = {
  seamlessChapters: true,
  seamlessChapterIndex: 2,
  seamlessChapterOrder: Array.from({ length: CHAPTERS }, (_, i) => ({ index: i, url: 'http://book.test/ch' + i + '.xhtml' })),
  navigationGeneration: 1,
};
// 章首标题上方留一大段外边距（真实 EPUB 的章首常见：标题样式 margin-top 若干 em）。
const CSS = 'p{margin:0;height:40px}h1{margin:200px 0 20px 0;height:40px;font-size:20px}';
const paras = (n) => Array.from({ length: PARAS }, (_, k) =>
  '<p' + (k === PARAS - 1 ? ' id="c' + n + '-last"' : '') + '>chapter ' + n + ' paragraph ' + k + '</p>').join('');
const chapterHtml = (n) => '<!doctype html><html><head><style>' + CSS + '</style></head>' +
  '<body class="ch' + n + '"><h1>Chapter ' + n + '</h1>' + paras(n) + '</body></html>';
const bodies = {};
for (let i = 0; i < CHAPTERS; i++) bodies['http://book.test/ch' + i + '.xhtml'] = chapterHtml(i);

const page = '<!doctype html><html><head><meta charset="utf-8">' +
  '<style>' + CSS + '</style>' +
  '<style id="fushi-reader-style">html,body{margin:0;padding:0}</style>' +
  '<script>' +
  'window.__bodies = ' + JSON.stringify(bodies) + ';' +
  'window.fetch = function(url) {' +
  '  var b = window.__bodies[url];' +
  '  return Promise.resolve(b === undefined ? new Response("", {status: 404}) : new Response(b, {status: 200}));' +
  '};' +
  'window.__events = [];' +
  'window.flutter_inappwebview = { callHandler: function() { window.__events.push(Array.prototype.slice.call(arguments)); return Promise.resolve(null); } };' +
  'window.fushiReader = {' +
  '  _reanchorPending: false,' +
  '  isVertical: function() { return false; },' +
  '  notifyRestoreComplete: function() {},' +
  '  claimBoundaryTurn: function() { return false; },' +
  '  chapterTurnEpoch: function() { return 0; },' +
  '  clearImageLateAnchor: function() {},' +
  '  _setRestoreCharAnchor: function() {},' +
  '  buildNodeOffsets: function() {}' +
  '};' +
  'window.__install = function(C) {' + scripts.seamless + '};' +
  '</script></head><body class="ch2"><h1>Chapter 2</h1>' + paras(2) + '</body></html>';

const driver = await launchChromeDriver();
try {
  const r = await driver.evalOnPage(page, `(async () => {
    window.__install(${JSON.stringify(config)});
    const S = window.__fushiSeamless;
    window.fushiReader.notifyRestoreComplete();
    for (let i = 0; i < 200; i++) {
      const m = S.mountedChapters();
      if (m.indexOf(1) >= 0 && m.indexOf(3) >= 0) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    const out = { mountedBefore: S.mountedChapters().slice().sort() };
    const host3 = Array.from(document.querySelectorAll('fushi-seamless-chapter'))
      .find((h) => h.getAttribute('data-chapter') === '3');
    const c = innerHeight / 2;
    // 章 3 宿主顶端放在视口中心上方 40px：中心落在宿主 padding 与标题 200px 外边距之内，
    // 已越过迟滞带（24px），下一次用户滚动求值就会晋升章 3。
    window.scrollBy(0, host3.getBoundingClientRect().top - (c - 40));
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    let hit = document.elementFromPoint(innerWidth / 2, c);
    if (hit && hit.shadowRoot) hit = hit.shadowRoot.elementFromPoint(innerWidth / 2, c) || hit;
    out.centerHit = hit ? (hit.localName + '.' + (hit.className || '')) : null;
    const mark = document.getElementById('c2-last');
    const before = mark.getBoundingClientRect().top;
    const scrollBefore = scrollY;
    document.dispatchEvent(new WheelEvent('wheel', { deltaY: 1, bubbles: true }));
    out.promoted = S.evaluate();
    out.active = S.activeChapter;
    out.mountedAfter = S.mountedChapters().slice().sort();
    out.markConnected = mark.isConnected;
    out.markDelta = mark.getBoundingClientRect().top - before;
    out.scrollDelta = scrollY - scrollBefore;
    out.events = window.__events.filter((e) => e[0] === 'onSeamlessChapterActivated');
    return out;
  })()`);
  const dump = JSON.stringify(r);
  assert.deepEqual(r.mountedBefore, [1, 3], 'neighbours 1 and 3 mounted around active chapter 2 ' + dump);
  assert.ok(/fushi-seamless-(body|html)|fushi-seamless-chapter/.test(String(r.centerHit)),
    'precondition: the viewport centre sits in blank space at the top of chapter 3, not on its text ' + dump);
  assert.equal(r.promoted, true, 'user scroll past the boundary promotes chapter 3 ' + dump);
  assert.equal(r.active, 3, dump);
  assert.deepEqual(r.events, [['onSeamlessChapterActivated', 3, 2, 1]], dump);
  assert.ok(r.mountedAfter.indexOf(1) < 0, 'chapter 1 above the viewport was unmounted in the same task ' + dump);
  assert.equal(r.markConnected, true, dump);
  assert.ok(Math.abs(r.markDelta) < 1,
    'promotion must keep the viewport still (the removed chapter 1 height is compensated), ' +
    'not clamp to the end of chapter 3 ' + dump);
  assert.ok(r.scrollDelta < 0, 'compensation scrolled back by the unmounted chapter height ' + dump);
  console.log('PASS seamless promote anchor');
} finally {
  driver.close();
}
