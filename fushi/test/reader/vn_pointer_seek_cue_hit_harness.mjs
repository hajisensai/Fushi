// BUG-3738：VN 中键「跳到点击句」的反查在真 Chrome 里的行为跑手。
// 由 vn_pointer_seek_cue_hit_test.dart 执行，argv[2] = payload.json（生产 VN shell +
// 选区脚本 + 生产 VN CSS）。
//
// 用户原始失败：VN 模式下中键点句子无反应。Dart `_seekToClickedSentence` 调
// `window.fushiReader.cueIdAtPoint(x, y)`，VN 的 fushiReader 此前根本没有这个方法，
// 恒拿到 null、静默忽略。这里在 VN 屏的克隆上按真实字形坐标点：
// - 两句各自的正文字 → 各自的 cue（`{type:'frag', id}`，id 即 textFragmentId）；
// - 句首逐字配对 ruby（七つの魔剣が支配するII 的原样标记）的基字与注音 → 第一句；
// - 第二屏（换屏后克隆重建）上的字 → 那一屏的句子。
// 点空白处与分页模式同样经 getCaretRange 的最近字符兜底（BUG-765），这里不另设判据。
//
// BUG-4839：合成书（SRT / VTT / LRC）的句子不进 sentenceAudioCues，身份在 [data-cue-id]
// 上。BUG-3738 只补了 frag 这一半，合成书在 VN 下中键与「从此句播放」仍恒拿到 null。
// 第二个页面不下发任何 cue，只在正文里带 [data-cue-id]，断言两个入口都回 `{type:'sid'}`。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const W = 1200;
const H = 800;
const body = '<p>　<ruby>赤<rt>しやく</rt>銅<rt>どう</rt></ruby>色の髪をした彼の従兄が、大きな弦楽器を抱えて' +
  'ステージ上に陣取る。その手前で、この集まりの主催者である監督生が、持ち前の美しい声を上げた。</p>' +
  '<p>「こんばんは、みんな。今夜も来てくれてありがとう」</p>';
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
const pageFor = (bodyHtml) => '<!doctype html><html><head><meta charset="utf-8">' +
  '<style>' + scripts.css + '</style>' +
  '<script>window.__fushiShells={};' +
  'window.flutter_inappwebview={callHandler:function(){return Promise.resolve(null);}};' +
  scripts.units + '</script>' + scripts.shell +
  '<script>' + scripts.selection +
  ';window.__fushiShells.vn(' + JSON.stringify(config) + ');</script>' +
  '</head><body>' + bodyHtml + '</body></html>';
const page = pageFor(body);
// 合成书：句子是带 data-cue-id 的 span（id = sentenceIndex），段首有一截不属于任何句子的字。
const syntheticBody = '<p>序<span data-cue-id="0">一句目の文章です。</span>' +
  '<span data-cue-id="1">二句目の<ruby>漢字<rt>かんじ</rt></ruby>です。</span></p>' +
  '<p><span data-cue-id="2">三句目だけの段落。</span></p>';

