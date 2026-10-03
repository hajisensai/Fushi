// BUG-2907：有声书当前句高亮的标点归属行为级跑手（由
// sentence_audio_ownership_behavior_test.dart 用 node 执行，argv[2] = payload.json）。
//
// payload.script 是生产常量 kSentenceAudioOwnershipJs 原文；这里只补一个最小 DOM
// （nodeType / tagName / nodeValue / 兄弟与父子指针），断言 extendSegments 放宽首尾
// 的结果与 Hoshi Reader Android 的标点归属一致。
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

const window = {};
new Function('window', data.script)(window);
const ownership = window.fushiSentenceAudioOwnership;
assert(ownership && typeof ownership.extendSegments === 'function',
  'script must define window.fushiSentenceAudioOwnership.extendSegments');

function link(parent, children) {
  parent.childNodes = children;
  parent.firstChild = children[0] || null;
  parent.lastChild = children[children.length - 1] || null;
  children.forEach(function(child, i) {
    child.parentNode = parent;
    child.previousSibling = children[i - 1] || null;
    child.nextSibling = children[i + 1] || null;
  });
  return parent;
}
function el(tag) {
  const children = Array.prototype.slice.call(arguments, 1);
  return link({nodeType: 1, tagName: tag.toUpperCase()}, children);
}
function txt(value) {
  return {nodeType: 3, nodeValue: value};
}
const readerRegex = /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゟァ-ヺー-ヿ０-９Ａ-Ｚａ-ｚｦ-ﾝ\u{4E00}-\u{9FFF}\u{20000}-\u{2A6DF}]/iu;
function isMatchable(ch) {
  return readerRegex.test(ch);
}
// 只取可匹配字的片段（与两条生产路径映射出的形状一致）。
function seg(node, text) {
  const value = node.nodeValue;
  const start = value.indexOf(text);
  assert(start >= 0, 'fixture text ' + text + ' not in ' + value);
  return {node: node, start: start, end: start + text.length};
}
function show(segments) {
  return segments.map(function(s) { return s.node.nodeValue.slice(s.start, s.end); }).join('|');
}
function expectExtend(label, segments, expected) {
  const actual = show(ownership.extendSegments(segments, isMatchable));
  assert(actual === expected,
    label + ': got ' + JSON.stringify(actual) + ', expected ' + JSON.stringify(expected));
}

// ① 截图那一句：句末「。」并进当前句。
const t1 = txt('声援が飛ぶ。そう思った');
el('body', el('p', t1));
expectExtend('trailing period', [seg(t1, '声援が飛ぶ')], '声援が飛ぶ。');

// ② 对白：两头括号都进当前句，后面的「と言った。」各归各。
const t2 = txt('「さいちゃーん」と言った。');
el('body', el('p', t2));
expectExtend('dialogue brackets', [seg(t2, 'さいちゃーん')], '「さいちゃーん」');
expectExtend('after closing bracket', [seg(t2, 'と言った')], 'と言った。');

// ③ 收尾标点在另一个文本节点里（中间隔着整颗 ruby），跨节点追加片段且跳过注音。
const t3a = txt('声援が');
const t3b = txt('飛');
const t3c = txt('ぶ');
const t3d = txt('。」');
el('body', el('p', t3a, el('ruby', t3b, el('rt', txt('と'))), t3c, el('span', t3d)));
expectExtend('trailing across nodes', [seg(t3a, '声援が'), seg(t3b, '飛'), seg(t3c, 'ぶ')], '声援が|飛|ぶ|。」');
// 注音后面紧跟的收尾标点也算。
const t3e = txt('飛');
const t3f = txt('」');
el('body', el('p', el('ruby', t3e, el('rt', txt('と'))), t3f));
expectExtend('trailing after ruby', [seg(t3e, '飛')], '飛|」');

