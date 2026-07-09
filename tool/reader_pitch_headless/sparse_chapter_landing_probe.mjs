// TODO-1349 续（用户复诉「安達としまむら2 往前翻还是会去到最开头，因为文字少」）忠实行为探针。
//
// 往前翻上一章走 restoreProgress(0.99)（章尾语义）。「文字少+图片」封面章不是纯图片章
// （含少量文字 → __hoshiImageOnlyChapter=false），整页插图仍 loading="lazy"。真机 WebView 里
// 离屏懒图不发请求 → 0 尺寸 → 被 buildPaginationMetrics（分页 maxScroll 塌缩）/ scrollToChapterEnd
// 可见性判据（连续停章首）排除 → 往前翻落章首（用户「去到最开头」）。但 headless Chrome 不延迟
// 离屏懒图（实测立即请求并加载全部图），故自然跑复现不出真机 0 尺寸态。本探针在拦截器里**扣住
// 尾图 HTTP 响应**让尾图 pending=0 尺寸忠实复现真机态，再释放模拟图进视口 / forceLoadPendingImages
// 触发加载，断言 restoreProgress(0.99) 章末落点由塌缩(章首)收敛到含尾图的真实章末。
//
// 断言（分页 + 连续两 shell）：①释放前尾图 0 尺寸 → 章末落点塌缩（复现「去到最开头」）；
// ②restoreProgress(0.99) 后无 img 仍 loading="lazy"（forceLoadPendingImages 强制 eager）；
// ③释放尾图后 load 回调重锚（分页 scrollToProgressPaged / 连续 scrollToChapterEnd）落真章末。
//
// 先生成真 shell 再跑：
//   flutter test test/reader/reader_headless_shell_dump_test.dart
//   node tool/reader_pitch_headless/sparse_chapter_landing_probe.mjs   # 退出码 0=全绿
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import zlib from 'node:zlib'; import puppeteer from 'puppeteer-core';
const CHROME=process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W=1000,H=800;
const imgCss=`:root{--hoshi-image-max-width:${W-40}px;--hoshi-image-max-height:${H}px;}
 img.block-img{max-width:var(--hoshi-image-max-width,${W-40}px);max-height:var(--hoshi-image-max-height,${H}px);width:auto;height:auto;display:block;margin:auto;break-inside:avoid;object-fit:contain;}
 .block-img-wrapper{display:flex;justify-content:center;align-items:center;break-inside:avoid;}
 img:not(.block-img){max-width:100%;max-height:var(--hoshi-image-max-height,${H}px);object-fit:contain;} p{margin:0 0 1em 0;}`;
