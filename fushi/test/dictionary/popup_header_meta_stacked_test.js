// 用户 10-23：词头元数据列（频率 / 音调 / 词形标签）换到词头下方时要铺满整行。
// 本文件真执行 popup.js 里提取出的 `updateEntryHeaderMetaLayout`，用假尺寸驱动
// 「挂不挂 .meta-stacked」的判据：
//   * 词头 + 按钮组放得下、再加 14em 元数据列放不下 → 挂（元数据列独占下一行整宽）；
//   * 三者放得进一行 → 不挂（元数据列贴词头右侧）；
//   * 词头 + 按钮组本身放不下 → 不挂（按钮组整组换行，BUG-3320 的既有布局）；
//   * 弹窗拖宽后摘掉，判据不依赖类名本身（不会来回振荡）。
// 真实绘制（display:contents 后元数据列确实铺满）由 PR 里的 headless Chrome 截图证明。
//
// 运行：node fushi/test/dictionary/popup_header_meta_stacked_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'), 'utf8');

function extract(pattern, what) {
  const m = popupSrc.match(pattern);
  assert.ok(m, `popup.js 里找不到 ${what}`);
  return m[0];
}

const childFn = extract(
  /function entryHeaderChildByClass\(parent, className\) \{[\s\S]*?\n\}/,
  'entryHeaderChildByClass');
const updateFn = extract(
  /function updateEntryHeaderMetaLayout\(header\) \{[\s\S]*?\n\}/,
  'updateEntryHeaderMetaLayout');

class FakeClassList {
  constructor(names) { this._set = new Set(names); }
  contains(n) { return this._set.has(n); }
  toggle(n, force) { if (force) this._set.add(n); else this._set.delete(n); }
}

class FakeEl {
  constructor(className, props = {}) {
    this.classList = new FakeClassList(className ? className.split(' ') : []);
    this.children = [];
    this.isConnected = true;
    this.clientWidth = 0;
    this.scrollWidth = 0;
    this.offsetWidth = 0;
    this.style = { columnGap: 'normal', fontSize: '16px' };
    Object.assign(this, props);
  }
  get firstElementChild() { return this.children[0] || null; }
  append(...kids) { this.children.push(...kids); return this; }
}

const context = {
  getComputedStyle: (e) => e.style,
};
vm.createContext(context);
vm.runInContext(`${childFn}\n${updateFn}\nthis.update = updateEntryHeaderMetaLayout;`, context);

// M3E 词头：行 gap 12、左簇 gap 12、元数据列 16px → 14em = 224。
function buildHeader({ row, headword, buttons }) {
  const headwordEl = new FakeEl('expression-scroll', { scrollWidth: headword });
  const meta = new FakeEl('entry-header-meta');
  const main = new FakeEl('entry-header-main').append(headwordEl, meta);
  main.style = { columnGap: '12px', fontSize: '16px' };
  const buttonsEl = new FakeEl('header-buttons', { offsetWidth: buttons });
  const header = new FakeEl('entry-header', { clientWidth: row }).append(main, buttonsEl);
  header.style = { columnGap: '12px', fontSize: '16px' };
  return header;
}

const stacked = (h) => h.classList.contains('meta-stacked');

// 用户截图的窄弹窗：168 + 12 + 176 = 356 ≤ 360，再加 12 + 224 放不下。
const narrow = buildHeader({ row: 360, headword: 168, buttons: 176 });
context.update(narrow);
assert.strictEqual(stacked(narrow), true, '窄弹窗：元数据列应铺满词头下方整行');

// 拖宽到三者放得进一行：摘掉，回到贴词头右侧。
narrow.clientWidth = 640;
context.update(narrow);
assert.strictEqual(stacked(narrow), false, '宽弹窗：元数据列应回到词头右侧');

// 再拖窄：判据不看类名，重新挂上。
narrow.clientWidth = 360;
context.update(narrow);
assert.strictEqual(stacked(narrow), true, '再拖窄应重新挂上');

// 词头 + 按钮组本身放不下：保持原布局（按钮组整组换行）。
const tooNarrow = buildHeader({ row: 300, headword: 168, buttons: 176 });
context.update(tooNarrow);
assert.strictEqual(stacked(tooNarrow), false, '按钮组都要换行时不拆左簇');

// 没有元数据列：什么也不做。
const noMeta = buildHeader({ row: 360, headword: 168, buttons: 176 });
noMeta.children[0].children.pop();
context.update(noMeta);
assert.strictEqual(stacked(noMeta), false, '无元数据列不挂类名');

// 未渲染（content-visibility 跳过 / 不在文档里）宽度为 0：不改动。
const unrendered = buildHeader({ row: 0, headword: 168, buttons: 176 });
context.update(unrendered);
assert.strictEqual(stacked(unrendered), false, '宽度 0 不判定');

console.log('all assertions passed');
