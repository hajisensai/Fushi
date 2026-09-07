// BUG-2205 复现 / 守卫：分页模式改字号（缩小 / 放大）的两阶段样式重锚，落页后
// **页首字不得越过锚字**（锚 = begin 时采到的首可见字）。
//
// 修前：scrollToCharOffset 的 ±1 page-stable hint 在锚字被缩字号推到前一页时仍保原页 →
// 原页页首字 > 锚字 → 用户丢掉锚字到新页首这段正文；进度刷新把这段当新读到计进统计，
// 反复缩放是单向棘轮（每缩一步多计约一页）。
// 修后：charPage < origPage 时先落原页实测页首字，> 锚字就改落锚字所在页。
//
// 先生成真 shell（CI 跑不到真 WebView，本探针本机跑）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写 shell 到 systemTemp
//   node tool/reader_pitch_headless/font_shrink_reanchor_probe.mjs  # 退出码 0=全绿
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800;
const cssPaginated = `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W-40}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}`;
const paras = Array.from({length: 90}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');

// 按真实装配顺序安装：完整引擎产物（工厂 + 学习单位 JS + __fushiInstallShell）→
// `__fushiInstallShell(C)` 建 window.fushiReader → load 时自动 boot initialize。
const CONFIG = {
  vnMode: false, continuousMode: false, perfTraceEnabled: false,
  chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
  initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
};
async function openChapter(){
  const engine = fs.readFileSync(path.join(os.tmpdir(), 'fushi_engine_paginated.html'), 'utf8');
  const install = `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});</script>`;
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${cssPaginated}</style><style id="probe-style"></style></head><body>${paras}\n${engine}\n${install}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u.startsWith('https://fushi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  await pg.goto('https://fushi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 500));
  return { b, pg };
}

// 一次两阶段样式重锚：begin（采锚 + 换 CSS）→ rAF commit（落页）。返回 begin 时的锚与
// commit 后的页首字 / 页号。
async function restyle(pg, css){
  const before = await pg.evaluate((css) => {
    const r = window.fushiReader;
    const el = document.getElementById('probe-style');
    const anchor = r.beginStyleReanchor(el, css);
    return { anchor };
  }, css);
  await pg.evaluate(() => new Promise(res => requestAnimationFrame(() => { window.fushiReader.commitStyleReanchor(); res(); })));
  await new Promise(r => setTimeout(r, 120));
  const after = await pg.evaluate(() => {
    const r = window.fushiReader; const c = r.getScrollContext();
    const pos = r.getPagePosition(c); const page = Math.round(pos / c.pageSize);
    const first = r.getFirstVisibleCharOffset();
    // 下一页页首字（用来断言锚字仍在当前页内），读完滚回。
    r.setPagePosition(c, pos + c.pageSize);
    const nextFirst = r.getFirstVisibleCharOffset();
    r.setPagePosition(c, pos);
    return { page, first, nextFirst };
  });
  return { anchor: before.anchor, ...after };
}

let fail = 0;
const { b, pg } = await openChapter();
// 落到章中段某页（精确锚），记初始首可见字。
const seed = await pg.evaluate(() => {
  const r = window.fushiReader; r.scrollToCharOffset(2600);
  const c = r.getScrollContext();
  return { page: Math.round(r.getPagePosition(c) / c.pageSize), first: r.getFirstVisibleCharOffset() };
});
console.log(`seed              page=${seed.page} first=${seed.first}`);
if (!(seed.page > 0 && seed.first > 0)) { console.log('  <-- seed did not leave chapter start'); fail = 1; }

// 缩字号四步（22→20→18→16→14），每步：页首字 ≤ 锚字（不越锚）且锚字 < 下一页页首（锚在当页）。
const sizes = [21, 20, 19, 18, 17, 16, 15, 14, 16, 18, 20, 22, 24, 26];
for (const px of sizes) {
  const r = await restyle(pg, `body{font-size:${px}px !important;}`);
  const notPast = r.first <= r.anchor;
  const onPage = r.nextFirst < 0 || r.anchor < r.nextFirst;
  const ok = notPast && onPage;
  console.log(`font=${String(px).padStart(2)}px anchor=${String(r.anchor).padStart(5)} page=${String(r.page).padStart(3)} first=${String(r.first).padStart(5)} nextFirst=${String(r.nextFirst).padStart(5)} ${ok ? 'OK' : (notPast ? '<-- ANCHOR NOT ON PAGE' : '<-- PAGE START PASSED ANCHOR (drift ' + (r.first - r.anchor) + ' chars)')}`);
  if (!ok) fail = 1;
}
await b.close();
process.exit(fail ? 1 : 0);
