// 路线图 m1（gap-readerjs1-3 / gap-readerjs2-2）：生产分页 shell + 光标脚本跑在真
// headless Chrome 里。
//
// 1. 分页「字符偏移 → 文本节点」、越界判据、扫描兜底走共享的章内文本索引：数值与旧的
//    逐节点 walk 逐点一致（横排 / 竖排、正文页 / 插图页），单次扫描兜底的几何查询是对数级，
//    页上校验不再建 walker，正文 DOM 变化同步失效索引。
// 2. 光标换行移动只对与视口相交的文本节点逐字量几何：落点与不做节点预筛时逐次一致，
//    一次移动的 getClientRects 次数远少于章内字数（旧实现每个字各量一次）。
// 3. HBK-AUDIT-023：整章只有一个不换段的长文本节点时，节点预筛挡不住（它总与视口相交），
//    逐字量几何须收窄到可见行盒：落点与整节点逐字扫描一致，一次移动的几何查询与页上字数
//    同量级，远少于该节点字数。
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const payload = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}

const PARAGRAPHS = 960;
const PIXEL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const BRIDGE = 'window.flutter_inappwebview={callHandler:function(){return Promise.resolve(null);}};';

// 一整段不换行的长文（单个文本节点跨很多页）。
const LONG_UNIT = 'これは改段のない長い章の本文で、行の幾何を検証するための文字列です。';
const LONG_REPEAT = 2400;

