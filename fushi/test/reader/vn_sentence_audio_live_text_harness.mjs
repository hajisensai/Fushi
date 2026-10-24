// BUG-3741：VN 有声书高亮推进时排版不得变化——真 Chrome 跑手。
// 由 vn_sentence_audio_live_text_test.dart 执行，argv[2] = payload.json（生产 VN shell +
// 选区脚本 + 生产 VN CSS）。
//
// 用户原始失败（Windows WebView2，七つの魔剣が支配するII，竖排 VN）：当前句从「赤銅…」换到
// 同段下一句时，同段带注音那一列的行盒窄了 6px，VN 居中把整屏跟着平移 3px。根因是 VN 播放到
// 哪句才处理哪句：Blink 上把下一句的文本节点切进 wrapper span，含 ruby 的段落重新排出不同的行盒。
// 这里钉住根因不变量：VN 在支持 CSS Highlight 的引擎上播放推进时屏上 DOM 一字不改，当前句由
// CSS.highlights('fushi-sentence-audio') 承载、文本恰为该句（不含注音），所有字形坐标不动。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const W = 1200;
const H = 800;
// 原书 p-002.xhtml 原样标记：逐字配对 ruby 在段首，同段两句。
const body = '<p>「──<ruby>従<rt>に</rt>兄<rt>い</rt></ruby>さん？」</p>' +
  '<p>　<ruby>赤<rt>しやく</rt>銅<rt>どう</rt></ruby>色の髪をした彼の従兄が、大きな弦楽器を抱えて' +
  'ステージ上に陣取る。その手前で、この集まりの主催者である監督生──カルロス＝ウィットロウが、' +
  '持ち前の美しい声を上げた。</p>';
const config = {
  vnRevealSpeed: 0,
  vnScreenMode: 'block',
  vnSentencesPerScreen: 1,
  vnPreserveDialogue: false,
  vnMergeCrossScreenSentenceAudioCues: false,
  sentenceAudioCues: [],
  initialProgress: 0,
  initialFragment: null,
  initialCharOffset: -1,
  navigationGeneration: 1,
  dartPageWidth: W,
  dartPageHeight: H,
  chromeTopInset: 0,
  chromeBottomInset: 0,
  blurImages: false,
  revealedKeys: [],
};
const page = '<!doctype html><html><head><meta charset="utf-8">' +
  '<style>' + scripts.css + '</style>' +
  '<script>window.__fushiShells={};' +
  'window.flutter_inappwebview={callHandler:function(){return Promise.resolve(null);}};' +
  scripts.units + '</script>' + scripts.shell +
  '<script>' + scripts.selection +
  ';window.__fushiShells.vn(' + JSON.stringify(config) + ');</script>' +
  '</head><body>' + body + '</body></html>';

const driver = await launchChromeDriver();
try {
  await driver.snap('<!doctype html><html></html>', null, W, H);
  const r = await driver.evalOnPage(page, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const reader = window.fushiReader;
    // 用引擎自己的坐标建 cue（与 Dart 下发的 start/length 同一口径）。
    const cue = (id, text, anchor) => {
      const entry = reader.contentStream.textEntries.find((e) => e.text.includes(anchor));
      const at = entry.text.indexOf(anchor);
      const start = reader.contentStream.matchableOffsetForRawOffset(
        entry.startRaw + Array.from(entry.text.slice(0, at)).length);
      return { id, text, start, length: text.length };
    };
    reader.applySentenceAudioCues([
      cue('first', '赤銅色の髪をした彼の従兄が大きな弦楽器を抱えてステージ上に陣取る', '赤'),
      cue('second', 'その手前でこの集まりの主催者である監督生カルロスウィットロウが持ち前の美しい声を上げた', 'その手前'),
    ]);
    const geometry = () => {
      const out = [];
      const walker = document.createTreeWalker(reader.screen, NodeFilter.SHOW_TEXT);
      const rg = document.createRange();
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        for (let i = 0; i < n.data.length; i++) {
          rg.setStart(n, i);
          rg.setEnd(n, i + 1);
          const b = rg.getBoundingClientRect();
          out.push(n.data[i] + '@' + b.left.toFixed(2) + ',' + b.top.toFixed(2));
        }
      }
      return out.join(' ');
    };
    const active = () => {
      const h = CSS.highlights && CSS.highlights.get('fushi-sentence-audio');
      return h ? Array.from(h)
        .sort((a, b) => a.compareBoundaryPoints(Range.START_TO_START, b))
        .map((range) => range.toString()).join('') : null;
    };
    const screenOf = reader.screenIndexForSentenceAudioCue(reader.sentenceAudioCueMap.get('first'));
    reader.renderScreen(screenOf, true);
    await frame();
    const state = (label) => ({ label, html: reader.screen.innerHTML, geo: geometry(), active: active() });
    const states = [state('plain')];
    reader.highlightSentenceAudioCue('first', true, false, false);
    await frame();
    states.push(state('first'));
    reader.highlightSentenceAudioCue('second', true, false, false);
    await frame();
    states.push(state('second'));
    return { screen: reader.currentScreenIndex, screenOf, states };
  })()`);
  const [plain, first, second] = r.states;
  assert.equal(r.screen, r.screenOf, 'both sentences stay on one VN screen ' + JSON.stringify(r));
  assert.equal(first.html, plain.html, 'highlighting the first sentence must not touch the screen DOM\n' +
    plain.html + '\n' + first.html);
  assert.equal(second.html, plain.html, 'advancing to the next sentence must not touch the screen DOM\n' +
    plain.html + '\n' + second.html);
  assert.equal(first.active, '赤銅色の髪をした彼の従兄が、大きな弦楽器を抱えてステージ上に陣取る。',
    'the first sentence is the CSS highlight, ruby annotations excluded');
  assert.equal(second.active,
    'その手前で、この集まりの主催者である監督生──カルロス＝ウィットロウが、持ち前の美しい声を上げた。',
    'the second sentence is the CSS highlight');
  assert.equal(first.geo, plain.geo, 'no glyph moves when the first sentence lights up');
  assert.equal(second.geo, plain.geo, 'no glyph moves when the highlight advances');
  console.log('PASS VN sentence audio live text');
} finally {
  driver.close();
}
