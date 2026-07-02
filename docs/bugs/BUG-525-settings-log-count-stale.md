## BUG-525 · 清除日志后系统页计数不刷新
- **报告**：2026-07-02（用户：macOS 手动测试“清除错误日志”）
- **真实性**：✅ 真 bug。Computer Use 复现：设置 → 系统 → 错误日志 (5) → 清除后错误日志页显示 `错误日志 (0)`，返回系统详情页仍显示 `错误日志 (5)`。
- **[x] ① 已修复** — 根因是窄屏设置详情页通过 `SettingsDetailPage(destination: destination)` 持有进入页面时的 `SettingsDestination` 快照，`diagnostics.error_log` 的标题字符串在清除前已冻结；日志服务通知不会让已 push 的详情页重新从 schema 取动态标题。修复：`hibiki/lib/src/settings/settings_detail_page.dart:50` 监听 `ErrorLogService` / `DebugLogService`，并在 build 时按 id 从 `buildSettingsSchema()` 取 fresh destination，找不到同 id 时保留合成详情页原对象。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/settings_renderer_test.dart:638` 新增 `pushed settings detail refreshes dynamic log row counts`，先渲染 `Error Log (1)`，调用 `ErrorLogService.clear()` 后断言旧标题消失、新标题变为 `Error Log (0)`。
- **备注**：修复提交：本提交。
