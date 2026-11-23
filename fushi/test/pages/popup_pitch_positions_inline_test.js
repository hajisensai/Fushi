// 反馈 iTMx1pCb2V：{pitch-accent-positions} 是 <ul> 列表，多音调的词在卡片上占多行。
// 新增单行变体 {pitch-accent-positions-inline}：条目与默认字段完全同源，只是不包 <ul>、
// 条目之间用「・」连接；默认字段仍是 <ul>（BUG-2151）。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM）。
//
// Run: node fushi/test/pages/popup_pitch_positions_inline_test.js
// (also driven from test/anki/pitch_positions_inline_marker_test.dart inside `flutter test`).

const assert = require('assert');
const { loadPopup } = require('./_popup_dom_host.js');

function dict(name, positions, patterns, transcriptions) {
  return {
    dictionary: name,
    pitchPositions: positions || [],
    patterns: patterns || [],
    transcriptions: transcriptions || [],
  };
}

function entry(text) {
  return `<span style="display:inline;"><span>[</span><span>${text}</span><span>]</span></span>`;
}

(function run() {
  const sb = loadPopup();

  // Case 1: 多音调——单行、不含任何列表标签，条目顺序与默认字段一致。
  {
    const pitches = [dict('d1', [0, 2]), dict('d2', [], ['heiban'], ['/a<b/'])];
    const expected = [entry(0), entry(2), entry('heiban'), entry('/a&lt;b/')];
    const inline = sb.constructPitchPositionInlineHtml(pitches);
    assert.strictEqual(inline, expected.join('・'), inline);
    assert.ok(!/<\/?(ul|ol|li)\b/.test(inline), 'inline variant must not contain list markup: ' + inline);

    const list = sb.constructPitchPositionHtml(pitches);
    assert.strictEqual(
      list,
      '<ul>' + expected.map(e => `<li>${e}</li>`).join('') + '</ul>',
      'default {pitch-accent-positions} keeps its <ul> shape (BUG-2151): ' + list,
    );
  }

  // Case 2: 单个音调没有分隔符。
  assert.strictEqual(sb.constructPitchPositionInlineHtml([dict('d1', [1])]), entry(1));

  // Case 3: 空输入 / 全空组都是 ''，字段按空跳过。
  assert.strictEqual(sb.constructPitchPositionInlineHtml([]), '');
  assert.strictEqual(sb.constructPitchPositionInlineHtml(null), '');
  assert.strictEqual(sb.constructPitchPositionInlineHtml([dict('d1', [])]), '');
  assert.strictEqual(sb.constructPitchPositionHtml([dict('d1', [])]), '');

  console.log('all assertions passed');
})();
