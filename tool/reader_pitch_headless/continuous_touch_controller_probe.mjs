// 反馈 R7k887yaJI 真 Chromium 探针：连续 shell 触摸控制器（斜滑补位 + 边界拉动跨章阻尼）。
//
// 吃 reader_headless_shell_dump_test.dart 写到 systemTemp 的**完整引擎产物**
// fushi_engine_continuous.html，按真实装配顺序 __fushiInstallShell(C) 安装；CSS 取
// ReaderContentStyles 连续模式的锁轴三件套（html 隐藏交叉轴 / body 交叉轴 clip /
// touch-action: pan-x pan-y）。用 CDP Input.dispatchTouchEvent 发真实触摸手势，桩掉
// flutter_inappwebview.callHandler 记录 onBoundarySwipe。
//
//   flutter test test/reader/reader_headless_shell_dump_test.dart --no-pub   # 写引擎到 systemTemp
//   node tool/reader_pitch_headless/continuous_touch_controller_probe.mjs
// 退出码 0 = 横排 / 竖排下每条断言都成立。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';

const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 400, H = 800;
const paras = Array.from({ length: 80 }, (_, i) =>
  `<p>【第${i}段】吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。</p>`).join('\n');

function css(vertical) {
  return vertical
    ? `html { overflow-y: hidden !important; }
html, body { touch-action: pan-x pan-y !important; }
body { overflow-y: clip !important; }
html, body { margin: 0 !important; padding: 0 !important; writing-mode: vertical-rl !important; }
body { height: 100vh !important; font-size: 20px; line-height: 1.8; }
body::after { content: ''; display: block; inline-size: 1px; block-size: 36vw; }`
    : `html { overflow-x: hidden !important; }
html, body { touch-action: pan-x pan-y !important; }
body { overflow-x: clip !important; }
html, body { margin: 0 !important; padding: 0 !important; writing-mode: horizontal-tb !important; }
body { width: 100vw !important; min-height: 100vh !important; font-size: 20px; line-height: 1.8; }
body::after { content: ''; display: block; inline-size: 1px; block-size: 36vh; }`;
}

async function open(browser, vertical, resistance) {
  const engine = fs.readFileSync(path.join(os.tmpdir(), 'fushi_engine_continuous.html'), 'utf8');
  const CONFIG = {
    vnMode: false, continuousMode: true, perfTraceEnabled: false,
    chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
    initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
    continuousTurnPullPx: resistance.pullPx, continuousTurnPinMidGesture: resistance.mid,
  };
  const install = `<script>window.__fushiApplyReaderMargins = function(){};
window.__boundary = [];
window.flutter_inappwebview = { callHandler: function(name, a) { if (name === 'onBoundarySwipe') window.__boundary.push(a); return Promise.resolve(null); } };
window.__fushiReaderConfig = ${JSON.stringify(CONFIG)};
window.__fushiInstallShell(window.__fushiReaderConfig);</script>`;
  const full = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>${css(vertical)}</style></head><body>${paras}\n${engine}\n${install}</body></html>`;
  const page = await browser.newPage();
  await page.emulate({
    viewport: { width: W, height: H, isMobile: true, hasTouch: true, deviceScaleFactor: 1 },
    userAgent: 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Mobile Safari/537.36',
  });
  await page.setRequestInterception(true);
  page.on('request', (q) => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({ status: 200, contentType: 'text/html', body: full });
    if (u.startsWith('https://fushi.local')) return q.respond({ status: 404, body: '' });
    return q.continue();
  });
  page.on('pageerror', (e) => console.log('  pageerror:', e.message));
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) console.log('  navigated:', f.url()); });
  await page.goto('https://fushi.local/chapter', { waitUntil: 'load', timeout: 8000 }).catch(() => {});
  await new Promise((r) => setTimeout(r, 700));
  const cdp = await page.createCDPSession();
  return { page, cdp };
}

// 手势：沿「前进」方向走 main、交叉轴走 cross（CSS px）。横排前进 = 手指上推，竖排 = 手指右移。
async function drag(cdp, vertical, x0, y0, main, cross, steps = 24) {
  const dx = vertical ? main : cross;
  const dy = vertical ? cross : -main;
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x0, y: y0 }] });
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchMove', touchPoints: [{ x: x0 + (dx * i) / steps, y: y0 + (dy * i) / steps }],
    });
    await new Promise((r) => setTimeout(r, 16));
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await new Promise((r) => setTimeout(r, 900));
}

const pos = (page, vertical) => page.evaluate((v) => {
  const root = document.scrollingElement;
  return v ? Math.abs(root.scrollLeft) : root.scrollTop;
}, vertical);
const max = (page, vertical) => page.evaluate((v) => {
  const root = document.scrollingElement;
  return v ? root.scrollWidth - innerWidth : root.scrollHeight - innerHeight;
}, vertical);
const setPos = (page, vertical, p) => page.evaluate((v, p) => {
  const root = document.scrollingElement;
  if (v) root.scrollLeft = -p; else root.scrollTop = p;
}, vertical, p);
const boundary = (page) => page.evaluate(() => { const b = window.__boundary.slice(); window.__boundary.length = 0; return b; });

const STANDARD = { pullPx: 20, mid: false }, LOW = { pullPx: 20, mid: true }, HIGH = { pullPx: 96, mid: false };
const problems = [];
const check = (cond, msg) => { if (!cond) problems.push(msg); console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${msg}`); };

