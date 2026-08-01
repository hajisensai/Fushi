## BUG-1232 · 桌面关闭后 Mihon Java sidecar 残留
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。真实 Windows 调试包关闭 Hibiki PID 23988 后，其直接子进程 Java PID 39436 仍存活；`DesktopMihonRuntime.dispose()` 虽保留了精确 `Process` 并注册到 `ExitFlushRegistry`，但桌面点 X 最终走 `exit(0)` 快速终止，异步 Dart 清理不是 OS 级生命周期约束（`hibiki/lib/main.dart:684`、`hibiki/lib/src/media/manga/mihon/desktop_mihon_runtime.dart:224`）。
- **[x] ① 已修复** — Windows 启动 sidecar 后立即把该精确 PID 加入私有 Job Object，并设置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`；正常路径仍先调用带令牌的 `/stop`、等待并按所持 `Process` 兜底，进程快速退出或回调竞态时则由内核在 Hibiki 的 job handle 关闭后终止且只终止被明确加入的 JVM。若 job 创建/配置/分配失败，sidecar 启动直接失败，绝不降级成无约束外部进程；同时补上 `Process.start` 与 runtime dispose 并发时的启动后检查。
- **[x] ② 已加自动化测试** — `mihon_child_process_containment_test.dart` 启动 30 秒测试子进程，验证关闭 containment 后 2 秒内精确退出；`desktop_mihon_runtime_integration_test.dart` 实际启动随 Windows debug 包的 Java/M-Extension-Server，协商能力后 dispose，并用 PID 验证无残留。2026-07-29 本机两项均通过。
- **备注**：验真后只手工终止了本次 Hibiki PID 23988 对应的精确 Java PID 39436；未按端口或进程名清理其他 Java。
