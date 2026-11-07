// 反馈 R7k887yaJI ③ 真 Chromium 探针：连续模式章节无缝衔接（reader_seamless_chapters_script.dart）。
//
// 吃 reader_headless_shell_dump_test.dart 写到 systemTemp 的**完整引擎源码**
// fushi_full_engine_continuous.js（与生产 evaluateJavascript 注入的同一份：选区 + 连续 shell
// + caret + setup），按生产顺序「文档 load 之后 eval 引擎源码 + boot」安装。4 章同源服务在
// https://fushi.local/epub/…，第 2 章放在另一个目录、带一张相对路径插图（验证 URL 改写与
// 解码后再插入）。flutter_inappwebview.callHandler 桩成一个假的 Dart：记录
// onSeamlessChapterActivated，探针手动决定何时 ack。
//
//   flutter test test/reader/reader_headless_shell_dump_test.dart --no-pub   # 写引擎到 systemTemp
//   node tool/reader_pitch_headless/continuous_seamless_chapters_probe.mjs
// 退出码 0 = 横排 / 竖排 + 开关关闭三组断言全部成立。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';

const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 420, H = 760;
const TOP = 40, BOTTOM = 30;
const ENGINE = fs.readFileSync(path.join(os.tmpdir(), 'fushi_full_engine_continuous.js'), 'utf8');

const CHAPTERS = [
  { path: '/epub/OEBPS/Text/ch0.xhtml', paras: 30 },
  { path: '/epub/OEBPS/Text/ch1.xhtml', paras: 40 },
  { path: '/epub/OEBPS/Text2/ch2.xhtml', paras: 40, image: true },
  { path: '/epub/OEBPS/Text/ch3.xhtml', paras: 30 },
];
const url = (i) => 'https://fushi.local' + CHAPTERS[i].path;
const PIC = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300"><rect width="400" height="300" fill="#c84"/></svg>`;
const EPUB_CSS = `body { color: #111; } p { margin: 0 0 0.4em 0; } body > h1 { font-size: 1.4em; margin: 0 0 0.6em 0; }`;

function readerCss(vertical) {
  const axis = vertical ? 'overflow-y' : 'overflow-x';
  return `html { ${axis}: hidden !important; }
html, body { touch-action: pan-x pan-y !important; }
body { ${axis}: clip !important; }
html, body { margin: 0 !important; padding: 0 !important; background: #fff !important; writing-mode: ${vertical ? 'vertical-rl' : 'horizontal-tb'} !important; }
body { font-size: 20px !important; line-height: 1.8; position: relative !important; box-sizing: border-box !important;
  ${vertical ? 'height: var(--fushi-continuous-height, 100vh) !important;' : 'width: 100vw !important; min-height: 100vh !important;'}
  padding: 0 16px !important;
  padding-top: calc(10px + var(--chrome-top-inset, 0px)) !important;
  padding-bottom: calc(10px + var(--chrome-bottom-inset, 0px)) !important;
  clip-path: inset(var(--chrome-top-inset, 0px) 0 var(--chrome-bottom-inset, 0px) 0) !important; }
body::after { content: '' !important; display: block !important; block-size: ${vertical ? '36vw' : '36vh'} !important; inline-size: 100% !important; }
img.block-img { max-inline-size: 100%; display: block; }`;
}

function chapterHtml(i, vertical) {
  const c = CHAPTERS[i];
  const paras = Array.from({ length: c.paras }, (_, k) =>
    `<p>【第${i}章-${k}段】吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。</p>`).join('\n');
  const css = i === 2 ? '../Styles/style.css' : '../Styles/style.css';
  const img = c.image ? `<p><img src="../Images/pic.svg" alt=""/></p>` : '';
  return `<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8"/>
<style id="fushi-cloak">body{visibility:hidden!important}</style>
<link rel="stylesheet" type="text/css" href="${css}"/>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>
<style id="fushi-reader-style">${readerCss(vertical)}</style></head>
<body class="ch${i}"><h1 id="t">第${i}章</h1>
${img}
${paras}
<p><a href="#t">top</a></p>
</body></html>`;
}

