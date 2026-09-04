// BUG-2122 behavior test: 同一个音调型被多本词典各渲染成一行。
//
// 用户报告（官网首页 demo 弹窗，查「ギター」）：音高区连出五行一模一样的
// `￣ギター [1]`，来源分别是五本音调词典。Yomitan 在 getGroupedPronunciations 里
// 把相同发音合并成一条、后面挂全部来源标签；popup.js 之前是一本词典一行。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM），驱动真实的
// `createPitchSection`，然后走产出的元素树数点 `.pitch-group` 行数与
// `.pitch-dict-label` 药丸。把 mergeIdenticalPitchGroups 或它的调用点撤掉，
// case 1 立刻变红。
//
// 覆盖：
//   1. 五本词典同为 [1]（去重关闭）→ 只剩 1 行，5 枚来源药丸，按首次出现顺序。
//   2. 音调型不同（[1] vs [0]）→ 不合并，仍是 2 行。
//   3. 位置部分重叠（[1,0] vs [1]）→ 判据是 payload 全等，故意不合并，仍是 2 行。
//   4. 去重打开 + 五本同为 [1] → 与改动前一致：1 行 1 枚药丸（默认外观零变化）。
//   5. 两本纯 IPA 词典给出完全相同的 transcriptions（去重打开）→ 合并成 1 行 2 枚药丸。
//
// Run: node fushi/test/pages/popup_pitch_merge_identical_test.js
// (also driven from popup_pitch_merge_identical_test.dart so it executes inside
//  `flutter test`).

const assert = require('assert');
const {
  loadPopup,
  collectByClass,
  collectText,
} = require('./_popup_dom_host.js');

function labelNames(section) {
  return collectByClass(section, 'pitch-dict-label').map(n => n.textContent);
}

function pitchGroupCount(section) {
  return collectByClass(section, 'pitch-group').length;
}

const FIVE_SAME = ['词典14', '词典13', '词典15', '词典16', '词典17'].map(
  name => ({ dictionary: name, pitchPositions: [1], patterns: [], transcriptions: [] }));

(function run() {
  // Case 1: 用户报告的原样输入 —— 五本词典同为 [1]，去重关闭。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.ok(section, 'five identical pitch dicts must still render a pitch section');
    assert.strictEqual(pitchGroupCount(section), 1,
      'five dictionaries agreeing on [1] must collapse into ONE .pitch-group row; got '
        + pitchGroupCount(section));
    assert.deepStrictEqual(labelNames(section),
      ['词典14', '词典13', '词典15', '词典16', '词典17'],
      'the merged row must carry every source label, in first-appearance order');
    const text = collectText(section);
    const occurrences = text.split('[1]').length - 1;
    assert.strictEqual(occurrences, 1,
      'the accent [1] must be drawn exactly once after merging; got ' + occurrences
        + ' in ' + JSON.stringify(text));
  }

  // Case 2: 音调型不同 —— 绝不合并。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [0], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 2,
      'dictionaries disagreeing on the accent must stay on separate rows');
    assert.deepStrictEqual(labelNames(section), ['A', 'B']);
  }

  // Case 3: 位置部分重叠 —— 判据是 payload 全等，故意不合并（宁可少合）。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1, 0], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [1], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 2,
      'partially overlapping position sets must NOT be merged (payload equality is the rule)');
  }

  // Case 4: 去重打开（**app 默认档**）—— 这才是 BUG-2122 的另一半。
  //
  // 旧行为：去重先跑，第二本同型词典的 unique 已经是空数组，整组被丢，来源名随之
  // 消失，弹窗只剩 `[词典14] ￣ギター [1]` 一枚药丸。BUG 文件自己写的判据是
  // 「一档丢信息，另一档出重复」——这一档丢的就是**信息**，而且绝大多数用户在这一档。
  // 合并挪到去重之前后：5 本先并成一组，unique=[1] 存活，5 个来源全留住。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.strictEqual(pitchGroupCount(section), 1,
      'dedup ON must still yield exactly one row');
    assert.deepStrictEqual(labelNames(section),
      ['词典14', '词典13', '词典15', '词典16', '词典17'],
      'dedup ON must keep EVERY source label — dropping four of them is the '
        + '"one setting loses information" half of BUG-2122');
    const text = collectText(section);
    assert.strictEqual(text.split('[1]').length - 1, 1,
      'the accent [1] must still be drawn exactly once; got ' + JSON.stringify(text));
  }

  // Case 4b: 位置顺序不同但集合相同 —— 同一音调型，必须合并。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1, 0], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [0, 1], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 1,
      '[1,0] and [0,1] are the same accent set; key must sort before comparing');
    assert.deepStrictEqual(labelNames(section), ['A', 'B']);
  }

  // Case 5: 两本纯 IPA 词典给出完全相同的 transcriptions → 合并。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'IPA-1', pitchPositions: [], patterns: [], transcriptions: ['neꜜko'] },
      { dictionary: 'IPA-2', pitchPositions: [], patterns: [], transcriptions: ['neꜜko'] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 1,
      'two IPA dicts with identical transcriptions must merge into one row');
    assert.deepStrictEqual(labelNames(section), ['IPA-1', 'IPA-2']);
    const text = collectText(section);
    assert.strictEqual(text.split('[neꜜko]').length - 1, 1,
      'the shared transcription must be printed once; got ' + JSON.stringify(text));
  }

  console.log('popup_pitch_merge_identical_test.js: all assertions passed');
})();
