// {popup-selection-html}（反馈 aBgKMjhfut / BUG-4049 方案 B）的 popup.js 行为守卫。
//
// 测的是「选区片段 → 卡片 HTML」这条管线：snapshotSelectionHtml 逐 Range 取
// cloneContents()、按公共祖先认词典、serializeSelectionHtml 外包 .yomitan-glossary 并
// 附该词典的 scoped CSS、sanitizeSelectionHtmlTree 去掉弹窗交互件与危险内容；以及
// snapshotSelection / clearSelectionSnapshot 让纯文本与 HTML 两份快照同生同灭。
//
// 分层说明：Range.cloneContents() 的边界切分是浏览器原语，fake 出来只会自证，这里的
// fake Range 直接交出一份预先构造好的片段（等价于浏览器已经切好）。真实 WebView 里的
// 端到端路径与 popup_selection_highlight_itest.dart 同一层，本轮未跑。
//
// 运行：node fushi/test/anki/popup_selection_html_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const assetsDir = path.resolve(__dirname, '..', '..', 'assets', 'popup');
const popupSrc = fs.readFileSync(path.join(assetsDir, 'popup.js'), 'utf8');
const dictMediaSrc = fs.readFileSync(path.join(assetsDir, 'dict-media.js'), 'utf8');

// ---- 从 popup.js 抽顶层声明（函数到列 0 的 `}` 为止，常量到列 0 起的 `;` 结尾行）----
function extractFunction(name) {
  let start = popupSrc.indexOf(`\nfunction ${name}(`);
  if (start < 0) start = popupSrc.indexOf(`\nasync function ${name}(`);
  assert.ok(start >= 0, `popup.js must define function ${name}`);
  const end = popupSrc.indexOf('\n}\n', start);
  assert.ok(end > start, `function ${name} must end with a column-0 brace`);
  return popupSrc.slice(start + 1, end + 2);
}

function extractConst(name) {
  const re = new RegExp(`\\nconst ${name} = [\\s\\S]*?;\\n`);
  const match = popupSrc.match(re);
  assert.ok(match, `popup.js must define const ${name}`);
  return match[0].slice(1);
}

// ---- 最小 fake DOM ---------------------------------------------------------
const VOID_TAGS = new Set(['br', 'img', 'hr', 'input', 'source', 'track', 'link', 'meta']);

function escapeText(value) {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeAttr(value) {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

class FakeNode {
  constructor() {
    this.parentNode = null;
    this.childNodes = [];
  }

  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null;
  }

  appendChild(child) {
    if (child.nodeType === 11) {
      for (const c of [...child.childNodes]) this.appendChild(c);
      child.childNodes = [];
      return child;
    }
    if (child.parentNode) child.remove();
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }

  remove() {
    if (!this.parentNode) return;
    const siblings = this.parentNode.childNodes;
    siblings.splice(siblings.indexOf(this), 1);
    this.parentNode = null;
  }

  get textContent() {
    return this.childNodes.map(c => c.textContent).join('');
  }

  *descendants() {
    for (const c of this.childNodes) {
      if (c.nodeType === 1) {
        yield c;
        yield* c.descendants();
      }
    }
  }

  querySelectorAll(selector) {
    const parts = selector.split(',').map(s => s.trim()).filter(Boolean);
    return [...this.descendants()].filter(el => parts.some(p => el.matches(p)));
  }
}

class FakeText extends FakeNode {
  constructor(value) {
    super();
    this.nodeType = 3;
    this.nodeValue = value;
  }

  get textContent() {
    return this.nodeValue;
  }

  cloneNode() {
    return new FakeText(this.nodeValue);
  }

  serialize() {
    return escapeText(this.nodeValue);
  }
}

class FakeElement extends FakeNode {
  constructor(tagName) {
    super();
    this.nodeType = 1;
    this.tagName = tagName.toUpperCase();
    this._attrs = new Map();
  }

  get attributes() {
    return [...this._attrs].map(([name, value]) => ({ name, value }));
  }

  setAttribute(name, value) {
    this._attrs.set(name, `${value}`);
  }

  getAttribute(name) {
    return this._attrs.has(name) ? this._attrs.get(name) : null;
  }

  removeAttribute(name) {
    this._attrs.delete(name);
  }

  matches(part) {
    if (part === '*') return true;
    let m;
    if ((m = part.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/))) {
      const value = this.getAttribute(m[1]);
      return value !== null && (m[2] === undefined || value === m[2]);
    }
    if ((m = part.match(/^\.([\w-]+)$/))) {
      return (this.getAttribute('class') || '').split(/\s+/).includes(m[1]);
    }
    assert.match(part, /^[a-z][a-z0-9]*$/, `fake DOM does not support selector ${part}`);
    return this.tagName.toLowerCase() === part;
  }

  closest(selector) {
    for (let node = this; node && node.nodeType === 1; node = node.parentNode) {
      if (selector.split(',').some(p => node.matches(p.trim()))) return node;
    }
    return null;
  }

  cloneNode(deep) {
    const copy = new FakeElement(this.tagName);
    for (const [k, v] of this._attrs) copy._attrs.set(k, v);
    if (deep) for (const c of this.childNodes) copy.appendChild(c.cloneNode(true));
    return copy;
  }

  get innerHTML() {
    return this.childNodes.map(c => c.serialize()).join('');
  }

  serialize() {
    const tag = this.tagName.toLowerCase();
    const attrs = [...this._attrs].map(([k, v]) => ` ${k}="${escapeAttr(v)}"`).join('');
    if (VOID_TAGS.has(tag)) return `<${tag}${attrs}>`;
    return `<${tag}${attrs}>${this.innerHTML}</${tag}>`;
  }
}