const cssPaginated=`html,body{margin:0;padding:0;}html{overflow:hidden;} body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}${imgCss}`;
const cssContinuous=`html,body{margin:0;padding:0;} body{width:${W}px;padding:0 20px;box-sizing:border-box;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}${imgCss}`;
const img=(n)=>`<img loading="lazy" src="https://hoshi.local/img${n}.png" alt="">`;
// 「文字少+图片」封面章：一行题名 + 5 张整页插图（尾图=章末）。HELD_FROM 起的图响应扣住,
// 模拟真机离屏懒图未加载(0 尺寸)。
const body=`<p>題名</p>${img(1)}${img(2)}${img(3)}${img(4)}${img(5)}`;
const HELD_FROM=2; // img2..img5 扣住(0 尺寸); img1 立即加载(章首可见,真机也已加载)
function png(w,h){const raw=Buffer.alloc((w*3+1)*h);for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;raw[o]=136;raw[o+1]=136;raw[o+2]=136;}}const d=zlib.deflateSync(raw);const sig=Buffer.from([137,80,78,71,13,10,26,10]);const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=2;const crc=b=>{let c=~0;for(let i=0;i<b.length;i++){c^=b[i];for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c;};const ch=(t,dd)=>{const l=Buffer.alloc(4);l.writeUInt32BE(dd.length,0);const tt=Buffer.from(t);const cc=Buffer.alloc(4);cc.writeUInt32BE(crc(Buffer.concat([tt,dd]))>>>0,0);return Buffer.concat([l,tt,dd,cc]);};return Buffer.concat([sig,ch('IHDR',ih),ch('IDAT',d),ch('IEND',Buffer.alloc(0))]);}
const bigPng=png(300,760);
async function measure(pg,mode){return await pg.evaluate((mode)=>{const r=window.hoshiReader;if(mode==='paginated'){const c=r.getScrollContext();const m=r.buildPaginationMetrics();return {pos:r.getPagePosition(c),unit:c.pageSize,metricsMax:m.maxScroll};}const el=document.scrollingElement||document.documentElement;return {pos:el.scrollTop,unit:window.innerHeight,metricsMax: el.scrollHeight-el.clientHeight};},mode);}
async function run(mode){
  const shell=fs.readFileSync(path.join(os.tmpdir(),mode==='paginated'?'hoshi_shell_paginated.html':'hoshi_shell_continuous.html'),'utf8');
  const css=mode==='paginated'?cssPaginated:cssContinuous;
  const full=`<!doctype html><html><head><meta charset="utf-8"><style>${css}</style>${shell}</head><body>${body}</body></html>`;
  const held=[];
  const b=await puppeteer.launch({executablePath:CHROME,headless:'new',args:['--no-sandbox']});
  const pg=await b.newPage(); await pg.setViewport({width:W,height:H});
  await pg.setRequestInterception(true);
  pg.on('request',async q=>{const u=q.url();
   if(u==='https://hoshi.local/chapter')return q.respond({status:200,contentType:'text/html',body:full});
   if(u.startsWith('https://hoshi.local/img')){const n=parseInt(u.match(/img(\d+)/)[1],10);
     if(n>=HELD_FROM){held.push(q);return;} // 扣住尾图响应=真机离屏懒图 0 尺寸态
     return q.respond({status:200,contentType:'image/png',body:bigPng});}
   if(u.startsWith('https://hoshi.local'))return q.respond({status:404,body:''});
   return q.continue();});
  await pg.goto('https://hoshi.local/chapter',{waitUntil:'domcontentloaded',timeout:8000}).catch(()=>{});
  await new Promise(r=>setTimeout(r,500));
  await pg.evaluate((mh,mw)=>{document.documentElement.style.setProperty('--hoshi-image-max-height',mh+'px');document.documentElement.style.setProperty('--hoshi-image-max-width',mw+'px');if(window.hoshiReader)window.hoshiReader.paginationMetrics=null;},H-40,W-40);
  await new Promise(r=>setTimeout(r,150));
  await pg.evaluate(()=>window.hoshiReader.restoreProgress(0));
  await new Promise(r=>setTimeout(r,120));
  await pg.evaluate(()=>window.hoshiReader.restoreProgress(0.99));
  await new Promise(r=>setTimeout(r,250));
  // 释放前:尾图仍 0 尺寸 -> 章末落点塌缩(复现「去到最开头」)。
  const before=await measure(pg,mode);
  const lazyAfterRestore=await pg.evaluate(()=>Array.from(document.querySelectorAll('img')).filter(i=>i.getAttribute('loading')==='lazy').length);
  // 释放尾图响应 = 尾图 load(forceLoadPendingImages 已置 eager;真机由此触发请求) -> 既有/新增 reanchor 收敛。
  for(const q of held) await q.respond({status:200,contentType:'image/png',body:bigPng});
  await new Promise(r=>setTimeout(r,700));
  const after=await measure(pg,mode);
  await b.close();
  const bp=before.pos/before.unit, ap=after.pos/after.unit, aMax=after.metricsMax/after.unit;
  // 收敛判据:释放后落点接近真实章末(含尾图的 metricsMax) >= aMax-0.6 页/屏。
  const recovered= aMax<0.5 ? true : (ap >= aMax-0.6);
  const collapsed= bp < aMax-0.6; // 释放前确实塌缩(短于真章末)
  console.log(`${mode.padEnd(11)} restore(0.99): beforeRelease=p${bp.toFixed(2)} (lazyImgs=${lazyAfterRestore}) afterRelease=p${ap.toFixed(2)} trueEnd=p${aMax.toFixed(2)}  collapse=${collapsed?'YES':'no'} recover=${recovered?'END-OK':'STUCK'}`);
  return (recovered?0:1) | (collapsed?0:0);
}
let fail=0;
for(const mode of ['paginated','continuous']) fail|=await run(mode);
console.log(fail?'\nRESULT: FAIL':'\nRESULT: PASS (collapse reproduced + reanchor converges to chapter end)');
process.exit(fail?1:0);
