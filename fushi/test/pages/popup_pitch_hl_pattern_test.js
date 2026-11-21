// BUG-5054 behavior test（反馈 ax68AKUrex）：H/L 模式串音调不画高低线、与同型数字位分两行。
//
// 大辞泉+ / NHK-meta 的 pitch position 是 H/L 串（"LHHHH"）。原生层原样放进 popup JSON 的
// `patterns`，popup.js 以前把它一律当纯文本 `[LHHHH]` 渲染，也不换算成下降位——于是
// 「関係 かんけい」的 [LHHHH] 和アクセント辞典的 [0] 明明同是平板型却分成两行，制卡字段
// 也写成 [LHHHH]。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM）：
//   1. 换算：拍数 + 1 长度的串唯一对应一个下降位；只给拍数且末拍高（平板 / 尾高不可分）不硬猜。
//   2. 弹窗：[LHHHH] 与 [0] 合并成一行（3 个来源），画出高低线、不再出现 [LHHHH] 文本。
//   3. 弹窗：换算不了的 H/L 串仍画高低线（逐拍读字符），"heiban" 这类名字仍是文本。
//   4. 制卡：{pitch-accent-positions} 写 [0]，{pitch-accent-categories} 给出 heiban。
//
// Run: node fushi/test/pages/popup_pitch_hl_pattern_test.js
// (also driven from popup_pitch_hl_pattern_test.dart inside `flutter test`).

const assert = require('assert');
const { loadPopup, collectByClass, collectText } = require('./_popup_dom_host.js');

function dict(name, positions, patterns) {
  return { dictionary: name, pitchPositions: positions || [], patterns: patterns || [], transcriptions: [] };
}

function moraPitches(section) {
  return collectByClass(section, 'pronunciation-text').map(text =>
    (text.children || []).map(m => (m.attributes['data-pitch'] === 'high' ? 'H' : 'L')).join(''));
}

(function run() {
  const sb = loadPopup();

  // Case 1: 换算。
  {
    const toDownstep = sb.pitchPatternToDownstep;
    assert.strictEqual(toDownstep('かんけい', 'LHHHH'), 0, 'heiban with particle');
    assert.strictEqual(toDownstep('かんけい', 'LHHHL'), 4, 'odaka with particle');
    assert.strictEqual(toDownstep('かんけい', 'HLLLL'), 1, 'atamadaka');
    assert.strictEqual(toDownstep('かんけい', 'LHLLL'), 2, 'nakadaka');
    assert.strictEqual(toDownstep('きょう', 'HLL'), 1, 'small kana joins its mora');
    assert.strictEqual(toDownstep('かんけい', 'LHHH'), null,
      'without the particle mora heiban and odaka are indistinguishable: do not guess');
    assert.strictEqual(toDownstep('かんけい', 'HHLL'), null, 'irregular pattern stays a pattern');
    assert.strictEqual(toDownstep('かんけい', 'LHH'), null, 'length mismatch stays a pattern');
    assert.strictEqual(toDownstep('かんけい', 'heiban'), null, 'named pattern stays a pattern');
  }

  // Case 2: 反馈原形——两本 H/L 串词典 + 一本数字位词典，同为平板型。
  for (const dedup of [true, false]) {
    sb.window.deduplicatePitchAccents = dedup;
    const section = sb.window.__test.createPitchSection(
      [dict('NHK-meta', [], ['LHHHH']), dict('大辞泉+', [], ['LHHHH']), dict('アクセント辞典', [0])],
      'かんけい',
    );
    const groups = collectByClass(section, 'pitch-group');
    assert.strictEqual(groups.length, 1,
      `[dedup=${dedup}] [LHHHH] and [0] are the same heiban accent and must share one row`);
    assert.strictEqual(groups[0].attributes['data-details'], 'NHK-meta, 大辞泉+, アクセント辞典');
    const text = collectText(section);
    assert.ok(!text.includes('[LHHHH]'), `[dedup=${dedup}] pattern must not be printed as text: ${text}`);
    assert.ok(text.includes('[0]'), `[dedup=${dedup}] downstep label must be shown: ${text}`);
    assert.deepStrictEqual(moraPitches(section), ['LHHH'], `[dedup=${dedup}] the graph must be drawn`);
  }

  // Case 3: 换算不了的 H/L 串仍画图；名字式 pattern 仍是文本。
  {
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection(
      [dict('d1', [], ['HHLL', 'heiban'])],
      'かんけい',
    );
    assert.deepStrictEqual(moraPitches(section), ['HHLL'], 'irregular H/L pattern is drawn mora by mora');
    const text = collectText(section);
    assert.ok(text.includes('[HHLL]') && text.includes('[heiban]'), text);
  }

  // Case 4: 制卡字段走同一份归一化。
  {
    const pitches = [dict('NHK-meta', [], ['LHHHH']), dict('アクセント辞典', [0])];
    const normalized = sb.normalizePitchPatterns(pitches, 'かんけい');
    const html = sb.constructPitchPositionHtml(sb.mergeIdenticalPitchGroups(normalized));
    assert.ok(!html.includes('LHHHH'), html);
    assert.strictEqual((html.match(/<li>/g) || []).length, 1, 'one [0] entry after merge: ' + html);
    assert.strictEqual(sb.constructPitchCategories(normalized, 'かんけい', []), 'heiban');
    // 入参不被改写（纯变换）。
    assert.deepStrictEqual(pitches[0].patterns, ['LHHHH']);
  }

  console.log('all assertions passed');
})();
