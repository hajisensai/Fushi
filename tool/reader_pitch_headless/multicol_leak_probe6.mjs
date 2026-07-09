// TODO-1285 probe6: CSS column count via coverage-gap detection.
// Within a column, glyph lefts are dense (~charWidth apart). Between columns is
// the column-gap (no glyphs). Column boundary = a jump between consecutive
// distinct glyph-lefts larger than ~1.4*charWidth. #columns = #boundaries+1.
import { launchChromeDriver, resolveChrome } from './cdp_client.mjs';

function buildHtml({ viewportWidth, marginPx, gapPx, fontPx, pageColumns, variant }) {
  const contentBoxCss = `calc(var(--page-width) - ${marginPx}px - ${marginPx}px)`;
  const subWCss = `max(1px, calc((${contentBoxCss} - ${(pageColumns - 1) * gapPx}px) / ${pageColumns}))`;
  let colWidthCss, columnsCss;
  if (variant === 'both') { colWidthCss = `column-width:${subWCss} !important;`; columnsCss = `column-count:${pageColumns} !important;`; }
  else if (variant === 'width') { colWidthCss = `column-width:${subWCss} !important;`; columnsCss = ''; }
  else { colWidthCss = ''; columnsCss = `column-count:${pageColumns} !important;`; }
  const lots = '日本語のテキストです。'.repeat(4000);
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;} :root{--page-width:${viewportWidth}px;}
  html{width:${viewportWidth}px;height:700px;overflow:hidden;}
  body{width:${viewportWidth}px;height:700px;box-sizing:border-box;font-size:${fontPx}px;line-height:1.8;
  ${colWidthCss}${columnsCss}column-gap:${gapPx}px !important;
  padding-left:${marginPx}px !important;padding-right:${marginPx}px !important;padding-top:0 !important;padding-bottom:0 !important;
  overflow:hidden;writing-mode:horizontal-tb;}
  </style></head><body>${lots}</body></html>`;
}

const EXPR = `
(function(){
  var el=document.body, cs=getComputedStyle(el);
  var pl=parseFloat(cs.paddingLeft)||0, prr=parseFloat(cs.paddingRight)||0, gap=parseFloat(cs.columnGap)||0;
  var subW=parseFloat(cs.columnWidth); var ccReadback=cs.columnCount;
  var fs=parseFloat(cs.fontSize)||20;
  var fullBox=el.getBoundingClientRect().width-pl-prr;
  el.scrollLeft=0;
  var walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null),node;
  var present={}; var seen=0, max=120000;
  while((node=walker.nextNode())&&seen<max){
    var len=node.textContent.length;
    for(var k=0;k<len&&seen<max;k++){
      var rg=document.createRange();rg.setStart(node,k);rg.setEnd(node,k+1);
      var rc=rg.getClientRects();if(!rc.length)continue;seen++;
      present[Math.round(rc[0].left)]=1;
    }
  }
  var lefts=Object.keys(present).map(Number).sort(function(a,b){return a-b;});
  // Column left edges: first left, plus every left preceded by a jump > 1.4*fs.
  var jumpThr=fs*1.4;
  var colEdges=[];
  for(var i=0;i<lefts.length;i++){ if(i===0||lefts[i]-lefts[i-1]>jumpThr) colEdges.push(lefts[i]); }
  var edgesInBox=colEdges.filter(function(e){return e>=pl-1 && e<pl+fullBox-1;});
  var diffs=[]; for(var i=1;i<Math.min(colEdges.length,8);i++) diffs.push(colEdges[i]-colEdges[i-1]);
  diffs.sort(function(a,b){return a-b;});
  var realPitch=diffs.length?Math.round(diffs[Math.floor(diffs.length/2)]*100)/100:null;
  return {pl:pl,gap:gap,subW:subW,ccReadback:ccReadback,fullBox:Math.round(fullBox*100)/100,fs:fs,
    dpr:window.devicePixelRatio, realPitch:realPitch, nominalPitch:(subW>0?subW:fullBox)+gap,
    countInBox:edgesInBox.length,
    edgesInBox:edgesInBox, first6:colEdges.slice(0,6), boxRight:Math.round((pl+fullBox)*10)/10};
})()
`.trim();

async function main(){
  if(!resolveChrome()){ console.log('NO_CHROME'); process.exit(2); }
  const driver=await launchChromeDriver();
  try{
    for(const variant of ['both','width','count']){
      for(const N of [2,3]){
        const html=buildHtml({viewportWidth:412.36,marginPx:16,gapPx:20,fontPx:20,pageColumns:N,variant});
        const m=await driver.evalOnPage(html, EXPR);
        const leak = m.countInBox>N, fewer=m.countInBox<N;
        console.log(`variant=${variant.padEnd(5)} N=${N}: colsInBox=${m.countInBox} (want ${N}) realPitch=${m.realPitch} nominalPitch=${Math.round(m.nominalPitch*100)/100} subW=${m.subW} cc=${m.ccReadback}`+
          `${leak?'  >>> LEAK':(fewer?'  << fewer':'  OK')}`);
        console.log(`        edgesInBox=${JSON.stringify(m.edgesInBox)} first6=${JSON.stringify(m.first6)} boxRight=${m.boxRight}`);
      }
    }
    driver.close(); process.exit(0);
  }catch(e){ console.log('ERR',e.message); try{driver.close();}catch(_){} process.exit(3); }
}
main();
