// TODO-1285 图片多列适配守卫 —— headless Chrome (= Android WebView / WebView2 同一
// Blink) 实测「每页多列(pageColumns>=2)时整页插图**收进本列**、不溢出盖住相邻列正文」，
// 并断言宽高比不被破坏（不挤压）。复刻 reader_content_styles.dart 的真实分页多列几何 +
// reader_pagination_scripts.dart `fushiReader._imageMaxBox` 的子列夹取逻辑（turn 轴图片
// max = used 子列 columnWidth）。同时跑「旧全整-content-box 逻辑」对照证明守卫有牙齿：
// 旧逻辑下宽插图溢出子列 → FAIL，新逻辑 → PASS。
//
// 用法：node image_multicol_fit_probe.mjs   (0=PASS, 1=FAIL, 2=NO_CHROME)
import { launchChromeDriver, resolveChrome } from './cdp_client.mjs';

const VW = 1000, VH = 800, ML = 20, MR = 20, MT = 0, MB = 0, FONT = 22, GAP = 22, RATIO = 0.95;

// 与 ReaderContentStyles.columnWidthForColumns 逐字节同构。
function subColWidthCss(baseCss, N) {
  if (N <= 1) return baseCss;
  const totalGap = (N - 1) * GAP;
  return `max(1px, calc((${baseCss} - ${totalGap}px) / ${N}))`;
}
function img(w, h, color) {
  return 'data:image/svg+xml;utf8,' + encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${color}"/></svg>`);
}

// legacy=true 复刻旧 bug 逻辑（整 content-box），false 复刻 _imageMaxBox（子列夹取）。
function imageSetupScript(legacy) {
  return `
  (function(){
    var body=document.body, cs=getComputedStyle(body);
    var pl=parseFloat(cs.paddingLeft)||0, pr=parseFloat(cs.paddingRight)||0;
    var pt=parseFloat(cs.paddingTop)||0, pb=parseFloat(cs.paddingBottom)||0;
    var w=(body.clientWidth||innerWidth)-pl-pr, h=(body.clientHeight||innerHeight)-pt-pb;
    var vertical=cs.writingMode==='vertical-rl';
    var maxW, maxH;
    if(${legacy}){
      maxW=Math.max(1,Math.floor(w*${RATIO})); maxH=Math.max(1,h);
    } else {
      var turnFull=vertical?h:w;
      var usedColW=parseFloat(cs.columnWidth);
      var multicol=usedColW>0 && usedColW<turnFull-1;
      if(vertical){ maxH=Math.max(1, multicol?Math.round(usedColW):h); maxW=Math.max(1,Math.floor(w*${RATIO})); }
      else { maxW=Math.max(1,Math.floor((multicol?usedColW:w)*${RATIO})); maxH=Math.max(1,h); }
    }
    var root=document.documentElement;
    root.style.setProperty('--fushi-image-max-width', maxW+'px');
    root.style.setProperty('--fushi-image-max-height', maxH+'px');
  })();`;
}

function buildHtml(mode, N, imgSrc, legacy) {
  const isVertical = mode.startsWith('vertical');
  const baseCss = isVertical
    ? `max(${FONT}px, calc(${VH}px - ${MT}px - ${MB}px - ${FONT}px))`
    : `calc(${VW}px - ${ML}px - ${MR}px)`;
  const colWCss = subColWidthCss(baseCss, N);
  const columnsCss = N > 0 ? `column-count:${N} !important;` : '';
  return `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:#fff;color:#000;}
html{width:${VW}px;height:${VH}px;overflow:hidden;}
body{box-sizing:border-box;font-size:${FONT}px;line-height:1.8;width:${VW}px;height:${VH}px;writing-mode:${mode} !important;
  column-width:${colWCss} !important;${columnsCss}column-fill:auto !important;column-gap:${GAP}px !important;
  padding-top:${MT}px !important;padding-right:${MR}px !important;padding-bottom:${MB + FONT}px !important;padding-left:${ML}px !important;overflow:hidden;}
img.block-img{max-width:var(--fushi-image-max-width) !important;max-height:var(--fushi-image-max-height) !important;
  width:auto !important;height:auto !important;display:block !important;margin:auto !important;
  break-inside:avoid !important;object-fit:contain !important;}
.block-img-wrapper{display:flex !important;justify-content:center !important;align-items:center !important;break-inside:avoid !important;}
</style></head><body><div class="block-img-wrapper"><img class="block-img" src="${imgSrc}"></div>
<script>${imageSetupScript(legacy)}</script></body></html>`;
}

