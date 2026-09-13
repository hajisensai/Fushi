// BUG-2397 behavior test: 「音调去重」对 pattern 式音调与 IPA 完全不生效。
//
// 用户报告：设置里「Deduplicate pitch accents」开着，音高区照样出现一模一样的重复行。
//
// 根因：createPitchSection 的去重分支只把**数字位置**（pitchPositions）收进 seen，
// `patterns`（"heiban" 等 pattern 式音调）与 `transcriptions`（IPA 音标）一概不参与去重，
// 而且「保活守卫」用的是「原始字段非空」——于是第二本词典即使一个字都不新，也照样整行
// 渲染出来。上游的 mergeIdenticalPitchGroups 只能接住「整份 payload 全等」的那一种；
// 两本词典只要在任意一个字段上差一点（一本带 IPA、一本不带），合并就不成立，重复
// 全部落到去重这一步，而这一步以前对这两类视而不见。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM），驱动真实的 createPitchSection，
// 然后在产出的元素树里数「同一个可见条目出现了几次」。把三个 seen 里的任何一个退回
// 原来的单一 seen，对应 case 立刻变红。
//
// Cases covered:
//   1. 两本词典同标 pattern `heiban`、其中一本另带 IPA（合并不成立）→ `[heiban]` 只出现一次。
//   2. 两本词典给出同一段 IPA、数字位置不同（合并不成立）→ 该 IPA 只出现一次，两个位置都在。
//   3. 去重关闭时，重复的 pattern / IPA 全部保留（开关必须仍然有意义，非恒真）。
//   4. 不回归 TODO-688：唯一的 IPA-only 词典（无数字位置）仍然渲染出它的 IPA。
//   5. 不回归 BUG-2122：五本同标 [1] 的词典塌成 1 行、5 枚来源药丸。
//
// Run: node fushi/test/pages/popup_pitch_dedup_patterns_ipa_test.js
// (also driven from popup_pitch_dedup_patterns_ipa_test.dart so it executes inside
//  `flutter test`).

const assert = require('assert');
const {
  loadPopup,
  collectByClass,
  collectText,
} = require('./_popup_dom_host.js');

function dict(name, positions, patterns, transcriptions) {
  return {
    dictionary: name,
    pitchPositions: positions || [],
    patterns: patterns || [],
    transcriptions: transcriptions || [],
  };
}

function render(pitches, dedup, reading) {
  const sb = loadPopup();
  sb.window.deduplicatePitchAccents = dedup;
  return sb.window.__test.createPitchSection(pitches, reading || 'ギター');
}

// 整棵树里某段可见文本出现了几次。pattern 式音调渲染成裸文本节点 `[heiban]`，
// IPA 渲染成 .pitch-transcription-tag 的 `[ipa]`——数「用户眼睛看到几次」，
// 所以统一在文本层数，而不是数元素类型。
function occurrences(section, needle) {
  const text = collectText(section);
  let count = 0;
  let from = 0;
  for (;;) {
    const at = text.indexOf(needle, from);
    if (at < 0) return count;
    count += 1;
    from = at + needle.length;
  }
}

function ipaTags(section) {
  return collectByClass(section, 'pitch-transcription-tag').map(n => n.textContent);
}

(function run() {
  // Case 1: 用户报告的主形态——两本词典都说 heiban，其中一本另带 IPA。
  // 整份 payload 不全等 ⇒ mergeIdenticalPitchGroups 合并不了 ⇒ 全靠去重这一步。
  {
    const section = render(
      [dict('d1', [], ['heiban']), dict('d2', [], ['heiban'], ['ɡiꜜtaː'])],
      true,
    );
    assert.ok(section, 'pattern-only pitch groups must still render a section');
    const heiban = occurrences(section, '[heiban]');
    assert.strictEqual(heiban, 1,
      'with dedup ON, the same pattern accent must be shown ONCE across '
        + 'dictionaries; got ' + heiban + ' copies');
    // 第二本词典独有的 IPA 不能被误杀——去重删的是重复，不是整行。
    assert.deepStrictEqual(ipaTags(section), ['[ɡiꜜtaː]'],
      'the second dictionary\'s unique IPA must survive dedup');
  }

  // Case 2: 两本 IPA 词典给出同一串音标，数字位置不同（同样合并不了）。
  {
    const section = render(
      [dict('d1', [1], [], ['ɡiꜜtaː']), dict('d2', [0], [], ['ɡiꜜtaː'])],
      true,
    );
    assert.deepStrictEqual(ipaTags(section), ['[ɡiꜜtaː]'],
      'with dedup ON, an identical IPA transcription must be shown ONCE');
    // 两个数字位置都是新的，必须都留下（去重不是「只留第一本词典」）。
    const text = collectText(section);
    assert.ok(text.includes('[1]') && text.includes('[0]'),
      'both distinct pitch positions must survive; got: ' + text);
  }

  // Case 3: 非恒真——关掉开关，重复必须回来。否则上面两条即使去重代码整块删掉也能过。
  {
    const section = render(
      [dict('d1', [], ['heiban']), dict('d2', [], ['heiban'], ['ɡiꜜtaː'])],
      false,
    );
    assert.strictEqual(occurrences(section, '[heiban]'), 2,
      'with dedup OFF the duplicate pattern must still be rendered twice '
        + '(otherwise the setting would be meaningless)');
  }

  // Case 4: TODO-688 不回归——纯 IPA 词典（无数字位置）在去重打开时仍要渲染 IPA。
  {
    const section = render([dict('d1', [1]), dict('ipa', [], [], ['neꜜko'])], true);
    assert.deepStrictEqual(ipaTags(section), ['[neꜜko]'],
      'an IPA-only dictionary must still render under dedup (TODO-688)');
  }

  // Case 5: BUG-2122 不回归——五本同标 [1] 塌成一行、五枚来源药丸。
  {
    const five = ['d1', 'd2', 'd3', 'd4', 'd5'].map(n => dict(n, [1]));
    const section = render(five, true);
    assert.strictEqual(collectByClass(section, 'pitch-group').length, 1,
      'five dictionaries agreeing on [1] must stay collapsed into one row');
    assert.strictEqual(collectByClass(section, 'pitch-dict-label').length, 5,
      'all five source labels must survive (BUG-2122)');
  }

  console.log('all assertions passed');
})();