class FakeFragment extends FakeNode {
  constructor() {
    super();
    this.nodeType = 11;
  }
}

function h(tag, attrs, ...children) {
  const el = new FakeElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  for (const c of children) el.appendChild(typeof c === 'string' ? new FakeText(c) : c);
  return el;
}

function fragmentOf(...nodes) {
  const frag = new FakeFragment();
  for (const n of nodes) frag.appendChild(n.cloneNode(true));
  return frag;
}

// cloneContents() 每次都交出一份新的片段（浏览器语义），屏幕树本身不被改动。
function fakeRange(commonAncestorContainer, nodes) {
  return {
    collapsed: false,
    commonAncestorContainer,
    cloneContents: () => fragmentOf(...nodes),
  };
}

function fakeSelection(ranges, text) {
  return {
    rangeCount: ranges.length,
    isCollapsed: ranges.length === 0,
    getRangeAt: i => ranges[i],
    toString: () => text,
  };
}

// ---- 执行环境 -------------------------------------------------------------
const context = {
  window: {},
  document: { createElement: tag => new FakeElement(tag) },
  console,
};
context.window.dictionaryStyles = {
  大辞林: '.dict-note { color: red; } span[data-sc-class="tag"] { font-weight: bold; }',
  // BUG-3762 回归：词典 CSS 里的 </style> 不能闭合导出卡片里的样式标签。
  恶意辞書: '.x { color: blue; } .y::after { content: "</style><script>alert(1)</script>"; }',
};
vm.createContext(context);
vm.runInContext(dictMediaSrc, context, { filename: 'dict-media.js' });
vm.runInContext([
  extractConst('DICT_HTML_BLOCKED_SELECTOR'),
  extractConst('DICT_AUTO_FETCH_ATTRS'),
  extractConst('DICT_CSS_REMOTE_URL_RE'),
  extractConst('SELECTION_HTML_DROPPED_SELECTOR'),
  'let lastSelection = "";',
  'let lastSelectionSpans = [];',
  'let lastSelectionHtml = "";',
  'let __testSelection = null;',
  'function __fushiSel() { return __testSelection; }',
  'function collectGlossarySelectionSpans() { return [{ glossaryIndex: 0, start: 0, end: 1 }]; }',
  extractFunction('stripDictCssRemoteRefs'),
  extractFunction('exportedDictStyleTag'),
  extractFunction('sanitizeSelectionElementAttributes'),
  extractFunction('sanitizeSelectionHtmlTree'),
  extractFunction('selectionRangeDictionary'),
  extractFunction('snapshotSelectionHtml'),
  extractFunction('serializeSelectionHtml'),
  extractFunction('snapshotSelection'),
  extractFunction('clearSelectionSnapshot'),
  'globalThis.__api = {',
  '  snapshotSelectionHtml, snapshotSelection, clearSelectionSnapshot,',
  '  setSelection(sel) { __testSelection = sel; },',
  '  state() { return { text: lastSelection, html: lastSelectionHtml, spans: lastSelectionSpans }; },',
  '};',
].join('\n'), context, { filename: 'popup.js (extracted)' });
const api = context.__api;

