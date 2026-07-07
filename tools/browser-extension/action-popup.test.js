// TODO-1184 守卫：action popup 队列删除 + 标签的纯逻辑单测（无 chrome/DOM 依赖）。
const { test } = require('node:test');
const assert = require('node:assert');
const { hibikiFilterQueue, hibikiQueueItemLabel, hibikiQueueItemContext } = require('./vendor/action-popup.js');

test('hibikiFilterQueue removes only the matching id', () => {
  const q = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
  assert.deepStrictEqual(hibikiFilterQueue(q, 'b'), [{ id: 'a' }, { id: 'c' }]);
});
test('hibikiFilterQueue is null/garbage safe', () => {
  assert.deepStrictEqual(hibikiFilterQueue(null, 'x'), []);
  assert.deepStrictEqual(hibikiFilterQueue([{ id: 'a' }], 'missing'), [{ id: 'a' }]);
});
test('hibikiQueueItemLabel prefers word, falls back to sentence, truncates', () => {
  // TODO-1270：主标签优先「词」，无词才回落句子。
  assert.strictEqual(hibikiQueueItemLabel({ fields: { expression: '見える' } }), '見える');
  assert.strictEqual(hibikiQueueItemLabel({ fields: { word: '走る' }, sentence: '彼は走る。' }), '走る');
  assert.strictEqual(hibikiQueueItemLabel({ sentence: '今日は' }), '今日は');
  assert.strictEqual(hibikiQueueItemLabel({}), '(空)');
  const long = 'あ'.repeat(50);
  assert.strictEqual(hibikiQueueItemLabel({ fields: { expression: long } }), 'あ'.repeat(40) + '…');
});
test('TODO-1270: same sentence + different words => distinct labels (no 一模一样 duplication)', () => {
  const sentence = '今日はいい天気ですね。';
  const a = { fields: { expression: '今日' }, sentence };
  const b = { fields: { expression: '天気' }, sentence };
  assert.strictEqual(hibikiQueueItemLabel(a), '今日');
  assert.strictEqual(hibikiQueueItemLabel(b), '天気');
  assert.notStrictEqual(hibikiQueueItemLabel(a), hibikiQueueItemLabel(b));
});
test('hibikiQueueItemContext shows sentence only when label is a word', () => {
  const sentence = '彼は毎朝走る。';
  // 有词：上下文行显示句子。
  assert.strictEqual(hibikiQueueItemContext({ fields: { expression: '走る' }, sentence }), sentence);
  // 无词：主标签已是句子，上下文行返回 '' 避免重复回显。
  assert.strictEqual(hibikiQueueItemContext({ sentence }), '');
  // 无句子：无上下文。
  assert.strictEqual(hibikiQueueItemContext({ fields: { expression: '走る' } }), '');
  // 超长句子截断到 60。
  const long = 'あ'.repeat(80);
  assert.strictEqual(hibikiQueueItemContext({ fields: { expression: '走る' }, sentence: long }), 'あ'.repeat(60) + '…');
});
