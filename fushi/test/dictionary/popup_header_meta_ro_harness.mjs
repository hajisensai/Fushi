// 反馈 3op205DyWN（BUG-4106）：查词弹窗词头元数据列的 ResizeObserver 不得再触发
// 「ResizeObserver loop completed with undelivered notifications」。
//
// 真 Chrome 里加载生产 popup.css + popup.js 里词头元数据列那一段（observer + 判据），
// 摆 N 个与 createEntryHeader 同构的词头，先观察、再把容器拖宽 / 拖回窄，统计
// window 'error' 里的 ResizeObserver 报错，并核对 .meta-stacked 的挂摘结果。旧实现在
// 回调里同步挂类、改了被观察的 .entry-header 自身尺寸：每次宽度变化必报一条，经
// window.onerror 桥落进错误日志（用户日志里 1489 条，把 200 条上限挤满）。
//
// 运行：node fushi/test/dictionary/popup_header_meta_ro_harness.mjs（cwd = fushi/）
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const popupDir = path.resolve(here, '..', '..', 'assets', 'popup');
const popupSrc = fs.readFileSync(path.join(popupDir, 'popup.js'), 'utf8');
const css = fs.readFileSync(path.join(popupDir, 'popup.css'), 'utf8');

const start = popupSrc.indexOf('var __fushiHeaderMetaObserver = null;');
const end = popupSrc.indexOf('function appendNextDeferredGlossaryBlock');
if (start < 0 || end < start) {
  console.error('popup.js 里找不到词头元数据列 observer 段');
  process.exit(1);
}
const block = popupSrc.slice(start, end);

const GLOSS = Array.from({ length: 200 }, (_, k) => `<span>釈義テキスト${k} </span>`).join('');
const HEADER_COUNT = 30;
const NARROW = 360;
const WIDE = 700;

function page() {
  const entries = [];
  for (let i = 0; i < HEADER_COUNT; i++) {
    entries.push(
      '<div class="entry"><div class="entry-header"><div class="entry-header-main">'
      + `<div class="expression-scroll"><span class="expression">見出し語${i}</span></div>`
      + '<div class="entry-header-meta"><div class="frequency-section">頻度 12345 · 6789 · 1111</div></div>'
      + '</div><div class="header-buttons">'
      + '<button style="width:36px;height:36px">a</button><button style="width:36px;height:36px">b</button>'
      + '<button style="width:36px;height:36px">c</button><button style="width:36px;height:36px">d</button>'
      + `</div></div><div class="gloss">${GLOSS}</div></div>`);
  }
  return `<!doctype html><html class="fushi-m3e"><head><meta charset="utf-8"><style>${css}</style></head>
<body><div id="entries-container" style="width:${NARROW}px">${entries.join('')}</div>
<script>
window.__roErrors = [];
window.addEventListener('error', function (e) {
  if (String(e && e.message).indexOf('ResizeObserver') >= 0) window.__roErrors.push(String(e.message));
});
${block}
</script></body></html>`;
}

const expr = `(async () => {
  const frames = (n) => new Promise((resolve) => {
    let left = n;
    const step = () => (--left <= 0 ? resolve() : requestAnimationFrame(step));
    requestAnimationFrame(step);
  });
  const headers = [...document.querySelectorAll('.entry-header')];
  const stacked = () => headers.filter((h) => h.classList.contains('meta-stacked')).length;
  const container = document.getElementById('entries-container');
  headers.forEach(observeEntryHeaderMetaLayout);
  await frames(8);
  const narrow = stacked();
  container.style.width = '${WIDE}px';
  await frames(8);
  const wide = stacked();
  container.style.width = '${NARROW}px';
  await frames(8);
  const back = stacked();
  return { headers: headers.length, narrow, wide, back, errors: window.__roErrors };
})()`;

const timer = setTimeout(() => {
  console.error('harness timed out after 60 s');
  process.exit(2);
}, 60000);

const driver = await launchChromeDriver();
let failed = false;
try {
  const r = await driver.evalOnPage(page(), expr);
  console.log(JSON.stringify(r));
  const check = (ok, msg) => {
    if (!ok) {
      failed = true;
      console.error(`FAIL ${msg}`);
    }
  };
  check(r.headers === HEADER_COUNT, `expected ${HEADER_COUNT} headers, got ${r.headers}`);
  check(r.narrow === HEADER_COUNT, `narrow popup: every header should stack, got ${r.narrow}`);
  check(r.wide === 0, `wide popup: no header should stack, got ${r.wide}`);
  check(r.back === HEADER_COUNT, `narrow again: every header should stack, got ${r.back}`);
  check(r.errors.length === 0, `ResizeObserver loop errors: ${JSON.stringify(r.errors)}`);
} finally {
  driver.close();
  clearTimeout(timer);
}
if (failed) process.exit(1);
console.log('PASS popup header meta ResizeObserver');
