## BUG-4188 · 同步冲突页只有重复笔记时右上角「全部确认」是一颗灰掉点不动的按钮
- **报告**：2026-11-05（用户：应用内反馈 IBjxAjty39，macOS 3.3.0-debug.23876；「同步冲突右上角按钮无法点击」，截图页上只有「可能重复的笔记」一节）
- **真实性**：✅ 真 bug（交互缺陷）。`fushi/lib/src/pages/implementations/srs/srs_conflicts_page.dart:376`（develop 9eae475329）：「全部确认」只作用于字段冲突（`_conflicts`），没有字段冲突时 `onPressed: null`，按钮照样画在顶栏、灰掉。页上只剩重复笔记 / 待删除 / 待确认时，用户看到的就是一颗点不动的按钮。
- **[x] ① 已修复** — 没有字段冲突时不画这颗按钮（MD3 顶栏与 Apple 导航栏同一判据）；其余几节各有逐条按钮。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_conflicts_duplicates_test.dart`（只有重复笔记：按钮不存在，MD3 / Apple 各一遍）；`fushi/test/srs/srs_device_names_test.dart`（有字段冲突：按钮存在）。
- **备注**：同一份日志里 `SrsConflictsPage` 期间 `SELECT srs_field_edits` 29 次读 22.5 万行 / 441 MB，rss 冲到 1.7 GB 后进程没了（疑似闪退）——是另一条性能问题，未在本条处理。
