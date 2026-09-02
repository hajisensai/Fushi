// 选中制卡高亮的**算法级**行为守卫：给定「义项内的字符区间」，
// applyGlossarySelectionHighlight 必须把导出树上对应的那几段文字（且只有那几段）
// 包进 <mark class="fushi-selection">。
//
// 分层说明（别把两层混起来）：
//   * 本文件测的是**切分与包裹**——纯逻辑，只依赖 splitText 与前序 TreeWalker
//     这两个语义简单到能精确复刻的原语，所以最小 fake DOM 不构成自证。
//   * 「屏幕选区 → 字符区间」那一半依赖 Range.comparePoint /
//     compareBoundaryPoints / intersectsNode 的真实语义，fake 出来就是拿自己的
//     假设验证自己的假设，只能在真 WebView 里验：
//     fushi/integration_test/popup_selection_highlight_itest.dart。
//
// 运行：node fushi/test/anki/glossary_selection_highlight_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'),
  'utf8',
);

// ---- 最小 fake DOM ---------------------------------------------------------
// 只实现被测代码真正用到的原语，语义按 DOM 标准复刻：
//   Text.splitText(offset)  → 原节点留 [0,offset)，新节点接在其后成为兄弟
//   TreeWalker(SHOW_TEXT)   → 深度优先前序，acceptNode 返回 FILTER_REJECT 则跳过
//   insertBefore/appendChild→ 移动语义（先从原父摘除）

class FakeText {
  constructor(value) {
    this.nodeType = 3;
    this.nodeValue = value;
    this.parentNode = null;
  }

  get parentElement() {
    return this.parentNode;
  }

  splitText(offset) {
    const tail = new FakeText(this.nodeValue.slice(offset));
    this.nodeValue = this.nodeValue.slice(0, offset);
    const parent = this.parentNode;
    assert.ok(parent, 'splitText on a detached text node');
    parent.childNodes.splice(parent.childNodes.indexOf(this) + 1, 0, tail);
    tail.parentNode = parent;
    return tail;
  }
}

class FakeElement {
  constructor(tagName) {
    this.nodeType = 1;
    this.tagName = tagName.toUpperCase();
    this.className = '';
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = {};
  }

  get parentElement() {
    return this.parentNode;
  }

  setAttribute(name, value) {
    this.attributes[name] = value;
  }

  getAttribute(name) {
    return name in this.attributes ? this.attributes[name] : null;
  }

  _detach(node) {
    if (node.parentNode) {
      const siblings = node.parentNode.childNodes;
      const at = siblings.indexOf(node);
      if (at >= 0) siblings.splice(at, 1);
    }
  }

  appendChild(node) {
    this._detach(node);
    this.childNodes.push(node);
    node.parentNode = this;
    return node;
  }

  insertBefore(node, ref) {
    this._detach(node);
    const at = ref ? this.childNodes.indexOf(ref) : this.childNodes.length;
    this.childNodes.splice(at < 0 ? this.childNodes.length : at, 0, node);
    node.parentNode = this;
    return node;
  }

  // 被测代码只用 closest('.gloss-image-link')。
  closest(selector) {
    assert.strictEqual(selector, '.gloss-image-link',
      'unexpected selector in fake closest(): ' + selector);
    const wanted = selector.slice(1);
    for (let el = this; el; el = el.parentNode) {
      if (el.nodeType === 1 && (el.className || '').split(/\s+/).includes(wanted)) {
        return el;
      }
    }
    return null;
  }
}

const NodeFilterStub = {
  SHOW_TEXT: 4,
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3,
};

function createTreeWalker(root, whatToShow, filter) {
  assert.strictEqual(whatToShow, NodeFilterStub.SHOW_TEXT);
  const collected = [];
  (function walk(node) {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === 3) {
        const verdict = filter && filter.acceptNode
          ? filter.acceptNode(child)
          : NodeFilterStub.FILTER_ACCEPT;
        if (verdict === NodeFilterStub.FILTER_ACCEPT) collected.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  let cursor = -1;
  return {
    nextNode() {
      cursor += 1;
      return cursor < collected.length ? collected[cursor] : null;
    },
  };
}

const documentStub = {
  createElement: (tag) => new FakeElement(tag),
  createTreeWalker,
};

// ---- 提取被测函数（不执行整个 popup.js：它依赖真实 DOM/window） -------------
function extract(pattern, what) {
  const match = popupSrc.match(pattern);
  assert.ok(match, 'popup.js must define ' + what);
  return match[0];
}

const walkerFn = extract(
  /function createGlossaryTextWalker\(root\) \{[\s\S]*?\n\}/,
  'createGlossaryTextWalker(root)',
);
const applyFn = extract(
  /function applyGlossarySelectionHighlight\(root, spans\) \{[\s\S]*?\n\}/,
  'applyGlossarySelectionHighlight(root, spans)',
);
const markClass = extract(
  /const GLOSSARY_SELECTION_MARK_CLASS = '[^']*';/,
  'GLOSSARY_SELECTION_MARK_CLASS',
);
const markStyle = extract(
  /const GLOSSARY_SELECTION_MARK_STYLE =\n?\s*'[^']*';/,
  'GLOSSARY_SELECTION_MARK_STYLE',
);

