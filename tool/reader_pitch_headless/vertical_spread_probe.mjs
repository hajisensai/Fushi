// 竖排对开（折叠屏书本姿态）分页几何的真渲染探针。
//
// 竖排对开 = 竖排 + CSS multicol 行换行（column-height + column-wrap: wrap，Chromium 145+，
// reader_content_styles.dart 的 verticalSpreadCss）：每页是一个 multicol 行，一屏右页 + 左页，
// 翻页轴变成从右往左的 x 轴（reader_pagination_scripts.dart 的 xr 轴 / _spreadScrollContext）。
// 逐页可见区间的无缝 / 覆盖由 visible_range_probe.mjs 的两组 spread 几何断言；本探针断言其余
// 落页路径在真引擎上同样成立：
//   · 轴识别：getScrollContext().axis == 'xr'，页步 == 2 ×（column-height + row-gap）；
//   · 精确恢复：restoreToCharOffset(k) 后第 k 个字画在当前对开上（charOffsetOnCurrentPage），
//     且「存→取」不动点：取页首字 f 再 restoreToCharOffset(f) 落回同一页；
//   · 后退：从章末 paginate('backward') 逐页回到 minScroll，每步都落在页网格上；
//   · 揭示：revealRange 到当前对开**左页**上的字不翻页，到下一对开上的字恰好翻一页；
//   · pageInfo 页码 1..N 与翻页步数一致。
// 另存一张中段对开截图（vertical_spread_probe.png，systemTemp）供肉眼核对：两页并排、中缝空出。
//
// 先生成真引擎产物（CI 跑不到真 WebView，本探针本机跑）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写引擎到 systemTemp
//   node tool/reader_pitch_headless/vertical_spread_probe.mjs       # 退出码 0=全绿 / 2=Chrome 不支持 column-wrap
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800, PT = 24, PB = 32, PL = 20, PR = 28, GAP = 40;

const paras = Array.from({length: 71}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');
// 与 verticalSpreadCss 逐项同构（column-height 用常量代替 calc，结果相同）。
const CSS = `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:${PT}px ${PR}px ${PB}px ${PL}px;box-sizing:border-box;writing-mode:vertical-rl;column-width:${H-PT-PB}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;
 column-count:1;column-height:${(W-PL-PR-GAP)/2}px;column-wrap:wrap;row-gap:${GAP}px;}
 body::after{content:"";display:block;block-size:1px;break-before:column;}
 p{margin:0 1em 0 0;}`;

async function open() {
  const engine = fs.readFileSync(path.join(os.tmpdir(), 'fushi_engine_paginated.html'), 'utf8');
  const CONFIG = {
    vnMode: false, continuousMode: false, perfTraceEnabled: false,
    chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
    initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
  };
  const install = `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});</script>`;
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${CSS}</style>\n${engine}\n${install}</head><body>${paras}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({status: 200, contentType: 'text/html', body: full});
    if (u.startsWith('https://fushi.local')) return q.respond({status: 404, body: ''});
    return q.continue();
  });
  pg.on('pageerror', e => console.log('  pageerror:', e.message));
  await pg.goto('https://fushi.local/chapter', {waitUntil: 'load', timeout: 8000}).catch(() => {});
  await new Promise(r => setTimeout(r, 500));
  return { b, pg };
}

const problems = [];
const expect = (ok, msg) => { if (!ok) problems.push(msg); };