function config(vertical, seamless) {
  return {
    navigationGeneration: 1, continuousMode: true, vnMode: false, vnClickAdvance: false,
    scanNonJapaneseText: false, hoverAutoLookup: false, hoverKey: 'shiftKey', hostHoverLookup: false,
    highlightOnTap: false, showChrome: false, debugLogging: false,
    swipeDistThreshold: 24, swipeFastDistThreshold: 12, swipeFastVelocity: 300, wheelGestureQuietMs: 300,
    continuousTurnPullPx: 20, continuousTurnPinMidGesture: false,
    pageTurnAnimation: 'none', pageTurnDurationMs: 0, pageTurnFollowDrag: false,
    furiganaMode: 'off', caretColor: '#f00', caretInsetTop: TOP, caretInsetBottom: BOTTOM,
    initialProgress: 0, initialCharOffset: -1, initialCharOffsetEnd: -1, initialFragment: null,
    chromeTopInset: TOP, chromeBottomInset: BOTTOM, dartPageWidth: W, dartPageHeight: H,
    marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0,
    blurImages: false, revealedKeys: [], perfTraceEnabled: false,
    vnRevealSpeed: 0, vnScreenMode: 'sentence', vnSentencesPerScreen: 1, vnPreserveDialogue: false,
    vnMergeCrossScreenSentenceAudioCues: false,
    seamlessChapters: seamless, seamlessChapterIndex: seamless ? 1 : -1,
    seamlessChapterOrder: seamless ? CHAPTERS.map((c, i) => ({ index: i, url: url(i) })) : [],
    sentenceAudioCues: null,
  };
}

