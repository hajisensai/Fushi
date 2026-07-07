const test = require('node:test');
const assert = require('node:assert');
const {
  extractNetflixCueText,
  currentVideoTimeMs,
  netflixVideoIdFromPath,
  parseSubtitleTimestamp,
  stripCueTags,
  parseWebVtt,
  parseTtml,
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

// TODO-1270 Bug A：Netflix 每行字幕是「外层定位 span > 内层样式 span」的嵌套结构，父 span 的
// textContent 已含子全文。旧实现把每一层 span 都拼进来 → 同句字幕重复两遍（卡里字幕出现两次）。
// 只取叶子 span，每段文本恰好一次。
test('extractNetflixCueText de-dups nested Netflix spans (TODO-1270 Bug A)', () => {
  const inner = { textContent: '今日はいい天気', querySelector: () => null };
  const outer = { textContent: '今日はいい天気', querySelector: () => inner };
  // querySelectorAll('...span, span') 同时返回外层与内层；断言不重复。
  const container = { querySelectorAll: () => [outer, inner] };
  assert.strictEqual(extractNetflixCueText(container), '今日はいい天気');
});

// 单行拆成多个并列叶子 span（无嵌套）仍应按序拼接，不受去重影响。
test('extractNetflixCueText joins sibling leaf spans (no regression)', () => {
  const a = { textContent: '走り', querySelector: () => null };
  const b2 = { textContent: '出した', querySelector: () => null };
  const container = { querySelectorAll: () => [a, b2] };
  assert.strictEqual(extractNetflixCueText(container), '走り出した');
});

test('currentVideoTimeMs seconds -> ms; null-safe', () => {
  assert.strictEqual(currentVideoTimeMs({ currentTime: 12.34 }), 12340);
  assert.strictEqual(currentVideoTimeMs(null), null);
});

test('netflixVideoIdFromPath extracts /watch/<id>', () => {
  assert.strictEqual(netflixVideoIdFromPath('/watch/81234567'), '81234567');
  assert.strictEqual(netflixVideoIdFromPath('/browse'), null);
});

// ── TODO-1219 P1：字幕解析器纯函数 ──

test('parseSubtitleTimestamp clock HH:MM:SS.mmm', () => {
  assert.strictEqual(parseSubtitleTimestamp('00:00:01.500'), 1500);
  assert.strictEqual(parseSubtitleTimestamp('01:02:03.004'), (3600 + 120 + 3) * 1000 + 4);
});

test('parseSubtitleTimestamp SRT comma and MM:SS', () => {
  assert.strictEqual(parseSubtitleTimestamp('00:00:02,250'), 2250);
  assert.strictEqual(parseSubtitleTimestamp('05:06.100'), (5 * 60 + 6) * 1000 + 100);
});

test('parseSubtitleTimestamp TTML offsets s/ms/tick', () => {
  assert.strictEqual(parseSubtitleTimestamp('3s'), 3000);
  assert.strictEqual(parseSubtitleTimestamp('250ms'), 250);
  // tick: 10,000,000 ticks/s -> 1000ms
  assert.strictEqual(parseSubtitleTimestamp('10000000t', 10000000), 1000);
  assert.strictEqual(parseSubtitleTimestamp('50000000t'), 5000); // default tickRate 1e7
});

test('parseSubtitleTimestamp rejects garbage', () => {
  assert.strictEqual(parseSubtitleTimestamp('abc'), null);
  assert.strictEqual(parseSubtitleTimestamp(''), null);
  assert.strictEqual(parseSubtitleTimestamp(null), null);
});

test('stripCueTags removes inline tags and entities', () => {
  assert.strictEqual(stripCueTags('<c.japanese>走れ</c>'), '走れ');
  assert.strictEqual(stripCueTags('a &amp; b &#65;'), 'a & b A');
  assert.strictEqual(stripCueTags('<i>x</i>&nbsp;y'), 'x y');
});

test('parseWebVtt parses Netflix webvtt cues, skips header', () => {
  const vtt = [
    'WEBVTT',
    '',
    '00:00:01.000 --> 00:00:04.000 align:start position:10%',
    '<c.j>走り</c>出した',
    '',
    '2',
    '00:00:05.000 --> 00:00:07.500',
    '二行目',
    'つづき',
    '',
  ].join('\n');
  const cues = parseWebVtt(vtt);
  assert.strictEqual(cues.length, 2);
  assert.deepStrictEqual(cues[0], { startMs: 1000, endMs: 4000, text: '走り出した' });
  assert.deepStrictEqual(cues[1], { startMs: 5000, endMs: 7500, text: '二行目\nつづき' });
});

test('parseWebVtt tolerant of CRLF and empty', () => {
  assert.deepStrictEqual(parseWebVtt(''), []);
  const cues = parseWebVtt('WEBVTT\r\n\r\n00:00:00.000 --> 00:00:01.000\r\nhi\r\n');
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].text, 'hi');
});

test('parseTtml parses <p begin end> clock times with <br/>', () => {
  const xml =
    '<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml">' +
    '<body><div>' +
    '<p begin="00:00:01.000" end="00:00:03.000">走れ<br/>メロス</p>' +
    '<p begin="00:00:04.000" end="00:00:06.000"><span>二つ目</span></p>' +
    '</div></body></tt>';
  const cues = parseTtml(xml);
  assert.strictEqual(cues.length, 2);
  assert.deepStrictEqual(cues[0], { startMs: 1000, endMs: 3000, text: '走れ\nメロス' });
  assert.deepStrictEqual(cues[1], { startMs: 4000, endMs: 6000, text: '二つ目' });
});

test('parseTtml honours ttp:tickRate offset times', () => {
  const xml =
    '<tt ttp:tickRate="10000000">' +
    '<body><div><p begin="10000000t" end="30000000t">tick</p></div></body></tt>';
  const cues = parseTtml(xml);
  assert.strictEqual(cues.length, 1);
  assert.deepStrictEqual(cues[0], { startMs: 1000, endMs: 3000, text: 'tick' });
});
