## BUG-5095 · text-to-epub-implied-body
- **报告**：2026-11-22（来源：Codex 2026-11-21 PR 审查 HBK-AUDIT-003，PR #3738）
- **真实性**：✅ 真 bug。HTML 允许省略 `<body>`（及 `<head>`）标签，这类文件恰好也是良构 XML 时走 XML 路径：`packages/fushi_engine/lib/media/audiobook/text_to_epub.dart:224`（修前，`_htmlBlocks`）找不到 `<body>` 元素、根又是 `<html>`，直接返回空节点列表，`_splitIntoChapters` 再兜底成 `<p></p>`，浏览器能正常显示的 HTML 导成一本空书。
- **[x] ① 已修复** — `_htmlBlocks` 的 XML 路径改由 `_xmlBodyNodes` 按 HTML 的 body 规则取正文：有 `<body>` 取其子节点；否则复刻 HTML5 树构建的隐含 body 判定（正文开始前跳过 `<head>`、注释、空白与 head 专属元素 title/meta/link/style/script 等，首个非空白文本或其他元素起全部归正文，中途的 `<head>` 只去标签留子节点；根不是 `<html>` 时根本身即内容）。XML 路径继续保住 `<a id="x"/>` 自闭合锚点。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/text_to_epub_test.dart`：省略 `<body>`（内容 + `<a id/>` 锚点 + 不带 title/style）、省略 `<head>` 和 `<body>`（正文精确比对）、无 `<html>` 的短章片段（锚点保留）。变异实测：撤掉修复后前两条变红。
- **备注**：HTML5 回退路径（不良构输入）本就由 html 解析器按同一规则定 body，未改。