let failures = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label}${detail !== undefined ? ' :: ' + JSON.stringify(detail) : ''}`);
  if (!ok) failures++;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function open(browser, vertical, seamless) {
  const page = await browser.newPage();
  await page.emulate({
    viewport: { width: W, height: H, isMobile: true, hasTouch: true, deviceScaleFactor: 1 },
    userAgent: 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Mobile Safari/537.36',
  });
  await page.setRequestInterception(true);
  page.on('request', (q) => {
    const u = new URL(q.url());
    if (u.host !== 'fushi.local') return q.continue();
    const idx = CHAPTERS.findIndex((c) => c.path === u.pathname);
    if (idx >= 0) return q.respond({ status: 200, contentType: 'text/html', body: chapterHtml(idx, vertical) });
    if (u.pathname === '/epub/OEBPS/Styles/style.css') return q.respond({ status: 200, contentType: 'text/css', body: EPUB_CSS });
    if (u.pathname === '/epub/OEBPS/Images/pic.svg') return q.respond({ status: 200, contentType: 'image/svg+xml', body: PIC });
    return q.respond({ status: 404, body: '' });
  });
  page.on('pageerror', (e) => console.log('  pageerror:', e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.log('  console.error:', m.text()); });
  await page.evaluateOnNewDocument(() => {
    window.__events = [];
    window.flutter_inappwebview = {
      callHandler: function(name) {
        window.__events.push([name].concat(Array.prototype.slice.call(arguments, 1)));
        return Promise.resolve(null);
      },
    };
  });
  await page.goto(url(1), { waitUntil: 'load', timeout: 8000 });
  const boot = `window.__fushiReaderConfig = ${JSON.stringify(config(vertical, seamless))};window.__fushiEngine.install(window.__fushiReaderConfig);`;
  await page.evaluate(ENGINE + '\n' + boot);
  await sleep(900);
  return page;
}

const state = (page) => page.evaluate(() => {
  const S = window.__fushiSeamless;
  const r = window.fushiReader;
  const firstP = Array.from(document.body.children).find((e) => e.localName === 'p' && e.textContent.indexOf('【') === 0);
  return {
    installed: !!S,
    active: S ? S.activeChapter : null,
    mounted: S ? S.mountedChapters() : [],
    total: r.chapterCharTotal(),
    firstVisible: r.getFirstVisibleCharOffset(),
    firstText: firstP ? firstP.textContent.slice(0, 8) : null,
    events: window.__events.filter((e) => e[0] === 'onSeamlessChapterActivated'),
    restoreCount: window.__events.filter((e) => e[0] === 'onRestoreComplete').length,
    details: window.fushiProgressDetails(),
    awaiting: S ? S.awaitingAck() : null,
  };
});

// 用户滚动一步：先发一个真实的 wheel 事件（模块的用户意图监听走 document capture），再按
// 主轴前进 [step] px。竖排 vertical-rl 前进 = 往左滚。
const userStep = (page, vertical, step) => page.evaluate((v, s) => {
  document.dispatchEvent(new WheelEvent('wheel', { deltaY: s, bubbles: true }));
  if (v) window.scrollBy({ left: -s, top: 0, behavior: 'auto' });
  else window.scrollBy({ left: 0, top: s, behavior: 'auto' });
  return new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(true))));
}, vertical, step);

// 记录晋升前后视口中心元素的主轴位移（锚点补偿是否生效）。
const instrumentPromote = (page, vertical) => page.evaluate((v) => {
  const S = window.__fushiSeamless;
  const orig = S.promote;
  window.__promoteDeltas = [];
  function deep() {
    let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(innerWidth / 2, innerHeight / 2);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }
  const edge = (el) => { const r = el.getBoundingClientRect(); return v ? r.left : r.top; };
  S.promote = function(h) {
    const el = deep();
    const before = el ? edge(el) : null;
    const text = el ? (el.textContent || '').slice(0, 10) : null;
    const out = orig.apply(this, arguments);
    window.__promoteDeltas.push({ text, delta: el && before !== null ? edge(el) - before : null, connectedLight: el ? el.getRootNode() === document : null });
    return out;
  };
}, vertical);

async function scrollUntilActive(page, vertical, target, dir, maxSteps = 200) {
  for (let i = 0; i < maxSteps; i++) {
    const s = await page.evaluate(() => window.__fushiSeamless.activeChapter);
    if (s === target) return true;
    await userStep(page, vertical, dir * 120);
  }
  return false;
}

async function runSeamless(browser, vertical) {
  const tag = vertical ? '[vertical]' : '[horizontal]';
  const page = await open(browser, vertical, true);
  let s = await state(page);
  check(`${tag} module installed and started`, s.installed && s.active === 1, s);
  check(`${tag} neighbors 0 and 2 mounted`, JSON.stringify(s.mounted.slice().sort()) === '[0,2]', s.mounted);
  check(`${tag} chapter start stays at viewport start after prev mount`, s.firstVisible === 0, s.firstVisible);
  const geometry = await page.evaluate((v) => {
    const h1 = Array.from(document.body.children).find((e) => e.localName === 'h1');
    const r = h1.getBoundingClientRect();
    const cs = getComputedStyle(document.body);
    return { edge: v ? innerWidth - r.right : r.top, pad: v ? parseFloat(cs.paddingRight) : parseFloat(cs.paddingTop), text: h1.textContent };
  }, vertical);
  check(`${tag} active h1 sits at body padding start (prev chapter above it, not on top of it)`,
    geometry.text === '第1章' && Math.abs(geometry.edge - geometry.pad) <= 2, geometry);
  const ownTotal = s.total;
  check(`${tag} engine index covers only the active chapter`, ownTotal > 0 && /第1章/.test(s.firstText), { ownTotal, firstText: s.firstText });
  const hostInfo = await page.evaluate(() => {
    const hs = Array.from(document.querySelectorAll('fushi-seamless-chapter'));
    return hs.map((h) => {
      const b = h.shadowRoot.querySelector('.fushi-seamless-body');
      const img = h.shadowRoot.querySelector('img');
      return {
        ch: h.getAttribute('data-chapter'),
        textInBody: document.body.innerText.indexOf('第' + h.getAttribute('data-chapter') + '章-0段') >= 0,
        bodyClass: b.className,
        img: img ? { src: img.src, w: img.naturalWidth } : null,
        rect: (() => { const r = h.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; })(),
      };
    });
  });
  const h2 = hostInfo.find((h) => h.ch === '2');
  check(`${tag} neighbor content is invisible to body text queries (shadow DOM)`, hostInfo.every((h) => !h.textInBody), hostInfo);
  check(`${tag} neighbor image src rewritten against its own chapter URL and decoded`,
    h2 && h2.img && h2.img.src === 'https://fushi.local/epub/OEBPS/Images/pic.svg' && h2.img.w === 400, h2);
  check(`${tag} neighbor body carries its own chapter class`, h2 && /\bch2\b/.test(h2.bodyClass), h2 && h2.bodyClass);

  // 程序化滚动（模拟有声书跟读）越过章界不晋升。
  await page.evaluate((v) => {
    const r = window.fushiReader;
    r.scrollToCharOffset(r.chapterCharTotal() - 2);
    const host = document.querySelector('fushi-seamless-chapter[data-chapter="2"]');
    const rect = host.getBoundingClientRect();
    if (v) window.scrollBy(-((innerWidth - rect.right) - (innerWidth / 2 - 100)), 0);
    else window.scrollBy(0, rect.top - (innerHeight / 2 - 100));
  }, vertical);
  await sleep(400);
  s = await state(page);
  check(`${tag} programmatic scroll across the boundary does not promote`, s.active === 1, s.active);

  // 回到第 1 章中段，再由用户滚过章界。
  await page.evaluate(() => window.fushiReader.restoreProgress(0.5));
  await sleep(300);
  await instrumentPromote(page, vertical);
  const reached = await scrollUntilActive(page, vertical, 2, 1);
  s = await state(page);
  check(`${tag} user scroll across the boundary promotes chapter 2`, reached && s.active === 2, s.active);
  check(`${tag} Dart notified once with (2, 1, seq 1)`, s.events.length === 1 && s.events[0][1] === 2 && s.events[0][2] === 1 && s.events[0][3] === 1, s.events);
  check(`${tag} progress snapshot gated (null) until Dart ack`, s.awaiting === true && s.details === null, { awaiting: s.awaiting, details: s.details });
  const deltas = await page.evaluate(() => window.__promoteDeltas);
  check(`${tag} viewport anchor did not move across promotion`, deltas.length === 1 && deltas[0].delta !== null && Math.abs(deltas[0].delta) <= 1.5, deltas);
  const acked = await page.evaluate(() => window.__fushiSeamless.ack(1, 7));
  s = await state(page);
  const parts = String(s.details || '').split(',');
  check(`${tag} after ack progress resumes and is chapter-2-scoped`, acked === true && s.awaiting === false && parts.length >= 3 && Number(parts[1]) === s.total, { details: s.details, total: s.total });
  check(`${tag} generation adopted from ack`, await page.evaluate(() => window.__fushiReaderConfig.navigationGeneration === 7), null);
  const ch2Total = await page.evaluate(() => {
    let n = 0;
    const r = window.fushiReader;
    const w = r.createWalker();
    let node;
    while ((node = w.nextNode())) n += r.countChars(node.textContent);
    return n;
  });
  check(`${tag} engine index now covers chapter 2 only`, /第2章/.test(s.firstText) && s.total === ch2Total, { firstText: s.firstText, total: s.total, ch2Total });
  const light = await page.evaluate(() => {
    const img = document.body.querySelector('img');
    return {
      img: img ? { src: img.src, w: img.naturalWidth, wrapped: !!img.closest('.block-img-wrapper') } : null,
      bodyHasCh2: document.body.classList.contains('ch2'),
      bodyHasCh1: document.body.classList.contains('ch1'),
      count: document.body.querySelectorAll(':scope > p').length,
      linkHref: (Array.from(document.body.querySelectorAll('a')).pop() || {}).href,
    };
  });
  check(`${tag} promoted content is light DOM with its own body class, image and absolute fragment link`,
    light.img && light.img.w === 400 && light.img.wrapped && light.bodyHasCh2 && !light.bodyHasCh1 &&
    light.linkHref === 'https://fushi.local/epub/OEBPS/Text2/ch2.xhtml#t', light);
  await sleep(700);
  s = await state(page);
  check(`${tag} window slid: chapter 0 unmounted, 1 and 3 mounted`, JSON.stringify(s.mounted.slice().sort()) === '[1,3]', s.mounted);

  // 章首落点在上一章挂载时以活动章边界为准。
  await page.evaluate(() => window.fushiReader.scrollToChapterStart());
  await sleep(100);
  s = await state(page);
  check(`${tag} scrollToChapterStart lands on the active chapter start, not document top`, s.firstVisible === 0 && s.active === 2 && /第2章/.test(s.firstText), s.firstVisible);
  const atStart = await page.evaluate((v) => {
    const h1 = Array.from(document.body.children).find((e) => e.localName === 'h1');
    const r = h1.getBoundingClientRect();
    const cs = getComputedStyle(document.body);
    return { edge: v ? innerWidth - r.right : r.top, pad: v ? parseFloat(cs.paddingRight) : parseFloat(cs.paddingTop) };
  }, vertical);
  check(`${tag} active h1 aligned to body padding start`, Math.abs(atStart.edge - atStart.pad) <= 2, atStart);
  check(`${tag} isAtEnd is false at chapter start with a next neighbor mounted`, await page.evaluate(() => window.fushiReader.isAtEnd() === false), null);

  // 用户往回滚过章界：晋升回第 1 章。
  const back = await scrollUntilActive(page, vertical, 1, -1);
  s = await state(page);
  check(`${tag} scrolling back promotes chapter 1 again`, back && s.active === 1 && /第1章/.test(s.firstText), s);
  const deltas2 = await page.evaluate(() => window.__promoteDeltas);
  check(`${tag} viewport anchor stable on backward promotion`, deltas2.length === 2 && Math.abs(deltas2[1].delta) <= 1.5, deltas2);
  check(`${tag} backward activation event (1, 2, seq 2)`, s.events.length === 2 && s.events[1][1] === 1 && s.events[1][2] === 2 && s.events[1][3] === 2, s.events);
  await page.evaluate(() => window.__fushiSeamless.ack(2, 8));

  // 轻点邻章即晋升，坐标落在同一个字上。
  await page.evaluate(() => window.fushiReader.restoreProgress(0.99));
  await sleep(300);
  const tap = await page.evaluate((v) => {
    const host = document.querySelector('fushi-seamless-chapter[data-chapter="2"]');
    let r = host.getBoundingClientRect();
    // 程序化推进到「下一章露出 1/4 屏、视口中心仍在第 1 章」。
    if (v) window.scrollBy(-((innerWidth - r.right) - innerWidth * 0.75), 0);
    else window.scrollBy(0, r.top - innerHeight * 0.75);
    r = host.getBoundingClientRect();
    const x = v ? (Math.max(r.left, 0) + Math.min(r.right, innerWidth)) / 2 : innerWidth / 2;
    const y = v ? innerHeight / 2 : (Math.max(r.top, 0) + Math.min(r.bottom, innerHeight)) / 2;
    return { x, y, visible: v ? r.right > 0 && r.left < innerWidth : r.top < innerHeight && r.bottom > 0 };
  }, vertical);
  if (tap.visible) {
    const cdp = await page.createCDPSession();
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: tap.x, y: tap.y }] });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await sleep(200);
    s = await state(page);
    check(`${tag} tap inside the next neighbor promotes it`, s.active === 2, { active: s.active, tap });
    const hit = await page.evaluate((x, y) => {
      const range = document.caretRangeFromPoint(x, y);
      const n = range && range.startContainer;
      if (!n) return null;
      const el = n.nodeType === 1 ? n : n.parentElement;
      const block = el.closest('p, h1') || el;
      return { light: n.getRootNode() === document, block: (block.textContent || '').slice(0, 10), img: !!block.querySelector('img') };
    }, tap.x, tap.y);
    check(`${tag} same tap point now resolves to light-DOM content of chapter 2`,
      hit && hit.light && (/第2章/.test(hit.block) || hit.img), hit);
  } else {
    check(`${tag} next neighbor visible for tap test`, false, tap);
  }
  await page.close();
}

async function runOff(browser) {
  const page = await open(browser, false, false);
  await sleep(500);
  let s = await state(page);
  check('[off] module not installed', !s.installed, s.installed);
  for (let i = 0; i < 60; i++) await userStep(page, false, 200);
  s = await state(page);
  const hostCount = await page.evaluate(() => document.querySelectorAll('fushi-seamless-chapter').length);
  check('[off] no neighbor hosts after scrolling to the end', hostCount === 0, hostCount);
  check('[off] progress snapshot not gated', typeof s.details === 'string' && s.details.length > 0, s.details);
  check('[off] isAtEnd reflects the physical end', await page.evaluate(() => window.fushiReader.isAtEnd() === true), null);
  await page.close();
}

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: 'new',
  args: ['--no-sandbox', '--overscroll-history-navigation=0', `--window-size=${W},${H}`],
});
try {
  await runSeamless(browser, false);
  await runSeamless(browser, true);
  await runOff(browser);
} finally {
  await browser.close();
}
console.log(failures === 0 ? 'ALL OK' : `${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
