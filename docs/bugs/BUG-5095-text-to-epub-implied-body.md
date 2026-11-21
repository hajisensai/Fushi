## BUG-5095 · text-to-epub-implied-body
- **报告**：2026-11-22（来源：Codex 2026-11-21 PR 审查 HBK-AUDIT-003，PR #3738）
- **真实性**：✅ 真 bug。HTML 允许省略 `<body>`（及 `<head>`）标签，这类文件恰好也是良构 XML 时走 XML 路径：`packages/fushi_engine/lib/media/audiobook/text_to_epub.dart:224`（修前，`_htmlBlocks`）找不到 `<body>` 元素、根又是 `<html>`，直接返回空节点列表，`_splitIntoChapters` 再兜底成 `<p></p>`，浏览器能正常显示的 HTML 导成一本空书。
- **[x] ① 已修复** — `_htmlBlocks` 的 XML 路径改由 `_xmlBodyNodes` 按 HTML5 树构建定 body 的规则取正文，与不良构输入走的 HTML5 解析器结论一致：`<html>`/`<head>`/`<body>` 三个标签本身都不进正文，只按文档顺序判定它们里面的节点——正文开始前空白文本与 head 专属元素（title/meta/link/style/script/noframes 等）归 head，首个非空白文本、其他元素或 `<body>` 标签开始正文，此后（含 `<body>` 前、`</body>` 后、`<head>` 里非 head 元素起）全归正文；注释 / 处理指令 / doctype 不进正文。XML 路径继续保住 `<a id="x"/>` 自闭合锚点。
  - 审查补修（PR #4048 复核）：初版只补了「找不到 `<body>`」一支，`<body>` 在场时仍只取其子节点，`<body>` 前 / `</body>` 后 / `<head>` 里的正文仍会丢，`<noframes>` 也与 HTML5 不一致；改成上面这条统一规则，逐例与 `package:html` 的 `parse(...).body` 对照过。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/text_to_epub_test.dart`：省略 `<body>`（内容 + `<a id/>` 锚点 + 不带 title/style）、省略 `<head>` 和 `<body>`（正文精确比对）、无 `<html>` 的短章片段（锚点保留）、`<body>` 标签外的正文（期望值先由 HTML5 解析器核对）。
- **备注**：HTML5 回退路径（不良构输入）本就由 html 解析器按同一规则定 body，未改。
