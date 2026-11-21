## BUG-4953 · iOS 装新版时旧进程被系统结束，下次启动误报「意外退出」闪退
- **报告**：2026-11-21（用户：应用内反馈 QL5TsHwY78，iPhone18,3 / iOS 27.2，TestFlight 调试包）
- **真实性**：✅ 真 bug（误报）。上次进程 3.3.0-debug.27417 启动、进 resumed 后被结束，没有 MetricKit 负载；约 100 秒后启动的已是 3.3.0-debug.27714。根因 `fushi/lib/src/diagnostics/previous_exit_log.dart:539`（修复前的 `describeUncleanPreviousSession` 兜底分支）：iOS / macOS 装新版时由系统结束旧进程、平台不留原因（不像 Android 有 `PACKAGE_UPDATED`→`appUpdated`），会话标记停在 resumed，就一律判成 `unexpected`（停在前台时没了，疑似闪退）并弹闪退报告。标记里明明记着上次进程的版本，却从没和本次版本比较。
- **[x] ① 已修复** — `describeUncleanPreviousSession` 新增 `currentVersion`，`PreviousExitLog.collect` 传入本次版本；上次标记版本与本次版本都已知（非空、非 `kUnknownSessionVersion`）且不同时归 `PreviousExitKind.appUpdated`（不上报、只进诊断段）。MetricKit / `.ips` / Android `CRASH*` 等崩溃证据按 `classifyPreviousExit` 的优先级照常压过它。`'unknown'` 占位抽成 `kUnknownSessionVersion` + `knownSessionVersion()`。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：「BUG-4953：上次进程之后装了新版本…」（版本变了→appUpdated 不上报；有崩溃证据仍上报；同版本 / 任一侧未知仍为 unexpected）与「BUG-4953：iOS 收集链路…」（走 `PreviousExitLog.collect(isIOS: true)` 端到端）。
- **备注**：代价是「旧版本真崩溃、没留 MetricKit / .ips，用户随后装了新版才再打开」会被归为更新、不再弹报告；那次崩溃属于已被替换的旧版本，取舍与 Android `PACKAGE_UPDATED` 一致。
