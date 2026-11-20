// BUG-4908 复现尝试：分页 progress 落点（scrollToProgressPaged / restoreProgress /
// reapplyImageLateAnchor）在度量缓存作废后第一次与之后几次是否一致。
//
// 先跑 fushi/test/reader/reader_headless_shell_dump_test.dart 生成完整生产引擎
// （systemTemp/fushi_full_engine_paginated.js），再：
//   node tool/reader_pitch_headless/progress_landing_repeat_probe.mjs [段落数=1400]
// 横排 / 竖排单条各一次；每组打印落点 scroll 与页号，任何一组前后不一致时退出码 1。
// 场景：三种字号切换后作废度量再落 0.9（连落三次）、restoreProgress(0.9)、作废度量后
// reapplyImageLateAnchor 两次；从章首 / 0.3 / 0.95 三个起点作废度量再落 0.9。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { launchChromeDriver } from './cdp_client.mjs';

const engine = fs.readFileSync(path.join(os.tmpdir(), 'fushi_full_engine_paginated.js'), 'utf8');
const paragraphs = Number(process.argv[2] || 1400);
const text = Array.from({ length: paragraphs }, (_, i) => `<p>\n  第${i}段。これは<ruby>本文<rt>ほんぶん</rt></ruby>です。` +
  '彼女は窓の外を眺めながら、遠い昔の出来事について静かに話し始めました。' +
  '私はその言葉を聞きながら、今まで気付かなかった世界の広さを感じていました。</p>').join('');
const PT = 24, PB = 32, PL = 20, PR = 28;
const config = {
  vnMode: false, continuousMode: false, initialFragment: null, initialCharOffset: -1, initialCharOffsetEnd: -1,
  initialProgress: 0, dartPageWidth: 0, dartPageHeight: 0, chromeTopInset: 0, chromeBottomInset: 0,
  marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0, sentenceAudioCues: null,
  caretColor: '#ff0000', caretInsetTop: 0, caretInsetBottom: 0, furiganaMode: 'always',
};

const driver = await launchChromeDriver();
let inconsistent = false;
try {
  for (const vertical of [true, false]) {
    const css = 'html,body{margin:0;padding:0}html{overflow:hidden}' +
      `body{width:100vw;height:100vh;box-sizing:border-box;padding:${PT}px ${PR}px ${PB}px ${PL}px;` +
      `writing-mode:${vertical ? 'vertical-rl' : 'horizontal-tb'};` +
      `column-width:${vertical ? `calc(100vh - ${PT + PB}px)` : `calc(100vw - ${PL + PR}px)`};` +
      'column-gap:22px;column-fill:auto;font-size:21px;line-height:1.8;overflow:hidden}';
    const html = `<html><head><meta name="viewport" content="width=device-width"><style>${css}</style></head><body>${text}</body></html>`;
    const groups = await driver.evalOnPage(html, `(async () => {
      window.__completions = 0;
      window.flutter_inappwebview = { callHandler(name) { if (name === 'onRestoreComplete') window.__completions++; return Promise.resolve(); } };
      ${engine}
      window.__fushiEngine.install(${JSON.stringify(config)});
      for (let i = 0; i < 100 && !window.__completions; i++) await new Promise((r) => setTimeout(r, 50));
      await new Promise((r) => setTimeout(r, 300));
      const R = window.fushiReader;
      const at = () => R.getPagePosition(R.getScrollContext());
      const land = () => { R.scrollToProgressPaged(R.getScrollContext(), 0.9); return at(); };
      const groups = [];
      for (const size of [24, 19, 21]) {
        document.body.style.fontSize = size + 'px';
        R.paginationMetrics = null;
        const g = { label: 'font' + size, values: [land(), land(), land()] };
        R.paginationMetrics = null;
        R.restoreProgress(0.9);
        await new Promise((r) => setTimeout(r, 60));
        g.values.push(at());
        R.paginationMetrics = null;
        R.reapplyImageLateAnchor();
        g.values.push(at());
        R.reapplyImageLateAnchor();
        g.values.push(at());
        groups.push(g);
      }
      for (const start of [0, 0.3, 0.95]) {
        R.paginationMetrics = null;
        R.scrollToProgressPaged(R.getScrollContext(), start);
        R.paginationMetrics = null;
        groups.push({ label: 'from' + start, values: [land(), land(), land()] });
      }
      return groups;
    })()`);
    for (const g of groups) {
      const same = g.values.every((v) => v === g.values[0]);
      if (!same) inconsistent = true;
      console.log((vertical ? 'vertical ' : 'horizontal ') + g.label + ' ' + (same ? 'consistent ' : 'INCONSISTENT ') + JSON.stringify(g.values));
    }
  }
} finally {
  driver.close();
}
process.exit(inconsistent ? 1 : 0);
