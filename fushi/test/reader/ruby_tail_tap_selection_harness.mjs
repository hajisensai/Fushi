// chj2rZn89F：点带 ruby 的词的后半个基字（「近衛（このえ）」点「衛」），旧实现只从「衛」起查、
// 高亮却给整个 <ruby> 元素加类——查的和亮的不是同一段。在真 Chrome DOM 上跑生产的
// fushiReader / fushiSelection，断言：① 点 ruby 基字任意位置，查词从该 ruby 基字段的开头起；
// ② 高亮只在完整覆盖 ruby 全部基字时才整元素加类，部分覆盖按字符范围画（等于查词范围）。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const driver = await launchChromeDriver();
let count = 0;
try {
  for (const shell of scripts.shells) {
    const start = shell.indexOf('window.fushiReader = {');
    const end = shell.indexOf('\n};', start);
    assert.ok(start >= 0 && end > start, 'production reader object exists');
    const source = 'const C = {};\n' + scripts.units + '\n' +
      shell.slice(start, end + 3) + '\n' + scripts.selection;
    const html = '<!doctype html><meta charset="utf-8">' +
      '<style>html,body{margin:0}body{padding:30px;font:20px/1.6 serif;width:520px}</style><body>';
    const result = await driver.evalOnPage(html, `(async () => {
      (0, eval)(${JSON.stringify(source)});
      window.flutter_inappwebview = {callHandler: (name, payload) => {
        if (typeof payload === 'string') window.lastPayload = JSON.parse(payload);
        return Promise.resolve(null);
      }};
      window.__fushiCssHighlightsSupported = true;
      const selection = window.fushiSelection;
      const results = [];
      function check(condition, label) {
        if (!condition) throw Error(label);
        results.push(label);
      }
      function selRanges() {
        const hl = CSS.highlights.get('fushi-selection');
        return hl ? Array.from(hl) : [];
      }

      document.body.innerHTML = '<p>ハクの<ruby>近衛<rt>このえ</rt></ruby>だった。</p>';
      const ruby = document.querySelector('ruby');
      const base = ruby.firstChild;
      // ① 点「衛」（偏移 1）：查词从「近」起。
      selection.clearSelection();
      const text = selection.selectFromPosition(base, 1, 20, 10, 10, false);
      check(typeof text === 'string' && text.indexOf('近衛') === 0,
        'tapping the tail of a ruby base starts the lookup at the ruby start: ' + text);
      check(selection.selection.startNode === base && selection.selection.startOffset === 0,
        'selection start is snapped to the ruby base start');
      // ② 匹配只覆盖「近」：不整元素加类，按字符范围画。
      selection.highlightSelection(1);
      check(!ruby.classList.contains('fushi-selection-ruby-active'),
        'a partial ruby match does not paint the whole ruby element');
      const partial = selRanges();
      check(partial.length === 1 && partial[0].toString() === '近',
        'a partial ruby match paints exactly the matched characters');
      // 完整覆盖「近衛」：整元素加类（BUG-110 的竖排单次绘取舍保留）。
      selection.highlightSelection(2);
      check(ruby.classList.contains('fushi-selection-ruby-active'),
        'a full ruby match paints the ruby element once');
      check(selRanges().length === 0, 'a fully covered ruby is not double-painted via ::highlight');

      // 同一个词再点后半个基字 = 再点同词：toggle 取消（起点归一后与当前选区同起点）。
      selection.clearSelection();
      selection.selectFromPosition(base, 0, 20, 10, 10, false);
      const tap = selection.selectionStartFor(base, 1);
      check(tap.node === selection.selection.startNode && tap.offset === selection.selection.startOffset,
        'the tail of the same ruby normalizes to the current selection start');

      // 多对基字的 ruby：按段吸附，查到一段时不把整个 ruby 都亮起来。
      document.body.innerHTML = '<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を読む</p>';
      const multi = document.querySelector('ruby');
      const kan = multi.childNodes[0];
      const ji = multi.childNodes[2];
      selection.clearSelection();
      const t2 = selection.selectFromPosition(ji, 0, 20, 10, 10, false);
      check(t2.indexOf('字') === 0, 'a per-character ruby pair stays on its own segment: ' + t2);
      selection.highlightSelection(1);
      check(!multi.classList.contains('fushi-selection-ruby-active'),
        'matching one pair of a multi-pair ruby does not paint the other pair');
      selection.clearSelection();
      selection.selectFromPosition(kan, 0, 20, 10, 10, false);
      selection.highlightSelection(2);
      check(multi.classList.contains('fushi-selection-ruby-active'),
        'covering every base of a multi-pair ruby paints it once');
      selection.clearSelection();

      // ssJjbvbAbs：义训把两个词标进同一个 <ruby>（じょうろ鼬 / ポットウィーゼル）。吸附后从组首
      // 查词只能查到「じょうろ」，点「鼬」必须还能查到鼬：payload 带上被点字的位置与从被点字
      // 起扫的整份候选 payload，由宿主按命中长度判定；采用后选区 / 高亮跟随被点字。
      document.body.innerHTML =
        '<p>ここ、<ruby>じょうろ鼬<rt>ポットウィーゼル</rt></ruby>が巣を作ってるの！</p>';
      const potRuby = document.querySelector('ruby');
      const potBase = potRuby.firstChild;
      selection.clearSelection();
      window.lastPayload = null;
      const t3 = selection.selectFromPosition(potBase, 4, 20, 10, 10, false);
      check(t3.indexOf('じょうろ鼬が') === 0, 'the snapped scan still starts at the ruby start: ' + t3);
      const snap = window.lastPayload && window.lastPayload.rubySnap;
      check(!!snap && snap.tapIndex === 4,
        'the payload carries the tapped code point index inside the snapped text: ' +
          JSON.stringify(snap && snap.tapIndex));
      check(!!snap && snap.selection && snap.selection.text.indexOf('鼬が巣') === 0,
        'the payload carries the lookup scanned from the tapped char: ' +
          (snap && snap.selection && snap.selection.text));
      check(!!snap && snap.selection && !snap.selection.rubySnap &&
          (snap.selection.rubyReadings || []).length === 0,
        'the tapped-char candidate carries no ruby reading for the partially covered ruby');
      check(selection.adoptRubySnapTap('stale text') === false,
        'adopting is refused when the live selection is no longer the reported one');
      check(selection.adoptRubySnapTap(t3) === true, 'the host can adopt the tapped-char start');
      check(selection.selection.startNode === potBase && selection.selection.startOffset === 4 &&
          selection.selection.text.indexOf('鼬が') === 0,
        'the adopted selection starts at the tapped char');
      selection.highlightSelection(1);
      const adopted = selRanges();
      check(adopted.length === 1 && adopted[0].toString() === '鼬' &&
          !potRuby.classList.contains('fushi-selection-ruby-active'),
        'the adopted lookup highlights exactly the tapped char');
      check(selection.designatesCurrentSelection({ node: potBase, offset: 4 },
          selection.selectionStartFor(potBase, 4)),
        'tapping the adopted char again designates the current selection (toggle)');
      check(!selection.designatesCurrentSelection({ node: potBase, offset: 0 },
          selection.selectionStartFor(potBase, 0)),
        'tapping the ruby start after adopting is a different lookup');
      // 点组首「じ」：不带候选（被点字就是起点）；查到「じょうろ」后点「鼬」是另一个词，不是同词取消。
      selection.clearSelection();
      window.lastPayload = null;
      selection.selectFromPosition(potBase, 0, 20, 10, 10, false);
      check(window.lastPayload && !window.lastPayload.rubySnap,
        'tapping the ruby start carries no tapped-char candidate');
      selection.highlightSelection(4);
      check(!selection.designatesCurrentSelection({ node: potBase, offset: 4 },
          selection.selectionStartFor(potBase, 4)),
        'a ruby char outside the matched word is not the current selection');
      check(selection.designatesCurrentSelection({ node: potBase, offset: 2 },
          selection.selectionStartFor(potBase, 2)),
        'a ruby char inside the matched word is the current selection');

      // 候选的句内偏移 / 归一偏移按被点字起算；fireTextSelected 只在外层追加的 fromHover /
      // selectedSeq / 歌词 cue 同步进候选（宿主采用候选后整份换成它）。
      document.body.innerHTML =
        '<p>ここ、<ruby>じょうろ鼬<rt>ポットウィーゼル</rt></ruby>が巣を作ってるの！</p>';
      const hoverBase = document.querySelector('ruby').firstChild;
      selection.clearSelection();
      window.lastPayload = null;
      window.__lyricsCueContext = { cueId: 'cue-7' };
      selection.selectFromPosition(hoverBase, 4, 20, 10, 10, true);
      delete window.__lyricsCueContext;
      const outer = window.lastPayload;
      const cand = outer && outer.rubySnap && outer.rubySnap.selection;
      check(!!cand && cand.sentenceOffset === outer.sentenceOffset + 4 &&
          outer.sentence.slice(cand.sentenceOffset).indexOf('鼬が') === 0,
        'the candidate sentence offset points at the tapped char: ' +
          JSON.stringify(cand && [outer.sentenceOffset, cand.sentenceOffset]));
      check(!!cand && cand.normalizedOffset === outer.normalizedOffset + 4,
        'the candidate normalized offset starts at the tapped char: ' +
          JSON.stringify(cand && [outer.normalizedOffset, cand.normalizedOffset]));
      check(!!cand && cand.fromHover === true && outer.fromHover === true &&
          cand.selectedSeq === outer.selectedSeq &&
          !!cand.lyricsCueContext && cand.lyricsCueContext.cueId === 'cue-7',
        'the candidate carries the outer hover / sequence / lyrics cue fields: ' +
          JSON.stringify(cand && [cand.fromHover, cand.selectedSeq, outer.selectedSeq, cand.lyricsCueContext]));

      // tapIndex 与宿主查词命中长度（bestLength，UTF-16）同单位：组内被点字前有扩展区汉字
      // （𩸽 占 2 个 UTF-16 单元）时，按码点数会少算 1，宿主把「𩸽」的命中误当成覆盖到了「鼬」。
      document.body.innerHTML = '<p>あ<ruby>𩸽鼬<rt>ほっけいたち</rt></ruby>が</p>';
      const astralBase = document.querySelector('ruby').firstChild;
      selection.clearSelection();
      window.lastPayload = null;
      selection.selectFromPosition(astralBase, 2, 20, 10, 10, false);
      const astral = window.lastPayload && window.lastPayload.rubySnap;
      check(!!astral && astral.tapIndex === 2 &&
          window.lastPayload.text.slice(astral.tapIndex).indexOf('鼬') === 0,
        'tapIndex is the UTF-16 index of the tapped char after an astral base: ' +
          JSON.stringify(astral && astral.tapIndex));
      selection.clearSelection();
      return results;
    })()`);
    count += result.length;
  }
  console.log('PASS ' + count + ' browser cases');
} finally {
  driver.close();
}
