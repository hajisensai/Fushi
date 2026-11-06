// BUG-3395：VN 插图屏与其后句子屏在真 Chrome 里的几何与有声书跟随行为跑手。
// 由 vn_illustration_screen_test.dart 执行，argv[2] = payload.json（生产 VN shell +
// 选区脚本 + 生产 VN CSS）。章首插图的注入形状照抄 webview.part.dart 的
// _mergedChapterImagesHtml（单图片章并进下一章章首）。
//
// 断言依赖的生产行为（供变异实测对照）：
// - 纯图片屏不再并进下一段（attachMediaScreensToAdjacentText 已删）：图独占一屏铺满，
//   句子屏完整可见（BUG-1244 那版把句子挤到屏左外侧）。
// - pauseAtCrossedMediaScreen：开图片暂停时跟随先停在图上并发 onImageDetected，
//   再次跟随（Dart 暂停结束 snapReaderToAudio）落到句子屏；关图片暂停直达句子屏。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const W = 440;
const H = 956;
// 竖长插图（与原书 i-0115_01.jpg 同为 7:10）。
const image = 'data:image/svg+xml,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="1600">' +
  '<rect width="1120" height="1600" fill="#888"/></svg>');
const figure = '<div class="fushi-merged-image"><img src="' + image +
  '" class="block-img"/></div>';
const sentence = '<p>……さすがだ、<ruby>由<rt>ゆ</rt></ruby><ruby>比<rt>い</rt></ruby>' +
  'ヶ<ruby>浜<rt>はま</rt></ruby>。よく人を見ている。</p>';
const reply = '<p>「あ、うん、え？」</p>';
// 用户原书：插图章并进下一章章首，紧跟这句。
const chapterStart = figure + sentence + reply;
// 章中插图：前一段 → 图 → 这句。
const midChapter = '<p>たぶんそういうのわかってて言ってるんだと思うよ」</p>' + figure + sentence + reply;
// BUG-3891：图前是不以「。！？」收尾的对白段（轻小说里最常见的形状）。按句分屏时它曾越过
// 插图把图后的这句吞进同一个句子单元，插图屏排到这句之后、字符区间倒挂。
const dialogueBeforeFigure = '<p>「たぶんそういうのわかってて言ってるんだと思うよ」</p>' + figure + sentence + reply;

function pageFor(css, body, screenMode, preserveDialogue) {
  const config = {
    vnRevealSpeed: 0,
    vnScreenMode: screenMode || 'block',
    vnSentencesPerScreen: 1,
    vnPreserveDialogue: preserveDialogue === undefined ? true : preserveDialogue,
    vnMergeCrossScreenSentenceAudioCues: false,
    sentenceAudioCues: [],
    initialProgress: 0,
    initialFragment: null,
    initialCharOffset: -1,
    navigationGeneration: 1,
    dartPageWidth: W,
    dartPageHeight: H,
    chromeTopInset: 120,
    chromeBottomInset: 150,
    blurImages: false,
    revealedKeys: [],
  };
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>' + css + '</style>' +
    '<script>window.__fushiShells={};window.imageDetected=0;' +
    'window.flutter_inappwebview={callHandler:function(name){' +
    'if(name==="onImageDetected")window.imageDetected++;return Promise.resolve(null);}};' +
    scripts.units + '</script>' + scripts.shell +
    '<script>' + scripts.selection +
    ';window.__fushiShells.vn(' + JSON.stringify(config) + ');</script>' +
    '</head><body>' + body + '</body></html>';
}

