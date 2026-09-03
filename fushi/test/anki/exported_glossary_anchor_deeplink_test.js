// BUG-1666 行为守卫：制卡导出的释义 HTML 里，词典内部交叉引用锚点必须改写成
// fushi://lookup?word=<可见词头> 深链，而不是保留 entry:// / 相对路径原样。
//
// 症状：Anki（桌面 + AnkiDroid）用本地媒体服务器（http://127.0.0.1:<随机端口>）
// 作卡片 WebView 的 base URL，释义里指向「另一个单词」的相对链接点下去就解析成
// 127.0.0.1 的死页。弹窗内这类点击被 handleGlossaryAnchorClick（BUG-767）拦截并按
// 可见词头重查；卡片上没有拦截器，只能把同一语义烤进导出字节。
//
// 判据（rewriteExportedGlossaryAnchors，popup.js）：
//   - entry:// 与相对路径 → fushi://lookup?word=<encodeURIComponent(textContent)>
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

const context = { console };
vm.createContext(context);
vm.runInContext(`${fnMatch[0]}; this.__fn = rewriteExportedGlossaryAnchors;`, context);
const rewriteExportedGlossaryAnchors = context.__fn;

// ---- 两个导出构建器都必须在序列化前调用它（调用点源级判据） ----------------
const callSites = popupSrc.match(/rewriteExportedGlossaryAnchors\(tempDiv\);/g) || [];
assert.ok(
  callSites.length >= 2,
  `both export builders (constructGlossaryHtml / constructSingleGlossaryHtml) must call ` +
  `rewriteExportedGlossaryAnchors(tempDiv); found ${callSites.length} call site(s)`,
);

// ---- 最小 fake DOM：只需 querySelectorAll('a[href]') + 锚点三方法 ----------
function makeAnchor(href, text) {
  const attrs = { href };
  return {
    textContent: text,
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

console.log('all assertions passed');
