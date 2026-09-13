## BUG-2515 · interconnect-manga-browse-raw-auth-error
- **报告**：2026-09-13（用户：漫画「来源」→「Fushi 互联」进去满屏 `SyncAuthError: Fushi server credentials not configured`，只有「重试」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/interconnect/interconnect_manga_browse_page.dart:150`（改前）错误态直接 `Text('$_error')`，绕过了 `sync_error_messages.dart:127` 已有的 `pairingNotConfigured → t.sync_err_not_paired` 本地化映射；且一台对端都没配对时「重试」永远不会成功，用户没有任何可操作出路。更上游的设计问题：来源页里「Fushi 互联」是一条无开关的直跳入口而不是来源开关（本轮一并重做成合集，见 `docs/specs/2026-09-13-interconnect-proxied-manga-sources.md`）。
- **[x] ① 已修复** — 错误态改走 `friendlySyncError`；`pairingNotConfigured` 时把「重试」换成「去配对」（推 `ModuleSettingsView(SettingsDestinationId.interconnect)`），回来自动重拉。浏览入口从来源页挪到发现页「浏览来源」卡片，来源页那行改成带开关的合集。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/interconnect_manga_browse_page_error_test.dart`：假 backend 抛 `pairingNotConfigured` → 断言本地化文案上屏、裸 `SyncAuthError:` 不出现、出「去配对」按钮不出「重试」；抛普通错误 → 出「重试」。
- **备注**：
