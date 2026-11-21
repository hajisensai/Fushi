// VN 有声书句子定位按原文重定位——真 Chrome 跑手。
// 由 vn_sentence_audio_cue_relocation_test.dart 执行（payload = 生产 VN shell + 选区脚本 +
// study units / 标点归属 / cue 重定位三个前置模块）。
//
// 测量组 m1（PR #3830 gap-readerjs2-8）：同一组 cue，提示坐标偏 3 / 30 个字时，分页 / 连续
// 模式仍 0 错（按原文在实时 DOM 里重定位），VN 105 / 105 全错——VN 直接拿 start / length 当
// 权威坐标。这里钉住：VN 下提示偏 0 / +3 / -3 / +30 时，每句都切到正确的屏、当前句高亮恰为
// 该句、中键反查回到该句。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const W = 800;
const H = 600;
// 每段一屏（block 模式），段内两句，带注音与半角 / 全角混排；句子互不重复。
const sentences = [
  ['朝の光が窓から差し込んで、部屋の中を照らした。', '彼女はゆっくりと目を開けた。'],
  ['<ruby>廊下<rt>ろうか</rt></ruby>の向こうで誰かが歩いている音がする。', '時計は七時を少し過ぎていた。'],
  ['ＡＢＣ放送のニュースが流れている。', '天気予報によると今日は雨らしい。'],
  ['台所からパンの焼ける匂いが漂ってきた。', '母はもう起きているようだ。'],
  ['机の上には昨日の宿題がそのまま残っている。', '急いで鞄に詰め込んだ。'],
  ['玄関の扉を開けると冷たい風が吹き込んだ。', '傘を持って家を出た。'],
];
const body = sentences.map((pair) => '<p>' + pair.join('') + '</p>').join('');
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
  '<style>body{margin:0;font:20px/1.5 sans-serif}' +
  '.fushi-vn-stage,.fushi-vn-screen{width:' + W + 'px;height:' + H + 'px}' +
  'p{margin:0}rt{font-size:10px}</style>' +
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
    const reader = window.fushiReader;
    const sentences = ${JSON.stringify(sentences)};
    const plain = (html) => html.replace(/<rt>[^<]*<\\/rt>/g, '').replace(/<[^>]+>/g, '');
    // 真实坐标：用引擎自己的源章节坐标（与 Dart 下发的 start/length 同一口径）。
    const exactCue = (id, text) => {
      const entry = reader.contentStream.textEntries.find((e) => e.text.includes(text.slice(0, 2)));
      const at = entry.text.indexOf(text.slice(0, 2));
      const start = reader.contentStream.matchableOffsetForRawOffset(
        entry.startRaw + Array.from(entry.text.slice(0, at)).length);
      return { id, text, start, length: reader.normalizeText(text).length };
    };
    const expected = [];
    const exact = [];
    sentences.forEach((pair, screen) => pair.forEach((html, k) => {
      const text = plain(html);
      expected.push({ id: 's' + screen + '_' + k, screen, text });
      exact.push(exactCue('s' + screen + '_' + k, text));
    }));
    const active = () => {
      const h = CSS.highlights && CSS.highlights.get('fushi-sentence-audio');
      if (h && h.size) {
        return Array.from(h)
          .sort((a, b) => a.compareBoundaryPoints(Range.START_TO_START, b))
          .map((range) => range.toString()).join('');
      }
      return Array.from(reader.screen.querySelectorAll('.fushi-sentence-audio-active'))
        .map((node) => node.textContent).join('');
    };
    const firstTextNodeOf = (text) => {
      const walker = reader.createWalker();
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        const at = n.textContent.indexOf(text.slice(-3, -1));
        if (at >= 0) return { node: n, offset: at };
      }
      return null;
    };
    const failures = [];
    let checked = 0;
    for (const shift of [0, 3, -3, 30]) {
      const cues = exact.map((cue) => ({ ...cue, start: Math.max(0, cue.start + shift) }));
      reader.applySentenceAudioCues(cues);
      reader.renderScreen(0, true);
      for (const want of expected) {
        const cue = reader.sentenceAudioCueMap.get(want.id);
        const screenOf = reader.screenIndexForSentenceAudioCue(cue);
        reader.clearSentenceAudioCue();
        reader.highlightSentenceAudioCue(want.id, true, false, false);
        await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
        const got = active();
        const hit = firstTextNodeOf(want.text);
        const back = hit ? reader.cueIdAtDomPoint(hit.node, hit.offset) : null;
        checked++;
        if (screenOf !== want.screen || reader.currentScreenIndex !== want.screen ||
            got !== want.text || back !== JSON.stringify({ type: 'frag', id: want.id })) {
          failures.push({ shift, id: want.id, screenOf, current: reader.currentScreenIndex,
            want: want.text, got, back });
        }
      }
    }
    return { checked, failures, screens: reader.screens.length };
  })()`);
  assert.equal(r.screens, sentences.length, 'one VN screen per paragraph ' + JSON.stringify(r.screens));
  assert.equal(r.checked, sentences.length * 2 * 4, 'every sentence checked under every hint shift');
  assert.deepEqual(r.failures, [], 'VN relocates each cue by its text:\n' + JSON.stringify(r.failures, null, 1));
  console.log('PASS ' + r.checked + ' VN cue relocations');
} finally {
  driver.close();
}
