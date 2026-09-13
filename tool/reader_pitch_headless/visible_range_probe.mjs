// 可见字符区间 [start, end) 的真渲染探针（统计口径「翻走即计 + 覆盖并集」）。
//
// Dart 侧每次进度采样读 `fushiProgressDetails()` 的第三/四段 = 当前可见区间两端
// （章内学习单位偏移）。起点 getFirstVisibleCharOffset 早有；终点 getLastVisibleCharOffset
// 是新增（分页对角 caret 探测 + 二分降级 / 连续末边 walk）。本探针在三种几何下从章首逐页
// / 逐屏翻到 isAtEnd，断言：
//   · 每步 start < end；
//   · 相邻步单调衔接：end_i − 1 <= start_{i+1} <= end_i + 1（允许边界一字误差）；
//   · 首页 start == 0（无前导图）；末页 end == total；
//   · 所有 [start, end) 的并集覆盖 [0, total) 的 >= 99%。
// 连续模式跑两遍：真实键盘翻屏路径 paginate('forward')（0.9H，参与断言；重叠合法、只查
// 无缝 + 覆盖）与整视口高 scrollBy（信息性，见几何表注释）。
//
// 先生成真引擎产物（CI 跑不到真 WebView，本探针本机跑）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 写引擎到 systemTemp
//   node tool/reader_pitch_headless/visible_range_probe.mjs         # 退出码 0=全绿
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import puppeteer from 'puppeteer-core';
import { fileURLToPath } from 'node:url';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800, PT = 24, PB = 32, PL = 20, PR = 28;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');

// fushiProgressDetails 不在引擎产物里（它是 webview.part.dart 的 setup 脚本一段），按
// reader_production_js_behavior_test 的切法从源码切出真实协议函数注入，探的就是生产协议。
function progressDetailsSource() {
  const src = fs.readFileSync(path.join(REPO, 'fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart'), 'utf8').replace(/\r\n/g, '\n');
  const start = src.indexOf('window.fushiProgressDetails = function()');
  const end = src.indexOf('\n  };', start);
  if (start < 0 || end < 0) throw new Error('fushiProgressDetails source not found');
  return src.slice(start, end + 5);
}

const paras = Array.from({length: 70}, (_, i) => `<p>P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。</p>`).join('\n');

const GEOMETRIES = [
  {
    name: 'paginated horizontal', engine: 'fushi_engine_paginated.html', continuous: false,
    css: `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:${PT}px ${PR}px ${PB}px ${PL}px;box-sizing:border-box;column-width:${W-PL-PR}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}`,
  },
  {
    name: 'paginated vertical', engine: 'fushi_engine_paginated.html', continuous: false,
    // 竖排：列（= 一页的一条横带）沿 Y 轴堆叠，column-width 是列高 = V − pt − pb；行自右向左。
    css: `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:${PT}px ${PR}px ${PB}px ${PL}px;box-sizing:border-box;writing-mode:vertical-rl;column-width:${H-PT-PB}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;}
 p{margin:0 1em 0 0;}`,
  },
  {
    // 真实键盘翻屏路径：连续 shell paginate('forward') 滚 0.9×视口高（相邻屏重叠两行）。
    // 断言无缝（start_{i+1} <= end_i + 1）+ 并集全覆盖；重叠合法（不查 >= end_i − 1）。
    name: 'continuous horizontal (paginate 0.9H)', engine: 'fushi_engine_continuous.html', continuous: true, step: 'paginate',
    css: `html,body{margin:0;padding:0;}
 body{padding:${PT}px ${PR}px ${PB}px ${PL}px;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}`,
  },
  {
    // 整视口高 scrollBy —— **信息性**，不参与退出码。这是离散最坏情况（真实路径里不存在：
    // 键盘翻屏走 paginate 0.9H、滚轮/触摸的 scroll 采样是 rAF 级密集的）：跨底边的半行在
    // end（rect.bottom <= innerHeight，未完整可见不计）与下一屏 start（caret 探
    // y=paddingTop+2，顶栏 inset 之下）之间两头都不算 → 每步最多漏一行（实测 4410 字
    // 8 步漏 125 字 ≈ 2.8%）。要闭合它只能把 end 判据改成「已开始可见」（rect.top < edge），
    // 代价是停读时底部半行被多计一行；口径取舍留给统计域决定，这里只把数字打出来。
    name: 'continuous horizontal (scrollBy H, informational)', engine: 'fushi_engine_continuous.html', continuous: true, step: 'scrollBy', informational: true,
    css: `html,body{margin:0;padding:0;}
 body{padding:${PT}px ${PR}px ${PB}px ${PL}px;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}`,
  },
];

