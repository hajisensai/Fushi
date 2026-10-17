// 小说翻页动画（reader_page_turn_script.dart）真渲染探针：横排 / 竖排 × 平移 / 覆盖 / 淡入，
// 把动画时长拉长到 2 秒，在 25% / 50% 处截图并记录 View Transition 动画数与页位置，
// 用来肉眼确认「竖排也是左右翻」「覆盖分层正确」「快照只截正文可视区」。
//
// 先生成真 shell：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写 shell 到 systemTemp
//   node tool/reader_pitch_headless/page_turn_animation_probe.mjs   # 截图写到 <systemTemp>/fushi_page_turn_probe
// CHROME_PATH 指向 Chromium（Playwright headless shell 亦可）。退出码 0 = 每组都在
// 动画中途观察到 View Transition 且落页正确。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
// 输出目录固定在系统临时目录下，不接受命令行路径（避免把任意路径当写入目标）。
const OUT = path.join(os.tmpdir(), 'fushi_page_turn_probe');
fs.mkdirSync(OUT, { recursive: true });
const W = 600, H = 800, DURATION = 2000;
const css = (vertical) => vertical
  ? `html,body{margin:0;padding:0;}html{overflow:hidden;background:#fbfaf6;}
     body{width:${W}px;height:${H}px;padding:20px 0;box-sizing:border-box;column-width:${H - 40}px;column-gap:40px;column-fill:auto;
     font-size:26px;line-height:1.9;overflow:hidden;writing-mode:vertical-rl;color:#222;background:#fbfaf6;}
     p{margin:0 0 0 1em;}`
  : `html,body{margin:0;padding:0;}html{overflow:hidden;background:#fbfaf6;}
     body{width:${W}px;height:${H}px;padding:0 20px;box-sizing:border-box;column-width:${W - 40}px;column-gap:40px;column-fill:auto;
     font-size:24px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;color:#222;background:#fbfaf6;}
     p{margin:0 0 1em 0;}`;
const paras = Array.from({ length: 60 }, (_, i) =>
  `<p>【第${i}段】吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。</p>`).join('\n');

async function run(vertical, effect) {
  const config = {
    vnMode: false, continuousMode: false, perfTraceEnabled: false,
    chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
    initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
    pageTurnAnimation: effect, pageTurnDurationMs: DURATION, pageTurnFollowDrag: true,
    swipeLeftIsForward: !vertical,
  };
  const engine = fs.readFileSync(process.env.FUSHI_ENGINE_HTML || path.join(os.tmpdir(), 'fushi_engine_paginated.html'), 'utf8');
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${css(vertical)}</style></head><body>${paras}\n${engine}\n<script>window.__fushiInstallShell(${JSON.stringify(config)});</script></body></html>`;
  const b = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox'] });
  try {
    const pg = await b.newPage(); await pg.setViewport({ width: W, height: H });
    await pg.setRequestInterception(true);
    pg.on('request', q => q.url() === 'https://fushi.local/chapter'
      ? q.respond({ status: 200, contentType: 'text/html', body: full })
      : q.url().startsWith('https://fushi.local') ? q.respond({ status: 404, body: '' }) : q.continue());
    await pg.goto('https://fushi.local/chapter', { waitUntil: 'load', timeout: 8000 }).catch(() => {});
    await new Promise(r => setTimeout(r, 500));
    const tag = `${vertical ? 'vertical' : 'horizontal'}-${effect}`;
    const before = await pg.evaluate(() => { const r = window.fushiReader; const c = r.getScrollContext(); return r.getPagePosition(c); });
    await pg.screenshot({ path: path.join(OUT, `${tag}-0.png`) });
    const result = await pg.evaluate(() => window.fushiReader.paginate('forward'));
    const mid = [];
    for (const pct of [25, 50]) {
      await new Promise(r => setTimeout(r, DURATION * 0.25));
      mid.push(await pg.evaluate(() => ({
        animations: document.getAnimations().length,
        marker: document.documentElement.getAttribute('data-fushi-pt'),
      })));
      await pg.screenshot({ path: path.join(OUT, `${tag}-${pct}.png`) });
    }
    await new Promise(r => setTimeout(r, DURATION));
    const after = await pg.evaluate(() => {
      const r = window.fushiReader; const c = r.getScrollContext();
      return { pos: r.getPagePosition(c), pageSize: c.pageSize, marker: document.documentElement.getAttribute('data-fushi-pt') };
    });
    await pg.screenshot({ path: path.join(OUT, `${tag}-100.png`) });
    const ok = result === 'scrolled' && mid.every(m => m.animations > 0) &&
      Math.abs(Math.abs(after.pos - before) - after.pageSize) <= 2 && after.marker == null;
    console.log(`${ok ? 'PASS' : 'FAIL'} ${tag} result=${result} before=${before} after=${after.pos} page=${after.pageSize} mid=${JSON.stringify(mid)}`);
    return ok;
  } finally { await b.close(); }
}

let fail = 0;
for (const vertical of [false, true]) {
  for (const effect of ['slide', 'cover', 'fade']) {
    if (!(await run(vertical, effect))) fail = 1;
  }
}
console.log(`screenshots: ${OUT}`);
process.exit(fail);
