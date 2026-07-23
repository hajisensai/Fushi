// TODO-1184 守卫：action popup 队列删除 + 标签的纯逻辑单测（无 chrome/DOM 依赖）。
const { test } = require('node:test');
const assert = require('node:assert');
const {
  hibikiFilterQueue, hibikiQueueItemLabel, hibikiQueueItemContext, hibikiReadPanelEnabled,
  hibikiQueueItemUrl, hibikiTabSite, hibikiGenButtonState,
} = require('./vendor/action-popup.js');

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

// TODO-1219：网飞字幕列表面板开关（扩展弹窗入口，方案 B）读值纯函数守卫。默认关 + 只认 boolean
// true——与 subtitle-panel.js 的 enabled:false 默认、options.js 的 === true 判据一致，防回归成默认打开。
test('TODO-1219: hibikiReadPanelEnabled only true for boolean true (default off)', () => {
  assert.strictEqual(hibikiReadPanelEnabled({ netflixSubtitlePanel: true }), true);
  assert.strictEqual(hibikiReadPanelEnabled({ netflixSubtitlePanel: false }), false);
  assert.strictEqual(hibikiReadPanelEnabled({}), false);
  assert.strictEqual(hibikiReadPanelEnabled(null), false);
  assert.strictEqual(hibikiReadPanelEnabled(undefined), false);
  // 非严格 true 的真值一律当关（防 'true' 字符串/1 之类误开）。
  assert.strictEqual(hibikiReadPanelEnabled({ netflixSubtitlePanel: 'true' }), false);
  assert.strictEqual(hibikiReadPanelEnabled({ netflixSubtitlePanel: 1 }), false);
});

// ── TODO-1881：队列条目跳转 URL（Netflix/YouTube 可跳，other 无跳转）──
test('TODO-1881: hibikiQueueItemUrl builds watch URLs per site, empty otherwise', () => {
  assert.strictEqual(
    hibikiQueueItemUrl({ site: 'netflix', netflixId: '81011111' }),
    'https://www.netflix.com/watch/81011111');
  assert.strictEqual(
    hibikiQueueItemUrl({ site: 'youtube', youtubeId: 'dQw4w9WgXcQ' }),
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
  // 无 id / other 站点 / 垃圾输入 → ''（不渲染跳转）。
  assert.strictEqual(hibikiQueueItemUrl({ site: 'netflix' }), '');
  assert.strictEqual(hibikiQueueItemUrl({ site: 'other', youtubeId: 'x' }), '');
  assert.strictEqual(hibikiQueueItemUrl(null), '');
  // id 会被 URL 编码（防注入路径分隔等特殊字符）。
  assert.strictEqual(
    hibikiQueueItemUrl({ site: 'youtube', youtubeId: 'a/b?c' }),
    'https://www.youtube.com/watch?v=a%2Fb%3Fc');
});

// ── TODO-1881：tab URL 站点判定（与 content.js hibikiSite 同判据：hostname 后缀）──
test('TODO-1881: hibikiTabSite classifies by hostname suffix, garbage-safe', () => {
  assert.strictEqual(hibikiTabSite('https://www.netflix.com/watch/81011111'), 'netflix');
  assert.strictEqual(hibikiTabSite('https://netflix.com/browse'), 'netflix');
  assert.strictEqual(hibikiTabSite('https://www.youtube.com/watch?v=abc'), 'youtube');
  assert.strictEqual(hibikiTabSite('https://youtu.be/abc'), 'youtube');
  assert.strictEqual(hibikiTabSite('https://example.com/'), 'other');
  // 恶意后缀不误判（evilnetflix.com 不是 *.netflix.com）。
  assert.strictEqual(hibikiTabSite('https://evilnetflix.com/'), 'other');
  assert.strictEqual(hibikiTabSite('chrome://newtab/'), 'other');
  assert.strictEqual(hibikiTabSite(''), 'other');
  assert.strictEqual(hibikiTabSite(undefined), 'other');
});

// ── TODO-1881：生成按钮状态机——消除旧「隐形三态」（取消/生成/静默 no-op）──
test('TODO-1881: gen button = cancel while batch active (escape hatch, even with empty queue)', () => {
  const s = hibikiGenButtonState([], true, 'other');
  assert.strictEqual(s.mode, 'cancel');
  assert.strictEqual(s.enabled, true);
});
test('TODO-1881: gen button disabled with empty queue', () => {
  const s = hibikiGenButtonState([], false, 'netflix');
  assert.strictEqual(s.mode, 'empty');
  assert.strictEqual(s.enabled, false);
});
test('TODO-1881: gen button disabled when queue has only non-generatable (other-site) items', () => {
  const s = hibikiGenButtonState([{ site: 'other', id: '1' }], false, 'netflix');
  assert.strictEqual(s.mode, 'unsupported');
  assert.strictEqual(s.enabled, false);
  assert.ok(s.hint.length > 0);
});
test('TODO-1881: gen button enabled with count on matching site', () => {
  const q = [
    { site: 'netflix', netflixId: 'a' }, { site: 'netflix', netflixId: 'b' },
    { site: 'youtube', youtubeId: 'c' },
  ];
  const nf = hibikiGenButtonState(q, false, 'netflix');
  assert.strictEqual(nf.mode, 'generate');
  assert.strictEqual(nf.enabled, true);
  assert.ok(nf.label.includes('2'));
  assert.ok(nf.hint.includes('YouTube')); // 跨站点剩余量提示
  const yt = hibikiGenButtonState(q, false, 'youtube');
  assert.strictEqual(yt.mode, 'generate');
  assert.ok(yt.label.includes('1'));
  assert.ok(yt.hint.includes('Netflix'));
});
test('TODO-1881: gen button disabled on wrong site, hint lists pending sites', () => {
  const q = [{ site: 'netflix', netflixId: 'a' }, { site: 'youtube', youtubeId: 'c' }];
  const s = hibikiGenButtonState(q, false, 'other');
  assert.strictEqual(s.mode, 'wrongSite');
  assert.strictEqual(s.enabled, false);
  assert.ok(s.hint.includes('Netflix 1 张'));
  assert.ok(s.hint.includes('YouTube 1 张'));
  // 站点匹配但该站点无可生成项（netflix tab + 只有 yt 项）同样按 wrongSite 处理。
  const s2 = hibikiGenButtonState([{ site: 'youtube', youtubeId: 'c' }], false, 'netflix');
  assert.strictEqual(s2.mode, 'wrongSite');
  assert.strictEqual(s2.enabled, false);
});