// ④ 块边界：上一段的「。」不越段；下一段的「「」只进本段的句子。
const t4a = txt('あいう。');
const t4b = txt('「えお」');
el('body', el('p', t4a), el('p', t4b));
expectExtend('end stops at block', [seg(t4a, 'あいう')], 'あいう。');
expectExtend('start stops at block', [seg(t4b, 'えお')], '「えお」');
// 开头括号单独在前一个文本节点里（同一段内）。
const t4c = txt('「');
const t4d = txt('えお');
el('body', el('p', el('span', t4c), t4d));
expectExtend('opening across nodes', [seg(t4d, 'えお')], '「|えお');

// ⑤ 中性类：跟前文；前文是开头类 / 空白 / 段首时跟后文。
const t5 = txt('あ……「い');
el('body', el('p', t5));
expectExtend('neutral follows left', [seg(t5, 'あ')], 'あ……');
expectExtend('opening after neutral', [seg(t5, 'い')], '「い');
const t5b = txt('　……い');
el('body', el('p', t5b));
expectExtend('neutral after space follows right', [seg(t5b, 'い')], '……い');
const t5c = txt('……い');
el('body', el('p', t5c));
expectExtend('neutral at paragraph start follows right', [seg(t5c, 'い')], '……い');
const t5d = txt('「……い」');
el('body', el('p', t5d));
expectExtend('neutral after opening follows right', [seg(t5d, 'い')], '「……い」');

// ⑥ 空白与屏障打断归属。
const t6 = txt('あ 。');
el('body', el('p', t6));
expectExtend('space breaks ownership', [seg(t6, 'あ')], 'あ');
const t6b = txt('あ');
const t6c = txt('。');
el('body', el('p', t6b, el('br'), t6c));
expectExtend('br is a barrier', [seg(t6b, 'あ')], 'あ');
const t6d = txt('あ');
const t6e = txt('。');
el('body', el('p', t6d, el('img'), t6e));
expectExtend('image is a barrier', [seg(t6d, 'あ')], 'あ');

// ⑦ 相邻两句不重叠：每个标点只归一侧。
const t7 = txt('あ。」「い');
el('body', el('p', t7));
const left = ownership.extendSegments([seg(t7, 'あ')], isMatchable);
const right = ownership.extendSegments([seg(t7, 'い')], isMatchable);
assert(left[0].end <= right[0].start,
  'adjacent cues overlap: ' + show(left) + ' / ' + show(right));
assert(show(left) === 'あ。」' && show(right) === '「い',
  'adjacent cues split wrong: ' + show(left) + ' / ' + show(right));

// ⑧ 星平面字前后也按码点走，不拆代理对。
const t8 = txt('「𠮷」');
el('body', el('p', t8));
expectExtend('astral char', [seg(t8, '𠮷')], '「𠮷」');

// ⑧b 句内跨节点的缝：注音两侧的「」原本落在两个文本节点之间、不在任何片段里。
const g1 = txt('「撃つ」と「');
const g2 = txt('鬱');
const g3 = txt('」のダブルミーニング！　奇跡');
el('body', el('p', g1, el('ruby', g2, el('rt', txt('うつ'))), g3));
expectExtend('interior gap around ruby',
  [seg(g1, '撃つ」と'), seg(g2, '鬱'), seg(g3, 'のダブルミーニング')],
  '「撃つ」と「|鬱|」のダブルミーニング！');
// 跨段的 cue：不跨块补缝，但段末「。」与下一段段首「「」仍归这一句；两段之间的
// 东西（这里是一张图）不进高亮。
const g4 = txt('あ。');
const g5 = txt('「い」');
el('body', el('p', g4), el('img'), el('p', g5));
expectExtend('cue across blocks', [seg(g4, 'あ'), seg(g5, 'い')], 'あ。|「い」');

// ⑨ 输入不被改写，空输入原样返回。
const t9 = txt('あ。');
el('body', el('p', t9));
const input = [seg(t9, 'あ')];
ownership.extendSegments(input, isMatchable);
assert(input[0].end === 1, 'extendSegments must not mutate its input');
assert(ownership.extendSegments([], isMatchable).length === 0, 'empty input');

process.stdout.write('OK\n');
