// TODO-1229 第 6 次复诉复现：章首带扉页插图的章，初始 restore 落插图页正确后，
// 一个「重锚」（setChromeInsets / uiscale / style）以 getFirstVisibleCharOffset()==0
// 走裸 scrollToCharOffset(0) → 滚到首个文本字符（跳过前导插图）= 残留第二跳。
//
// 先生成真 shell（CI 跑不到真 WebView，本探针本机跑）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写 shell 到 systemTemp
//   node tool/reader_pitch_headless/chapter_start_reanchor_probe.mjs # 本探针；退出码 0=全绿
// 修复前：continuous 的 chromeInsets/styleReanchor/uiscaleReanchor jumped=1（越过插图）；
// 修复后（连续版 scrollToCharOffset <=0 → scrollToChapterStart）：全 jumped=0，且中段守卫 PRESERVED。
//
// 覆盖分页 + 连续两 shell，动作覆盖真实编排里恢复完成后会异步发出的重锚：
//   - chromeInsets   : setChromeInsets(0,60)          （_reapplyChromeInsetsAfterFirstLoad 每次翻章都发）
//   - renavChar      : restoreToCharOffset(fvco)      （_syncPageSize 宽变重导）
//   - styleReanchor  : begin/commitStyleReanchor      （改字号/主题/顶部进度上升沿）
//   - uiscaleReanchor: begin/commitUiScaleReanchor    （界面缩放）
// 断言：章首插图页上任一动作都不得把落点从「插图页/顶部」移到「首文本」。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import zlib from 'node:zlib'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800;
// block-img-wrapper 用满页高（扉页插图占整页），text 落到下一页/滚动位。
const cssPaginated = `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--hoshi-image-max-width,${W-40}px);max-height:var(--hoshi-image-max-height,${H}px);width:auto;height:auto;break-inside:avoid;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;break-inside:avoid;} p{margin:0 0 1em 0;}`;
// 连续模式：纵向滚动，前导插图占满一屏，文字接在其后。
const cssContinuous = `html,body{margin:0;padding:0;}
 body{width:${W}px;padding:0 20px;box-sizing:border-box;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--hoshi-image-max-width,${W-40}px);max-height:var(--hoshi-image-max-height,${H}px);width:auto;height:auto;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;} p{margin:0 0 1em 0;}`;
const paras = Array.from({length: 60}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');
function png(w, h){const raw=Buffer.alloc((w*3+1)*h);for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;raw[o]=136;raw[o+1]=136;raw[o+2]=136;}}const d=zlib.deflateSync(raw);const sig=Buffer.from([137,80,78,71,13,10,26,10]);const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=2;const crc=b=>{let c=~0;for(let i=0;i<b.length;i++){c^=b[i];for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c;};const ch=(t,dd)=>{const l=Buffer.alloc(4);l.writeUInt32BE(dd.length,0);const tt=Buffer.from(t);const cc=Buffer.alloc(4);cc.writeUInt32BE(crc(Buffer.concat([tt,dd]))>>>0,0);return Buffer.concat([l,tt,dd,cc]);};return Buffer.concat([sig,ch('IHDR',ih),ch('IDAT',d),ch('IEND',Buffer.alloc(0))]);}
const bigPng = png(300, 760);

// 统一位置读数：分页读 getPagePosition→页号；连续读 scrollingElement.scrollTop→页高倍数。
async function measure(pg, mode){
  return await pg.evaluate((mode) => {
    const r = window.hoshiReader;
    if (mode === 'paginated') {
      const c = r.getScrollContext();
      return { pos: r.getPagePosition(c), unit: c.pageSize };
    }
    const el = document.scrollingElement || document.documentElement;
    return { pos: el.scrollTop, unit: window.innerHeight };
  }, mode);
}