function page(writingMode, layout) {
  const paras = [];
  if (layout === 'long') paras.push(`<p>${LONG_UNIT.repeat(LONG_REPEAT)}</p>`);
  for (let i = 0; layout !== 'long' && i < PARAGRAPHS; i++) {
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
  return Object.assign({fails: fails, scanRects: scanRects, nodes: nodes, total: total}, caretMoves(fails, total));
})()`;

// 光标换行移动：落点与「每个与视口相交的节点都整节点逐字扫描」一致（参照实现
// = _visibleSpan 恒返回整节点），记录每次移动的 getClientRects 次数（新 / 参照）。
const caretMovesFn = `function caretMoves(fails, total) {
  var r = window.fushiReader, R = Range.prototype, orig = R.getClientRects;
  function goTo(f) {
    var m = r.buildPaginationMetrics(), ctx = r.getScrollContext();
    r.setPagePosition(ctx, Math.round((m.minScroll + (m.maxScroll - m.minScroll) * f) / ctx.pageSize) * ctx.pageSize);
  }
  var k = window.fushiCaret, moves = 0, caretRects = [], refRects = [];
  // 页上全部落点（含页首 / 页尾行）与整节点逐字扫描逐个一致：只比较移动结果覆盖不到
  // 首末行，_visibleSpan 的二分边界偏一行（漏掉页首 / 页尾的字）也会被这里抓到。
  function stopKey(p) { return p ? (p.el ? 'el' : r.countChars(p.node.textContent) + '/' + p.offset + '/' + p.node.textContent.slice(0, 8)) : 'null'; }
  function stopsAt(f) {
    goTo(f);
    var own = k._visibleSpan, got = k._collectVisibleStops(false), first = k._firstVisibleStop();
    var ref, refFirst;
    k._visibleSpan = function(node, text) { return {start: 0, end: text.length}; };
    try { ref = k._collectVisibleStops(false); refFirst = k._firstVisibleStop(); } finally { k._visibleSpan = own; }
    var same = got.length === ref.length && got.every(function(s, i) {
      return s.node === ref[i].node && s.offset === ref[i].offset && s.el === ref[i].el;
    });
    if (!ref.length) fails.push('no visible stops at ' + f);
    if (!same) fails.push('visible stops at ' + f + ': ' + got.length + ' vs whole-node ' + ref.length);
    if (!first || !refFirst || first.node !== refFirst.node || first.offset !== refFirst.offset) fails.push('first visible stop at ' + f + ': ' + stopKey(first) + ' vs ' + stopKey(refFirst));
  }
  [0, 0.4, 1].forEach(stopsAt);
  goTo(0.4);
  // 本页可落的字数（光标所在页的可见落点数）：几何查询的预期量级按它算，不按固定字数——
  // 一页装多少字随字体度量变（CI 的 Linux Chrome 与 Windows / macOS 字形宽度不同）。
  var pageStops = k._collectVisibleStops(false).length;
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
    var own = k._visibleSpan, n1 = 0;
    k._visibleSpan = function(node, text) { return {start: 0, end: text.length}; };
    R.getClientRects = function() { n1++; return orig.apply(this, arguments); };
    var refRes; try { refRes = k.move(dir); } finally { k._visibleSpan = own; R.getClientRects = orig; }
    refRects.push(n1);
    if (res.status !== refRes.status || k.node !== to.node || k.offset !== to.offset || k.el !== to.el) fails.push('caret ' + dir + '#' + s + ' ' + res.status + '/' + refRes.status);
    moves++;
  }
  var maxCaret = Math.max.apply(null, caretRects);
  // 旧实现每次移动对整章每个字各量一次（>= total 次）；现在每个文本节点量一次行盒，
  // 只有与视口相交的节点才逐字量。
  if (!(maxCaret < total / 2)) fails.push('caret geometry ' + maxCaret + ' per move for ' + total + ' chars');
  return {caretRects: caretRects, refRects: refRects, moves: moves, maxCaret: maxCaret, pageStops: pageStops};
}`;

// HBK-AUDIT-023：整章一个文本节点。每次移动的几何查询不超过页上字数的量级（一页约
// 千字，加二分探测的对数项）；整节点扫描（旧实现）是该节点的全部字数。
const longCheck = `(async () => {
  await document.fonts.ready;
  var fails = [], r = window.fushiReader, w = r.createWalker(), n, total = 0, nodes = 0;
  while ((n = w.nextNode())) { total += r.countChars(n.textContent); nodes++; }
  if (nodes !== 1) fails.push('long chapter has ' + nodes + ' text nodes');
  var res = caretMoves(fails, total);
  // 上限按本页落点数定（逐字量的只该是可见行盒里的字，外加两次二分各 ~log2(n) 次探测与行盒读取），
  // 不用「总字数 / 20」这种固定数：Linux CI 的 Chrome 字形更窄、一页装的字多，固定数在那里
  // 恒红（4426 > 3840），而按页算的量级关系各平台一致。另要求远少于整节点逐字扫描。
  var probes = 2 * Math.ceil(Math.log2(total + 1)) + 64;
  if (!(res.maxCaret <= 4 * res.pageStops + probes)) fails.push('long caret geometry ' + res.maxCaret + ' per move for ' + res.pageStops + ' on-page stops');
  if (!(res.maxCaret * 10 < Math.min.apply(null, res.refRects))) fails.push('long caret geometry ' + res.maxCaret + ' per move is not far below whole-node scan ' + Math.min.apply(null, res.refRects));
  return Object.assign({fails: fails, total: total}, res);
})()`;

// evalOnPage 只收表达式：把 caretMoves 声明包进一个立即调用的函数里。
function withCaretMoves(expr) {
  return `(function(){ ${caretMovesFn}
 return ${expr}; })()`;
}

const driver = await launchChromeDriver();
let failed = 0;
let cases = 0;
try {
  for (const mode of ['horizontal-tb', 'vertical-rl']) {
    const res = await driver.evalOnPage(page(mode, 'paras'), withCaretMoves(check));
    cases++;
    if (res.fails.length) {
      failed++;
      console.log(`FAIL ${mode}: ${res.fails.join('; ')}`);
    } else {
      console.log(`ok ${mode}: scan ${res.scanRects} geometry calls for ${res.nodes} text nodes; `
        + `caret ${res.caretRects.join('/')} per move over ${res.total} chars `
        + `(whole-node scan ${res.refRects.join('/')})`);
    }
  }
  for (const mode of ['horizontal-tb', 'vertical-rl']) {
    const res = await driver.evalOnPage(page(mode, 'long'), withCaretMoves(longCheck));
    cases++;
    if (res.fails.length) {
      failed++;
      console.log(`FAIL long ${mode}: ${res.fails.join('; ')} [caret ${res.caretRects.join('/')}, ${res.pageStops} on-page stops]`);
    } else {
      console.log(`ok long ${mode}: caret ${res.caretRects.join('/')} per move for ${res.pageStops} on-page stops over ${res.total} chars in one node `
        + `(whole-node scan ${res.refRects.join('/')})`);
    }
  }
} finally {
  await driver.close();
}
if (failed) process.exit(1);
console.log(`PASS ${cases} browser cases`);
