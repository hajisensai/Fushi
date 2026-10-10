## BUG-3236 · 制卡词典 CSS 裁剪把 details[open] 等交互态属性规则裁掉
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2053）。根因 `packages/fushi_anki/lib/src/anki_glossary_css.dart` `_stripPseudos`（原 :148-194）只放宽伪类 / 伪元素，属性条件原样参与命中判断：导出时 `<details>` 关着、没有 `open` 属性，`details[open] .x` 一类规则命中不到就被裁掉，卡片上点开 details 后展开内容没有词典样式。
- **[x] ① 已修复** — 提交「fix(anki): relax interactive [open] conditions when slimming glossary CSS」：`_stripPseudos` 识别属性选择器，交互态属性（`_interactiveAttributes = {open}`，含 `[OPEN="" i]` 等写法）与 `:hover` 同样去掉后再判断命中；其它属性条件不放宽。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/anki_glossary_css_test.dart`「BUG-3236 交互态属性 [open] 放宽后判断」（未修复时红）。
- **备注**：
