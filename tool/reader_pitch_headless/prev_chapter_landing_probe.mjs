// TODO-1349 复现：从目录往前翻，落到封面（章首）而非封面章节的最后部分（章尾）。
//
// 往前翻章走 _handlePageTurnLimit backward → _navigateToChapter(prev, progress:0.99)
// → shell 初始 restoreProgress(0.99)（章尾语义）。本探针对**真 shell** 直接调
// restoreProgress(0.99)，断言落点应到章末（最后一张图/最后一屏），而非停在章首（封面）。
//
// 覆盖三类「封面章节」几何 × 分页/连续两 shell：
//   imageOnly3 : 3 张整屏图、零文本（纯封面/口绘章）——findNodeAtProgress 无文本节点。
//   textThenImages : 文本 + 章尾 3 张整屏图（正文后附插图）——文本 99% 在图之前。
//   imagesThenText : 章首 2 张图 + 正文（普通图文章，回归对照，0.99 应到文本尾）。
//
// 先生成真 shell：
//   flutter test test/reader/reader_headless_shell_dump_test.dart
//   node tool/reader_pitch_headless/prev_chapter_landing_probe.mjs   # 退出码 0=全绿
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import zlib from 'node:zlib'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800;
const cssPaginated = `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--fushi-image-max-width,${W-40}px);max-height:var(--fushi-image-max-height,${H}px);width:auto;height:auto;break-inside:avoid;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;break-inside:avoid;} p{margin:0 0 1em 0;}`;
const cssContinuous = `html,body{margin:0;padding:0;}
 body{width:${W}px;padding:0 20px;box-sizing:border-box;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 img.block-img{display:block;max-width:var(--fushi-image-max-width,${W-40}px);max-height:var(--fushi-image-max-height,${H}px);width:auto;height:auto;}
 .block-img-wrapper{display:flex;align-items:center;justify-content:center;width:${W-40}px;height:${H}px;} p{margin:0 0 1em 0;}`;
const paras = Array.from({length: 60}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');
const img = (n) => `<img loading="lazy" src="https://fushi.local/img${n}.png" alt="">`;
const BODIES = {
  imageOnly3: `${img(1)}${img(2)}${img(3)}`,
  textThenImages: `${paras}\n${img(1)}${img(2)}${img(3)}`,
  imagesThenText: `${img(1)}${img(2)}\n${paras}`,
};
function png(w, h){const raw=Buffer.alloc((w*3+1)*h);for(let y=0;y<h;y++){raw[y*(w*3+1)]=0;for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;raw[o]=136;raw[o+1]=136;raw[o+2]=136;}}const d=zlib.deflateSync(raw);const sig=Buffer.from([137,80,78,71,13,10,26,10]);const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=2;const crc=b=>{let c=~0;for(let i=0;i<b.length;i++){c^=b[i];for(let k=0;k<8;k++)c=(c>>>1)^(0xEDB88320&-(c&1));}return ~c;};const ch=(t,dd)=>{const l=Buffer.alloc(4);l.writeUInt32BE(dd.length,0);const tt=Buffer.from(t);const cc=Buffer.alloc(4);cc.writeUInt32BE(crc(Buffer.concat([tt,dd]))>>>0,0);return Buffer.concat([l,tt,dd,cc]);};return Buffer.concat([sig,ch('IHDR',ih),ch('IDAT',d),ch('IEND',Buffer.alloc(0))]);}
const bigPng = png(300, 760);

async function measure(pg, mode){
  return await pg.evaluate((mode) => {
    const r = window.fushiReader;
    if (mode === 'paginated') { const c = r.getScrollContext(); return { pos: r.getPagePosition(c), unit: c.pageSize }; }
    const el = document.scrollingElement || document.documentElement;
    return { pos: el.scrollTop, unit: window.innerHeight, max: el.scrollHeight - el.clientHeight };
  }, mode);
}

async function openChapter(mode, bodyHtml){
  const shellFile = mode === 'paginated' ? 'hoshi_shell_paginated.html' : 'hoshi_shell_continuous.html';
  const shell = fs.readFileSync(path.join(os.tmpdir(), shellFile), 'utf8');
  const css = mode === 'paginated' ? cssPaginated : cssContinuous;
  // shell 放 <head>：真实 reader 用 _stripScriptTags 剥离后单独注入 JS，createWalker(body)
  // 绝不把脚本文本当正文节点计数。放 body 会污染 findNodeAtProgress/totalChars（脚本注释含中日文）。
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style>${shell}</head><body>${bodyHtml}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u.startsWith('https://fushi.local/img')) return q.respond({status:200,contentType:'image/png',body:bigPng});
    if (u.startsWith('https://fushi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  await pg.goto('https://fushi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 900)); // 等图 decode + block-img 归类 + 初始 restore(0)
  return { b, pg };
}

// 往前翻落章尾：restoreProgress(0.99) 后落点必须明显离开章首（>= 半页/半屏）。
async function runLanding(mode, bodyName){
  const { b, pg } = await openChapter(mode, BODIES[bodyName]);
  // 先滚到章首（模拟往前翻进入本章的初始态），再发章尾恢复。
  await pg.evaluate(() => window.fushiReader.restoreProgress(0));
  await new Promise(r => setTimeout(r, 120));
  await pg.evaluate(() => window.fushiReader.restoreProgress(0.99));
  await new Promise(r => setTimeout(r, 300));
  const m = await measure(pg, mode);
  await b.close();
  const pages = m.pos / m.unit;
  // 章尾语义：落点应 >= 0.5 页/屏（离开封面/章首）。纯图章至少滚到后面的图。
  const landedAtEnd = pages >= 0.5;
  const tag = `${mode}/${bodyName}`;
  console.log(`${tag.padEnd(26)} restoreProgress(0.99) pos=p${pages.toFixed(2)}${m.max!==undefined?` max=p${(m.max/m.unit).toFixed(2)}`:''} ${landedAtEnd ? 'END-OK' : '<-- STUCK AT COVER'}`);
  return landedAtEnd ? 0 : 1;
}

let fail = 0;
for (const mode of ['paginated', 'continuous'])
  for (const body of ['imageOnly3', 'textThenImages', 'imagesThenText'])
    fail |= await runLanding(mode, body);
console.log(fail ? '\nRESULT: FAIL (some chapters stuck at cover on backward turn)' : '\nRESULT: PASS (backward turn lands at chapter end)');
process.exit(fail ? 1 : 0);