// ---- 屏幕树：一本词典的 structured-content 释义 + 弹窗自己的交互件 -------------
function buildScreen() {
  const content = h('div', { class: 'gloss-content', 'data-fushi-entry': '0', 'data-fushi-gloss': '0' },
    h('span', { 'data-sc-class': 'tag', style: 'font-size: 0.8em; background: url(https://evil.test/x.png)' }, '名'),
    h('span', { class: 'dict-note', style: 'color: rgb(10, 20, 30);', lang: 'ja' }, '物事の', h('b', {}, '大事'), 'な点'),
    h('a', { href: 'fushi://lookup?word=%E7%82%B9', class: 'dict-link', onclick: 'steal()', target: '_blank' }, '点'),
    h('a', { class: 'gloss-image-link', 'data-dictionary': '大辞林' }, h('img', { src: 'http://127.0.0.1/dict/x.png' })),
    h('button', { class: 'copy-btn' }, 'コピー'),
    h('script', {}, 'alert(1)'),
    h('span', { id: 'dup', tabindex: '0', onmouseover: 'x()' }, '<危険>&'),
    h('style', {}, '.screen-only { color: green; }'),
  );
  const dictWrapper = h('div', { 'data-dictionary': '大辞林' }, content);
  const body = h('div', { class: 'glossary-group' }, dictWrapper);
  return { body, dictWrapper, content };
}

// ① 单本词典内的选区：外包词典作用域 + 该词典的 scoped CSS，样式属性保留。
{
  const { content } = buildScreen();
  const textNode = content.childNodes[1].childNodes[0];
  const html = api.snapshotSelectionHtml(fakeSelection(
    [fakeRange(textNode, content.childNodes)], '物事の大事な点'));

  assert.ok(html.startsWith('<div style="text-align: left;" class="yomitan-glossary fushi-popup-selection">'),
    `selection html must be wrapped like an exported glossary, got:\n${html}`);
  assert.ok(html.includes('<div data-dictionary="大辞林">'),
    'the fragment must sit inside its dictionary scope so the scoped CSS applies');
  assert.ok(html.includes('<span class="dict-note" style="color: rgb(10, 20, 30);" lang="ja">物事の<b>大事</b>な点</span>'),
    `dictionary styling (class / inline style / lang / inline tags) must survive, got:\n${html}`);
  assert.ok(html.includes('<span data-sc-class="tag" style="font-size: 0.8em; background: url()">名</span>'),
    `data-sc-* must survive and remote url() must be stripped from inline style, got:\n${html}`);
  assert.ok(/<style>[^<]*\.yomitan-glossary \[data-dictionary="大辞林"\][^<]*\.dict-note[^<]*<\/style><\/div>$/.test(html),
    `the dictionary CSS must be appended scoped under .yomitan-glossary [data-dictionary], got:\n${html}`);
  assert.ok(!html.includes('screen-only'), 'the popup\'s own <style> must not leak into the card');
}

// ② 净化：交互件、脚本、图片、事件、链接、坐标锚点全部不进卡，文本照常转义。
{
  const { content } = buildScreen();
  const html = api.snapshotSelectionHtml(fakeSelection(
    [fakeRange(content, content.childNodes)], 'x'));
  for (const banned of ['<script', 'alert(1)', '<button', 'コピー', '<img', 'gloss-image-link',
    'onclick', 'onmouseover', 'steal()', 'href=', 'fushi://', 'target=', 'data-fushi', 'id="dup"', 'tabindex']) {
    assert.ok(!html.includes(banned), `sanitized selection html must not contain ${banned}:\n${html}`);
  }
  assert.ok(html.includes('<a class="dict-link">点</a>'),
    `links keep their element (dictionary CSS may target it) but lose href/target/handlers:\n${html}`);
  assert.ok(html.includes('&lt;危険&gt;&amp;'), 'text must stay escaped, never re-parsed as markup');
}

