// TODO-1285 每页列数（pageColumns）真实渲染守卫 —— headless Chrome (= Android
// System WebView / Windows WebView2 的同一 Blink 引擎) 实测「改 N 真的每屏渲染 N
// 列」，横排 (horizontal-tb) 与竖排 (vertical-rl) 都验。
//
// 为什么需要它：`hibiki/test/reader/reader_content_styles_test.dart` 的 TODO-1285
// 守卫是**纯字符串断言**（`css` 里含 `column-count: N` + 子列宽表达式），结构上
// **测不出**浏览器 multicol 是否真把内容排成每屏 N 列——尤其竖排 multicol 的列沿
// inline 轴（vertical-rl = 自上而下 Y 轴）推进，语义与横排（沿 X 轴）不同，字符串
// 断言无法揭示。本探针复刻 `reader_content_styles.dart` 的真实几何
// （`ReaderContentStyles.columnWidthForColumns` 的子列宽 + column-count:N +
// column-fill:auto + column-gap + writing-mode + padding），把正文逐字符包 <span>，
// 量每个 multicol 列首字符的坐标，数出「第一屏内的列数」，断言 == N。
//
// 用法（本机；CI 跑不到真 WebView）：
//   cd tool/reader_pitch_headless
//   node columns_per_page_proof.mjs      # 退出码 0=PASS 1=FAIL 2=NO_CHROME
//
// 断言：横排/竖排下 pageColumns=1→每屏 1 列、=2→2 列、=3→3 列（=0 自动等价 1 列）。
import { launchChromeDriver, resolveChrome } from './cdp_client.mjs';

const VW = 1000;
const VH = 800;
const ML = 20;
const MR = 20;
const MT = 0;
const MB = 0;
const FONT = 22;
const GAP = 22;

// 与 ReaderContentStyles.columnWidthForColumns 逐字节同构（单一真相：改那边这里跟）。
function subColWidthCss(baseCss, N) {
  if (N <= 1) return baseCss;
  const totalGap = (N - 1) * GAP;
  return `max(1px, calc((${baseCss} - ${totalGap}px) / ${N}))`;
}

function buildHtml(mode, N) {
  const isVertical = mode.startsWith('vertical');
  // 单列 content-box 基准（turn/inline 轴）：竖排=高、横排=宽，镜像 reader_content_styles。
  const baseCss = isVertical
    ? `max(${FONT}px, calc(${VH}px - ${MT}px - ${MB}px - ${FONT}px))`
    : `calc(${VW}px - ${ML}px - ${MR}px)`;
  const colWCss = subColWidthCss(baseCss, N);
  const columnsCss = N > 0 ? `column-count:${N} !important;` : '';
  const text = '日本語のテキストサンプル。'.repeat(120);
  const spans = Array.from(text).map((c) => `<span>${c}</span>`).join('');
  return `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:#fff;color:#000;}
html{width:${VW}px;height:${VH}px;overflow:hidden;}
body{
  box-sizing:border-box; font-size:${FONT}px; line-height:1.8;
  width:${VW}px; height:${VH}px;
  writing-mode:${mode} !important;
  column-width:${colWCss} !important;
  ${columnsCss}
  column-fill:auto !important;
  column-gap:${GAP}px !important;
  padding:${MT}px ${MR}px ${MB}px ${ML}px !important;
  overflow:hidden;
}
</style></head><body>${spans}</body></html>`;
}

// 数第一屏内的 multicol 列数：走 <span>，每检测到列首/行首就记一条候选列首坐标，
// 再按「推进轴」（竖排=top/Y、横排=left/X）分桶去重，数落在第一屏内的桶数。
function measureExpr(isVertical) {
  const advanceExtent = isVertical ? VH : VW;
  return `(function(){
    var spans=[].slice.call(document.querySelectorAll('span'));
    var starts=[]; var prev=null;
    for(var i=0;i<spans.length;i++){
      var r=spans[i].getBoundingClientRect();
      if(r.width===0&&r.height===0) continue;
      if(prev===null){ starts.push({left:r.left,top:r.top}); prev=r; continue; }
      var topReset = r.top < prev.top - ${FONT};
      var leftReset = Math.abs(r.left - prev.left) > ${FONT}*2;
      if(topReset || leftReset){ starts.push({left:r.left,top:r.top}); }
      prev=r;
    }
    // 推进轴分桶（8px 容差）去重。
    var advance = ${isVertical} ? function(s){return s.top;} : function(s){return s.left;};
    var buckets={};
    starts.forEach(function(s){ buckets[Math.round(advance(s)/8)*8]=1; });
    var coords=Object.keys(buckets).map(Number).sort(function(a,b){return a-b;});
    // 第一屏 = 推进坐标 < 视口推进范围（减一个字号裕度，排除紧贴下/右缘的下一页列首）。
    var inFirstPage=coords.filter(function(c){return c >= -4 && c < ${advanceExtent} - ${FONT};});
    return { columnsPerPage: inFirstPage.length, firstPageStarts: inFirstPage,
             usedColumnCount: getComputedStyle(document.body).columnCount };
  })()`;
}

async function main() {
  if (!resolveChrome()) { console.log('NO_CHROME (set CHROME_PATH)'); process.exit(2); }
  const driver = await launchChromeDriver();
  let failed = 0;
  const cases = [];
  for (const mode of ['horizontal-tb', 'vertical-rl']) {
    for (const N of [0, 1, 2, 3]) cases.push({ mode, N });
  }
  try {
    for (const c of cases) {
      const isVertical = c.mode.startsWith('vertical');
      const html = buildHtml(c.mode, c.N);
      const res = await driver.evalOnPage(html, measureExpr(isVertical));
      const expected = c.N <= 1 ? 1 : c.N; // 0=自动/单列 == 1 列
      const ok = res.columnsPerPage === expected;
      if (!ok) failed++;
      console.log(
        `${ok ? 'PASS' : 'FAIL'} mode=${c.mode} pageColumns=${c.N} ` +
        `=> columnsPerPage=${res.columnsPerPage} (expected ${expected}) ` +
        `usedColumnCount=${res.usedColumnCount} starts=[${res.firstPageStarts.map(Math.round).join(',')}]`);
    }
    driver.close();
    if (failed > 0) {
      console.log(`\nFAIL: ${failed} case(s) — 每页列数未按 N 渲染（TODO-1285 回归）`);
      process.exit(1);
    }
    console.log('\nPASS: 横排+竖排 pageColumns=N 均真实渲染 N 列/屏（TODO-1285）');
    process.exit(0);
  } catch (e) {
    console.log('ERR', e.stack || e.message);
    try { driver.close(); } catch (_) {}
    process.exit(3);
  }
}
main();
