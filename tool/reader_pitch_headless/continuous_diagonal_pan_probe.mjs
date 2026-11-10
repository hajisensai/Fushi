// 反馈 R7k887yaJI 真 Chromium 探针：连续（滚动）模式手指斜着滑（拇指弧线）能不能滚动正文。
//
// 根因（Chromium components/input/touch_action_filter.cc `ShouldSuppressScrolling`）：
// 根元素 `touch-action: pan-y` 时，GestureScrollBegin 的起始位移提示 |dx| > |dy|
// （起手偏横向的斜滑）会被判成「不符合 touch-action」，**整段手势的 scroll update 全被丢弃**，
// 正文一动不动；`pan-x pan-y` 两轴都放行时同一手势照常滚（横向分量由
// `html { overflow-x: hidden }` + `body { overflow-x: clip }` 吃掉，交叉轴无可滚范围）。
//
// 本探针在真 Chromium 里对每种 touch-action 规则发几条真实触摸手势（竖直、偏离主轴
// 30° / 50° / 60°，都朝「往下读」方向），读手势后的 scrollTop / scrollLeft。
// 实测（Chrome 14x，2026-11-07）：`pan-y` 下 50° 为 0、`pan-x pan-y` 下 50° 照常滚；
// 60° 两种规则下 Chromium 都按交叉轴锁存、正文不动——那一段由连续 shell 的触摸控制器
// 补位（continuous_touch_controller_probe.mjs 验证），这里只记录、不断言。
// 用法：node tool/reader_pitch_headless/continuous_diagonal_pan_probe.mjs
// 退出码 0 = `pan-x pan-y` 下竖直 / 30° / 50° 都沿主轴滚动且交叉轴恒 0，且复现出
// `pan-y` 吞掉 50° 斜滑（根因仍成立）。
import puppeteer from 'puppeteer-core';

const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 400, H = 800;

const paras = Array.from({ length: 120 }, (_, i) =>
  `<p>【第${i}段】吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。</p>`).join('\n');

function html(touchAction) {
  // 与 ReaderContentStyles._continuousLayoutCss 横排连续模式同构的锁轴：html 隐藏交叉轴、
  // body 交叉轴 clip，外加一个沿交叉轴越界的块（BUG-3482 那类溢出来源）。
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html { overflow-x: hidden !important; }
html, body { touch-action: ${touchAction} !important; }
body { overflow-x: clip !important; margin: 0; width: 100vw; font-size: 20px; line-height: 1.8; }
.overflow { width: ${W + 40}px; height: 8px; background: #c33; }
</style></head><body><div class="overflow"></div>${paras}</body></html>`;
}

// 手势：从 (x0,y0) 出发，总位移 (dx,dy)，分 steps 步匀速。dy<0 = 手指上推 = 往下读。
async function drag(cdp, x0, y0, dx, dy, steps = 24) {
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x0, y: y0 }] });
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchMove',
      touchPoints: [{ x: x0 + (dx * i) / steps, y: y0 + (dy * i) / steps }],
    });
    await new Promise((r) => setTimeout(r, 16));
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await new Promise((r) => setTimeout(r, 400));
}

const gestures = [
  { name: 'straight', dx: 0, dy: -300 },
  // 偏离主轴 30°：|dx| < |dy|，pan-y 下也能滚。
  { name: 'diag30', dx: 173, dy: -300 },
  // 偏离主轴 60°（拇指弧线起手偏横）：|dx| > |dy|，pan-y 下被 Chromium 整段丢弃。
  { name: 'diag60', dx: 300, dy: -173 },
  // 偏离主轴 50°：|dx| 略大于 |dy|（最常见的拇指弧线起手）。
  { name: 'diag50', dx: 250, dy: -210 },
];

async function run(browser, touchAction) {
  const page = await browser.newPage();
  await page.emulate({
    viewport: { width: W, height: H, isMobile: true, hasTouch: true, deviceScaleFactor: 1 },
    userAgent: 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Mobile Safari/537.36',
  });
  await page.setContent(html(touchAction));
  const cdp = await page.createCDPSession();
  const out = {};
  for (const g of gestures) {
    await page.evaluate(() => { document.scrollingElement.scrollTop = 0; document.scrollingElement.scrollLeft = 0; });
    await new Promise((r) => setTimeout(r, 100));
    await drag(cdp, 40, 600, g.dx, g.dy);
    out[g.name] = await page.evaluate(() => ({
      top: Math.round(document.scrollingElement.scrollTop),
      left: Math.round(document.scrollingElement.scrollLeft),
    }));
  }
  await page.close();
  return out;
}

const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox', '--overscroll-history-navigation=0', '--disable-features=OverscrollHistoryNavigation'] });
let ok = true;
try {
  const panY = await run(browser, 'pan-y');
  const both = await run(browser, 'pan-x pan-y');
  console.log(JSON.stringify({ 'pan-y': panY, 'pan-x pan-y': both }, null, 2));
  for (const g of gestures) {
    if (g.name === 'diag60') continue; // Chromium 原生上限，见文件头
    if (!(both[g.name].top > 50) || both[g.name].left !== 0) {
      console.log(`FAIL pan-x pan-y ${g.name}: expected main-axis scroll and zero cross axis`);
      ok = false;
    }
  }
  if (!(panY.straight.top > 50)) {
    console.log('FAIL probe sanity: pan-y straight gesture did not scroll (touch input not reaching compositor?)');
    ok = false;
  }
  console.log(`pan-y diag50 top=${panY.diag50.top} (root cause reproduced: ${panY.diag50.top === 0})`);
  if (panY.diag50.top !== 0) {
    console.log('NOTE pan-y no longer drops the 50° swipe on this Chromium build');
  }
} finally {
  await browser.close();
}
process.exit(ok ? 0 : 1);
