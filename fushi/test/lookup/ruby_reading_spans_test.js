// 原文振假名随查词 payload 带给宿主：buildSelectionPayload 的 rubyReadings。
//
// 症状：正文 `<ruby>忙<rt>せわ</rt></ruby>しい` 点「忙」，词典弹窗首条却是高频的
// 「いそがしい」。根因：取词时 createWalker 拒掉 <rt>，查询串只剩「忙しい」，来源自带的
// 读音在 JS 这一步就丢了，宿主无从按它排序。
//
// 本 harness 在最小 fake DOM 里真执行阅读器注入脚本 ReaderSelectionScripts.source()
// （由 .dart wrapper 落到固定位置 fushi/.dart_tool/fushi_test_scripts/reader_selection.js；
// 不接受外部传入路径），断言 rubyReadingSpans 对取词串报出的区间与读音。
//
// 运行：先跑一次 .dart wrapper 落脚本，再 node fushi/test/lookup/ruby_reading_spans_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { el, text, loadSelectionScript } = require('./selection_fake_dom.js');

function load(src, paragraph) {
  const sel = loadSelectionScript(src, paragraph);
  sel.fireTextSelected = function () {
    return this.selection ? this.selection.text : null;
  };
  return sel;
}

// 从 [node] 的 [offset] 起取词，返回 { text, spans }。
function scan(src, paragraph, node, offset) {
  const sel = load(src, paragraph);
  sel.selection = null;
  sel.selectFromPosition(node, offset, 16);
  assert.ok(sel.selection, 'selectFromPosition 必须产生选区');
  return {
    text: sel.selection.text,
    spans: structuredClone(sel.rubyReadingSpans(sel.selection.ranges, sel.selection.text)),
  };
}

const readerPath = path.join(__dirname, '../../.dart_tool/fushi_test_scripts/reader_selection.js');
if (!fs.existsSync(readerPath)) {
  console.log('reader selection script not generated; run ruby_reading_spans_test.dart');
  process.exit(1);
}
const src = fs.readFileSync(readerPath, 'utf8');

// ① 用户报告的原样：<ruby>忙<rt>せわ</rt></ruby>しい。点基字「忙」。
{
  const base = text('忙');
  const p = el('p', ['時間が', el('ruby', [base, el('rt', ['せわ'])]), 'しい。']);
  const r = scan(src, p, base, 0);
  assert.strictEqual(r.text, '忙しい', '取词串不含 rt');
  assert.deepStrictEqual(r.spans, [{ s: 0, e: 1, r: 'せわ' }], '忙 的来源读音 せわ 必须随 payload 带出');
}

// ② 一个 <ruby> 里多对基字 / rt（含 <rb> 包裹），各自配对。
{
  const kan = text('漢');
  const p = el('p', [
    el('ruby', [el('rb', [kan]), el('rp', ['(']), el('rt', ['かん']), el('rp', [')']), el('rb', ['字']), el('rt', ['じ'])]),
    'を',
  ]);
  const r = scan(src, p, kan, 0);
  assert.strictEqual(r.text, '漢字を');
  assert.deepStrictEqual(r.spans, [
    { s: 0, e: 1, r: 'かん' },
    { s: 1, e: 2, r: 'じ' },
  ], '多对 ruby 逐对配对，rp 不进读音');
}

// ③ 多字基字整段对应一个读音。
{
  const base = text('今日');
  const p = el('p', [el('ruby', [base, el('rt', ['きょう'])]), 'は晴れ。']);
  const r = scan(src, p, base, 0);
  assert.strictEqual(r.text, '今日は晴れ');
  assert.deepStrictEqual(r.spans, [{ s: 0, e: 2, r: 'きょう' }]);
}

// ④ 从多字基字中间起点：基字只被扫到一部分，读音无法按字拆分 → 不报。
{
  const base = text('今日');
  const p = el('p', [el('ruby', [base, el('rt', ['きょう'])]), 'は晴れ。']);
  const r = scan(src, p, base, 1);
  assert.strictEqual(r.text, '日は晴れ');
  assert.deepStrictEqual(r.spans, [], '残缺基字不得报读音');
}

// ⑤ 没有 ruby 的正文：空数组。
{
  const t = text('忙しい日々。');
  const p = el('p', [t]);
  assert.deepStrictEqual(scan(src, p, t, 0).spans, []);
}

// ⑥ 后续 ruby 的偏移以取词串为坐标系。
{
  const start = text('毎日');
  const p = el('p', [start, el('ruby', ['忙', el('rt', ['せわ'])]), 'しい。']);
  const r = scan(src, p, start, 0);
  assert.strictEqual(r.text, '毎日忙しい');
  assert.deepStrictEqual(r.spans, [{ s: 2, e: 3, r: 'せわ' }]);
}

// ⑦ payload 把它放在 rubyReadings 键上。
{
  const base = text('忙');
  const p = el('p', [el('ruby', [base, el('rt', ['せわ'])]), 'しい。']);
  const sel = load(src, p);
  sel.selectFromPosition(base, 0, 16);
  sel.getSelectionRect = () => null;
  const payload = sel.buildSelectionPayload(0, 0);
  assert.deepStrictEqual(structuredClone(payload.rubyReadings), [{ s: 0, e: 1, r: 'せわ' }]);
}

console.log('all assertions passed');
