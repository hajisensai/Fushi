// BUG-2903: runs the production continuous-mode engine shell in real headless
// Chrome and checks the chapter text index that backs per-frame progress
// reports: same numbers as the old whole-chapter walk, O(log n) geometry per
// report, and synchronous invalidation when the chapter DOM changes.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const engine = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).engine;

const W = 1000;
const H = 800;
const PARAGRAPHS = 300;
const CONFIG = {
  vnMode: false, continuousMode: true, perfTraceEnabled: false,
  chromeTopInset: 0, chromeBottomInset: 0, dartPageWidth: W, dartPageHeight: H,
  initialFragment: null, initialCharOffset: -1, initialProgress: 0, sentenceAudioCues: null,
};

function page(writingMode) {
  const css = 'html,body{margin:0;padding:0}'
    + `body{padding:20px;font-size:22px;line-height:1.8;writing-mode:${writingMode}}`
    + 'p{margin:0 0 1em 0}';
  const paras = Array.from({ length: PARAGRAPHS }, (_, i) =>
    `<p>P${i} これは<ruby>試験<rt>しけん</rt></ruby>本文です。<ruby>頁<rt>ぺーじ</rt></ruby>`
    + 'の幾何を<span>検証</span>するための十分な長さのダミーテキストを並べています。'
    + `「会話文の例です」と<ruby>彼<rt>かれ</rt></ruby>は言った。</p>`).join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head>`
    + `<body><div id="chapter">${paras}</div>\n${engine}\n`
    + `<script>window.__fushiInstallShell(${JSON.stringify(CONFIG)});</script></body></html>`;
}

// Executed in the page. The reference is the pre-BUG-2903 algorithm: walk every
// text node and sum countCharsBeforeViewport.
const check = (vertical) => `(async () => {
  const vertical = ${vertical};
  const r = window.fushiReader;
  const root = document.scrollingElement;
  const fails = [];
  function reference(edge) {
    const walker = r.createWalker();
    let total = 0, explored = 0, node;
    while ((node = walker.nextNode())) {
      const len = r.countChars(node.textContent);
      total += len;
      if (len > 0) explored += r.countCharsBeforeViewport(node, vertical, edge);
    }
    return {total, explored};
  }
  function scrollToFraction(f) {
    if (vertical) window.scrollTo(-(root.scrollWidth - root.clientWidth) * f, 0);
    else window.scrollTo(0, (root.scrollHeight - root.clientHeight) * f);
  }
  const lastEdge = vertical ? 0 : window.innerHeight;
  for (const f of [0, 0.27, 0.71, 0.98]) {
    scrollToFraction(f);
    const first = reference(undefined);
    const last = reference(lastEdge);
    const total = r.chapterCharTotal();
    if (total !== first.total) fails.push('total@' + f + ' ' + total + ' != ' + first.total);
    const explored = Math.round(r.calculateProgress() * total);
    if (explored !== first.explored) fails.push('first@' + f + ' ' + explored + ' != ' + first.explored);
    const scan = r.firstVisibleCharOffsetByScan();
    if (scan !== first.explored) fails.push('scan@' + f + ' ' + scan + ' != ' + first.explored);
    const end = r.getLastVisibleCharOffset();
    const expectedEnd = r.isAtEnd() ? last.total : last.explored;
    if (end !== expectedEnd) fails.push('last@' + f + ' ' + end + ' != ' + expectedEnd);
  }

  // Per-report geometry stays logarithmic once the index is warm.
  scrollToFraction(0.5);
  r.calculateProgress();
  const proto = Range.prototype;
  const original = proto.getClientRects;
  let calls = 0;
  proto.getClientRects = function() { calls++; return original.apply(this, arguments); };
  try {
    r.calculateProgress();
    r.getLastVisibleCharOffset();
  } finally {
    proto.getClientRects = original;
  }
  const nodes = (() => { const w = r.createWalker(); let c = 0; while (w.nextNode()) c++; return c; })();
  if (!(calls < 200)) fails.push('geometry calls ' + calls + ' for ' + nodes + ' text nodes');

  // A DOM change invalidates the index synchronously (no observer tick needed).
  const before = r.chapterCharTotal();
  const extra = document.createElement('p');
  extra.textContent = '追加段落';
  const chapter = document.getElementById('chapter');
  chapter.insertBefore(extra, chapter.firstChild);
  const after = r.chapterCharTotal();
  if (after !== before + r.countChars('追加段落')) fails.push('mutation total ' + before + ' -> ' + after);
  scrollToFraction(0.4);
  const ref = reference(undefined);
  const explored = Math.round(r.calculateProgress() * after);
  if (explored !== ref.explored) fails.push('after mutation ' + explored + ' != ' + ref.explored);
  return {fails, calls, nodes};
})()`;

const driver = await launchChromeDriver();
let failed = 0;
let cases = 0;
try {
  for (const [name, mode, vertical] of [
    ['horizontal', 'horizontal-tb', false],
    ['vertical-rl', 'vertical-rl', true],
  ]) {
    const res = await driver.evalOnPage(page(mode), check(vertical));
    cases++;
    if (res.fails.length) {
      failed++;
      console.log(`FAIL ${name}: ${res.fails.join('; ')}`);
    } else {
      console.log(`ok ${name}: ${res.calls} geometry calls for ${res.nodes} text nodes`);
    }
  }
} finally {
  await driver.close();
}
if (failed) process.exit(1);
console.log(`PASS ${cases} browser cases`);
