// chj2rZn89F：点带 ruby 的词的后半个基字（「近衛（このえ）」点「衛」），旧实现只从「衛」起查、
// 高亮却给整个 <ruby> 元素加类——查的和亮的不是同一段。在真 Chrome DOM 上跑生产的
// fushiReader / fushiSelection，断言：① 点 ruby 基字任意位置，查词从该 ruby 基字段的开头起；
// ② 高亮只在完整覆盖 ruby 全部基字时才整元素加类，部分覆盖按字符范围画（等于查词范围）。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
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
      return results;
    })()`);
    count += result.length;
  }
  console.log('PASS ' + count + ' browser cases');
} finally {
  driver.close();
}
