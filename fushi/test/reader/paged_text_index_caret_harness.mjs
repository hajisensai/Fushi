// 路线图 m1（gap-readerjs1-3 / gap-readerjs2-2）：生产分页 shell + 光标脚本跑在真
// headless Chrome 里。
//
// 1. 分页「字符偏移 → 文本节点」、越界判据、扫描兜底走共享的章内文本索引：数值与旧的
//    逐节点 walk 逐点一致（横排 / 竖排、正文页 / 插图页），单次扫描兜底的几何查询是对数级，
//    页上校验不再建 walker，正文 DOM 变化同步失效索引。
// 2. 光标换行移动只对与视口相交的文本节点逐字量几何：落点与不做节点预筛时逐次一致，
//    一次移动的 getClientRects 次数远少于章内字数（旧实现每个字各量一次）。
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './vn_shell_harness_support.mjs';

const payload = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}

const PARAGRAPHS = 960;
const PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const BRIDGE = 'window.flutter_inappwebview={callHandler:function(){return Promise.resolve(null);}};';

function page(writingMode) {
  const paras = [];
  for (let i = 0; i < PARAGRAPHS; i++) {
    if (i === PARAGRAPHS / 2) paras.push(`<p id="fig"><img src="${PIXEL}" width="400" height="600" alt=""></p>`);
    paras.push(`<p>P${i} これは<ruby>試験<rt>しけん</rt></ruby>本文です。<ruby>頁<rt>ぺーじ</rt></ruby>`
      + 'の幾何を<span>検証</span>するための十分な長さのダミーテキストを並べています。'
      + `「会話文の例です」と<ruby>彼<rt>かれ</rt></ruby>は言った。</p>`);
  }
  const config = Object.assign({}, payload.config, { initialProgress: 0 });
  // 脚本全放 head、DOMContentLoaded 后再装：body 里不留 <script> 文本节点，章内字数只数正文。
  return '<!doctype html><html><head><meta charset="utf-8">'
    + `<style>${payload.css[writingMode]}</style><script>${BRIDGE}</script>${payload.engine}`
    + `<script>${payload.caret}\ndocument.addEventListener('DOMContentLoaded', function() {`
    + `window.__fushiInstallShell(${JSON.stringify(config)});`
    + 'window.fushiCaret.init({color:"#000",insetTop:0,insetBottom:0,scopeSelector:null});});</script>'
    + `</head><body>${paras.join('\n')}</body></html>`;
}

