// Dart↔JS 学习单位计数对拍 harness。
//
// 由 study_char_count_parity_test.dart 调起：
//   argv[2] = 内嵌 JS（ReaderStudyUnitScript.kStudyUnitJs 的真值，落到临时文件）
//   argv[3] = 语料 JSON 文件（字符串数组）
// 输出一行 JSON：{ counts: [...], prefixTotals: [...] }
//   counts[i]       = window.fushiStudyUnits.count(sample)
//   prefixTotals[i] = 逐位置 isUnitEnd 累加的总数（必须等于 counts[i]，否则两个
//                     入口自相矛盾——调用点用的是 isUnitEnd，总数用的是 count）
//   inverseFails    = unitStartOffset（isUnitEnd 前缀计数的逆，落页 / 页上校验用）违例：
//                     第 k 个单位的首码点前必须恰有 k 个单位结束、该码点是字母数字、
//                     不在词中间；k == count 时落到文本末尾（BUG-3648）
const fs = require('node:fs');
const vm = require('node:vm');

const jsPath = process.argv[2];
const corpusPath = process.argv[3];

const sandbox = { console };
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(jsPath, 'utf8'), sandbox);

const units = sandbox.window.fushiStudyUnits;
if (!units) {
  console.error('fushiStudyUnits not defined by the injected script');
  process.exit(2);
}

const samples = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
const counts = [];
const prefixTotals = [];
const inverseFails = [];
const LN = /[\p{L}\p{N}]/u;
const prefixBefore = (s, end) => {
  let n = 0;
  for (let i = 0; i < end;) {
    const ch = String.fromCodePoint(s.codePointAt(i));
    if (units.isUnitEnd(s, i)) n++;
    i += ch.length;
  }
  return n;
};
for (const s of samples) {
  counts.push(units.count(s));
  const unitTotal = units.count(s);
  for (let k = 0; k <= unitTotal; k++) {
    const o = units.unitStartOffset(s, k);
    const tag = JSON.stringify(s) + ' k=' + k + ' -> ' + o;
    if (k === unitTotal) {
      if (o !== s.length) inverseFails.push(tag + ': past the last unit must be text end');
      continue;
    }
    if (prefixBefore(s, o) !== k) inverseFails.push(tag + ': ' + prefixBefore(s, o) + ' units end before it');
    const ch = o < s.length ? String.fromCodePoint(s.codePointAt(o)) : '';
    if (!LN.test(ch)) inverseFails.push(tag + ': lands on ' + JSON.stringify(ch) + ', not a unit start');
    if (o > 0) {
      let j = o - 1;
      if (j > 0 && s.charCodeAt(j) >= 0xDC00 && s.charCodeAt(j) <= 0xDFFF) j--;
      const prev = String.fromCodePoint(s.codePointAt(j));
      if (LN.test(prev) && !units.isUnitEnd(s, j)) inverseFails.push(tag + ': lands mid-word');
    }
  }
  let total = 0;
  for (let i = 0; i < s.length;) {
    const cp = s.codePointAt(i);
    const ch = String.fromCodePoint(cp);
    if (units.isUnitEnd(s, i)) total++;
    i += ch.length;
  }
  prefixTotals.push(total);
}
process.stdout.write(JSON.stringify({ counts, prefixTotals, inverseFails }));
