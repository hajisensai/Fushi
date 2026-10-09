const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// HBK-AUDIT-021：词条头部按钮（未制卡 = primary、已制卡 duplicate = primaryContainer、最新 latest =
// tertiaryContainer……）自带语义底色。后置的通用 .inline-action-button 悬停 / 焦点 / 按下规则与默认
// 底色选择器同 specificity (0,3,1)，曾把 background-color 换成 currentColor 薄染：一交互就丢
// primary 底、只剩 onPrimary 白十字。这里按层叠规则逐条检查真源 popup.css（vendor 是字节镜像）。
const CSS = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.css'), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '');

function rules() {
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(CSS))) out.push({ selectors: m[1].split(',').map((s) => s.trim()), body: m[2] });
  return out;
}

for (const state of ['hover', 'focus-visible', 'active']) {
  test(`M3E ${state}：会改 background-color 的 .inline-action-button 状态规则必须排除头部按钮`, () => {
    let checked = 0;
    for (const r of rules()) {
      if (!/(^|;|\s)background-color\s*:/.test(r.body)) continue;
      for (const sel of r.selectors) {
        if (!sel.startsWith('html.fushi-m3e') || !sel.includes('.inline-action-button') || !sel.endsWith(':' + state)) continue;
        checked++;
        assert.ok(/:where\(:not\(\.header-buttons > \*\)\)/.test(sel),
          `${sel} 会盖掉头部按钮（未制卡 / duplicate / latest）的语义底色`);
      }
    }
    assert.ok(checked >= 1, '没找到通用状态规则：切片锚失效');
  });

  test(`M3E ${state}：头部按钮状态层只叠 background-image，不改 background-color`, () => {
    let found = 0;
    for (const r of rules()) {
      for (const sel of r.selectors) {
        if (sel.startsWith('html.fushi-m3e .header-buttons > .inline-action-button') && sel.endsWith(':' + state)) {
          found++;
          assert.match(r.body, /background-image\s*:/, sel);
          assert.doesNotMatch(r.body, /(^|;|\s)background-color\s*:/, sel);
        }
      }
    }
    assert.ok(found >= 1);
  });
}

test('未制卡 / duplicate / latest 的底色规则仍在（primary / primaryContainer / tertiaryContainer）', () => {
  assert.match(CSS, /html\.fushi-m3e \.header-buttons > \.mine-button:where\(:not\(\.duplicate\)\) \{[^}]*background-color: var\(--md-sys-color-primary\);/);
  assert.match(CSS, /html\.fushi-m3e \.header-buttons > \.mine-button\.duplicate \{[^}]*background-color: var\(--md-sys-color-primary-container\);/);
  assert.match(CSS, /html\.fushi-m3e \.header-buttons > \.mine-button\.latest \{[^}]*background-color: var\(--md-sys-color-tertiary-container\);/);
});
