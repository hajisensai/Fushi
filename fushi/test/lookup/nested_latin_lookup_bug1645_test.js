// BUG-1645 行为守卫：嵌套查词必须能查到英文注释里的单词。
//
// 症状：在查词弹窗里点 Jitendex 释义中的英文词（如 acrid）→ 子卡「未找到搜索结果」，
// 而同一个词在顶层查词框里输入能正常查到。
//
// 根因：selection.js 的 `selectFromPosition` 跨文本节点续扫时不认元素边界，把相邻
// 释义（`<li>acrid</li><li>pungent</li>`）的文字直接粘成 `acridpungent`；而 C++
// `scan_candidates`（native/fushidicts/fushidicts_src/scan/word_scan.cpp）出于
// 「不在单词中间切」的正确规则，拒绝在两个空格分词类字母之间切分 —— 于是
// scan_candidates("acridpungent") 只产出 ["acridpungent"]，永远还原不出 "acrid"。
// 日语不受影响：CJK 不是空格分词脚本，任意码点处都可切。
//
// 修复：跨节点续扫前用 `crossesRenderBoundary` 判断两节点之间有没有渲染断点
// （块盒/列表项边界，或 compact 模式下 `li::after { content: " | " }` 这种生成内容分隔符）。
// 判据必须是渲染盒而不是「两侧都是字母就断」，否则 `<b>ac</b>rid` 这种行内标记
// 拆开的单词会被误断（场景 C 守这条）。
//
// BUG-1659（同一函数的后续回归）：`isInlineBox` 手工枚举 inline 盒，漏掉了
// inline-block（popup.css 的 `.ruby-unit` 正是它）与「computed display 为空串」
// 两种情况，两者都被误判成渲染断点 —— 见下方场景 E / F。
//
// 运行：node fushi/test/lookup/nested_latin_lookup_bug1645_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const selectionSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'selection.js'),
  'utf8',
);

// ---- 最小 fake DOM -------------------------------------------------------
function makeText(content, parent) {
  return {
    nodeType: 3,
    textContent: content,
    parentElement: parent,
    __rectForChar: (i) => ({ left: 100 + 20 * i, right: 120 + 20 * i, top: 50, bottom: 70 }),
  };
}

// display / ::after / ::before 由建节点时显式指定，模拟真实 CSS。
function makeElement(tagName, { className = '', display = 'inline', after = 'none', before = 'none' } = {}) {
  return {
    nodeType: 1,
    tagName,
    className,
    parentElement: null,
    shadowRoot: null,
    childNodes: [],
    __display: display,
    __after: after,
    __before: before,
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const parts = selector.split(',').map((s) => s.trim().toLowerCase());
      let node = this;
      while (node && node.nodeType === 1) {
        for (const part of parts) {
          if (part.startsWith('.')) {
            if ((node.className || '').split(/\s+/).includes(part.slice(1))) return node;
          } else if ((node.tagName || '').toLowerCase() === part) {
            return node;
          }
        }
        node = node.parentElement;
      }
      return null;
    },
  };
}

function appendChildren(parent, children) {
  parent.childNodes = children;
  for (const child of children) {
    if (child.nodeType === 1) child.parentElement = parent;
  }
  return parent;
}

function makeRange() {
  return {
    startContainer: null,
    startOffset: 0,
    endContainer: null,
    endOffset: 0,
    setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
    setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
    collapse(toStart) {
      if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; }
    },
    getClientRects() {
      const n = this.startContainer;
      if (n && n.nodeType === 3 && this.endOffset === this.startOffset + 1) {
        return [n.__rectForChar(this.startOffset)];
      }
      return [];
    },
    getBoundingClientRect() {
      const rects = this.getClientRects();
      return rects.length ? rects[0] : { left: 0, right: 0, top: 0, bottom: 0 };
    },
  };
}

