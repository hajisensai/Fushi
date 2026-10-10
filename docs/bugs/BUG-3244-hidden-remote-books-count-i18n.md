## BUG-3244 · 已从本机移除的远端书设置项副标题硬拼条数未走 i18n
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2024，i18n 纪律）。根因 `fushi/lib/src/sync/sync_settings_schema.dart` `buildHiddenRemoteBooksItem`（原 :999-1004）副标题硬拼 `'$n · ${t.remote_hidden_books_hint}'`：数字没有量词 / 单位，语序也不能按语言调整，绕过了 Slang 文案。
- **[x] ① 已修复** — `05e9063536`：新 key `remote_hidden_books_hint_count`（经 `i18n_sync --add` 加到 17 个文件 + `dart run slang`），副标题抽成 `hiddenRemoteBooksSubtitle(int n)`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/hidden_remote_books_subtitle_test.dart`（中 / 英两种语言下副标题按文案拼、0 条只给说明）。
- **备注**：
