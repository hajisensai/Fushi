const test = require('node:test');
const assert = require('node:assert');
const {
  extractNetflixCueText,
  currentVideoTimeMs,
  netflixVideoIdFromPath,
} = require('./subtitle-adapters.js');

test('extractNetflixCueText joins span lines', () => {
  const container = {
    querySelectorAll: () => [{ textContent: '走り' }, { textContent: '出した' }],
  };
  assert.strictEqual(extractNetflixCueText(container), '走り出した');
});

test('extractNetflixCueText null container -> empty', () => {
  assert.strictEqual(extractNetflixCueText(null), '');
});

test('currentVideoTimeMs seconds -> ms; null-safe', () => {
  assert.strictEqual(currentVideoTimeMs({ currentTime: 12.34 }), 12340);
  assert.strictEqual(currentVideoTimeMs(null), null);
});

test('netflixVideoIdFromPath extracts /watch/<id>', () => {
  assert.strictEqual(netflixVideoIdFromPath('/watch/81234567'), '81234567');
  assert.strictEqual(netflixVideoIdFromPath('/browse'), null);
});
