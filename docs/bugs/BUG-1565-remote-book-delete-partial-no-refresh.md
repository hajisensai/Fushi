## BUG-1565 · 远端书删除半成功不刷新列表：书已删仍留幽灵卡，提示语与实情相反
- **报告**：2026-08-12（用户：互联 UI 层审计）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:287-304`（旧行号）：删除远端书是**两次**远端调用（`deleteRemoteBook` + 有声书的 `deleteRemoteAudiobook`），旧实现只有一个 `failed` 布尔。书删成功、有声书删失败时，它弹 `t.remote_delete_failed`（「无法在对端设备上删除」）并直接 `return` 不调 `_forceRefreshRemoteBooks()`——两句都与实情相反：书其实已从 host 消失，列表不刷新就留一张点了必 404 的幽灵卡，而提示语告诉用户「没删掉」。
- **[x] ① 已修复** — 分别记账 `bookDeleted` / `audiobookFailed`（`remote.part.dart:278` 起）：书删掉了就刷新列表（哪怕有声书失败）；`remote_delete_failed` 只留给书本身没删掉的情形；半成功走新文案 `remote_delete_audiobook_partial`（经 `fushi/tool/i18n_sync.dart --add` 落 17 语言 + `dart run slang`）。随本轮 `fix(interconnect)` 提交。
- **[x] ② 已加自动化测试** — `fushi/test/sync/remote_book_delete_partial_test.dart`：函数体守卫（分别记账、`if (bookDeleted) _forceRefreshRemoteBooks();` 且刷新先于失败早退、两种文案分流）+ 17 语言 key 齐全。
- **备注**：删除身份键仍统一用 `RemoteBookInfo.downloadId`（BUG-414 纪律），本次未动。