const context = {
  console,
  document: documentStub,
  NodeFilter: NodeFilterStub,
};
vm.createContext(context);
vm.runInContext(
  markClass + '\n' + markStyle + '\n' + walkerFn + '\n' + applyFn +
  '\nthis.__apply = applyGlossarySelectionHighlight;' +
  '\nthis.__markClass = GLOSSARY_SELECTION_MARK_CLASS;' +
  '\nthis.__markStyle = GLOSSARY_SELECTION_MARK_STYLE;',
  context,
);
const applyGlossarySelectionHighlight = context.__apply;
const MARK_CLASS = context.__markClass;
const MARK_STYLE = context.__markStyle;

// ---- 两个导出构建器都必须调用高亮（调用点源级判据） ------------------------
const callSites = popupSrc.match(/highlightExportedGlossary\(tempDiv, entryIndex, glossaryIndex\);/g) || [];
assert.ok(
  callSites.length >= 2,
  'both export builders (constructGlossaryHtml / constructSingleGlossaryHtml) must ' +
  'apply the selection highlight; found ' + callSites.length + ' call site(s)',
);
// 屏幕侧锚点：两个渲染分支（多义项 ol/li 与单义项 wrapper）都要打坐标，
// 少打一个就有整类义项永远高亮不了。
const anchorSites = popupSrc.match(/tagGlossaryContent\(content, entryIdx, item\.glossaryIndex\);/g) || [];
assert.ok(
  anchorSites.length >= 2,
  'both on-screen glossary render branches must tag their content container; ' +
  'found ' + anchorSites.length + ' site(s)',
);

// ---- 测试脚手架 -------------------------------------------------------------
function build(spec) {
  // spec: 数组，字符串 = 文本节点；{tag, className, children} = 元素
  const root = new FakeElement('div');
  (function fill(parent, items) {
    for (const item of items) {
      if (typeof item === 'string') {
        parent.appendChild(new FakeText(item));
      } else {
        const el = new FakeElement(item.tag || 'span');
        if (item.className) el.className = item.className;
        parent.appendChild(el);
        fill(el, item.children || []);
      }
    }
  })(root, spec);
  return root;
}

function serialize(node) {
  if (node.nodeType === 3) return node.nodeValue;
  const inner = node.childNodes.map(serialize).join('');
  if (node === undefined) return inner;
  const cls = node.className ? ' class="' + node.className + '"' : '';
  return '<' + node.tagName.toLowerCase() + cls + '>' + inner +
    '</' + node.tagName.toLowerCase() + '>';
}

function serializeChildren(root) {
  return root.childNodes.map(serialize).join('');
}

function marksOf(root) {
  const found = [];
  (function walk(node) {
    for (const child of node.childNodes) {
      if (child.nodeType === 1) {
        if ((child.className || '').split(/\s+/).includes(MARK_CLASS)) {
          found.push(child);
        }
        walk(child);
      }
    }
  })(root);
  return found;
}

function markTexts(root) {
  return marksOf(root).map((m) => m.childNodes.map(serialize).join(''));
}

let passed = 0;
function check(name, fn) {
  fn();
  passed += 1;
  console.log('ok - ' + name);
}

// 场景 A：区间落在单个文本节点中间 → 切成三段，只有中间那段被包。
check('a range inside one text node is split into exactly one mark', () => {
  const root = build(['配分の基準となる単位を表す。']);
  const ok = applyGlossarySelectionHighlight(root, [
    { start: 3, end: 5, text: '基準' },
  ]);
  assert.strictEqual(ok, true, 'must report that it marked something');
  assert.deepStrictEqual(markTexts(root), ['基準']);
  assert.strictEqual(
    serializeChildren(root),
    '配分の<mark class="' + MARK_CLASS + '">基準</mark>となる単位を表す。',
    'text outside the range must survive byte-identically',
  );
  assert.strictEqual(marksOf(root)[0].getAttribute('style'), MARK_STYLE,
    'the factory default colour must ride along as an inline style');
});

