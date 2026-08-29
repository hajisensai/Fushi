// 字幕振假名行为守卫。
//
// 用户报：字幕列表的振假名没正常显示，变成和文字一个层级了。
// 根因是两处都把读音当成了正文：
//   ① DOM 采样（content.js）用 `textContent` 取字幕 —— `<ruby>熱<rt>ねつ</rt></ruby>さまし`
//      直接变成 `熱ねつさまし`；
//   ② 字符串路径（subtitle-adapters.js 的 stripCueTags）只删标签、保留内容，同样把 `<rt>`
//      的读音拼进正文。
// app 侧 strip_html_tags.dart 早为同一形状收过口（BUG-1161）：`<rt>` / `<rp>` / `<rtc>` 的内容
// 都不是正文，只有 ruby base 是。这里守住扩展侧的三件事：正文干净、读音单独留存、渲染时画成
// 真正的 `<ruby>`（振假名在正文上方，而不是与正文同级）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const adapters = require('./subtitle-adapters.js');
const RUBY_RENDER = fs.readFileSync(path.join(__dirname, 'ruby-render.js'), 'utf8');

// ───────────────────────── 字符串路径（VTT / TTML / SRT） ─────────────────────────

test('stripCueTags 不再把 <rt> 的读音拼进正文', () => {
  assert.strictEqual(adapters.stripCueTags('<ruby>震<rt>ふる</rt></ruby>える'), '震える');
  assert.strictEqual(
    adapters.stripCueTags('（玲琳）<ruby>熱<rt>ねつ</rt></ruby>さましが…'),
    '（玲琳）熱さましが…');
  // <rp> 是给不支持 ruby 的渲染器看的回退括号，同样不是正文。
  assert.strictEqual(
    adapters.stripCueTags('<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>字'), '漢字');
});

test('隐式闭合（<ruby>震<rt>ふる</ruby>）同样只留 base', () => {
  assert.strictEqual(adapters.stripCueTags('<ruby>漢字<rt>かんじ</ruby>の話'), '漢字の話');
});

test('普通行内标签的行为不变（只删标签、保留内容）', () => {
  assert.strictEqual(adapters.stripCueTags('<i>普通</i>のテキスト'), '普通のテキスト');
  assert.strictEqual(adapters.stripCueTags('<c.yellow>色</c>つき'), '色つき');
});

test('畸形注音退回旧行为，绝不吃掉正文', () => {
  // 缺 `>` 的开标签不许借后面的 `>` 凑合法，否则会把 `の話` 一路吃光。
  assert.strictEqual(adapters.stripCueTags('<ruby>漢<rt かん</ruby>の話'), '漢の話');
  // 自闭合 <rt/>（TTML / XHTML 派生字幕里真实存在）不是「有内容的开标签」。
  assert.strictEqual(adapters.stripCueTags('a<rt/>b'), 'ab');
});

test('splitCueRuby 把读音单独留出来（正文段 + 可选读音）', () => {
  assert.deepStrictEqual(
    adapters.splitCueRuby('（玲琳）<ruby>熱<rt>ねつ</rt></ruby>さまし'),
    [
      { text: '（玲琳）', reading: '' },
      { text: '熱', reading: 'ねつ' },
      { text: 'さまし', reading: '' },
    ]);
});

test('没有注音时是单段，reading 为空', () => {
  assert.deepStrictEqual(adapters.splitCueRuby('ただのテキスト'),
    [{ text: 'ただのテキスト', reading: '' }]);
});

test('段拼接恒等于 stripCueTags 的正文（否则列表上的字与查到的词会对不上）', () => {
  const samples = [
    '（玲琳）<ruby>熱<rt>ねつ</rt></ruby>さましが…',
    '<ruby>漢字<rt>かんじ</ruby>の話',
    '<ruby>漢<rt かん</ruby>の話',     // 畸形：整行退回单段
    'a<rt/>b',
    '<i>普通</i>のテキスト',
    '',
  ];
  for (const sample of samples) {
    const joined = adapters.splitCueRuby(sample).map((seg) => seg.text).join('').trim();
    assert.strictEqual(joined, adapters.stripCueTags(sample),
      '段拼接与正文不一致：' + JSON.stringify(sample));
  }
});

// ───────────────────────── 渲染（列表与覆盖层共用） ─────────────────────────

function loadRenderer() {
  const makeNode = (tag) => ({
    tagName: tag ? tag.toUpperCase() : '',
    childNodes: [],
    _text: '',
    get textContent() {
      if (!this.childNodes.length) return this._text;
      return this.childNodes.map((c) => c.textContent).join('');
    },
    set textContent(value) {
      this.childNodes = [];
      this._text = String(value);
    },
    appendChild(child) { this.childNodes.push(child); return child; },
  });
  const sandbox = { Array, String };
  sandbox.document = {
    createElement: (tag) => makeNode(tag),
    createTextNode: (value) => ({ tagName: '', childNodes: [], textContent: String(value) }),
  };
  sandbox.window = {};
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(RUBY_RENDER, sandbox, { filename: 'ruby-render.js' });
  return { render: sandbox.window.fushiRenderCueText, makeNode };
}

// 元素里除 <rt> 之外的文本（= 真正的正文）。
function baseText(el) {
  return el.childNodes.map((child) => {
    if (child.tagName !== 'RUBY') return child.textContent;
    return child.childNodes
      .filter((part) => part.tagName !== 'RT')
      .map((part) => part.textContent)
      .join('');
  }).join('');
}

function shape(el) {
  return el.childNodes.map((child) => {
    if (child.tagName !== 'RUBY') return child.textContent;
    return child.childNodes.map((part) =>
      (part.tagName === 'RT' ? '[' + part.textContent + ']' : part.textContent)).join('');
  }).join('|');
}

test('有读音时画出真正的 <ruby><rt>（振假名回到正文上方）', () => {
  const h = loadRenderer();
  const el = h.makeNode('div');
  const drew = h.render(el, {
    text: '（玲琳）熱さまし',
    ruby: [
      { text: '（玲琳）', reading: '' },
      { text: '熱', reading: 'ねつ' },
      { text: 'さまし', reading: '' },
    ],
  });
  assert.strictEqual(drew, true, '有读音却没画振假名');
  assert.strictEqual(shape(el), '（玲琳）|熱[ねつ]|さまし');
  // 注意：真实 DOM 的 textContent **包含** <rt>（`<ruby>熱<rt>ねつ</rt></ruby>`.textContent
  // === '熱ねつ'）——这正是采集端不能用 textContent 取字幕的原因。这里断言的是「非 rt 部分」。
  assert.strictEqual(baseText(el), '（玲琳）熱さまし',
    '正文必须与 cue.text 一致——读音不是正文的一部分');
});

test('没有 ruby 数据时就是一个文本节点（与从前完全一样）', () => {
  const h = loadRenderer();
  const el = h.makeNode('div');
  assert.strictEqual(h.render(el, { text: 'ただのテキスト' }), false);
  assert.strictEqual(el.textContent, 'ただのテキスト');
  assert.strictEqual(el.childNodes.length, 0, '无注音不该凭空生出子节点');
});

test('段序列全空时退回正文，绝不留下空白行', () => {
  const h = loadRenderer();
  const el = h.makeNode('div');
  h.render(el, { text: 'テキスト', ruby: [{ text: '', reading: 'よみ' }] });
  assert.strictEqual(el.textContent, 'テキスト');
});