function measureExpr(isVertical, N) {
  // 子列 turn 轴范围：横排=宽、竖排=高。图片 turn 轴渲染尺寸须 <= 子列 turn 范围（不溢出）。
  const fullBoxW = VW - ML - MR;
  const fullBoxH = VH - MT - MB - FONT;
  const subTurn = N > 1
    ? (isVertical ? (fullBoxH - (N - 1) * GAP) / N : (fullBoxW - (N - 1) * GAP) / N)
    : (isVertical ? fullBoxH : fullBoxW);
  return `(function(){
    var img=document.querySelector('img.block-img'); var r=img.getBoundingClientRect();
    var turn = ${isVertical} ? r.height : r.width;
    return { w:r.width, h:r.height, natW:img.naturalWidth, natH:img.naturalHeight, turn:turn, subTurn:${subTurn} };
  })()`;
}

async function main() {
  if (!resolveChrome()) { console.log('NO_CHROME (set CHROME_PATH)'); process.exit(2); }
  const driver = await launchChromeDriver();
  let failed = 0;
  const imgs = [['portrait', img(800, 1200, '#c00'), 800 / 1200], ['landscape', img(1200, 500, '#06c'), 1200 / 500]];
  const cases = [];
  for (const mode of ['horizontal-tb', 'vertical-rl'])
    for (const N of [0, 1, 2, 3])
      for (const [iname, isrc, iaspect] of imgs)
        cases.push({ mode, N, iname, isrc, iaspect });
  try {
    // 主验证：新 _imageMaxBox 逻辑 → 图片收进子列 + 宽高比保持。
    for (const c of cases) {
      const isVertical = c.mode.startsWith('vertical');
      const res = await driver.evalOnPage(buildHtml(c.mode, c.N, c.isrc, false), measureExpr(isVertical, c.N));
      const aspect = res.w / res.h;
      const aspectErr = Math.abs(aspect - c.iaspect) / c.iaspect;
      const fits = res.turn <= res.subTurn + 2; // 2px 容差
      const ok = aspectErr <= 0.05 && fits;
      if (!ok) failed++;
      console.log(`${ok ? 'PASS' : 'FAIL'} [fix] ${c.mode} N=${c.N} ${c.iname} => ${res.w.toFixed(0)}x${res.h.toFixed(0)} ` +
        `turn=${res.turn.toFixed(0)}<=sub=${res.subTurn.toFixed(0)}?${fits} aspectErr=${(aspectErr * 100).toFixed(1)}%`);
    }
    // 牙齿对照：旧整-content-box 逻辑在多列(N>=2)宽插图**必溢出**子列（turn>subTurn）。
    let toothSeen = false;
    for (const mode of ['horizontal-tb', 'vertical-rl']) {
      const isVertical = mode.startsWith('vertical');
      const wide = isVertical ? img(500, 1200, '#093') : img(1200, 500, '#093'); // turn 轴长的插图
      const res = await driver.evalOnPage(buildHtml(mode, 2, wide, true), measureExpr(isVertical, 2));
      const overflow = res.turn > res.subTurn + 2;
      if (overflow) toothSeen = true;
      console.log(`${overflow ? 'TOOTH-OK' : 'TOOTH-MISS'} [legacy] ${mode} N=2 => turn=${res.turn.toFixed(0)} sub=${res.subTurn.toFixed(0)} overflow=${overflow}`);
    }
    if (!toothSeen) { console.log('\nFAIL: 牙齿对照未触发（旧逻辑应溢出，探针失效）'); failed++; }
    driver.close();
    if (failed > 0) { console.log(`\nFAIL: ${failed} case(s) — 图片在多列布局挤压/溢出（TODO-1285）`); process.exit(1); }
    console.log('\nPASS: 所有列数×朝向×朝向插图 图片收进子列且宽高比保持（TODO-1285）');
    process.exit(0);
  } catch (e) { console.log('ERR', e.stack || e.message); try { driver.close(); } catch (_) {} process.exit(3); }
}
main();
