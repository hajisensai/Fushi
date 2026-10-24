// BUG-3770：VN 逐字显现推进时排版不得变化——真 Chrome 跑手。
// 由 vn_reveal_live_text_test.dart 执行，argv[2] = payload.json（生产 VN shell +
// 选区脚本 + 生产 VN CSS）。
//
// 用户原始失败（Windows WebView2，竖排 VN，逐字显现开着）：翻到下一屏后逐字显现推进到带注音的
// 「明後日」那一刻整屏左移 3px，显现结束又移回来。根因是显现把每个文本节点切成「已显现文本 +
// visibility:hidden 的 span」、每个 tick 在两者之间挪字，Blink 对含 ruby 的段落按不同的切分排出
// 不同的行盒（与 BUG-3741 同一机制）。这里钉住根因不变量：支持 CSS Highlight 的引擎上显现全程
// 屏上 DOM 一字不改、所有字形坐标不动，未显现部分由 CSS.highlights('fushi-vn-unrevealed') 承载
// （注音随基字显现完才露出），未显现的字点不中。
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
// 录屏里那一屏的原文：段首单字注音、段中多字注音。
const body = '<p>「ただ、<ruby>憶<rt>おぼ</rt></ruby>えるのでござる。ここに咲いた花の形を。……' +
  '敵味方の位置付けなど、明日にはどう変わっているとも分からぬ。<ruby>明後日<rt>あさって</rt></ruby>' +
  'には誰が生きて誰が死んでいるとも知れぬ。武人は未来について語る言葉を持ち得ぬ。' +
  '出来るのは、この<ruby>刹那<rt>いま</rt></ruby>を鮮烈に焼き付けることのみ」</p>';
const config = {
  vnRevealSpeed: 30,
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
    const hidden = () => {
      const h = CSS.highlights && CSS.highlights.get('fushi-vn-unrevealed');
      return h ? Array.from(h).map((range) => range.toString()).join('') : null;
    };
    // 文本恰为 [text] 的那个节点的首字现在点不点得中（查词命中的唯一收口 charRangeVisible）。
    const hittable = (text) => {
      const walker = document.createTreeWalker(reader.screen, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n.data !== text) continue;
        const rg = document.createRange();
        rg.setStart(n, 0);
        rg.setEnd(n, 1);
        return window.fushiSelection.charRangeVisible(rg);
      }
      return null;
    };
    reader.renderScreen(0, true);
    await frame();
    const plain = { html: reader.screen.innerHTML, geo: geometry() };
    reader.renderScreen(0, false);
    reader.clearRevealTimer();
    await frame();
    const steps = [];
    const snap = (label) => steps.push({
      label, html: reader.screen.innerHTML, geo: geometry(), hidden: hidden(),
      complete: reader.revealComplete,
    });
    snap('start');
    const total = reader.totalRevealCharacters();
    let beforeRuby = null;
    let afterRuby = null;
    for (let i = 1; i < total; i++) {
      reader.revealOneCharacter();
      const h = hidden();
      if (beforeRuby === null && h && h.startsWith('明後日')) {
        beforeRuby = { hidden: h, hit: hittable('明後日') };
      }
      if (afterRuby === null && h && h.startsWith('には誰')) {
        afterRuby = { hidden: h, hit: hittable('明後日') };
      }
      if (i % 7 === 0 || (h && (h.startsWith('明後日') || h.startsWith('後日') || h.startsWith('には誰')))) {
        await frame();
        snap('tick ' + i);
      }
    }
    reader.completeCurrentReveal();
    await frame();
    snap('complete');
    return { plain, steps, beforeRuby, afterRuby, total };
  })()`);
  assert.ok(r.total > 50, 'the screen has text to reveal ' + r.total);
  for (const step of r.steps) {
    assert.equal(step.html, r.plain.html, step.label + ': revealing must not touch the screen DOM\n' +
      r.plain.html + '\n' + step.html);
    assert.equal(step.geo, r.plain.geo, step.label + ': no glyph moves while revealing');
  }
  const start = r.steps[0];
  assert.equal(start.complete, false, 'the screen starts unrevealed');
  assert.ok(start.hidden && start.hidden.startsWith('「ただ'), 'everything starts hidden: ' + start.hidden);
  // 注音跟着基字：基字没显现完，注音仍在未显现 Range 里。
  assert.ok(r.beforeRuby, 'the reveal reaches the ruby word');
  assert.ok(r.beforeRuby.hidden.startsWith('明後日あさって'), 'ruby text stays hidden with its base: ' +
    r.beforeRuby.hidden);
  assert.equal(r.beforeRuby.hit, false, 'an unrevealed character cannot be looked up');
  assert.ok(r.afterRuby && !r.afterRuby.hidden.includes('あさって'), 'ruby shows once its base is revealed');
  assert.equal(r.afterRuby.hit, true, 'a revealed character can be looked up');
  const done = r.steps[r.steps.length - 1];
  assert.equal(done.complete, true, 'reveal completes');
  assert.equal(done.hidden, null, 'nothing stays hidden after the reveal');
  console.log('PASS VN reveal live text');
} finally {
  driver.close();
}
