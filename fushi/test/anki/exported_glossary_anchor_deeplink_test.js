// BUG-1666 行为守卫：制卡导出的释义 HTML 里，词典内部交叉引用锚点必须改写成
// fushi://lookup?word=<可见词头> 深链，而不是保留 entry:// / 相对路径原样。
//
// 症状：Anki（桌面 + AnkiDroid）用本地媒体服务器（http://127.0.0.1:<随机端口>）
// 作卡片 WebView 的 base URL，释义里指向「另一个单词」的相对链接点下去就解析成
// 127.0.0.1 的死页。弹窗内这类点击被 handleGlossaryAnchorClick（BUG-767）拦截并按
// 可见词头重查；卡片上没有拦截器，只能把同一语义烤进导出字节。
//
// 判据（rewriteExportedGlossaryAnchors，popup.js）：
//   - entry:// 与相对路径 → fushi://lookup?word=<encodeURIComponent(基字文本)>
//     基字文本 = linkVisibleBaseText(anchor)：剔掉 rt / rp / .ruby-rt / .ruby-reserve，
//     否则带振假名的「歯が立たない」会被深链成「歯はが立たたない」（用户 10-17 报）
//   - http(s):// 外链保留
//   - # 片段保留（不离开卡片，无 127 危害）
//   - sound:/image:/dictmedia:（字节未导出）→ 去掉 href
//   - 无可见文本的内部锚点 → 去掉 href
//
// 运行：node fushi/test/anki/exported_glossary_anchor_deeplink_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'),
  'utf8',
);

// ---- 提取被测函数（不执行整个 popup.js：它依赖真实 DOM/window） ------------
const fnMatch = popupSrc.match(
  /function rewriteExportedGlossaryAnchors\(root\) \{[\s\S]*?\n\}/,
);
assert.ok(fnMatch, 'popup.js must define rewriteExportedGlossaryAnchors(root)');

const baseTextMatch = popupSrc.match(/function linkVisibleBaseText\(root\) \{[\s\S]*?\n\}/);
assert.ok(baseTextMatch, 'popup.js must define linkVisibleBaseText(root)');

const context = { console, Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 } };
vm.createContext(context);
vm.runInContext(
  `${baseTextMatch[0]}\n${fnMatch[0]}; this.__fn = rewriteExportedGlossaryAnchors;`,
  context,
);
const rewriteExportedGlossaryAnchors = context.__fn;

// ---- 两个导出构建器都必须在序列化前调用它（调用点源级判据） ----------------
const callSites = popupSrc.match(/rewriteExportedGlossaryAnchors\(tempDiv\);/g) || [];
assert.ok(
  callSites.length >= 2,
  `both export builders (constructGlossaryHtml / constructSingleGlossaryHtml) must call ` +
  `rewriteExportedGlossaryAnchors(tempDiv); found ${callSites.length} call site(s)`,
);

// ---- 最小 fake DOM：querySelectorAll('a[href]') + 锚点三方法 + childNodes ------
function textNode(text) {
  return { nodeType: 3, textContent: text };
}

function elementNode(tagName, children, className = '') {
  const classes = new Set(className.split(/\s+/).filter(Boolean));
  return {
    nodeType: 1,
    tagName,
    childNodes: children,
    classList: { contains: (c) => classes.has(c) },
    get textContent() { return children.map((c) => c.textContent).join(''); },
  };
}

// text 为字符串时是单个文本子节点；为数组时是现成的子节点列表。
function makeAnchor(href, text) {
  const attrs = { href };
  const children = typeof text === 'string' ? [textNode(text)] : text;
  return {
    nodeType: 1,
    tagName: 'A',
    childNodes: children,
    classList: { contains: () => false },
    get textContent() { return children.map((c) => c.textContent).join(''); },
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    setAttribute: (name, value) => { attrs[name] = value; },
    removeAttribute: (name) => { delete attrs[name]; },
    get href() { return attrs.href; },
    hasHref() { return 'href' in attrs; },
  };
}

function makeRoot(anchors) {
  return {
    querySelectorAll: (selector) => {
      assert.strictEqual(selector, 'a[href]');
      return anchors;
    },
  };
}

// 场景 A：MDX entry:// 交叉引用 → fushi 深链（按可见词头，percent-encode）。
{
  const a = makeAnchor('entry://belong', 'belong');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.href, 'fushi://lookup?word=belong', 'entry:// must become a fushi deep link');
}

// 场景 B：相对路径（Anki 卡片里会解析到 127.0.0.1 本地服务器）→ fushi 深链。
{
  const a = makeAnchor('/belong_1', 'belong');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.href, 'fushi://lookup?word=belong', 'relative href must become a fushi deep link');
}