// 在页内执行。参照实现 = 改动前的逐节点 walk。
const check = `(async () => {
  await document.fonts.ready;
  await Promise.all(Array.from(document.images, function(i) { return i.decode().catch(function() {}); }));
  var r = window.fushiReader;
  var fails = [];
  function refScan() {
    var axis = r.pagedAxis(), edge = r.pagedFirstEdge(axis), w = r.createWalker(), n, sum = 0;
    while ((n = w.nextNode())) if (r.countChars(n.textContent) > 0) sum += r.countCharsBeforeViewportPaged(n, axis, edge);
    return sum;
  }
  function refLocate(off) {
    var w = r.createWalker(), run = 0, n;
    while ((n = w.nextNode())) { var c = r.countChars(n.textContent); if (run + c > off) return {node: n, remaining: off - run}; run += c; }
    return null;
  }
  function sameLocate(a, b) { return (!a && !b) || (a && b && a.node === b.node && a.remaining === b.remaining); }
  function goTo(f) {
    var m = r.buildPaginationMetrics(), ctx = r.getScrollContext();
    r.setPagePosition(ctx, Math.round((m.minScroll + (m.maxScroll - m.minScroll) * f) / ctx.pageSize) * ctx.pageSize);
  }
  function goToFigure() {
    var ctx = r.getScrollContext(), fig = document.getElementById('fig');
    var at = r.getPagePosition(ctx) + r.turnSpan(ctx.axis, fig.getBoundingClientRect()).start;
    r.setPagePosition(ctx, Math.floor(at / ctx.pageSize) * ctx.pageSize);
  }
  var total = refLocate(0) ? (function(){ var w = r.createWalker(), n, t = 0; while ((n = w.nextNode())) t += r.countChars(n.textContent); return t; })() : 0;
  // 负偏移：旧 walk 会返回首个节点 + 负的 remaining（调用方都先拦掉负数，从不传）；
  // 索引版明确返回 null。
  if (r.textNodeAtCharOffset(-1) !== null) fails.push('locate@-1 not null');
  [-1, 0, 1, 7, Math.floor(total / 3), Math.floor(total / 2), total - 1, total, total + 5].forEach(function(off) {
    if (off >= 0 && !sameLocate(r.textNodeAtCharOffset(off), refLocate(off))) fails.push('locate@' + off);
    if (r.charOffsetInRange(off) !== (off >= 0 && off < total)) fails.push('inRange@' + off);
  });
  var positions = [0, 0.3, 0.77, 1, 'figure'];
  for (var i = 0; i < positions.length; i++) {
    if (positions[i] === 'figure') goToFigure(); else goTo(positions[i]);
    var got = r.firstVisibleCharOffsetByScanPaged(), want = refScan();
    if (got !== want) fails.push('scan@' + positions[i] + ' ' + got + ' != ' + want);
  }
  // 单次扫描兜底的几何查询是对数级；页上校验不再建 walker。
  goTo(0.5);
  r.firstVisibleCharOffsetByScanPaged();
  var pageStart = r.getFirstVisibleCharOffset();
  var R = Range.prototype, orig = R.getClientRects, rects = 0;
  R.getClientRects = function() { rects++; return orig.apply(this, arguments); };
  var origWalker = r.createWalker, walkers = 0;
  r.createWalker = function() { walkers++; return origWalker.apply(this, arguments); };
  var nodes = 0;
  try {
    r.firstVisibleCharOffsetByScanPaged();
    var scanRects = rects;
    r.charOffsetOnCurrentPage(pageStart);
    if (walkers !== 0) fails.push('page check built ' + walkers + ' walkers');
  } finally {
    R.getClientRects = orig;
    r.createWalker = origWalker;
  }
  (function(){ var w = r.createWalker(); while (w.nextNode()) nodes++; })();
  if (!(scanRects < 200)) fails.push('scan geometry ' + scanRects + ' for ' + nodes + ' text nodes');
  // 正文 DOM 变化同步失效索引。
  var extra = document.createElement('span');
  extra.textContent = '追加';
  document.body.insertBefore(extra, document.body.firstChild);
  var after = total + r.countChars('追加');
  if (r.charOffsetInRange(after - 1) !== true || r.charOffsetInRange(after) !== false) fails.push('mutation range');
  if (!sameLocate(r.textNodeAtCharOffset(0), {node: extra.firstChild, remaining: 0})) fails.push('mutation locate');
  extra.remove();

  // 光标：换行移动的落点与不做节点预筛时一致，几何查询远少于章内字数。
  var k = window.fushiCaret, moves = 0, caretRects = [];
  goTo(0.4);
  k.enter();
  var dirs = r.isVertical() ? ['left', 'right'] : ['down', 'up'];
  for (var s = 0; s < 6; s++) {
    var dir = s < 4 ? dirs[0] : dirs[1];
    var from = {node: k.node, offset: k.offset, el: k.el};
    var n0 = 0; R.getClientRects = function() { n0++; return orig.apply(this, arguments); };
    var res; try { res = k.move(dir); } finally { R.getClientRects = orig; }
    caretRects.push(n0);
    var to = {node: k.node, offset: k.offset, el: k.el};
    k.node = from.node; k.offset = from.offset; k.el = from.el;
    var own = k._nodeTouchesViewport;
    k._nodeTouchesViewport = function() { return true; };
    var refRes; try { refRes = k.move(dir); } finally { k._nodeTouchesViewport = own; }
    if (res.status !== refRes.status || k.node !== to.node || k.offset !== to.offset || k.el !== to.el) fails.push('caret ' + dir + '#' + s + ' ' + res.status + '/' + refRes.status);
    moves++;
  }
  var maxCaret = Math.max.apply(null, caretRects);
  // 旧实现每次移动对整章每个字各量一次（>= total 次）；现在每个文本节点量一次行盒，
  // 只有与视口相交的节点才逐字量。
  if (!(maxCaret < total / 2)) fails.push('caret geometry ' + maxCaret + ' per move for ' + total + ' chars');
  return {fails: fails, scanRects: scanRects, nodes: nodes, total: total, caretRects: caretRects, moves: moves};
})()`;

const driver = await launchChromeDriver();
let failed = 0;
let cases = 0;
try {
  for (const mode of ['horizontal-tb', 'vertical-rl']) {
    const res = await driver.evalOnPage(page(mode), check);
    cases++;
    if (res.fails.length) {
      failed++;
      console.log(`FAIL ${mode}: ${res.fails.join('; ')}`);
    } else {
      console.log(`ok ${mode}: scan ${res.scanRects} geometry calls for ${res.nodes} text nodes; `
        + `caret ${res.caretRects.join('/')} per move over ${res.total} chars`);
    }
  }
} finally {
  await driver.close();
}
if (failed) process.exit(1);
console.log(`PASS ${cases} browser cases`);
