## BUG-2488 · Lapis来源模板更新残留前导空行
- **报告**：2026-09-10（用户截图：来源标题与作品链接之间仍有空行）
- **真实性**：✅ 真 bug。当前 Anki `Lapis/Mining/Back` 的 `.misc-info` 中仍有前导 `<br />`；上轮本地模板更新脚本仅移除了 Details 文本行。仓库 `packages/fushi_anki/lib/src/lapis_note_type.dart:264` 已同时删除该换行，问题来自已安装模板的更新遗漏。
- **[x] ① 已修复** — 对当前 Anki 模板备份、比较原值后仅删除该前导换行，并读回确认。没有修改笔记字段或复习记录。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/lapis_blocks_test.dart` 断言来源容器直接包含 MiscInfo 字段，仅允许排版空白，拒绝前导 HTML 换行。
- **备注**：本机备份位于忽略目录 `.codex-test/lapis-source-spacing-before.json`；刷新 Anki 卡面生效。
