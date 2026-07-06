// TODO-1184 守卫：action popup 队列删除 + 标签的纯逻辑单测（无 chrome/DOM 依赖）。
const { test } = require('node:test');
const assert = require('node:assert');
const { hibikiFilterQueue, hibikiQueueItemLabel } = require('./vendor/action-popup.js');

test('hibikiFilterQueue removes only the matching id', () => {
  const q = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
  assert.deepStrictEqual(hibikiFilterQueue(q, 'b'), [{ id: 'a' }, { id: 'c' }]);
});
test('hibikiFilterQueue is null/garbage safe', () => {
  assert.deepStrictEqual(hibikiFilterQueue(null, 'x'), []);
  assert.deepStrictEqual(hibikiFilterQueue([{ id: 'a' }], 'missing'), [{ id: 'a' }]);
});
test('hibikiQueueItemLabel prefers sentence, then fields, truncates', () => {
  assert.strictEqual(hibikiQueueItemLabel({ sentence: '今日は' }), '今日は');
  assert.strictEqual(hibikiQueueItemLabel({ fields: { expression: '見える' } }), '見える');
  assert.strictEqual(hibikiQueueItemLabel({}), '(空)');
  const long = 'あ'.repeat(50);
  assert.strictEqual(hibikiQueueItemLabel({ sentence: long }), 'あ'.repeat(40) + '…');
});
