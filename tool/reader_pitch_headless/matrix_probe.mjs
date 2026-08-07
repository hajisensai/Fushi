import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import zlib from 'node:zlib'; import puppeteer from 'puppeteer-core';
const CHROME='C:/Program Files/Google/Chrome/Application/chrome.exe'; const W=1000,H=800;
const css=`html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--hoshi-image-max-width,${W-40}px);max-height:var(--hoshi-image-max-height,${H}px);width:auto;height:auto;break-inside:avoid;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;break-inside:avoid;} p{margin:0 0 1em 0;}`;
const paras=Array.from({length:60},(_,i)=>`<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');
function png(w,h){const raw=Buffer.alloc((w*3+1)*h);for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;raw[o]=136;raw[o+1]=136;raw[o+2]=136;}}const d=zlib.deflateSync(raw);const sig=Buffer.from([137,80,78,71,13,10,26,10]);const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=2;const crc=b=>{let c=~0;for(let i=0;i<b.length;i++){c^=b[i];for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c;};const ch=(t,dd)=>{const l=Buffer.alloc(4);l.writeUInt32BE(dd.length,0);const tt=Buffer.from(t);const cc=Buffer.alloc(4);cc.writeUInt32BE(crc(Buffer.concat([tt,dd]))>>>0,0);return Buffer.concat([l,tt,dd,cc]);};return Buffer.concat([sig,ch('IHDR',ih),ch('IDAT',d),ch('IEND',Buffer.alloc(0))]);}
const bigPng=png(300,520);
async function run(kind, dir, action){
  const shell=fs.readFileSync(path.join(os.tmpdir(),`hoshi_shell_${dir}.html`),'utf8');
  const lead = kind==='image' ? `<img id="lead" loading="lazy" src="https://fushi.local/lead.png" alt="">` : '';
  const full=`<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>${lead}\n${paras}\n${shell}</body></html>`;
  const b=await puppeteer.launch({executablePath:CHROME,headless:'new',args:['--no-sandbox']});const pg=await b.newPage();await pg.setViewport({width:W,height:H});
  let rel;const ready=new Promise(r=>rel=r);await pg.setRequestInterception(true);
  pg.on('request',async q=>{const u=q.url();if(u==='https://fushi.local/chapter')return q.respond({status:200,contentType:'text/html',body:full});if(u==='https://fushi.local/lead.png'){await ready;return q.respond({status:200,contentType:'image/png',body:bigPng});}if(u.startsWith('https://fushi.local'))return q.respond({status:404,body:''});return q.continue();});
  await pg.goto('https://fushi.local/chapter',{waitUntil:'load',timeout:8000}).catch(()=>{});
  await new Promise(r=>setTimeout(r,350)); if(kind==='image'){rel(); await new Promise(r=>setTimeout(r,700));}
  const before=await pg.evaluate(()=>{const r=window.fushiReader;const c=r.getScrollContext();return{scroll:r.getPagePosition(c),pageStep:c.pageSize};});
  const info=await pg.evaluate((action)=>{const r=window.fushiReader;const c=r.getScrollContext();const sb=r.getPagePosition(c);const fvco=r.getFirstVisibleCharOffset();
    if(action==='chromeInsets'){ r.setChromeInsets(0,60); }
    else if(action==='renavChar'){ r.restoreToCharOffset(fvco); }
    return {fvco, sb};}, action);
  await new Promise(r=>setTimeout(r,150));
  const after=await pg.evaluate(()=>{const r=window.fushiReader;const c=r.getScrollContext();return{scroll:r.getPagePosition(c),pageStep:c.pageSize};});
  await b.close();
  const jumped=Math.round((after.scroll-before.scroll)/before.pageStep);
  console.log(`${kind.padEnd(6)} ${dir} ${action.padEnd(12)} fvco=${String(info.fvco).padStart(4)} before=p${(before.scroll/before.pageStep).toFixed(1)} after=p${(after.scroll/after.pageStep).toFixed(1)} jumped=${jumped}${jumped!==0?'  <-- JUMP':''}`);
}
for(const kind of ['image','text']) for(const dir of ['fwd','bwd']) for(const action of ['chromeInsets','renavChar']) await run(kind,dir,action);
