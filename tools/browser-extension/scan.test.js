const { test } = require('node:test');
const assert = require('node:assert');
const { expandWordWindow, extractSentence } = require('./scan.js');

test('expandWordWindow slices from offset up to maxLen', () => {
  assert.strictEqual(expandWordWindow({ textContent: '見える世界' }, 0, 3), '見える');
  assert.strictEqual(expandWordWindow({ textContent: 'abc' }, 1, 10), 'bc');
});
test('extractSentence expands to sentence boundaries', () => {
  const t = '昨日は雨。今日は晴れ。明日は？';
  assert.strictEqual(extractSentence(t, 6), '今日は晴れ。'); // offset 在第二句内
});
test('extractSentence handles no enders', () => {
  assert.strictEqual(extractSentence('ただのテキスト', 2), 'ただのテキスト');
});
