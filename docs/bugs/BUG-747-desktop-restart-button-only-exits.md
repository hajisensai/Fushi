## BUG-747 · 桌面导入后点立即重启只退出不重启
- **报告**：2026-07-12（用户：多次报「导入后点重启没重启」）
- **真实性**：✅ 真 bug（既有行为）— 根因 `hibiki/lib/src/sync/sync_settings_schema/backup.part.dart` 的 `backupImportRestart()`：移动端走 `FlutterExitApp.exitApp()`，桌面端只 `exit(0)`——**只退出、不重新拉起**。按钮文案是「立即重启」，用户点了却只是关掉、要手动再开。
- **[x] ① 已修复** — 桌面分支在 `exit(0)` 前用 `Process.start(Platform.resolvedExecutable, [], mode: ProcessStartMode.detached)` 拉起一个 detached 新实例，实现真正重启；`try/catch` 兜底：拉起失败仍 `exit(0)`（never-break，不劣于旧的只退出）。移动端分支不变。
- **[x] ② 已加自动化测试** — 更新源码守卫 `hibiki/test/sync/backup_import_overlay_test.dart` 的 `backupImportRestart` 用例：仍断言 `FlutterExitApp.exitApp()` + `exit(0)`（never-break），新增断言桌面端含 `Process.start` + `ProcessStartMode.detached`（真重启）。
- **备注**：同轮修 [BUG-746](BUG-746-overwrite-import-rename-access-denied.md)（覆盖导入换名失败）。潜在风险：若 app 有单实例锁，detached 新实例与旧进程退出之间有极短竞态；实测 Hibiki 桌面无强单实例锁。真机复测：导入完成点「立即重启」应自动重开 app。