// 场景 C：可见词头含非 ASCII / 空白 → encodeURIComponent + trim。
{
  const a = makeAnchor('entry://食べる（たべる）', ' 食べる ');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(
    a.href,
    `fushi://lookup?word=${encodeURIComponent('食べる')}`,
    'visible headword must be trimmed and percent-encoded',
  );
}

// 场景 D：真外链保留原样。
{
  const a = makeAnchor('https://example.com/belong', 'belong');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.href, 'https://example.com/belong', 'external http(s) links must be kept');
}

// 场景 E：# 片段保留（卡内跳转无 127 危害）。
{
  const a = makeAnchor('#idiom-1', 'Idioms');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.href, '#idiom-1', '# fragments must be kept');
}

// 场景 F：sound:// 发音锚点（音频字节未随卡导出）→ 去 href，不指向任何死地址。
{
  const a = makeAnchor('sound://media/belong.mp3', '🔊');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.hasHref(), false, 'sound:// anchors must lose their href');
}

// 场景 G：无可见文本的内部锚点（图标图等）→ 去 href。
{
  const a = makeAnchor('entry://belong', '  ');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(a.hasHref(), false, 'internal anchors without visible text must lose their href');
}

// 场景 H：带振假名的交叉引用（结构化内容 <ruby>基字<rt>读音</rt></ruby>，postProcessRuby
// 还会给每个 rt 克隆 .ruby-reserve 孪生体）→ 深链只带基字。
{
  const ruby = (base, reading) => elementNode('RUBY', [
    textNode(base),
    elementNode('RP', [textNode('(')]),
    elementNode('RT', [textNode(reading)]),
    elementNode('RP', [textNode(')')]),
    elementNode('SPAN', [textNode(reading)], 'ruby-reserve'),
  ]);
  const a = makeAnchor('?query=歯が立たない&wildcards=off', [
    ruby('歯', 'は'),
    textNode('が'),
    ruby('立', 'た'),
    textNode('たない'),
  ]);
  assert.match(a.textContent, /歯\(は\)は/, 'fixture must actually carry furigana in textContent');
  rewriteExportedGlossaryAnchors(makeRoot([a]));
  assert.strictEqual(
    a.href,
    `fushi://lookup?word=${encodeURIComponent('歯が立たない')}`,
    'furigana (rt / rp / .ruby-reserve) must not leak into the deep-link word',
  );
}

// 场景 I：词典弹窗（definition.html，独立页面，没有 popup.js）点结构化内容里的交叉引用，
// href 没带 ?query= 时退回可见文本——同样只取基字。definition.js 的 linkBaseText 是
// popup.js linkVisibleBaseText 的同口径副本（两个页面互不加载对方的脚本），钉住两者输出一致。
{
  const defSrc = fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'popup', 'definition.js'), 'utf8');
  const defMatch = defSrc.match(/function linkBaseText\(root\) \{[\s\S]*?\n\}/);
  assert.ok(defMatch, 'definition.js must define linkBaseText(root)');
  const defContext = { Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 } };
  vm.createContext(defContext);
  vm.runInContext(`${defMatch[0]}; this.__base = linkBaseText;`, defContext);
  const popupContext = { Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 } };
  vm.createContext(popupContext);
  vm.runInContext(`${baseTextMatch[0]}; this.__base = linkVisibleBaseText;`, popupContext);

  const ruby = (base, reading) => elementNode('RUBY', [
    textNode(base),
    elementNode('RP', [textNode('(')]),
    elementNode('RT', [textNode(reading)]),
    elementNode('RP', [textNode(')')]),
    elementNode('SPAN', [textNode(reading)], 'ruby-reserve'),
    elementNode('SPAN', [textNode(reading)], 'ruby-rt'),
  ]);
  const link = elementNode('A', [ruby('歯', 'は'), textNode(' が \n'), ruby('立', 'た'), textNode('たない ')]);
  assert.strictEqual(defContext.__base(link), '歯 が 立たない', 'definition.js fallback query must be base text only');
  assert.strictEqual(defContext.__base(link), popupContext.__base(link), 'definition.js and popup.js must agree');
  // 点击路径：无 ?query= 时用的就是 linkBaseText，而不是带振假名的 textContent。
  assert.ok(/const baseText = linkBaseText\(element\);/.test(defSrc), 'definition.js click must use linkBaseText');
  assert.ok(!/get\('query'\) \|\| element\.textContent/.test(defSrc), 'definition.js must not fall back to raw textContent');
}

console.log('all assertions passed');
