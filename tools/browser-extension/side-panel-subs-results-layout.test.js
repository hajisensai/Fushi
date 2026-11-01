// 反馈 auJaOKXl3W：Side Panel「查字幕」结果被超长番名挤压——每行标题被切、行与行重叠、
// 出横向滚动条，看不到集数。
//
// 根因：.subs-results 是 max-height 的纵向 flex 容器，全局 `button { min-height: 32px }`
// 把 flex 项的自动最小尺寸（内容高）换成了 32px，结果一多每行被 flex-shrink 压扁，换行的
// 长标题溢进下一行。本文件钉：
// ① CSS：行不收缩、宽度钉在容器内、容器不出横向滚动、长串任意处可断；
// ② 集号识别 / 中段省略：超长文件名省略中段，集号及其后的 [WebRip 1080p] 等始终保留；
// ③ 渲染：集号单独成块（.subs-item-ep），完整文件名进 title。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const CSS = fs.readFileSync(path.join(__dirname, 'side-panel.css'), 'utf8');

function extract(src, name) {
  const start = src.indexOf('function ' + name + '(');
  assert.ok(start >= 0, name + ' 不见了');
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error('unbalanced ' + name);
}

function helpers() {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(extract(SRC, 'findSubsEpisode') + '\n' + extract(SRC, 'compactSubsName'), ctx);
  return ctx;
}

function ruleBody(selector) {
  const idx = CSS.indexOf('\n' + selector + ' {');
  assert.ok(idx >= 0, selector + ' 规则不见了');
  return CSS.slice(idx, CSS.indexOf('}', idx));
}

test('结果行不被 flex 压扁、不出横向滚动', () => {
  const item = ruleBody('.subs-item');
  assert.match(item, /flex: 0 0 auto;/, '行必须不收缩，否则 min-height:32px 会把它压扁、文字溢进下一行');
  assert.match(item, /min-width: 0;/);
  assert.match(item, /max-width: 100%;/);
  const list = ruleBody('.subs-results');
  assert.match(list, /overflow-x: hidden;/);
  assert.match(list, /overflow-y: auto;/);
  assert.match(CSS, /\.subs-item-name,\n\.subs-item-meta \{[^}]*overflow-wrap: anywhere;/);
  assert.doesNotMatch(CSS, /\.subs-item-name \{[^}]*white-space: nowrap/);
});

test('文件名集号识别', () => {
  const { findSubsEpisode } = helpers();
  const cases = [
    ['[Nekomoe kissaten&LoliHouse] Chii Fuyo - 01 [WebRip 1080p HEVC-10bit AAC ASSx2].ass', '1'],
    ['[NanakoRaws] Tsuihou sareta Cheat Fuyo Majutsushi - 04 (TX 1920x1080 x264 AAC).srt', '4'],
    ['Show.Name.S01E12.1080p.WEB.ja.srt', '12'],
    ['Show Name EP07.ass', '7'],
    ['追放されたチート付与魔術師 第4話.ass', '4'],
    ['[Group][Title][03][1080p].ass', '3'],
    ['Title #05.srt', '5'],
  ];
  for (const [name, ep] of cases) {
    const hit = findSubsEpisode(name);
    assert.ok(hit, name);
    assert.strictEqual(hit.episode, ep, name);
  }
  assert.strictEqual(findSubsEpisode('Movie Title 1080p.ass'), null);
  assert.strictEqual(findSubsEpisode(null), null);
});

test('超长文件名中段省略，集号与其后的关键信息完整保留', () => {
  const { compactSubsName } = helpers();
  const longName = '[NanakoRaws] Tsuihou sareta Cheat Fuyo Majutsushi wa Kimama na Second Life wo Ouka suru. '
    + 'Ore wa Buki dake ja naku, Arayuru Mono ni "Kyouka Point" wo Fuyo dekiru shi - 04 [WebRip 1080p].ass';
  const out = compactSubsName(longName, 72);
  assert.ok(out.length <= 72 + 2, out);
  assert.ok(out.startsWith('[NanakoRaws] Tsuihou'), out);
  assert.ok(out.endsWith(' - 04 [WebRip 1080p].ass'), out);
  assert.ok(out.includes('…'), out);
  // 短名原样。
  const short = '[Group] Chii Fuyo - 01 [WebRip 1080p].ass';
  assert.strictEqual(compactSubsName(short, 72), short);
  // 认不出集号：保留尾部 24 字符（扩展名 / 版本标签）。
  const noEp = 'A'.repeat(100) + 'tail-version-tag-v2.ass';
  const outNoEp = compactSubsName(noEp, 72);
  assert.ok(outNoEp.endsWith(noEp.slice(-24)), outNoEp);
  assert.ok(outNoEp.length < noEp.length);
});

test('渲染：集号单独成块、完整名进 title、省略名进正文', () => {
  const render = extract(SRC, 'renderSubsResults');
  assert.match(render, /name\.textContent = compactSubsName\(candidate\.fileName, 72\)/);
  assert.match(render, /row\.title = String\(candidate\.fileName \|\| ''\)/);
  assert.match(render, /ep\.className = 'subs-item-ep'/);
  assert.match(render, /candidate\.episode != null \? candidate\.episode : \(hit \? hit\.episode : null\)/);
  // 集号不再混在 meta 的 · 串里（会随 meta 换行被挤走）。
  assert.doesNotMatch(render, /parts\.push\(tr\('subs_episode_label'/);
});
