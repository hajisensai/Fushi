// PR #4508 审查：设计系统 Material ↔ Apple 翻转时 window.__fushiRefreshIcons 重盖已渲染
// 按钮的字形。Material 下 __fushiPaintMineGlyph 画文本标记并删掉制卡按钮的 data-icon，
// 只按 [data-icon] 找会把制卡按钮漏掉，Material → Apple 后它停在文本 '+' / '✓'；远端词典
// 角标没有 data-icon，同样要按当前设计系统重建。本测试切出 popup.js 图标段真跑。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const POPUP_JS = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

function sliceBetween(src, startAnchor, endAnchor) {
  const start = src.indexOf(startAnchor);
  assert.ok(start >= 0, `切片锚失效：找不到 ${startAnchor}`);
  const end = src.indexOf(endAnchor, start);
  assert.ok(end > start, `切片锚失效：${startAnchor} 之后找不到 ${endAnchor}`);
  return src.slice(start, end);
}

class FakeClassList {
  constructor(names) { this.set = new Set(names); }
  contains(name) { return this.set.has(name); }
  toggle(name, on) { if (on) this.set.add(name); else this.set.delete(name); }
}

function fakeElement(classes, dataset) {
  const node = {
    classList: new FakeClassList(classes),
    dataset: { ...dataset },
    innerHTML: '',
    textContent: '',
    replacedWith: null,
    replaceWith(next) { node.replacedWith = next; },
  };
  return node;
}

function load() {
  const nodes = [];
  const container = fakeElement([], {});
  container.querySelectorAll = (selector) => {
    if (selector === '.dict-remote-glyph') {
      return nodes.filter((n) => n.classList.contains('dict-remote-glyph'));
    }
    assert.equal(selector, '[data-icon], [data-mine-glyph]');
    return nodes.filter((n) => n.dataset.icon !== undefined || n.dataset.mineGlyph !== undefined);
  };
  const document = {
    documentElement: fakeElement([], {}),
    getElementById: (id) => (id === 'entries-container' ? container : null),
  };
  const window = {};
  const ctx = vm.createContext({
    window,
    document,
    __fushiRemoteDictGlyph: () => ({ rebuiltApple: container.classList.contains('fushi-apple') }),
  });
  vm.runInContext(sliceBetween(POPUP_JS, 'function __fushiContainer()', '\n'), ctx);
  vm.runInContext(sliceBetween(POPUP_JS, 'const ICON_PATHS = {', 'function toHiragana('), ctx);
  const setApple = (on) => {
    container.classList.toggle('fushi-glass-host', on);
    container.classList.toggle('fushi-apple', on);
  };
  return {
    nodes,
    setApple,
    paintMine: vm.runInContext('__fushiPaintMineGlyph', ctx),
    refresh: () => window.__fushiRefreshIcons(),
  };
}

test('Material → Apple：已画成文本 + 的制卡按钮被重盖成 SF 字形', () => {
  const h = load();
  const mine = fakeElement(['inline-action-button', 'mine-button'], { mineGlyph: 'add' });
  h.nodes.push(mine);
  h.paintMine(mine);
  assert.equal(mine.textContent, '+');
  assert.equal(mine.dataset.icon, undefined);

  h.setApple(true);
  h.refresh();
  assert.equal(mine.dataset.icon, 'add');
  assert.match(mine.innerHTML, /fushi-sf-icon/);
});

test('Apple → Material：制卡按钮回到文本标记，✓ 状态保留', () => {
  const h = load();
  h.setApple(true);
  const mine = fakeElement(['inline-action-button', 'mine-button'], { mineGlyph: 'mined' });
  h.nodes.push(mine);
  h.paintMine(mine);
  assert.equal(mine.dataset.icon, 'mined');

  h.setApple(false);
  h.refresh();
  assert.equal(mine.textContent, '✓');
  assert.equal(mine.dataset.icon, undefined);
});

test('普通动作按钮与远端词典角标随翻转重建', () => {
  const h = load();
  const audio = fakeElement(['inline-action-button'], { icon: 'audio' });
  const remote = fakeElement(['dict-remote-glyph'], {});
  h.nodes.push(audio, remote);

  h.setApple(true);
  h.refresh();
  assert.match(audio.innerHTML, /fushi-sf-icon/);
  assert.deepEqual({ ...remote.replacedWith }, { rebuiltApple: true });
});