async function run(mode, action){
  const shellFile = mode === 'paginated' ? 'hoshi_shell_paginated.html' : 'hoshi_shell_continuous.html';
  const shell = fs.readFileSync(path.join(os.tmpdir(), shellFile), 'utf8');
  const css = mode === 'paginated' ? cssPaginated : cssContinuous;
  const lead = `<img id="lead" loading="lazy" src="https://hoshi.local/lead.png" alt="">`;
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>${lead}\n${paras}\n${shell}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  let rel; const ready = new Promise(r => rel = r); await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://hoshi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u === 'https://hoshi.local/lead.png') { await ready; return q.respond({status:200,contentType:'image/png',body:bigPng}); }
    if (u.startsWith('https://hoshi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  await pg.goto('https://hoshi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 350)); rel(); await new Promise(r => setTimeout(r, 700));
  const before = await measure(pg, mode);
  const info = await pg.evaluate((action) => {
    const r = window.hoshiReader;
    const fvco = r.getFirstVisibleCharOffset();
    if (action === 'chromeInsets') { r.setChromeInsets(0, 60); }
    else if (action === 'renavChar') { r.restoreToCharOffset(fvco); }
    else if (action === 'styleReanchor') {
      if (typeof r.beginStyleReanchor !== 'function') return { fvco, off: 'N/A' };
      // 模拟改样式两阶段重锚（Dart begin→postFrame commit）。styleEl 传 null（不换 CSS）。
      const off = r.beginStyleReanchor(null, '');
      requestAnimationFrame(() => { r.commitStyleReanchor(); });
      return { fvco, off };
    } else if (action === 'uiscaleReanchor') {
      if (typeof r.beginUiScaleReanchor !== 'function') return { fvco, off: 'N/A' };
      const off = r.beginUiScaleReanchor();
      requestAnimationFrame(() => { r.commitUiScaleReanchor(); });
      return { fvco, off };
    }
    return { fvco };
  }, action);
  await new Promise(r => setTimeout(r, 200));
  const after = await measure(pg, mode);
  await b.close();
  const jumped = Math.round((after.pos - before.pos) / before.unit);
  const has = info.off !== undefined ? ` off=${info.off}` : '';
  console.log(`${mode.padEnd(10)} ${action.padEnd(14)} fvco=${String(info.fvco).padStart(4)}${has} before=p${(before.pos/before.unit).toFixed(2)} after=p${(after.pos/after.unit).toFixed(2)} jumped=${jumped}${jumped!==0?'  <-- JUMP':''}`);
  return jumped;
}

// 中章守卫：charOffset>0 的重锚必须保住位置（归一只作用于 <=0，不得把用户从正文
// 中段弹回章首）。先滚进正文（越过插图），再 setChromeInsets，落点应贴近原文本锚。
async function runMidChapter(mode){
  const shellFile = mode === 'paginated' ? 'hoshi_shell_paginated.html' : 'hoshi_shell_continuous.html';
  const shell = fs.readFileSync(path.join(os.tmpdir(), shellFile), 'utf8');
  const css = mode === 'paginated' ? cssPaginated : cssContinuous;
  const lead = `<img id="lead" loading="lazy" src="https://hoshi.local/lead.png" alt="">`;
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>${lead}\n${paras}\n${shell}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  let rel; const ready = new Promise(r => rel = r); await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://hoshi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u === 'https://hoshi.local/lead.png') { await ready; return q.respond({status:200,contentType:'image/png',body:bigPng}); }
    if (u.startsWith('https://hoshi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  await pg.goto('https://hoshi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 350)); rel(); await new Promise(r => setTimeout(r, 700));
  // 滚进正文中段（charOffset 600，远超前导插图，两模式首可见字符都 >0），采锚 setChromeInsets 重锚。
  const info = await pg.evaluate(() => {
    const r = window.hoshiReader;
    r.scrollToCharOffset(600);
    return { fvco: r.getFirstVisibleCharOffset() };
  });
  await new Promise(r => setTimeout(r, 120));
  const before = await measure(pg, mode);
  await pg.evaluate(() => window.hoshiReader.setChromeInsets(0, 60));
  await new Promise(r => setTimeout(r, 200));
  const after = await measure(pg, mode);
  await b.close();
  const drift = Math.round((after.pos - before.pos) / before.unit);
  // 断言：中段重锚保住位置（drift≈0），且未把非零锚坍缩回章首（before 明显 > 章首）。
  const preserved = info.fvco > 0 && before.pos > before.unit * 0.5 && Math.abs(drift) <= 1;
  console.log(`${mode.padEnd(10)} midChapter     fvco=${String(info.fvco).padStart(4)} before=p${(before.pos/before.unit).toFixed(2)} after=p${(after.pos/after.unit).toFixed(2)} drift=${drift} ${preserved ? 'PRESERVED' : '<-- LOST ANCHOR'}`);
  return preserved ? 0 : 1;
}

let fail = 0;
for (const mode of ['paginated', 'continuous'])
  for (const action of ['chromeInsets', 'renavChar', 'styleReanchor', 'uiscaleReanchor'])
    fail |= (await run(mode, action)) !== 0 ? 1 : 0;
for (const mode of ['paginated', 'continuous'])
  fail |= await runMidChapter(mode);
process.exit(fail ? 1 : 0);
