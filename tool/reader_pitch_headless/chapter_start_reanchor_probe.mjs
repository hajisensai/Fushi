// TODO-1229 第 6 次复诉复现：章首带扉页插图的章，初始 restore 落插图页正确后，
// 一个「重锚」（setChromeInsets / uiscale / style）以 getFirstVisibleCharOffset()==0
// 走裸 scrollToCharOffset(0) → 滚到首个文本字符（跳过前导插图）= 残留第二跳。
//
// 先生成真 shell（CI 跑不到真 WebView，本探针本机跑）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写 shell 到 systemTemp
//   node tool/reader_pitch_headless/chapter_start_reanchor_probe.mjs # 本探针；退出码 0=全绿
//
// 两条残留第二跳：
//   (A) 连续版：重锚以 fvco==0 裸调 scrollToCharOffset(0)（无 hint）→ 越过前导插图。
//       修复 = 连续 scrollToCharOffset(<=0) → scrollToChapterStart（滚到顶含前导）。
//   (B) 分页版：重锚（setChromeInsets）带 page-stable hint，旧 ±1 page-stable 只在「前导恰
//       占 1 页」时兜住；前导跨 ≥2 页（扉页图+标题页 / 多张图）时 charPage 与 origPage 差 ≥2、
//       ±1 失效 → 越过整段前导跳到首文本（headless 实证 2 张前导图 jumped=2）。修复 =
//       分页 scrollToCharOffset(<=0) 保住用户当前页（有 hint 走 origPage=round(hint/pageSize)，
//       无 hint 落 contentFirstPageScroll=章首含前导），绝不按字符页跳。
//
// 覆盖分页 + 连续两 shell、单页前导 + 多页前导两几何。动作覆盖真实编排里恢复完成后异步发出的重锚：
//   - chromeInsets   : setChromeInsets(0,60)          （_reapplyChromeInsetsAfterFirstLoad 每次翻章都发）
//   - renavChar      : restoreToCharOffset(fvco)      （_syncPageSize 宽变重导）
//   - styleReanchor  : begin/commitStyleReanchor      （改字号/主题/顶部进度上升沿；分页 shell 缺席=N/A）
//   - uiscaleReanchor: begin/commitUiScaleReanchor    （界面缩放；分页 shell 缺席=N/A）
// 断言：章首前导页上任一动作都不得把落点从「前导页/顶部」移到「首文本」；用户在前导中段某页 /
// 首文本页时重锚亦保住当页（不弹回、不越过）。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import zlib from 'node:zlib'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800;
// block-img-wrapper 用满页高（扉页插图占整页），text 落到下一页/滚动位。
const cssPaginated = `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--fushi-image-max-width,${W-40}px);max-height:var(--fushi-image-max-height,${H}px);width:auto;height:auto;break-inside:avoid;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;break-inside:avoid;} p{margin:0 0 1em 0;}`;
// 连续模式：纵向滚动，前导插图占满一屏，文字接在其后。
const cssContinuous = `html,body{margin:0;padding:0;}
 body{width:${W}px;padding:0 20px;box-sizing:border-box;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--fushi-image-max-width,${W-40}px);max-height:var(--fushi-image-max-height,${H}px);width:auto;height:auto;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;} p{margin:0 0 1em 0;}`;
const paras = Array.from({length: 60}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');
// 前导几何：single=1 张满页图（≈1 页前导，旧 ±1 hint 恰好兜住）；multi=2 张满页图
// （≈2 页前导：扉页图 + 标题/第二张，首文本落到第 2 页，旧 ±1 hint 失效 → 复现 (B)）。
const LEADS = {
  single: `<img id="lead" loading="lazy" src="https://fushi.local/lead.png" alt="">`,
  multi: `<img loading="lazy" src="https://fushi.local/lead1.png" alt=""><img loading="lazy" src="https://fushi.local/lead2.png" alt="">`,
};
function png(w, h){const raw=Buffer.alloc((w*3+1)*h);for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;raw[o]=136;raw[o+1]=136;raw[o+2]=136;}}const d=zlib.deflateSync(raw);const sig=Buffer.from([137,80,78,71,13,10,26,10]);const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=2;const crc=b=>{let c=~0;for(let i=0;i<b.length;i++){c^=b[i];for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c;};const ch=(t,dd)=>{const l=Buffer.alloc(4);l.writeUInt32BE(dd.length,0);const tt=Buffer.from(t);const cc=Buffer.alloc(4);cc.writeUInt32BE(crc(Buffer.concat([tt,dd]))>>>0,0);return Buffer.concat([l,tt,dd,cc]);};return Buffer.concat([sig,ch('IHDR',ih),ch('IDAT',d),ch('IEND',Buffer.alloc(0))]);}
const bigPng = png(300, 760);

// 统一位置读数：分页读 getPagePosition→页号；连续读 scrollingElement.scrollTop→页高倍数。
async function measure(pg, mode){
  return await pg.evaluate((mode) => {
    const r = window.fushiReader;
    if (mode === 'paginated') {
      const c = r.getScrollContext();
      return { pos: r.getPagePosition(c), unit: c.pageSize };
    }
    const el = document.scrollingElement || document.documentElement;
    return { pos: el.scrollTop, unit: window.innerHeight };
  }, mode);
}

