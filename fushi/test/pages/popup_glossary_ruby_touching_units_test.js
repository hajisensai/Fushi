// BUG-1898 行为测试：紧邻的两个带注音基字必须被标成 .ruby-tight，中间隔着普通文字
// 的不得标记。
//
// 背景：.ruby-rt 是 absolute + nowrap，宽度恒等于基字宽，读音更长时向两侧溢出而不撑
// 开任何东西。BUG-850 曾让 .ruby-reserve 永远 in-flow 来防碰撞，BUG-1778 又把它改成
// 永远 absolute 以保住正文字距 —— 于是 BUG-850 的碰撞原样回来了。真正的判据是「隔壁
// 是不是也有注音」：悬出到普通文字上没问题，悬到另一条读音上就是糊。
//
// 语料取自 2026-08-28 对「明鏡国語辞典 第三版」term_bank_1.json 的实测（205,702 个
// ruby 元素里有 7,832 处紧邻 ruby 对），真实样本：
//   曲学(きょくがく) + 阿世(あせい)      ← 四字熟語，两个独立 <ruby> 直接相邻
//   阿諛(あゆ) + 追従(ついしょう)
//   外国(がいこく) + 語(ご)
// 对照组取同一份数据里的整词 ruby（灰白色/かいはくしょく）与被助词隔开的相邻词。
//
// 本文件 EXECUTE 真正的 popup.js postProcessRuby，不做字符串匹配。把
// markTouchingRubyUnits 的判据改坏（例如恒返回 true / 恒返回 false / 忽略中间文本）
// 都会让这里变红。
//
// Run: node fushi/test/pages/popup_glossary_ruby_touching_units_test.js
// (also driven from popup_glossary_ruby_touching_units_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

// ---- 最小可信 DOM ---------------------------------------------------------
// 只实现 postProcessRuby / markTouchingRubyUnits 真正会碰的原语：childNodes、
// nextSibling、parentNode、nodeType、textContent、classList、querySelectorAll('.cls')。
// 刻意不提供 Range / :scope —— 生产代码若哪天回退到依赖它们，这里会立刻发现。
function siblingOf(node, delta) {
  const p = node.parentNode;
  if (!p) return null;
  const i = p.childNodes.indexOf(node);
  if (i < 0) return null;
  return p.childNodes[i + delta] || null;
}
function adopt(parent, node) {
  if (node.parentNode) {
    const old = node.parentNode.childNodes;
    const i = old.indexOf(node);
    if (i >= 0) old.splice(i, 1);
  }
  node.parentNode = parent;
}
function mkText(text) {
  return {
    nodeType: 3,
    _text: String(text),
    parentNode: null,
    childNodes: [],
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); },
    get nextSibling() { return siblingOf(this, 1); },
    replaceWith(...nodes) {
      const p = this.parentNode;
      const i = p.childNodes.indexOf(this);
      for (const n of nodes) adopt(p, n);
      p.childNodes.splice(i, 1, ...nodes);
      this.parentNode = null;
    },
  };
}
function mkEl(tag) {
  const el = {
    nodeType: 1,
    tagName: String(tag || 'div').toUpperCase(),
    _className: '',
    style: {},
    attributes: {},
    childNodes: [],
    parentNode: null,
    classList: {
      _s: new Set(),
      add(n) { this._s.add(n); el._className = [...this._s].join(' '); },
      remove(n) { this._s.delete(n); el._className = [...this._s].join(' '); },
      contains(n) { return this._s.has(n); },
    },
    get className() { return this._className; },
    set className(v) {
      this._className = String(v);
      this.classList._s = new Set(String(v).split(/\s+/).filter(Boolean));
    },
    get nextSibling() { return siblingOf(this, 1); },
    get firstChild() { return this.childNodes[0] || null; },
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    set textContent(v) {
      for (const c of this.childNodes) c.parentNode = null;
      this.childNodes = [];
      this.appendChild(mkText(v));
    },
    appendChild(n) { adopt(this, n); this.childNodes.push(n); return n; },
    insertBefore(n, ref) {
      adopt(this, n);
      const i = ref ? this.childNodes.indexOf(ref) : this.childNodes.length;
      this.childNodes.splice(i < 0 ? this.childNodes.length : i, 0, n);
      return n;
    },
    replaceWith(...nodes) {
      const p = this.parentNode;
      const i = p.childNodes.indexOf(this);
      for (const n of nodes) adopt(p, n);
      p.childNodes.splice(i, 1, ...nodes);
      this.parentNode = null;
    },
    setAttribute(k, v) {
      this.attributes[k] = String(v);
      if (k === 'class') this.className = String(v);
    },
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(this.attributes, k)
        ? this.attributes[k] : null;
    },
    addEventListener() {},
    closest() { return null; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; },
    // 支持 `tag`、`.cls`、`tag.cls`、逗号列表、后代组合子 —— 够 postProcessRuby
    // 的 `.glossary-content ruby, .expression ruby` 与 `.ruby-unit` 用。
    querySelectorAll(sel) {
      const groups = String(sel).split(',').map((g) =>
        g.trim().split(/\s+/).filter(Boolean).map((tok) => {
          const parts = tok.split('.');
          const tag = parts[0] ? parts[0].toUpperCase() : null;
          return { tag: (!tag || tag === '*') ? null : tag, classes: parts.slice(1).filter(Boolean) };
        })).filter((g) => g.length > 0);
      const out = [];
      const matchSimple = (s, n) =>
        (s.tag === null || n.tagName === s.tag) &&
        s.classes.every((c) => n.classList.contains(c));
      const matchChain = (chain, node, ancestors) => {
        if (!matchSimple(chain[chain.length - 1], node)) return false;
        let ai = ancestors.length - 1;
        for (let ci = chain.length - 2; ci >= 0; ci--) {
          while (ai >= 0 && !matchSimple(chain[ci], ancestors[ai])) ai--;
          if (ai < 0) return false;
          ai--;
        }
        return true;
      };
      const walk = (n, ancestors) => {
        for (const c of (n.childNodes || [])) {
          if (c.nodeType !== 1) continue;
          if (groups.some((chain) => matchChain(chain, c, ancestors))) out.push(c);
          walk(c, ancestors.concat([c]));
        }
      };
      walk(this, [this]);
      return out;
    },
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
  };
  return el;
}

