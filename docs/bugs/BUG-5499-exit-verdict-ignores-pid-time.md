## BUG-5499 · 退出判定不看 pid / 时间，存活进程的厂商告警转储压过真死因
- **报告**：2026-11-26（反馈 632O8xFQSV，HONOR ALI-AN00 / Android 15 / 3.3.0，误报「原生崩溃」）
- **真实性**：✅ 真 bug（误报）。同一 pid 7975 有两条 ExitInfo：23:36:28.404 的 `CRASH_NATIVE`（荣耀 debuggerd 对存活进程发的 vss 告警转储，之后 Dart 会话 28.501 才起来、34.057 还记了 resumed）与 23:36:36.626 的 `OTHER [KILL UID] MANAGE_EXTERNAL_STORAGE changed.`（真正死因，良性）。`fushi/lib/src/diagnostics/previous_exit_log.dart` `classifyPreviousExit` 只按 `PreviousExitKind` 枚举序取最靠前的种类，不看 pid 与时间，于是存活时的转储压过了 `permissionChanged`。
- **[x] ① 已修复** — `ExitReportEntry` 加 `pid` 与 `aliveAtMs`（Android ExitInfo 带 pid + 死亡时刻；会话标记条目带 pid + 最后一次生命周期时刻作存活证据）；新增 `isSupersededDeathRecord`：同一 pid 另有更晚的死亡记录、或会话标记在它之后仍记到生命周期的死亡记录不参与判定，摘要里标「同一进程之后仍在运行，不是死因」。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_evidence_test.dart`「BUG-5499」组。
- **备注**：总结里提到的「arm64 设备装了 armeabi 包、反馈上报的 abi 是 supportedAbis.first」不在本修复范围，要不要提示用户另行定夺（未改）。