const driver = await launchChromeDriver();
try {
  await driver.snap('<!doctype html><html></html>', null, W, H);
  const r = await driver.evalOnPage(page, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const reader = window.fushiReader;
    // 用引擎自己的坐标给三句建 cue（与 Dart 下发的 start/length 同一口径）。
    const cue = (id, text, anchor) => {
      const entry = reader.contentStream.textEntries.find((e) => e.text.includes(anchor));
      const at = entry.text.indexOf(anchor);
      const start = reader.contentStream.matchableOffsetForRawOffset(
        entry.startRaw + Array.from(entry.text.slice(0, at)).length);
      return { id, text, start, length: text.length };
    };
    reader.applySentenceAudioCues([
      cue('first', '赤銅色の髪をした彼の従兄が大きな弦楽器を抱えてステージ上に陣取る', '赤'),
      cue('second', 'その手前でこの集まりの主催者である監督生が持ち前の美しい声を上げた', 'その手前'),
      cue('third', 'こんばんはみんな今夜も来てくれてありがとう', 'こんばんは'),
    ]);
    const centerOf = (ch, inRt) => {
      const walker = document.createTreeWalker(reader.screen, NodeFilter.SHOW_TEXT);
      let n;
      while ((n = walker.nextNode())) {
        if (!!n.parentElement.closest('rt') !== !!inRt) continue;
        const k = n.data.indexOf(ch);
        if (k < 0) continue;
        const rg = document.createRange();
        rg.setStart(n, k);
        rg.setEnd(n, k + 1);
        const b = rg.getBoundingClientRect();
        return [b.left + b.width / 2, b.top + b.height / 2];
      }
      return null;
    };
    const hit = (ch, inRt) => {
      const p = centerOf(ch, inRt);
      return p ? reader.cueIdAtPoint(p[0], p[1]) : 'missing:' + ch;
    };
    reader.renderScreen(0, true);
    await frame();
    const out = {
      screens: reader.screens.length,
      base: hit('銅'),
      annotation: hit('や', true),
      first: hit('髪'),
      second: hit('監'),
    };
    // 跟随高亮包裹过之后（DOM 被切开、包进 wrapper）仍按章内坐标归属。
    reader.highlightSentenceAudioCue('second', true, false, false);
    await frame();
    out.afterWrapFirst = hit('髪');
    out.afterWrapSecond = hit('監');
    reader.renderScreen(1, true);
    await frame();
    out.nextScreen = hit('夜');
    return out;
  })()`);
  const frag = (id) => JSON.stringify({ type: 'frag', id });
  assert.equal(r.screens, 2, 'fixture renders two VN screens ' + JSON.stringify(r));
  assert.equal(r.base, frag('first'), 'ruby base glyph seeks to its sentence ' + JSON.stringify(r));
  assert.equal(r.annotation, frag('first'), 'ruby annotation seeks to the ruby sentence ' + JSON.stringify(r));
  assert.equal(r.first, frag('first'), 'first sentence glyph ' + JSON.stringify(r));
  assert.equal(r.second, frag('second'), 'second sentence glyph ' + JSON.stringify(r));
  assert.equal(r.afterWrapFirst, frag('first'), 'after follow wrapping, first ' + JSON.stringify(r));
  assert.equal(r.afterWrapSecond, frag('second'), 'after follow wrapping, second ' + JSON.stringify(r));
  assert.equal(r.nextScreen, frag('third'), 'a re-cloned screen resolves its own sentence ' + JSON.stringify(r));

  const s = await driver.evalOnPage(pageFor(syntheticBody), `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const reader = window.fushiReader;
    const find = (ch, inRt) => {
      const walker = document.createTreeWalker(reader.screen, NodeFilter.SHOW_TEXT);
      let n;
      while ((n = walker.nextNode())) {
        if (!!n.parentElement.closest('rt') !== !!inRt) continue;
        const k = n.data.indexOf(ch);
        if (k >= 0) return { node: n, offset: k };
      }
      return null;
    };
    const hit = (ch, inRt) => {
      const at = find(ch, inRt);
      if (!at) return 'missing:' + ch;
      const rg = document.createRange();
      rg.setStart(at.node, at.offset);
      rg.setEnd(at.node, at.offset + 1);
      const b = rg.getBoundingClientRect();
      return reader.cueIdAtPoint(b.left + b.width / 2, b.top + b.height / 2);
    };
    // 查词载荷 / 「从此句播放」走的入口：直接给（节点, 偏移）。
    const domHit = (ch, inRt) => {
      const at = find(ch, inRt);
      return at ? reader.cueIdAtDomPoint(at.node, at.offset) : 'missing:' + ch;
    };
    reader.renderScreen(0, true);
    await frame();
    const out = {
      screens: reader.screens.length,
      cues: (reader.sentenceAudioCues || []).length,
      first: hit('一'),
      second: hit('二'),
      base: hit('漢'),
      annotation: hit('か', true),
      outside: hit('序'),
      domFirst: domHit('一'),
      domAnnotation: domHit('か', true),
      domOutside: domHit('序'),
    };
    reader.renderScreen(1, true);
    await frame();
    out.nextScreen = hit('三');
    out.domNextScreen = domHit('三');
    return out;
  })()`);
  const sid = (id) => JSON.stringify({ type: 'sid', id });
  assert.equal(s.screens, 2, 'synthetic fixture renders two VN screens ' + JSON.stringify(s));
  assert.equal(s.cues, 0, 'a synthetic book has no sentenceAudioCues ' + JSON.stringify(s));
  assert.equal(s.first, sid('0'), 'synthetic: first sentence glyph ' + JSON.stringify(s));
  assert.equal(s.second, sid('1'), 'synthetic: second sentence glyph ' + JSON.stringify(s));
  assert.equal(s.base, sid('1'), 'synthetic: ruby base glyph ' + JSON.stringify(s));
  assert.equal(s.annotation, sid('1'), 'synthetic: ruby annotation ' + JSON.stringify(s));
  assert.equal(s.outside, null, 'synthetic: text outside every sentence resolves to nothing ' + JSON.stringify(s));
  assert.equal(s.domFirst, sid('0'), 'synthetic: DOM point in the first sentence ' + JSON.stringify(s));
  assert.equal(s.domAnnotation, sid('1'), 'synthetic: DOM point in an annotation ' + JSON.stringify(s));
  assert.equal(s.domOutside, null, 'synthetic: DOM point outside every sentence ' + JSON.stringify(s));
  assert.equal(s.nextScreen, sid('2'), 'synthetic: a re-cloned screen resolves its own sentence ' + JSON.stringify(s));
  assert.equal(s.domNextScreen, sid('2'), 'synthetic: DOM point on a re-cloned screen ' + JSON.stringify(s));
  console.log('PASS VN pointer seek cue hit-test');
} finally {
  driver.close();
}