// 页内工具：当前屏几何 + 用引擎自己的坐标给「よく人を見ている」建 cue。
const HELPERS = `
function geometry(reader) {
  const box = reader.screen.getBoundingClientRect();
  const inBox = (r) => r.left >= box.left - 1 && r.right <= box.right + 1 &&
    r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
  const range = document.createRange();
  const walker = document.createTreeWalker(reader.screen, NodeFilter.SHOW_TEXT);
  let node, inside = 0, outside = 0;
  while ((node = walker.nextNode())) {
    if (!node.textContent.trim() || node.parentElement.closest('rt')) continue;
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) {
      if (!rect.width && !rect.height) continue;
      if (inBox(rect)) inside++; else outside++;
    }
  }
  const imgs = Array.from(reader.screen.querySelectorAll('img')).map((img) => {
    const r = img.getBoundingClientRect();
    return { inside: inBox(r), width: r.width, height: r.height };
  });
  return { index: reader.currentScreenIndex, inside, outside, imgs,
    boxWidth: box.width, boxHeight: box.height,
    // 内容盒 = 屏盒扣掉用户边距（padding）：插图「铺满」的分母。
    contentWidth: reader.screen.clientWidth - parseFloat(getComputedStyle(reader.screen).paddingLeft) -
      parseFloat(getComputedStyle(reader.screen).paddingRight),
    contentHeight: reader.screen.clientHeight - parseFloat(getComputedStyle(reader.screen).paddingTop) -
      parseFloat(getComputedStyle(reader.screen).paddingBottom),
    text: reader.screen.textContent.replace(/\\s+/g, '') };
}
function applyYokuCue(reader) {
  const cueText = 'よく人を見ている';
  const entry = reader.contentStream.textEntries.find((e) => e.text.includes(cueText));
  const start = reader.contentStream.matchableOffsetForRawOffset(
    entry.startRaw + Array.from(entry.text.slice(0, entry.text.indexOf(cueText))).length);
  reader.applySentenceAudioCues([{ id: 'yoku', text: cueText, start, length: cueText.length }]);
}
const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
`;

