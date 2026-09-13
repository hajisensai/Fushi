// 听书 reveal → fushiProgressDetails 真渲染探针：逐 cue 调 highlightSentenceAudioCue(id, true)
//
// 跑法（仓库根，不要 cd 进本目录）：
//   flutter test test/reader/reader_headless_shell_dump_test.dart   # 先 dump 引擎到 systemTemp
//   node tool/reader_pitch_headless/audiobook_reveal_progress_probe.mjs
// 引擎产物不含 setup 脚本的 __fushiApplyReaderMargins（webview.part.dart），这里桩掉它，
// 否则 initialize 在 applySentenceAudioCues 之前就抛错、cue 不会被包裹。
// （= AudiobookBridge.highlight(reveal:true) 的 JS 终点），随后读 fushiProgressDetails()，
// 断言 cue 首字落在回传的 [start,end) 内（reveal 翻到了 cue 所在页且进度协议读到了新页）。
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const require = createRequire(path.join(HERE, 'package.json'));
const puppeteer = require('puppeteer-core');
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const W = 1000, H = 800, PT = 24, PB = 32, PL = 20, PR = 28;

function progressDetailsSource() {
  const src = fs.readFileSync(path.join(REPO, 'fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart'), 'utf8').replace(/\r\n/g, '\n');
  const start = src.indexOf('window.fushiProgressDetails = function()');
  const end = src.indexOf('\n  };', start);
  if (start < 0 || end < 0) throw new Error('fushiProgressDetails source not found');
  return src.slice(start, end + 5);
}

const N = 70;
const texts = Array.from({length: N}, (_, i) => `P${i} これはテスト本文です。ページ分割の幾何を検証するための十分な長さのダミーテキストを並べています。文章文章文章文章文章文章文章文章。`);
const paras = texts.map(t => `<p>${t}</p>`).join('\n');
const cues = texts.map((t, i) => ({ id: 'cue' + i, text: t }));

const GEOMETRIES = [
  { name: 'paginated horizontal', engine: 'fushi_engine_paginated.html', continuous: false, settle: 120,
    css: `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:${PT}px ${PR}px ${PB}px ${PL}px;box-sizing:border-box;column-width:${W-PL-PR}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}` },
  { name: 'paginated vertical', engine: 'fushi_engine_paginated.html', continuous: false, settle: 120,
    css: `html,body{margin:0;padding:0;}html{overflow:hidden;}
 body{width:${W}px;height:${H}px;padding:${PT}px ${PR}px ${PB}px ${PL}px;box-sizing:border-box;writing-mode:vertical-rl;column-width:${H-PT-PB}px;column-gap:22px;column-fill:auto;font-size:22px;line-height:1.8;overflow:hidden;}
 p{margin:0 1em 0 0;}` },
  { name: 'continuous horizontal', engine: 'fushi_engine_continuous.html', continuous: true, settle: 900,
    css: `html,body{margin:0;padding:0;}
 body{padding:${PT}px ${PR}px ${PB}px ${PL}px;font-size:22px;line-height:1.8;writing-mode:horizontal-tb;}
 p{margin:0 0 1em 0;}` },
];

async function openChapter(geom) {
  const engine = fs.readFileSync(path.join(os.tmpdir(), geom.engine), 'utf8');
  const CONFIG = {
    vnMode: false, continuousMode: geom.continuous, perfTraceEnabled: false,
    chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
    initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: cues,
  };
  const install = `<script>window.__fushiApplyReaderMargins = function(){};
window.__fushiInstallShell(${JSON.stringify(CONFIG)});\n${progressDetailsSource()}</script>`;
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
  await new Promise(r => setTimeout(r, 600));
  return { b, pg };
}

function details(d) { const p = d.split(',').map(Number); return { raw: d, current: p[0], total: p[1], start: p[2], end: p.length >= 4 ? p[3] : -1 }; }

async function run(geom) {
  const { b, pg } = await openChapter(geom);
  const problems = [];
  try {
    const wrappers = await pg.evaluate(() => window.fushiReader.cueWrappers.size);
    if (wrappers !== N) problems.push(`cueWrappers=${wrappers} != ${N}`);
    let prev = await pg.evaluate(() => window.fushiProgressDetails());
    let flips = 0, samples = [];
    for (let i = 0; i < N; i++) {
      const res = await pg.evaluate((id) => {
        const r = window.fushiReader;
        const w = r.cueWrappers.get(id)[0];
        const off = r.nodeStartOffsets.get(w.firstChild);
        const before = r.getPagePosition ? r.getPagePosition(r.getScrollContext()) : window.scrollY;
        const ret = r.highlightSentenceAudioCue(id, true);
        return { off, before, revealed: ret !== null };
      }, 'cue' + i);
      await new Promise(r => setTimeout(r, geom.settle));
      const after = await pg.evaluate(() => {
        const r = window.fushiReader;
        return { d: window.fushiProgressDetails(), pos: r.getPagePosition ? r.getPagePosition(r.getScrollContext()) : window.scrollY, pending: r._reanchorPending === true };
      });
      const s = details(after.d);
      const moved = after.pos !== res.before;
      if (moved) flips++;
      samples.push({ i, off: res.off, revealed: res.revealed, moved, ...s, pending: after.pending });
      if (after.pending) problems.push(`cue ${i}: _reanchorPending stuck true after reveal`);
      if (!(s.start >= 0 && s.end > s.start)) problems.push(`cue ${i}: bad range ${s.raw}`);
      if (res.off === undefined) problems.push(`cue ${i}: cue offset unresolved`);
      else if (!(res.off >= s.start && res.off < s.end)) problems.push(`cue ${i}: cue offset ${res.off} outside sampled [${s.start},${s.end}) moved=${moved} revealed=${res.revealed}`);
      // 连续模式章首 / 章末：scrollBy 被文档边界钳住，revealed 但位置不变是合法的（不判红）。
      prev = after.d;
    }
    console.log(`${geom.name}: cues=${N} flips=${flips} ${problems.length ? 'FAIL' : 'OK'}`);
    samples.filter(s => s.moved || s.i === 0).forEach(s => console.log(`  cue#${String(s.i).padStart(2)} off=${String(s.off).padStart(5)} moved=${s.moved} revealed=${s.revealed} -> [${s.start},${s.end}) current=${s.current}`));
    problems.forEach(p => console.log('  <-- ' + p));
  } finally { await b.close(); }
  return problems.length === 0;
}

let fail = 0;
for (const g of GEOMETRIES) { if (!(await run(g))) fail = 1; }
process.exit(fail ? 1 : 0);