// 真 TreeWalker 语义：从 currentNode 之后继续（selectFromPosition 会先设 currentNode）。
function makeTreeWalker(root, filter) {
  const order = [];
  (function walk(node) {
    for (const child of node.childNodes || []) {
      if (child.nodeType === 3) {
        if (filter.acceptNode(child) === 1) order.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  return {
    currentNode: root,
    nextNode() {
      const idx = order.indexOf(this.currentNode);
      this.currentNode = order[idx < 0 ? 0 : idx + 1] || null;
      return this.currentNode;
    },
  };
}

function buildContext(buildDom) {
  const body = makeElement('body', { display: 'block' });
  const built = buildDom(body);

  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    elementFromPoint: () => null,
    caretRangeFromPoint: () => null,
  };
  const calls = [];
  const window = {
    flutter_inappwebview: { callHandler: (...args) => { calls.push(args); } },
    getComputedStyle: (element, pseudo) => {
      if (pseudo === '::after') return { content: element.__after };
      if (pseudo === '::before') return { content: element.__before };
      return { display: element.__display };
    },
  };
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
  };
  vm.createContext(sandbox);
  vm.runInContext(selectionSrc, sandbox);
  return { sandbox, calls, ...built };
}

// 弹窗真实结构：<div class="glossary-content"><ul><li>释义1</li><li>释义2</li></ul></div>
function glossaryList(liDisplay, liAfter) {
  return (body) => {
    const content = makeElement('div', { className: 'glossary-content', display: 'block' });
    const list = makeElement('ul', { display: 'block' });
    const first = makeElement('li', { display: liDisplay, after: liAfter });
    const second = makeElement('li', { display: liDisplay, after: liAfter });
    const firstText = makeText('acrid', first);
    const secondText = makeText('pungent', second);
    first.childNodes = [firstText];
    second.childNodes = [secondText];
    appendChildren(list, [first, second]);
    appendChildren(content, [list]);
    appendChildren(body, [content]);
    return { hit: firstText };
  };
}

function run() {
  // 场景 A（根因回归守卫）：相邻释义是各自的 list-item 盒，点第一条里的英文词
  // 只能取到这条释义的那个词。修复前这里是 'acridpungent'。
  {
    const ctx = buildContext(glossaryList('list-item', 'none'));
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 2, 20);
    assert.strictEqual(text, 'acrid', '[list-item] 点释义里的英文词不得粘上相邻释义');
    assert.deepStrictEqual(
      ctx.calls.map((c) => c.slice(0, 2)),
      [['textSelected', 'acrid']],
      '[list-item] 发给宿主的查询串必须是干净的单词',
    );
  }

  // 场景 B：compact 释义模式——li 是 inline 盒，分隔符 " | " 只存在于 ::after
  // 生成内容里，DOM 中没有对应文本节点。不查伪元素同样会粘成 acridpungent。
  {
    const ctx = buildContext(glossaryList('inline', '" | "'));
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 2, 20);
    assert.strictEqual(text, 'acrid', '[compact] ::after 分隔符也是渲染断点');
  }

  // 场景 C（不回归）：行内标记拆开的单词必须继续跨节点粘 —— <b>ac</b>rid。
  // 这是「两侧都是字母就断」那种简单判据会打坏的用例。
  {
    const ctx = buildContext((body) => {
      const paragraph = makeElement('p', { display: 'block' });
      const bold = makeElement('b', { display: 'inline' });
      const boldText = makeText('ac', bold);
      bold.childNodes = [boldText];
      const tailText = makeText('rid', paragraph);
      appendChildren(paragraph, [bold]);
      paragraph.childNodes = [bold, tailText];
      appendChildren(body, [paragraph]);
      return { hit: boldText };
    });
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 0, 20);
    assert.strictEqual(text, 'acrid', '[inline-split] 行内标记拆开的单词必须仍能拼回');
  }

  // 场景 D（不回归）：日语跨 inline span 续扫照旧粘接。
  {
    const ctx = buildContext((body) => {
      const paragraph = makeElement('p', { display: 'block' });
      const span = makeElement('span', { display: 'inline' });
      const spanText = makeText('打ち', span);
      span.childNodes = [spanText];
      const tailText = makeText('合わせ', paragraph);
      appendChildren(paragraph, [span]);
      paragraph.childNodes = [span, tailText];
      appendChildren(body, [paragraph]);
      return { hit: spanText };
    });
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 0, 20);
    assert.strictEqual(text, '打ち合わせ', '[ja-inline] 日语跨行内节点续扫不得回归');
  }

  // 场景 E（BUG-1659 根因守卫）：振假名单元是 `display: inline-block`。
  // popup.css `.ruby-unit { display: inline-block }`（每个振假名单元一个盒），
  // 而 inline-block 是 **inline-level** 盒 —— 它和相邻文字排在同一行上，两侧
  // 文字完全可能是同一个词。BUG-1645 的 isInlineBox 手工枚举成
  // `display === 'inline'`，把它连同 inline-flex / inline-grid / inline-table
  // 一起当成了渲染断点，于是查词浮窗 glossary 里任何带振假名的词扫到第一个
  // ruby 单元就断：「打ち合わせ」只剩下「打」。
  //
  // 注意 test/js/popup_ruby_selection.test.mjs 盖不住这条：jsdom 的默认样式表
  // 只给块级元素赋 display，fixture 里 span/ruby 的 computed display 全是空串，
  // 那条测试踩到的是「空 display」路径（场景 F），不是 inline-block。
  {
    const ctx = buildContext((body) => {
      const content = makeElement('div', { className: 'glossary-content', display: 'block' });
      const ruby = makeElement('ruby', { display: 'ruby' });
      const unit = makeElement('span', { className: 'ruby-unit', display: 'inline-block' });
      const baseText = makeText('打', unit);
      unit.childNodes = [baseText];
      const tail = makeElement('span', { display: 'inline' });
      const tailText = makeText('ち合わせ', tail);
      tail.childNodes = [tailText];
      appendChildren(ruby, [unit]);
      appendChildren(content, [ruby, tail]);
      appendChildren(body, [content]);
      return { hit: baseText };
    });
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 0, 20);
    assert.strictEqual(
      text,
      '打ち合わせ',
      '[inline-block] 振假名单元(.ruby-unit)是 inline-level 盒，不得当成渲染断点',
    );
  }

  // 场景 F（BUG-1659）：computed display 取不到值（空串）时不得当成断点。
  // isInlineBox 的既有兜底是「拿不到样式时返回 true」，但只挡了 style 对象本身
  // 为空的情况；样式对象在、display 是空串时会一路落到 `=== 'inline'` 全部不中，
  // 反而判成断点。jsdom / 精简沙箱 / 未附加到文档的节点都会走到这条路径。
  {
    const ctx = buildContext((body) => {
      const paragraph = makeElement('p', { display: 'block' });
      const span = makeElement('span', { display: '' });
      const spanText = makeText('打ち', span);
      span.childNodes = [spanText];
      const tailText = makeText('合わせ', paragraph);
      appendChildren(paragraph, [span]);
      paragraph.childNodes = [span, tailText];
      appendChildren(body, [paragraph]);
      return { hit: spanText };
    });
    const text = ctx.sandbox.window.fushiSelection.selectFromPosition(ctx.hit, 0, 20);
    assert.strictEqual(
      text,
      '打ち合わせ',
      '[empty-display] 拿不到 display 时必须沿用旧的续扫行为，不得判成断点',
    );
  }

  console.log('all assertions passed');
}

run();
