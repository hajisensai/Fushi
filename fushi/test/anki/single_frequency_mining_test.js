// BUG-4227（反馈 ArXVzMKmM5）：popup.js 制卡 payload 的逐词典频率。
//
// node 真执行 popup.js 抽出的 collectFrequencyNumbers / getFrequencyHarmonicRank /
// constructSingleFrequencyNumbers / constructSingleFrequenciesHtml /
// constructFrequencyHtml，断言：
//   1. 每本词典的数与 Yomitan getFrequencyNumbers 同语义（displayValue 前导数字 > 0
//      优先，否则 value > 0；同词典只认第一组）；
//   2. 调和平均与逐词典数同源（改动前后调和平均逐值不变）；
//   3. buildMinePayload 真的把两张表放进返回对象（Dart 侧 fromJson 读这两个键）。
// Dart 侧渲染见 packages/fushi_anki/test/handlebar_single_frequency_test.dart；
// 三镜像逐字节一致由 browser_extension_popup_parity_guard_test.dart 守。
//
// 运行：node fushi/test/anki/single_frequency_mining_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
// 真 popup.js 整份跑在共享宿主里（vm + 假 DOM，见 _popup_dom_host.js），顶层函数声明
// 落在沙盒全局上，直接取用——不再各测试复制一份「抽函数 + vm」的样板。
const { loadPopup } = require('../pages/_popup_dom_host.js');

const api = loadPopup();
for (const name of ['constructFrequencyHtml', 'getFrequencyHarmonicRank',
  'constructSingleFrequencyNumbers', 'constructSingleFrequenciesHtml']) {
  assert.strictEqual(typeof api[name], 'function', `popup.js must define function ${name}`);
}

// popup 的 frequencies 形状：按词典分组，每组若干条 {value, displayValue}。
const frequencies = [
  { dictionary: 'JPDB', frequencies: [{ value: 5000, displayValue: '5000㋕' }] },
  { dictionary: 'Jiten', frequencies: [{ value: 1234, displayValue: null }, { value: 9, displayValue: null }] },
  // 同词典第二组：Yomitan 与调和平均都只认第一组。
  { dictionary: 'Jiten', frequencies: [{ value: 7, displayValue: null }] },
  // displayValue 无前导数字 → 退回 value。
  { dictionary: 'BCCWJ', frequencies: [{ value: 88, displayValue: '~88' }] },
  // 没有可用数值：不进数表，但 HTML 表照样有它。
  { dictionary: 'Zero', frequencies: [{ value: 0, displayValue: null }] },
  { dictionary: 'Empty', frequencies: [] },
];

const numbers = structuredClone(api.constructSingleFrequencyNumbers(frequencies));
assert.deepStrictEqual(numbers, { JPDB: '5000', Jiten: '1234', BCCWJ: '88' });

const htmls = structuredClone(api.constructSingleFrequenciesHtml(frequencies));
assert.deepStrictEqual(Object.keys(htmls), ['JPDB', 'Jiten', 'BCCWJ', 'Zero']);
assert.strictEqual(
  htmls.Jiten,
  '<ul style="text-align: left;"><li>Jiten: 1234</li><li>Jiten: 9</li><li>Jiten: 7</li></ul>');
assert.strictEqual(
  htmls.JPDB, '<ul style="text-align: left;"><li>JPDB: 5000㋕</li></ul>');
assert.strictEqual(
  htmls.JPDB,
  api.constructFrequencyHtml(frequencies.filter(g => g.dictionary === 'JPDB')),
  'single-frequency HTML must be the {frequencies} markup restricted to one dictionary');

// 调和平均与逐词典数同源：3 / (1/5000 + 1/1234 + 1/88)
const expectedHarmonic = String(Math.floor(3 / (1 / 5000 + 1 / 1234 + 1 / 88)));
assert.strictEqual(api.getFrequencyHarmonicRank(frequencies), expectedHarmonic);
assert.strictEqual(api.getFrequencyHarmonicRank([]), '9999999');
assert.strictEqual(api.getFrequencyHarmonicRank(null), '9999999');
assert.deepStrictEqual(
  structuredClone(api.constructSingleFrequencyNumbers(null)), {});
assert.deepStrictEqual(
  structuredClone(api.constructSingleFrequenciesHtml([])), {});

// buildMinePayload 必须把两张表带上（Dart fromJson 读的键名）。
const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'), 'utf8');
const bmpStart = popupSrc.indexOf('\nasync function buildMinePayload(');
assert.ok(bmpStart >= 0, 'popup.js must define function buildMinePayload');
const buildMinePayload = popupSrc.slice(bmpStart, popupSrc.indexOf('\n}\n', bmpStart));
assert.match(
  buildMinePayload,
  /singleFrequencyNumbers: JSON\.stringify\(singleFrequencyNumbers\)/,
  'buildMinePayload must ship singleFrequencyNumbers');
assert.match(
  buildMinePayload,
  /singleFrequenciesHtml: JSON\.stringify\(singleFrequenciesHtml\)/,
  'buildMinePayload must ship singleFrequenciesHtml');

console.log('all assertions passed');