async function openChapter(geom) {
  const engine = fs.readFileSync(path.join(os.tmpdir(), geom.engine), 'utf8');
  const CONFIG = {
    vnMode: false, continuousMode: geom.continuous, perfTraceEnabled: false,
    chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
    initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
  };
  const install = `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});\n${progressDetailsSource()}</script>`;
  // 引擎与安装脚本放 <head>：createWalker 走 document.body 的全部文本节点，脚本正文若在
  // body 里会被数进 totalChars（章总字数虚高、末页 end 跟着虚高）。生产路径引擎经
  // evaluateJavascript 注入、不进 DOM，head 放置与之等价。
  const full = `<!doctype html><html><head><meta charset="utf-8"><style>${geom.css}</style>\n${engine}\n${install}</head><body>${paras}</body></html>`;
  const b = await puppeteer.launch({executablePath: CHROME, headless: 'new', args: ['--no-sandbox']});
  const pg = await b.newPage(); await pg.setViewport({width: W, height: H});
  await pg.setRequestInterception(true);
  pg.on('request', async q => {
    const u = q.url();
    if (u === 'https://fushi.local/chapter') return q.respond({status:200,contentType:'text/html',body:full});
    if (u.startsWith('https://fushi.local')) return q.respond({status:404,body:''});
    return q.continue();
  });
  pg.on('pageerror', e => console.log('  pageerror:', e.message));
  await pg.goto('https://fushi.local/chapter', {waitUntil:'load', timeout:8000}).catch(()=>{});
  await new Promise(r => setTimeout(r, 500));
  return { b, pg };
}

async function walk(pg, geom) {
  const steps = [];
  for (let i = 0; i < 400; i++) {
    const s = await pg.evaluate(() => {
      const r = window.fushiReader;
      const d = window.fushiProgressDetails();
      const parts = d.split(',').map(Number);
      return { raw: d, current: parts[0], total: parts[1], start: parts[2], end: parts.length >= 4 ? parts[3] : -1, atEnd: r.isAtEnd() };
    });
    steps.push(s);
    if (s.atEnd) break;
    const moved = await pg.evaluate((step, H) => {
      if (step === 'scrollBy') {
        const before = window.scrollY;
        window.scrollBy({left: 0, top: H, behavior: 'auto'});
        return window.scrollY !== before ? 'scrolled' : 'limit';
      }
      return window.fushiReader.paginate('forward');
    }, geom.step || 'paginate', H);
    await new Promise(r => setTimeout(r, 60));
    if (moved === 'limit') {
      const tail = await pg.evaluate(() => {
        const d = window.fushiProgressDetails(); const p = d.split(',').map(Number);
        return { raw: d, current: p[0], total: p[1], start: p[2], end: p.length >= 4 ? p[3] : -1, atEnd: window.fushiReader.isAtEnd() };
      });
      steps.push(tail);
      break;
    }
  }
  return steps;
}

function check(geom, steps) {
  const name = geom.name;
  const problems = [];
  const info = [];
  const total = steps[0]?.total ?? 0;
  if (!(total > 0)) problems.push('total <= 0');
  const covered = new Uint8Array(Math.max(0, total));
  steps.forEach((s, i) => {
    if (s.raw.split(',').length !== 4) problems.push(`step ${i}: protocol has ${s.raw.split(',').length} parts (${s.raw})`);
    if (!(s.start >= 0 && s.start < s.end)) problems.push(`step ${i}: start ${s.start} !< end ${s.end}`);
    if (s.end > total) problems.push(`step ${i}: end ${s.end} > total ${total}`);
    if (i > 0) {
      const prev = steps[i - 1];
      const gap = s.start - prev.end;
      if (gap > 1) (geom.informational ? info : problems).push(`step ${i}: gap ${gap} chars (start ${s.start} > end_{i-1}=${prev.end} + 1)`);
      // 分页：相邻页严格衔接（end 不得越过下一页页首超过一字）；连续：重叠合法。
      if (!geom.continuous && gap < -1) problems.push(`step ${i}: overlap ${-gap} chars (start ${s.start} < end_{i-1}=${prev.end} − 1)`);
    }
    for (let k = Math.max(0, s.start); k < Math.min(total, s.end); k++) covered[k] = 1;
  });
  if (steps[0].start !== 0) problems.push(`first start ${steps[0].start} != 0`);
  const last = steps[steps.length - 1];
  if (!last.atEnd) problems.push('walk did not reach isAtEnd');
  if (last.end !== total) problems.push(`last end ${last.end} != total ${total}`);
  let n = 0; for (let k = 0; k < total; k++) n += covered[k];
  const ratio = total > 0 ? n / total : 0;
  if (ratio < 0.99) (geom.informational ? info : problems).push(`union coverage ${(ratio*100).toFixed(2)}% < 99%`);
  console.log(`${name}: steps=${steps.length} total=${total} coverage=${(ratio*100).toFixed(2)}% ${problems.length ? 'FAIL' : (geom.informational ? 'INFO' : 'OK')}`);
  steps.forEach((s, i) => console.log(`  #${String(i).padStart(3)} start=${String(s.start).padStart(5)} end=${String(s.end).padStart(5)} current=${String(s.current).padStart(5)}${s.atEnd ? ' atEnd' : ''}`));
  info.forEach(p => console.log('  (info) ' + p));
  problems.forEach(p => console.log('  <-- ' + p));
  return problems.length === 0;
}

let fail = 0;
for (const geom of GEOMETRIES) {
  const { b, pg } = await openChapter(geom);
  try {
    const steps = await walk(pg, geom);
    if (!check(geom, steps)) fail = 1;
  } finally {
    await b.close();
  }
}
process.exit(fail ? 1 : 0);
