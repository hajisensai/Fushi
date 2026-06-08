## BUG-160 · 同步服务器开关每次启动重置为关闭
- **报告**：2026-06-08
- **真实性**：✅ 真 bug
- **根因**：`hibiki/lib/src/sync/hibiki_server_controller.dart:125,130`
  — `start()` 的失败路径（`on SyncServerPortInUseException` 约 line 125 / 泛 `catch` 约 line 130）
  调用 `await repo.setServerEnabled(false)`，将用户的持久化"想开服"意图抹成 false。
  `serverEnabled` 同时被用作「用户意图」和「本次绑定成功」两个概念；
  端口被占用导致绑定失败时用户意图被永久清除，下次启动开关显示关闭。
- **[x] ① 已修复** — 删除两处失败路径中的 `await repo.setServerEnabled(false)`，
  绑定失败保留持久化意图，仅由用户显式关闭（`stop(persistDisabled: true)`）清除意图。
  注释更新说明新语义（BUG-160 / HBK-AUDIT-167 revised）。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/server_enabled_persist_test.dart`
  行为测试：占用端口使 `start()` 必然 PortInUse → 断言失败后 `repo.isServerEnabled()` 仍为 `true`。
  泛错误路径同样覆盖。先红（修复前 setServerEnabled(false) 被调用导致 false）后绿。
- **备注**：`stop(persistDisabled: true)` 语义不变（用户显式关闭仍清意图）；
  成功路径的 `setServerEnabled(true)` 保留；设置页会话级视觉回退（`_enabled=false`）不持久化，无需改动。
