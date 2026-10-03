// BUG-2122 behavior test: 同一个音调型被多本词典各渲染成一行。
//
// 用户报告（官网首页 demo 弹窗，查「ギター」）：音高区连出五行一模一样的
// `￣ギター [1]`，来源分别是五本音调词典。Yomitan 在 getGroupedPronunciations 里
// 把相同发音合并成一条、后面挂全部来源标签；popup.js 之前是一本词典一行。
//
// 后续（2026-09-30 用户要求）：合并行一排五枚来源药丸读起来仍像重复，改成默认只挂
// 一枚「N 本辞典」药丸；悬停看 title，点击就地展开 / 收起各来源药丸（触屏没有悬停）。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM），驱动真实的
// `createPitchSection`，然后走产出的元素树数点 `.pitch-group` 行数、来源药丸
// `.pitch-dict-label` 与计数药丸 `.pitch-dict-label.pitch-dict-count`。把
// mergeIdenticalPitchGroups 或它的调用点撤掉，case 1 立刻变红。
//
// 覆盖：
//   1. 五本词典同为 [1]（去重关闭）→ 只剩 1 行；默认只见「5 本辞典」，5 枚来源药丸
//      按首次出现顺序在 DOM 里但隐藏；点击展开、再点收起。
//   2. 音调型不同（[1] vs [0]）→ 不合并，仍是 2 行，单来源行无计数药丸。
//   3. 位置部分重叠（[1,0] vs [1]）→ 判据是 payload 全等，故意不合并，仍是 2 行。
//   4. 去重打开 + 五本同为 [1] → 1 行，5 个来源全留住（BUG-2122 的另一半）。
//   5. 两本纯 IPA 词典给出完全相同的 transcriptions（去重打开）→ 合并成 1 行。
//   6. 宿主注入的 i18n 文案生效。
//
// Run: node fushi/test/pages/popup_pitch_merge_identical_test.js
// (also driven from popup_pitch_merge_identical_test.dart so it executes inside
//  `flutter test`).

const assert = require('assert');
const {
  loadPopup,
  collectByClass,
  collectText,
  dispatch,
} = require('./_popup_dom_host.js');

// 全部来源药丸（含隐藏的），按 DOM 顺序。
function labelNames(section) {
  return collectByClass(section, 'pitch-dict-label').map(n => n.textContent);
}

function visibleLabelNames(section) {
  return collectByClass(section, 'pitch-dict-label')
    .filter(n => n.style.display !== 'none')
    .map(n => n.textContent);
}

function countPills(section) {
  return collectByClass(section, 'pitch-dict-label pitch-dict-count');
}

function pitchGroupCount(section) {
  return collectByClass(section, 'pitch-group').length;
}

const FIVE_SAME = ['词典14', '词典13', '词典15', '词典16', '词典17'].map(
  name => ({ dictionary: name, pitchPositions: [1], patterns: [], transcriptions: [] }));
const FIVE_NAMES = ['词典14', '词典13', '词典15', '词典16', '词典17'];

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

    const counts = countPills(section);
    assert.strictEqual(counts.length, 1, 'a merged row carries exactly one count pill');
    const count = counts[0];
    assert.strictEqual(count.textContent, '5 本辞典');
    assert.strictEqual(count.title, FIVE_NAMES.join(', '),
      'hovering the count pill must reveal every source, in first-appearance order');
    assert.strictEqual(count.getAttribute('aria-expanded'), 'false');
    assert.deepStrictEqual(labelNames(section), FIVE_NAMES,
      'every source pill must stay in the DOM, in first-appearance order');
    assert.deepStrictEqual(visibleLabelNames(section), [],
      'source pills are collapsed by default — only the count pill shows');

    // 点击展开（触屏没有悬停）、再点收起。
    dispatch(count, 'click');
    assert.strictEqual(count.getAttribute('aria-expanded'), 'true');
    assert.deepStrictEqual(visibleLabelNames(section), FIVE_NAMES,
      'clicking the count pill must reveal every source pill');
    dispatch(count, 'click');
    assert.strictEqual(count.getAttribute('aria-expanded'), 'false');
    assert.deepStrictEqual(visibleLabelNames(section), [],
      'a second click collapses the sources again');

    const text = collectText(section);
    const occurrences = text.split('[1]').length - 1;
    assert.strictEqual(occurrences, 1,
      'the accent [1] must be drawn exactly once after merging; got ' + occurrences
        + ' in ' + JSON.stringify(text));
  }

  // Case 2: 音调型不同 —— 绝不合并；单来源行照旧直接显示词典名、无计数药丸。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [0], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 2,
      'dictionaries disagreeing on the accent must stay on separate rows');
    assert.deepStrictEqual(visibleLabelNames(section), ['A', 'B']);
    assert.strictEqual(countPills(section).length, 0,
      'single-source rows need no count pill');
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
  // 消失。合并挪到去重之前后：5 本先并成一组，unique=[1] 存活，5 个来源全留住。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.strictEqual(pitchGroupCount(section), 1,
      'dedup ON must still yield exactly one row');
    assert.deepStrictEqual(labelNames(section), FIVE_NAMES,
      'dedup ON must keep EVERY source — dropping four of them is the '
        + '"one setting loses information" half of BUG-2122');
    assert.strictEqual(countPills(section)[0].textContent, '5 本辞典');
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
    assert.strictEqual(countPills(section)[0].title, 'A, B');
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
    assert.strictEqual(countPills(section)[0].textContent, '2 本辞典');
    const text = collectText(section);
    assert.strictEqual(text.split('[neꜜko]').length - 1, 1,
      'the shared transcription must be printed once; got ' + JSON.stringify(text));
  }

  // Case 6: 宿主注入的本地化文案（popup_settings_injection 的 i18nPitchSourceCount）。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    sb.window.i18nPitchSourceCount = '{count} dictionaries';
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.strictEqual(countPills(section)[0].textContent, '5 dictionaries');
  }

  console.log('popup_pitch_merge_identical_test.js: all assertions passed');
})();