const driver = await launchChromeDriver();
try {
  // 只为设一次 iPhone 尺寸视口；之后 evalOnPage 的导航沿用同一视口。
  await driver.snap('<!doctype html><html></html>', null, W, H);
  let passed = 0;

  // ① 几何：图独占一屏铺满、句子屏完整可见（竖排 / 横排）。
  for (const [label, css] of [
    ['vertical', scripts.cssVertical],
    ['vertical right margin 9%', scripts.cssVerticalWideRight],
    ['horizontal', scripts.cssHorizontal],
  ]) {
    const r = await driver.evalOnPage(pageFor(css, chapterStart), `(async () => {
      ${HELPERS}
      await new Promise((r) => setTimeout(r, 300));
      const reader = window.fushiReader;
      reader.renderScreen(0, true);
      await frame();
      const imageScreen = geometry(reader);
      reader.renderScreen(1, true);
      await frame();
      return { imageScreen, sentenceScreen: geometry(reader) };
    })()`);
    const img = r.imageScreen;
    assert.equal(img.imgs.length, 1, label + ': screen 0 is the illustration ' + JSON.stringify(r));
    assert.equal(img.text, '', label + ': the illustration screen carries no text ' + JSON.stringify(r));
    assert.ok(img.imgs[0].inside, label + ': the illustration fits inside the screen box ' + JSON.stringify(r));
    // 铺满 = 至少一条轴顶到内容盒上限（宽上限是内容盒宽 × imageWidthViewportRatio 0.95）。
    assert.ok(Math.max(img.imgs[0].width / img.contentWidth, img.imgs[0].height / img.contentHeight) >= 0.9,
      label + ': the illustration fills the screen ' + JSON.stringify(r));
    const text = r.sentenceScreen;
    assert.ok(text.text.includes('よく人を見ている'), label + ': screen 1 is the sentence ' + JSON.stringify(r));
    assert.ok(text.inside > 0 && text.outside === 0,
      label + ': every glyph run of the sentence is inside the screen box ' + JSON.stringify(r));
    passed++;
  }

  // ② 跟随：开图片暂停时先停在图上，再次跟随落到句子屏；关图片暂停直达句子屏。
  const follow = await driver.evalOnPage(pageFor(scripts.cssVertical, midChapter), `(async () => {
    ${HELPERS}
    await new Promise((r) => setTimeout(r, 300));
    const reader = window.fushiReader;
    applyYokuCue(reader);
    const out = {};
    reader.renderScreen(0, true);
    reader.highlightSentenceAudioCue('yoku', true, true, false);
    await frame();
    out.paused = { geo: geometry(reader), detected: window.imageDetected };
    reader.highlightSentenceAudioCue('yoku', true, true, false);
    await frame();
    out.resumed = { geo: geometry(reader), detected: window.imageDetected,
      // 当前句：支持 CSS Highlight 时是 Range（BUG-3741），否则是 wrapper。
      active: CSS.highlights && CSS.highlights.has('fushi-sentence-audio')
        ? Array.from(CSS.highlights.get('fushi-sentence-audio')).map((r) => r.toString()).join('')
        : Array.from(reader.screen.querySelectorAll('.fushi-sentence-audio-active'))
          .map((n) => n.textContent).join('') };
    window.imageDetected = 0;
    reader.renderScreen(0, true);
    reader.highlightSentenceAudioCue('yoku', true, false, false);
    await frame();
    out.noPause = { geo: geometry(reader), detected: window.imageDetected };
    return out;
  })()`);
  assert.ok(follow.paused.geo.imgs.length === 1 && follow.paused.geo.index === 1 &&
    follow.paused.detected === 1,
    'image pause on: follow stops on the crossed illustration and notifies Dart ' + JSON.stringify(follow));
  assert.ok(follow.resumed.geo.index === 2 && follow.resumed.geo.outside === 0 &&
    follow.resumed.active.includes('よく人を見ている') && follow.resumed.detected === 1,
    'after the pause the follow lands on the visible, highlighted sentence ' + JSON.stringify(follow));
  assert.ok(follow.noPause.geo.index === 2 && follow.noPause.detected === 0,
    'image pause off: follow goes straight to the sentence ' + JSON.stringify(follow));
  passed++;

  // ③ 章首插图（用户原书形状）：音频从上一章读进来（fromChapterStart），落点已是句子屏
  // 也要先停在章首图上；之后的跟随不带 fromChapterStart，落回句子屏。
  const arrival = await driver.evalOnPage(pageFor(scripts.cssVertical, chapterStart), `(async () => {
    ${HELPERS}
    await new Promise((r) => setTimeout(r, 300));
    const reader = window.fushiReader;
    applyYokuCue(reader);
    reader.renderScreen(1, true);
    reader.highlightSentenceAudioCue('yoku', true, true, true);
    await frame();
    const paused = { geo: geometry(reader), detected: window.imageDetected };
    reader.highlightSentenceAudioCue('yoku', true, true, false);
    await frame();
    return { paused, resumed: { geo: geometry(reader), detected: window.imageDetected } };
  })()`);
  assert.ok(arrival.paused.geo.index === 0 && arrival.paused.geo.imgs.length === 1 &&
    arrival.paused.detected === 1,
    'chapter arrival: the chapter-start illustration gets its pause ' + JSON.stringify(arrival));
  assert.ok(arrival.resumed.geo.index === 1 && arrival.resumed.geo.outside === 0 &&
    arrival.resumed.detected === 1,
    'chapter arrival: the follow then shows the sentence ' + JSON.stringify(arrival));
  passed++;
  // ④ BUG-3891：按句分屏（vnScreenMode = sentences，保留对白气泡关 = 默认值）+ 图前是「……」对白段。插图必须独占
  // 一屏、排在图前那句与图后这句之间；跟随从图前那句推进到这句时先停在图上。
  const sentences = await driver.evalOnPage(pageFor(scripts.cssVertical, dialogueBeforeFigure, 'sentences', false), `(async () => {
    ${HELPERS}
    await new Promise((r) => setTimeout(r, 300));
    const reader = window.fushiReader;
    applyYokuCue(reader);
    const screens = reader.screens.map((s, i) => ({ i, media: reader.isMediaOnlyScreen(s),
      start: reader.screenStartCharCount(s), end: reader.screenEndCharCount(s) }));
    reader.renderScreen(0, true);
    const first = geometry(reader);
    reader.highlightSentenceAudioCue('yoku', true, true, false);
    await frame();
    const paused = { geo: geometry(reader), detected: window.imageDetected };
    reader.highlightSentenceAudioCue('yoku', true, true, false);
    await frame();
    return { screens, first, paused, resumed: { geo: geometry(reader), detected: window.imageDetected } };
  })()`);
  const mediaAt = sentences.screens.findIndex((s) => s.media);
  assert.ok(mediaAt === 1, 'sentences mode: the illustration is the second screen ' + JSON.stringify(sentences));
  for (let i = 1; i < sentences.screens.length; i++) {
    assert.ok(sentences.screens[i].start >= sentences.screens[i - 1].end,
      'sentences mode: screen char ranges stay in reading order ' + JSON.stringify(sentences));
  }
  assert.ok(!sentences.first.text.includes('よく人を見ている'),
    'sentences mode: the sentence after the illustration is not pulled in front of it ' + JSON.stringify(sentences));
  assert.ok(sentences.paused.geo.index === mediaAt && sentences.paused.geo.imgs.length === 1 &&
    sentences.paused.detected === 1,
    'sentences mode: follow stops on the crossed illustration ' + JSON.stringify(sentences));
  assert.ok(sentences.resumed.geo.text.includes('よく人を見ている') && sentences.resumed.detected === 1,
    'sentences mode: after the pause the follow lands on the sentence ' + JSON.stringify(sentences));
  passed++;
  console.log('PASS ' + passed + ' VN illustration/sentence screens');
} finally {
  driver.close();
}
