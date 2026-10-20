// P2-F：popup.js 的 applyCustomCSS 按「键 → <style>」diff 落地（真执行 popup.js）。
//
// 旧实现每次渲染（首词条 / 尾批 / 增量追加各一次）都把全部 style.fushi-custom-css 删掉
// 再整批重插：内容一字未变也让全文档样式失效重算。这里守的是：
//   ① 内容不变时一个节点都不增删、不改文本；
//   ② 只改某本词典的 CSS 时原位改 textContent，不重插；
//   ③ 键集合变化（加一本词典）才重建，且全局 CSS 仍排在最前；
//   ④ realm 根换了（__fushiRoot 换新）时在新根下重建，不留在旧根里。
const assert = require('assert');
const { loadPopup } = require('./_popup_dom_host');

function makeRoot(stats) {
  const root = {
    children: [],
    appendChild(child) {
      if (child.parentNode && child.parentNode !== root) child.remove();
      child.parentNode = root;
      root.children.push(child);
      stats.appends++;
      return child;
    },
    querySelectorAll(selector) {
      assert.strictEqual(selector, 'style.fushi-custom-css');
      return root.children.filter((c) => c.className === 'fushi-custom-css');
    },
  };
  return root;
}

function makeStyle(stats) {
  const node = {
    tagName: 'STYLE',
    className: '',
    parentNode: null,
    _text: '',
    get textContent() { return this._text; },
    set textContent(v) { this._text = v; stats.textWrites++; },
    remove() {
      const parent = node.parentNode;
      if (!parent) return;
      const i = parent.children.indexOf(node);
      if (i >= 0) parent.children.splice(i, 1);
      node.parentNode = null;
      stats.removes++;
    },
  };
  return node;
}

const stats = { appends: 0, removes: 0, textWrites: 0 };
function resetStats() { stats.appends = 0; stats.removes = 0; stats.textWrites = 0; }

let root = makeRoot(stats);
const sandbox = loadPopup((sb) => {
  sb.document.createElement = (tag) => {
    assert.strictEqual(tag, 'style');
    return makeStyle(stats);
  };
  // dict-media.js 不在这个沙盒里：用可辨认的假作用域化，断言文本即可。
  sb.constructDictCss = (css, dictName) => `[${dictName}]${css}`;
});
sandbox.window.__fushiRoot = root;

// ① 首次落地：全局在前，词典按键序。
sandbox.window.globalDictCSS = 'g{}';
sandbox.window.customDictCSS = { A: 'a{}', B: '' /* 空串跳过 */ };
resetStats();
sandbox.applyCustomCSS();
assert.deepStrictEqual(root.children.map((c) => c.textContent), ['g{}', '[A]a{}']);
assert.strictEqual(stats.appends, 2);
const firstNodes = root.children.slice();

// ② 内容不变：零增删、零改写。
resetStats();
sandbox.applyCustomCSS();
sandbox.applyCustomCSS();
assert.deepStrictEqual(stats, { appends: 0, removes: 0, textWrites: 0 },
  'unchanged custom CSS must not touch the DOM (style recalc)');
assert.strictEqual(root.children[0], firstNodes[0]);
assert.strictEqual(root.children[1], firstNodes[1]);

// ③ 只改 A：原位改文本，不重插。
sandbox.window.customDictCSS = { A: 'a2{}' };
resetStats();
sandbox.applyCustomCSS();
assert.strictEqual(stats.appends, 0);
assert.strictEqual(stats.removes, 0);
assert.strictEqual(stats.textWrites, 1);
assert.strictEqual(root.children[1], firstNodes[1]);
assert.strictEqual(root.children[1].textContent, '[A]a2{}');

// ④ 加一本词典：键集合变了才重建，顺序仍是全局在前。
sandbox.window.customDictCSS = { A: 'a2{}', C: 'c{}' };
resetStats();
sandbox.applyCustomCSS();
assert.deepStrictEqual(root.children.map((c) => c.textContent), ['g{}', '[A]a2{}', '[C]c{}']);
assert.strictEqual(stats.appends, 3);

// ⑤ 去掉全局 CSS：重建后不留旧全局节点。
sandbox.window.globalDictCSS = '';
sandbox.applyCustomCSS();
assert.deepStrictEqual(root.children.map((c) => c.textContent), ['[A]a2{}', '[C]c{}']);

// ⑥ realm 根换新：在新根下重建，旧根清空。
const oldRoot = root;
root = makeRoot(stats);
sandbox.window.__fushiRoot = root;
resetStats();
sandbox.applyCustomCSS();
assert.deepStrictEqual(root.children.map((c) => c.textContent), ['[A]a2{}', '[C]c{}']);
assert.strictEqual(oldRoot.children.length, 0, 'stale nodes left in the old realm root');

console.log('all assertions passed');
