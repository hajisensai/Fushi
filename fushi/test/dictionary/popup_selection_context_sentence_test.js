// 释义里点词带上「被点处那一句」：assets/popup/selection.js 的 selectFromPosition 把
// getSentence 的结果作为 textSelected 第 4 参交给宿主（反馈 TnKWBi4C-9）。
//
// 症状：查词页在释义里点「世間知らず」叠出的浮层制卡，Sentence 字段恒空——宿主拿不到
// 被点处的句子。修：selection.js 在取词同一个归一后的起点上取句，随 textSelected 上报；
// 查词页 / 独立查词窗把它记进该浮层 entry（DictionaryPopupEntry.contextSentence），
// 制卡时补 `{sentence}`。
//
// 在最小 fake DOM（test/lookup/selection_fake_dom.js）里真执行 assets/popup/selection.js。
//
// 运行：node fushi/test/dictionary/popup_selection_context_sentence_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { el, text, loadSelectionScript } = require('../lookup/selection_fake_dom.js');

const src = fs.readFileSync(path.join(__dirname, '../../assets/popup/selection.js'), 'utf8');

// 从 [node] 的 [offset] 起取词，返回 textSelected 的全部参数（去掉 rect）。
function scan(paragraph, node, offset) {
  const calls = [];
  const sel = loadSelectionScript(src, paragraph, (...args) => { calls.push(args); });
  sel.selection = null;
  sel.selectFromPosition(node, offset, 16);
  assert.ok(sel.selection, 'selectFromPosition 必须产生选区');
  assert.strictEqual(calls.length, 1, 'textSelected 恰好发一次');
  const [name, query, , , sentence] = calls[0];
  return { name, query, sentence, selectionSentence: sel.selection.sentence };
}

// ① 释义段里点句中的词：第 4 参是被点处所在的那一句（不含前一句 / 后一句）。
{
  const t = text('（名）経験が浅い。まだ世間知らずの若者だ。大人になる。');
  const p = el('div', [t], 'glossary-content');
  const r = scan(p, t, t.textContent.indexOf('世間'));
  assert.strictEqual(r.name, 'textSelected');
  assert.strictEqual(r.query.startsWith('世間知らず'), true);
  assert.strictEqual(r.sentence, 'まだ世間知らずの若者だ。',
    'textSelected 第 4 参必须是被点处那一句');
  assert.strictEqual(r.selectionSentence, r.sentence, 'selection.sentence 与上报一致');
}

// ② 句子跨多个文本节点（释义里的 <b> / <span>）照样拼回整句。
{
  const head = text('子どもは');
  const word = text('世間');
  const tail = text('を知らない。次の文。');
  const p = el('p', [head, el('b', [word]), tail]);
  const r = scan(p, word, 0);
  assert.strictEqual(r.sentence, '子どもは世間を知らない。');
}

// ③ 没有段落级祖先（findParagraph 为 null）：不猜句子，给空串——那时 getSentence 会
//    退到整个 body 遍历，浏览器扩展页面悬停扫描每换一个词都会走到这里。
{
  const t = text('世間知らずの若者だ。');
  const loose = el('span', [t]);
  const r = scan(loose, t, 0);
  assert.strictEqual(r.sentence, '', '无段落祖先时第 4 参为空串');
}

console.log('all assertions passed');
