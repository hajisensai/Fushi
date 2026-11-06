## BUG-3945 · 应用内更新 / 安装新版本后误报「意外退出」
- **报告**：2026-11-01（应用内自动闪退报告：Windows 3PqGTEsweI / 9ZYafFWPky / hfzlMGXJWr / msySECp2Cy，macOS bY4NXr-B8u，Android 8z1tk0jEna / U_gWy3lDbx，另 jmgMk1gHG2 截图里的提示条）
- **真实性**：✅ 真 bug（误报）。
  - Windows：日志里旧进程最后一条都是 `WindowsInstaller.handoff` / `stageLauncher`，下一次启动 `windowsHandoff status=installed`。`WindowsInstaller.runAndExit`（`fushi/lib/src/utils/misc/platform_updater.dart:1147` 修前位置）交接完直接 `exit(0)`，没调 `PreviousExitLog.markCleanExit()`，会话标记停在 resumed/inactive → 下次启动判「停在前台时没了，疑似闪退」。
  - macOS：`MacInstaller.runAndExit`（同文件 `:2017` 修前位置）同样直接 `exit(0)`；bY4NXr-B8u 第二次是 3.1.0-22337 → 3.2.0-22671 的应用内替换。
  - Android：系统给的退出原因是 `PACKAGE_UPDATED`（`installPackageLI`），但 `androidExitKind`（`fushi/lib/src/diagnostics/previous_exit_log.dart:371` 附近）把它映射成 null（「不说明问题」），判定于是落回会话标记的 `unexpected`。
- **[x] ① 已修复** — 两个桌面安装交接在 `exit(0)` 前 `PreviousExitLog.markCleanExit()`；新增 `PreviousExitKind.appUpdated`（`PACKAGE_UPDATED` 映射到它，优先级排在会话标记推断之前，`worthReporting=false`）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_handoff_test.dart`「marks the session clean before exiting…」（真 `PreviousExitLog.collect` 起会话标记 → `WindowsInstaller.runAndExit` → 退出钩子里读标记 clean=true，下一次启动 `describeUncleanPreviousSession` 为 null）；`fushi/test/feedback/crash_report_test.dart`「Android 装新版本被系统停掉（PACKAGE_UPDATED）」。
- **备注**：被安装器强杀的**其他** Fushi 实例（hfzlMGXJWr 里的开发版 PID 2672）、bY4NXr-B8u 第一次（10-31 21:11 停在前台、无任何证据）不在本修复范围。