const documentObj = {
  createElement: (t) => mkEl(t),
  createTextNode: (t) => mkText(t),
  createDocumentFragment() { const f = mkEl('documentfragment'); return f; },
  documentElement: { style: {}, classList: mkEl().classList },
  head: { appendChild() {} },
  body: mkEl('body'),
  getElementById() { return null; },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  addEventListener() {},
};
const windowObj = {
  flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
  getSelection() { return { toString() { return ''; } }; },
};
documentObj.defaultView = windowObj;
const sandbox = {
  Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
  Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, String, Number, console,
  performance: { now() { return 0; } },
  setTimeout, clearTimeout,
  DOMParser: class { parseFromString() { return { body: mkEl('body'), querySelectorAll() { return []; } }; } },
  document: documentObj,
  window: windowObj,
  getComputedStyle() { return {}; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(source + '\n;window.__t = { post: postProcessRuby };', sandbox, {
  filename: 'popup.js',
});

// ---- 语料构造 -------------------------------------------------------------
/// `<ruby><span>基字</span><rt><span>读音</span></rt></ruby>` —— 明鏡释义正文的真实
/// 形状（元素基字，BUG-733）。
function mkRuby(base, reading) {
  const ruby = mkEl('ruby');
  const rb = mkEl('span');
  rb.appendChild(mkText(base));
  ruby.appendChild(rb);
  const rt = mkEl('rt');
  rt.appendChild(mkText(reading));
  ruby.appendChild(rt);
  return ruby;
}
/// 注音缺失的 ruby（只有基字），用于验证「没读音就不该被算作会碰撞的邻居」。
function mkBareRuby(base) {
  const ruby = mkEl('ruby');
  const rb = mkEl('span');
  rb.appendChild(mkText(base));
  ruby.appendChild(rb);
  return ruby;
}

function run(nodes) {
  const gloss = mkEl('div');
  gloss.classList.add('glossary-content');
  for (const n of nodes) gloss.appendChild(n);
  sandbox.window.__t.post(gloss);
  return gloss.querySelectorAll('.ruby-unit');
}
const tightOf = (units) => units.map((u) => u.classList.contains('ruby-tight'));
const textOf = (units) => units.map((u) => {
  // 单元文本要剔掉 .ruby-reserve 孪生体与 .ruby-rt，只留基字，便于断言定位。
  const keep = u.childNodes.filter((c) =>
    !(c.nodeType === 1 && (c.classList.contains('ruby-reserve') || c.classList.contains('ruby-rt'))));
  return keep.map((c) => c.textContent).join('');
});

let checks = 0;
function check(label, fn) { fn(); checks++; console.log('  ok - ' + label); }

// ① 明鏡实测语料：曲学(きょくがく) + 阿世(あせい)，两个独立 <ruby> 直接相邻。
check('adjacent <ruby> pair (曲学阿世) marks BOTH units tight', () => {
  const units = run([mkRuby('曲学', 'きょくがく'), mkRuby('阿世', 'あせい')]);
  assert.deepStrictEqual(textOf(units), ['曲学', '阿世']);
  assert.deepStrictEqual(tightOf(units), [true, true],
    '紧邻的两条读音会相碰，两侧都必须恢复横向预留（BUG-850 的场景）');
});

// ② 阿諛(あゆ) + 追従(ついしょう) —— 只有后者读音超宽，仍然两侧都标（孪生体是
//    max-content，读音不比基字宽时撑不开单元，标了等于没标）。
check('adjacent pair marks both even when only one reading overflows', () => {
  const units = run([mkRuby('阿諛', 'あゆ'), mkRuby('追従', 'ついしょう')]);
  assert.deepStrictEqual(tightOf(units), [true, true]);
});

// ③ 对照组：中间隔着助词「の」→ 悬出到普通文字上是被允许的（BUG-1778），不得标记。
check('units separated by plain text stay untagged (BUG-1778 overhang kept)', () => {
  const units = run([mkRuby('展開', 'てんかい'), mkText('の'), mkRuby('心理', 'しんり')]);
  assert.deepStrictEqual(textOf(units), ['展開', '心理']);
  assert.deepStrictEqual(tightOf(units), [false, false],
    '中间有普通文字时注音各自悬出即可，撑宽正文正是 BUG-1778 报的问题');
});

// ④ 空白不算内容：换行/缩进不该让两个真正相邻的单元逃掉标记。
check('whitespace-only text between units still counts as touching', () => {
  const units = run([mkRuby('外国', 'がいこく'), mkText('\n  '), mkRuby('語', 'ご')]);
  assert.deepStrictEqual(tightOf(units), [true, true]);
});

// ⑤ 同一个 <ruby> 内的逐字多基字（小学館形状，BUG-722）也必须判为相邻。
check('multi-base ruby inside ONE <ruby> (将棋) marks units tight', () => {
  const ruby = mkEl('ruby');
  const b1 = mkEl('span'); b1.appendChild(mkText('将')); ruby.appendChild(b1);
  const t1 = mkEl('rt'); t1.appendChild(mkText('しょう')); ruby.appendChild(t1);
  const b2 = mkEl('span'); b2.appendChild(mkText('棋')); ruby.appendChild(b2);
  const t2 = mkEl('rt'); t2.appendChild(mkText('ぎ')); ruby.appendChild(t2);
  const units = run([ruby]);
  assert.deepStrictEqual(textOf(units), ['将', '棋']);
  assert.deepStrictEqual(tightOf(units), [true, true]);
});

// ⑥ 没有读音的邻居不会溢出，不该把它拉进来。
check('a reading-less neighbour is not treated as a collision partner', () => {
  const units = run([mkRuby('灰白色', 'かいはくしょく'), mkBareRuby('体')]);
  assert.strictEqual(units.length, 2);
  assert.deepStrictEqual(tightOf(units), [false, false],
    '隔壁没有注音就撞不上，此时保持 BUG-1778 的紧凑悬出');
});

// ⑦ 单独一个整词 ruby（灰白色/かいはくしょく，读音比基字宽）不标记：它只会悬到
//    普通文字上，这正是 BUG-1778 要保住的行为。
check('a lone wide-reading unit stays untagged', () => {
  const units = run([mkText('の'), mkRuby('灰白色', 'かいはくしょく'), mkText('と')]);
  assert.deepStrictEqual(tightOf(units), [false]);
});

// ⑧ 幂等：postProcessRuby 会对 entry 0 走两遍（BUG-1098），第二遍不得改变结论，
//    也不得把已有单元再包一层。
check('second postProcessRuby pass is idempotent', () => {
  const gloss = mkEl('div');
  gloss.classList.add('glossary-content');
  gloss.appendChild(mkRuby('曲学', 'きょくがく'));
  gloss.appendChild(mkRuby('阿世', 'あせい'));
  sandbox.window.__t.post(gloss);
  const first = gloss.querySelectorAll('.ruby-unit');
  sandbox.window.__t.post(gloss);
  const second = gloss.querySelectorAll('.ruby-unit');
  assert.strictEqual(second.length, first.length, '重复 post 不得增加 .ruby-unit');
  assert.deepStrictEqual(tightOf(second), [true, true]);
});

console.log('all assertions passed (' + checks + ' checks)');