// 打开一章（前导图 leadHtml + 正文），等图片 decode + 初始 restore(progress0) 落地。
async function openChapter(mode, leadHtml){
  const shellFile = mode === 'paginated' ? 'fushi_shell_paginated.html' : 'fushi_shell_continuous.html';
  const shell = fs.readFileSync(path.join(os.tmpdir(), shellFile), 'utf8');
  const css = mode === 'paginated' ? cssPaginated : cssContinuous;
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>${leadHtml}\n${paras}\n${shell}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  let rel; const ready = new Promise(r => rel = r); await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u.startsWith('https://fushi.local/lead')) { await ready; return q.respond({status:200,contentType:'image/png',body:bigPng}); }
    if (u.startsWith('https://fushi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  await pg.goto('https://fushi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 350)); rel(); await new Promise(r => setTimeout(r, 700));
  return { b, pg };
}

// 初始落前导页后发一个重锚动作，断言落点不被移到首文本（jumped 必须 0）。
async function run(mode, action, leadName){
  const { b, pg } = await openChapter(mode, LEADS[leadName]);
  const before = await measure(pg, mode);
  const info = await pg.evaluate((action) => {
    const r = window.fushiReader;
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
  const tag = `${mode}/${leadName}`;
  console.log(`${tag.padEnd(20)} ${action.padEnd(14)} fvco=${String(info.fvco).padStart(4)}${has} before=p${(before.pos/before.unit).toFixed(2)} after=p${(after.pos/after.unit).toFixed(2)} jumped=${jumped}${jumped!==0?'  <-- JUMP':''}`);
  return jumped;
}

// 保位守卫：先按字符锚 seedChar 把视口滚离章首（越过前导），再发 action 重锚，
// 断言重锚保住当页（before 明显离开章首 + drift≈0，既不弹回前导、也不越过）。
// action 覆盖 setChromeInsets / 两阶段 style / 两阶段 uiscale（后两者分页 shell 缺席=N/A 跳过）。
async function runPreserve(mode, leadName, label, seedChar, action){
  const { b, pg } = await openChapter(mode, LEADS[leadName]);
  const info = await pg.evaluate((seedChar) => {
    const r = window.fushiReader;
    r.scrollToCharOffset(seedChar);
    return { fvco: r.getFirstVisibleCharOffset() };
  }, seedChar);
  await new Promise(r => setTimeout(r, 120));
  const before = await measure(pg, mode);
  const na = await pg.evaluate((action) => {
    const r = window.fushiReader;
    if (action === 'chromeInsets') { r.setChromeInsets(0, 60); return false; }
    if (action === 'styleReanchor') {
      if (typeof r.beginStyleReanchor !== 'function') return true;
      r.beginStyleReanchor(null, '');
      requestAnimationFrame(() => r.commitStyleReanchor());
      return false;
    }
    if (action === 'uiscaleReanchor') {
      if (typeof r.beginUiScaleReanchor !== 'function') return true;
      r.beginUiScaleReanchor();
      requestAnimationFrame(() => r.commitUiScaleReanchor());
      return false;
    }
    return false;
  }, action);
  await new Promise(r => setTimeout(r, 200));
  const after = await measure(pg, mode);
  await b.close();
  const tag = `${mode}/${leadName}`;
  const lbl = `${label}:${action}`;
  if (na) { console.log(`${tag.padEnd(20)} ${lbl.padEnd(26)} N/A (function absent)`); return 0; }
  const drift = Math.round((after.pos - before.pos) / before.unit);
  // seed 必须真把视口带离章首（before>0.5 页），且重锚 drift≈0（未弹回前导 / 未越过）。
  const preserved = before.pos > before.unit * 0.5 && Math.abs(drift) <= 1;
  console.log(`${tag.padEnd(20)} ${lbl.padEnd(26)} fvco=${String(info.fvco).padStart(4)} before=p${(before.pos/before.unit).toFixed(2)} after=p${(after.pos/after.unit).toFixed(2)} drift=${drift} ${preserved ? 'PRESERVED' : '<-- LOST ANCHOR'}`);
  return preserved ? 0 : 1;
}

let fail = 0;
// ── 单页前导（旧几何）：全动作 × 两模式，落点不越前导（零回归） ──
for (const mode of ['paginated', 'continuous'])
  for (const action of ['chromeInsets', 'renavChar', 'styleReanchor', 'uiscaleReanchor'])
    fail |= (await run(mode, action, 'single')) !== 0 ? 1 : 0;
// ── 多页前导（≥2 页）：初始落前导页 0，chromeInsets 重锚不得越过整段前导跳到首文本 ──
// （分页版旧 ±1 hint 在此失效 → 修前 jumped=2；修后保住 page0 = jumped 0。连续版由
//  scrollToChapterStart 归一覆盖，任意前导页数都停顶。）
for (const mode of ['paginated', 'continuous'])
  fail |= (await run(mode, 'chromeInsets', 'multi')) !== 0 ? 1 : 0;
// ── 保位守卫：中段（单页前导，charOffset>0 精确锚保留）——三条重锚路径 ──
for (const mode of ['paginated', 'continuous'])
  for (const action of ['chromeInsets', 'styleReanchor', 'uiscaleReanchor'])
    fail |= await runPreserve(mode, 'single', 'midChapter', 600, action);
// ── 保位守卫：多页前导下用户在「首文本页」（fvco==0 但 hint 指首文本页）重锚不被弹回前导页 ──
// 覆盖三条重锚路径：setChromeInsets / 两阶段 style / 两阶段 uiscale 都必须用采到的滚动位保住当页。
for (const mode of ['paginated', 'continuous'])
  for (const action of ['chromeInsets', 'styleReanchor', 'uiscaleReanchor'])
    fail |= await runPreserve(mode, 'multi', 'firstTextPage', 1, action);
process.exit(fail ? 1 : 0);