// 场景 B：跨元素的区间 → 每个文本节点各自成 mark，拼接等于选中文本。
// 绝不能把跨节点的选中压平成一个 mark：那会重排 DOM、毁掉词典自己的标记。
check('a range spanning elements marks each text node in place', () => {
  const root = build([
    { tag: 'span', children: ['一日に'] },
    { tag: 'em', children: ['三回'] },
    { tag: 'span', children: ['食べる'] },
  ]);
  const ok = applyGlossarySelectionHighlight(root, [
    { start: 0, end: 8, text: '一日に三回食べる' },
  ]);
  assert.strictEqual(ok, true);
  assert.deepStrictEqual(markTexts(root), ['一日に', '三回', '食べる']);
  assert.strictEqual(
    serializeChildren(root),
    '<span><mark class="' + MARK_CLASS + '">一日に</mark></span>' +
    '<em><mark class="' + MARK_CLASS + '">三回</mark></em>' +
    '<span><mark class="' + MARK_CLASS + '">食べる</mark></span>',
    'element structure must be preserved; only text nodes get wrapped',
  );
});

// 场景 C：部分跨节点（起点和终点都在节点中间）。
check('a partial cross-node range trims both ends', () => {
  const root = build([
    { tag: 'span', children: ['あいうえお'] },
    { tag: 'span', children: ['かきくけこ'] },
  ]);
  applyGlossarySelectionHighlight(root, [
    { start: 3, end: 7, text: 'えおかき' },
  ]);
  assert.deepStrictEqual(markTexts(root), ['えお', 'かき']);
  assert.strictEqual(
    serializeChildren(root),
    '<span>あいう<mark class="' + MARK_CLASS + '">えお</mark></span>' +
    '<span><mark class="' + MARK_CLASS + '">かき</mark>くけこ</span>',
  );
});

// 场景 D（关键）：图片子树的文本不算进文本流。
// 导出端在不嵌媒体时会把图片 alt 写成可见文本（createDefinitionImage 的
// image.textContent = alt），屏幕端只有 <img> 不产文本。不跳过 .gloss-image-link
// 的话，图片之后的区间会整体后移 alt 的长度——标到错误的字上。
check('text inside .gloss-image-link is excluded from the text flow', () => {
  const root = build([
    '前文',
    {
      tag: 'span',
      className: 'gloss-image-link',
      children: [{ tag: 'span', className: 'gloss-image', children: ['ALTALTALT'] }],
    },
    '図のあとの本文',
  ]);
  applyGlossarySelectionHighlight(root, [
    // 「前文」之后紧接着就是「図のあと」——中间的 alt 不占偏移。
    { start: 2, end: 6, text: '図のあと' },
  ]);
  assert.deepStrictEqual(markTexts(root), ['図のあと'],
    'the image alt text must not shift the offsets');
  assert.strictEqual(
    serializeChildren(root),
    '前文' +
    '<span class="gloss-image-link"><span class="gloss-image">ALTALTALT</span></span>' +
    '<mark class="' + MARK_CLASS + '">図のあと</mark>の本文',
  );
  assert.strictEqual(marksOf(root).length, 1,
    'the alt text itself must never be marked');
});

// 场景 E：文本流对不上就整棵树放弃——宁可不标，绝不标错位置。
// （屏幕树与导出树对 HTML 型词典内容走的是不同的清洗函数，真的可能对不上。）
check('a stale span marks nothing at all', () => {
  const root = build(['配分の基準となる単位を表す。']);
  const before = serializeChildren(root);
  const ok = applyGlossarySelectionHighlight(root, [
    { start: 3, end: 5, text: 'まったく別の文字' },
  ]);
  assert.strictEqual(ok, false, 'must report that nothing was marked');
  assert.strictEqual(marksOf(root).length, 0);
  assert.strictEqual(serializeChildren(root), before, 'DOM must be untouched');
});

// 场景 F：空 spans / 空树是安全的 no-op。
check('empty input is a safe no-op', () => {
  const root = build(['abc']);
  assert.strictEqual(applyGlossarySelectionHighlight(root, []), false);
  assert.strictEqual(applyGlossarySelectionHighlight(build([]), [
    { start: 0, end: 1, text: 'a' },
  ]), false);
  assert.strictEqual(marksOf(root).length, 0);
});

// 场景 G：多段选中（Ctrl 多选）互不干扰，且都落在正确位置。
check('multiple disjoint spans each land in the right place', () => {
  const root = build(['あいうえおかきくけこ']);
  applyGlossarySelectionHighlight(root, [
    { start: 0, end: 2, text: 'あい' },
    { start: 6, end: 8, text: 'きく' },
  ]);
  assert.deepStrictEqual(markTexts(root), ['あい', 'きく']);
  assert.strictEqual(
    serializeChildren(root),
    '<mark class="' + MARK_CLASS + '">あい</mark>うえおか' +
    '<mark class="' + MARK_CLASS + '">きく</mark>けこ',
  );
});

console.log(passed + ' checks: all assertions passed');