// ③ 跨两本词典：公共祖先在词典容器之上，不外包作用域，片段自带的两本词典各得一份样式；
//    恶意词典 CSS 里的 </style> 被转义（BUG-3762 同一条防线）。
{
  const a = h('div', { 'data-dictionary': '大辞林' }, h('span', { class: 'dict-note' }, 'あ'));
  const b = h('div', { 'data-dictionary': '恶意辞書' }, h('span', { class: 'x' }, 'い'));
  const group = h('div', { class: 'glossary-group' }, a, b);
  const html = api.snapshotSelectionHtml(fakeSelection([fakeRange(group, [a, b])], 'あい'));
  assert.ok(html.includes('<div><div data-dictionary="大辞林">'),
    `a cross-dictionary range gets no outer dictionary scope:\n${html}`);
  assert.equal((html.match(/<style>/g) || []).length, 2, 'one scoped <style> per dictionary present');
  assert.ok(!/<\/style><script/i.test(html), `dictionary CSS must not close the <style> tag:\n${html}`);
  assert.ok(html.includes('<\\/style'), 'the </style inside dictionary CSS is escaped');
}

// ④ 多个 Range（如 Firefox 多选区）：逐段各包一层，顺序不变；只有装饰的选区产出空串。
{
  const { content } = buildScreen();
  const note = content.childNodes[1];
  const tag = content.childNodes[0];
  const html = api.snapshotSelectionHtml(fakeSelection(
    [fakeRange(note, [note]), fakeRange(tag, [tag])], '物事の大事な点名'));
  assert.ok(html.indexOf('物事の') < html.indexOf('>名<'), 'ranges keep selection order');
  assert.equal((html.match(/<div data-dictionary="大辞林">/g) || []).length, 2);

  const button = content.childNodes[4];
  assert.equal(api.snapshotSelectionHtml(fakeSelection([fakeRange(button, [button])], 'コピー')), '',
    'a selection that only covers popup chrome yields no html');
  assert.equal(api.snapshotSelectionHtml(fakeSelection([], '')), '', 'collapsed selection yields no html');
  assert.equal(api.snapshotSelectionHtml(null), '', 'no selection yields no html');
}

// ⑤ 快照生命周期：纯文本与 HTML 同一时刻取、同一时刻清，屏幕树不被净化改动。
{
  const { content } = buildScreen();
  const note = content.childNodes[1];
  api.setSelection(fakeSelection([fakeRange(note, [note])], '物事の大事な点'));
  api.snapshotSelection();
  let state = api.state();
  assert.equal(state.text, '物事の大事な点');
  assert.ok(state.html.includes('<b>大事</b>'), 'snapshotSelection captures the html alongside the text');
  assert.ok(content.querySelectorAll('button').length === 1 && content.getAttribute('data-fushi-gloss') === '0',
    'sanitizing the clone must not touch the on-screen tree');

  api.setSelection(fakeSelection([], ''));
  api.snapshotSelection();
  state = api.state();
  assert.equal(state.text, '');
  assert.equal(state.html, '', 'an empty selection must not keep the previous html (BUG-3210 sibling)');

  api.setSelection(fakeSelection([fakeRange(note, [note])], '物事の大事な点'));
  api.snapshotSelection();
  api.clearSelectionSnapshot();
  state = api.state();
  assert.equal(state.html, '', 'clearSelectionSnapshot clears the html snapshot too');
}

// ⑥ 源级：buildMinePayload 只在纯文本就是这次快照时带上 HTML，并把它作为 wire 键上报。
{
  const build = extractFunction('buildMinePayload');
  assert.ok(/const popupSelectionHtml = popupSelectionText && popupSelectionText === lastSelection\s*\?\s*lastSelectionHtml\s*:\s*'';/.test(build),
    'buildMinePayload must tie popupSelectionHtml to the same snapshot as popupSelectionText');
  assert.ok(/\n\s+popupSelectionHtml,\n/.test(build), 'buildMinePayload must send popupSelectionHtml');
}

console.log('popup_selection_html_test: all assertions passed');
