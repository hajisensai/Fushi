// Dart↔JS 学习单位计数对拍 harness。
//
// 由 study_char_count_parity_test.dart 调起：
//   argv[2] = 内嵌 JS（ReaderStudyUnitScript.kStudyUnitJs 的真值，落到临时文件）
//   argv[3] = 语料 JSON 文件（字符串数组）
// 输出一行 JSON：{ counts: [...], prefixTotals: [...] }
//   counts[i]       = window.fushiStudyUnits.count(sample)
//   prefixTotals[i] = 逐位置 isUnitEnd 累加的总数（必须等于 counts[i]，否则两个
//                     入口自相矛盾——调用点用的是 isUnitEnd，总数用的是 count）
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
for (const s of samples) {
  counts.push(units.count(s));
  let total = 0;
  for (let i = 0; i < s.length;) {
    const cp = s.codePointAt(i);
    const ch = String.fromCodePoint(cp);
    if (units.isUnitEnd(s, i)) total++;
    i += ch.length;
  }
  prefixTotals.push(total);
}
process.stdout.write(JSON.stringify({ counts, prefixTotals }));
