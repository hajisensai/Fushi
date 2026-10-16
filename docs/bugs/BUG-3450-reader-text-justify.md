## BUG-3450 · 两端对齐开关开启时正文不对齐（Standard Ebooks EPUB）
- **报告**：2026-10-16（应用内反馈，Android 2.10.0-debug.19013：「英语两侧对齐，对齐不准。有的书籍文件可以，用 standardebooks 里的 EPUB 总是不能对齐」，附截图：开关已开，英文正文行尾参差）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/reader/reader_content_styles.dart:572`（修复前）：`settings.enableTextJustification ? '' : 'text-align: start …'`——开关开时只是**不注入** `start`，全仓没有任何地方注入 `justify`）
- **[x] ① 已修复** — 开关开时在 `body` 规则注入 `text-align: justify !important;`（`reader_content_styles.dart` gridCss），提交见 PR
- **[x] ② 已加自动化测试** — CSS 生成器测试 `fushi/test/reader/reader_text_justify_bug3450_test.dart`（三种 view mode × 横竖排：开 → body 规则里恰有一条 justify、全 CSS 只此一处、无 start；关 → start / hanging-punctuation / line-break 原样、无 justify）；真 app 探针 `fushi/integration_test/reader_text_justify_probe_itest.dart`
- **备注**：开关开时仍不注入 hanging-punctuation / line-break（与修复前一致，见「待拍板」）。

### 根因

`text_justify` 开关（`reader_settings.dart:523`）只控制 gridCss 是否注入
`text-align: start; hanging-punctuation: allow-end; line-break: normal`。开关开时 gridCss 为空串，
正文对齐完全落回书自带 CSS：

- 书 CSS 给段落写了 `text-align: justify` 的（例如很多日文书、部分英文书）→ 看起来「有的书可以」；
- Standard Ebooks 的 `core.css` / `se.css` 只给标题、页眉、署名等写 center / right，**正文段落从不写
  text-align**（只有版权页小字是 justify）→ 段落继承初始值 `start`，开关开了也是左对齐、行尾参差。

已下载 standardebooks.org 的 *Pride and Prejudice* 核对其 CSS 确认。

### 修复与判据

开关开时注入 `text-align: justify !important`，**只挂在 `body` 规则上**（与关闭时的 `start` 同一层级），
靠继承下放到正文：

- 书里没写对齐、靠继承的段落 → 两端对齐（本 bug 的修复面）；
- 书里**显式**给元素写了 text-align 的（标题 / 页眉 center、署名 / 引文出处 right、诗行 / 版权页 left）
  是元素自己的声明，优先于继承值 → 原样保留，不被误伤；
- 末行按 `text-align-last: auto` 仍落在行首；
- 开关关：gridCss 字节不变。

### 验证

见 PR 正文（真 app 三种 view mode × 开 / 关，英文 SE 原书 + 日文竖排真书）。

### 待拍板

- 书 CSS **显式**写了 `p { text-align: left }` 的书，开关开时仍左对齐（要压过它只能对 `p` 下
  `!important`，会把书里 `p.center` 之类的显式居中一起压平）。
- 开关开时不注入 `hanging-punctuation: allow-end` 与 `line-break: normal`（BUG-2929 的行首禁则修复因此
  只在开关关时生效），这是修复前就有的行为，未改。