const { b, pg } = await open();
try {
  const supported = await pg.evaluate(() => CSS.supports('column-wrap', 'wrap'));
  if (!supported) {
    console.log('[SPREAD] Chrome lacks column-wrap (needs 145+); skipping');
    process.exit(2);
  }
  const geo = await pg.evaluate(() => {
    const r = window.fushiReader;
    const ctx = r.getScrollContext();
    const cs = getComputedStyle(document.body);
    const m = r.buildPaginationMetrics();
    return { axis: ctx.axis, pageSize: ctx.pageSize, rowH: parseFloat(cs.columnHeight), gap: parseFloat(cs.rowGap),
      minScroll: m.minScroll, maxScroll: m.maxScroll, total: m.totalChars };
  });
  console.log('geometry', JSON.stringify(geo));
  expect(geo.axis === 'xr', `axis ${geo.axis} != xr`);
  expect(Math.abs(geo.pageSize - 2 * (geo.rowH + geo.gap)) < 0.01, `pageSize ${geo.pageSize} != 2*(rowH+gap)`);
  const pages = Math.round((geo.maxScroll - geo.minScroll) / geo.pageSize) + 1;

  // 精确恢复 + 存→取不动点。
  const offsets = [1, 37, 400, 777, 1500, 2222, 3001, geo.total - 5];
  for (const k of offsets) {
    const res = await pg.evaluate(async (k) => {
      const r = window.fushiReader;
      await r.restoreToCharOffset(k);
      await new Promise(res => setTimeout(res, 80)); // _settleAndNotify 16ms 后重写落点，等它跑完再读
      const pos = r.getPagePosition(r.getScrollContext());
      const onPage = r.charOffsetOnCurrentPage(k);
      const f = r.getFirstVisibleCharOffset();
      await r.restoreToCharOffset(f);
      await new Promise(res => setTimeout(res, 80)); // _settleAndNotify 16ms 后重写落点，等它跑完再读
      const pos2 = r.getPagePosition(r.getScrollContext());
      return { pos, onPage, f, pos2 };
    }, k);
    expect(res.onPage, `restoreToCharOffset(${k}) landed at ${res.pos}, char not on current spread`);
    expect(Math.abs(res.pos - res.pos2) < 1, `fixed point: offset ${k} -> page ${res.pos}, first char ${res.f} -> page ${res.pos2}`);
    expect(Math.abs(res.pos / geo.pageSize - Math.round(res.pos / geo.pageSize)) * geo.pageSize < 1 || Math.abs(res.pos - geo.maxScroll) < 1,
      `restoreToCharOffset(${k}) off-grid position ${res.pos}`);
  }

  // 后退：章末逐页回到章首。
  const back = await pg.evaluate(async () => {
    const r = window.fushiReader;
    r.setPagePosition(r.getScrollContext(), r.contentLastPageScroll(r.getScrollContext()));
    const seen = [];
    for (let i = 0; i < 200; i++) {
      const ctx = r.getScrollContext();
      const info = r.pageInfo();
      seen.push({ pos: r.getPagePosition(ctx), page: info && info.currentPage, totalPages: info && info.totalPages });
      if (r.paginate('backward') === 'limit') break;
      r.finishPageTurnAnimation();
    }
    return seen;
  });
  expect(back.length === pages, `backward walk visited ${back.length} spreads, expected ${pages}`);
  back.forEach((s, i) => {
    const expectedPos = geo.minScroll + (back.length - 1 - i) * geo.pageSize;
    expect(Math.abs(s.pos - expectedPos) < 1 || (i === 0 && Math.abs(s.pos - geo.maxScroll) < 1),
      `backward step ${i}: position ${s.pos} != grid ${expectedPos}`);
    expect(s.page === back.length - i, `backward step ${i}: pageInfo.currentPage ${s.page} != ${back.length - i}`);
    expect(s.totalPages === pages, `backward step ${i}: pageInfo.totalPages ${s.totalPages} != ${pages}`);
  });
  expect(Math.abs(back[back.length - 1].pos - geo.minScroll) < 1, 'backward walk did not end at minScroll');

  // 揭示：同一对开左页上的字不翻页；下一对开上的字恰好翻一页。
  const reveal = await pg.evaluate(async () => {
    const r = window.fushiReader;
    const ctx = r.getScrollContext();
    r.setPagePosition(ctx, ctx.pageSize * 3);
    const before = r.getPagePosition(ctx);
    const right = document.body.getBoundingClientRect().right;
    // 左页 = 到右缘距离落在 [pr + rowH + gap, pr + 2rowH + gap) 的字。
    const cs = getComputedStyle(document.body);
    const pr = parseFloat(cs.paddingRight), rowH = parseFloat(cs.columnHeight), gap = parseFloat(cs.rowGap);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let leftRange = null, nextRange = null, node;
    while ((node = walker.nextNode())) {
      for (let i = 0; i < node.length; i += 7) {
        const rg = document.createRange(); rg.setStart(node, i); rg.setEnd(node, i + 1);
        const rc = rg.getBoundingClientRect(); if (!(rc.width > 0)) continue;
        const d = right - rc.right;
        if (!leftRange && d > pr + rowH + gap + 5 && d < pr + 2 * rowH + gap - 30) leftRange = rg;
        if (!nextRange && d > ctx.pageSize + pr + 5 && d < ctx.pageSize + pr + rowH - 30) nextRange = rg;
      }
      if (leftRange && nextRange) break;
    }
    const turnedLeft = r.revealRange(leftRange);
    r.finishPageTurnAnimation();
    const afterLeft = r.getPagePosition(r.getScrollContext());
    const turnedNext = r.revealRange(nextRange);
    r.finishPageTurnAnimation();
    const afterNext = r.getPagePosition(r.getScrollContext());
    return { before, turnedLeft, afterLeft, turnedNext, afterNext, found: !!leftRange && !!nextRange };
  });
  expect(reveal.found, 'reveal: could not find probe characters on left page / next spread');
  expect(!reveal.turnedLeft && Math.abs(reveal.afterLeft - reveal.before) < 1, `reveal left page turned: ${JSON.stringify(reveal)}`);
  expect(reveal.turnedNext && Math.abs(reveal.afterNext - reveal.before - geo.pageSize) < 1, `reveal next spread: ${JSON.stringify(reveal)}`);

  const shot = path.join(os.tmpdir(), 'vertical_spread_probe.png');
  await pg.evaluate(() => { const r = window.fushiReader; const c = r.getScrollContext(); r.setPagePosition(c, c.pageSize * 2); });
  await new Promise(r => setTimeout(r, 100));
  await pg.screenshot({path: shot});
  console.log('pages', pages, 'backward steps', back.length, 'screenshot', shot);
} finally {
  await b.close();
}
problems.forEach(p => console.log('  <-- ' + p));
console.log(problems.length ? `[SPREAD] FAIL (${problems.length})` : '[SPREAD] all assertions passed');
process.exit(problems.length ? 1 : 0);