const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox', '--overscroll-history-navigation=0', '--disable-features=OverscrollHistoryNavigation'] });
try {
  for (const vertical of [false, true]) {
    const tag = vertical ? 'vertical-rl' : 'horizontal-tb';
    // 起点坐标：横排手指从下往上推，竖排从左往右。
    const x0 = vertical ? 40 : 60, y0 = vertical ? 200 : 650;
    console.log(`== ${tag} standard`);
    let { page, cdp } = await open(browser, vertical, STANDARD);
    const m = await max(page, vertical);
    check(m > 2000, `${tag}: chapter long enough to scroll (max=${Math.round(m)})`);
    // ① 斜滑补位：60° 斜滑（Chromium 原生不滚）正文跟着主轴走。
    await setPos(page, vertical, 1000);
    let before = await pos(page, vertical);
    await drag(cdp, vertical, x0, y0, 150, 260);
    let moved = (await pos(page, vertical)) - before;
    check(moved >= 130, `${tag}: 60° diagonal swipe scrolls forward (moved=${Math.round(moved)})`);
    // 主轴占优的 30° 斜滑：原生滚动，补位不得叠加（位移不超过手指主轴位移 + 原生惯性的合理范围）。
    await setPos(page, vertical, 1000);
    before = await pos(page, vertical);
    await drag(cdp, vertical, x0, y0, 260, 150);
    moved = (await pos(page, vertical)) - before;
    check(moved >= 200, `${tag}: 30° diagonal swipe scrolls natively (moved=${Math.round(moved)})`);
    // 近乎横划（80°）：不是阅读滚动，正文不动、不跨章。
    await setPos(page, vertical, 1000);
    before = await pos(page, vertical);
    await drag(cdp, vertical, x0, y0, 50, 290);
    moved = (await pos(page, vertical)) - before;
    check(Math.abs(moved) < 2, `${tag}: near-cross-axis swipe does not scroll (moved=${Math.round(moved)})`);
    await boundary(page);
    // ③ 标准档：起点已贴章末 + 50° 斜着再推 → 跨下一章。
    await setPos(page, vertical, m);
    await drag(cdp, vertical, x0, y0, 80, 95);
    check(JSON.stringify(await boundary(page)) === '["forward"]', `${tag}: standard, start pinned at end + diagonal pull → forward`);
    // 标准档：从章中一口气滚到章末继续推 → 不跨章（TODO-656）。
    await setPos(page, vertical, m - 120);
    await drag(cdp, vertical, x0, y0, 260, 0);
    check(JSON.stringify(await boundary(page)) === '[]', `${tag}: standard, same gesture reaching end does not cross`);
    // 章首向后拉 → 上一章。
    await setPos(page, vertical, 0);
    const bx = vertical ? 360 : 60, by = vertical ? 200 : 150;
    await drag(cdp, vertical, bx, by, -80, 40);
    check(JSON.stringify(await boundary(page)) === '["backward"]', `${tag}: standard, start pinned at start + backward pull → backward`);
    await page.close();

    console.log(`== ${tag} low`);
    ({ page, cdp } = await open(browser, vertical, LOW));
    const m2 = await max(page, vertical);
    await setPos(page, vertical, m2 - 120);
    await drag(cdp, vertical, x0, y0, 260, 0);
    check(JSON.stringify(await boundary(page)) === '["forward"]', `${tag}: low, same gesture reaching end and pushing on → forward`);
    await setPos(page, vertical, m2 - 400);
    await drag(cdp, vertical, x0, y0, 120, 0);
    check(JSON.stringify(await boundary(page)) === '[]', `${tag}: low, gesture that never reaches the end does not cross`);
    await page.close();

    console.log(`== ${tag} high`);
    ({ page, cdp } = await open(browser, vertical, HIGH));
    const m3 = await max(page, vertical);
    await setPos(page, vertical, m3);
    await drag(cdp, vertical, x0, y0, 60, 0);
    check(JSON.stringify(await boundary(page)) === '[]', `${tag}: high, 60px pull at end does not cross`);
    await setPos(page, vertical, m3);
    await drag(cdp, vertical, x0, y0, 140, 0);
    check(JSON.stringify(await boundary(page)) === '["forward"]', `${tag}: high, 140px pull at end → forward`);
    await page.close();
  }
} finally {
  await browser.close();
}
console.log(problems.length ? `FAILED ${problems.length}` : 'ALL OK');
process.exit(problems.length ? 1 : 0);
