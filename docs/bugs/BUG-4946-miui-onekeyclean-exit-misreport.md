## BUG-4946 · 小米 MIUI / HyperOS 一键清理（OneKeyClean）被误报为闪退
- **报告**：2026-11-21（应用内崩溃报告：反馈 PojVLNyNtZ，Xiaomi 22041219G，SDK 34，3.3.0）
- **真实性**：✅ 真 bug，沿代码路径确认。反馈日志里同 pid 的 `ApplicationExitInfo` 是 `reason=OTHER description=OneKeyClean importance=125`（MIUI / HyperOS 一键清理 / 最近任务「全部清除」结束应用；死时在跑前台服务），应用并没有崩，却弹了「意外退出」报告。
  - 根因：`fushi/lib/src/diagnostics/previous_exit_log.dart:633`（修复前）厂商停应用形态表 `_vendorStopDescriptions` 只收了 OPlus `o-stop`、MIUI `SwipeUpClean`、`ScreenOffCPUCheckKill`，`OneKeyClean` 不命中 → `androidExitKind` 返回 null → `classifyPreviousExit` 只剩会话标记推断（125 + 标记停在前台）→ `PreviousExitKind.unexpected` → 上报。BUG-4729 修 `SwipeUpClean` 时明确把 `OneKeyClean` 留在范围外，测试还钉成了 null。
- **[x] ① 已修复** — `previous_exit_log.dart` 新增整串锚定的 `_miuiOneKeyClean`（`^(?:\[[A-Z0-9_ ]+\] )?OneKeyClean$`）并加入 `_vendorStopDescriptions`，`OTHER` + `OneKeyClean` → `PreviousExitKind.vendorStopped`（`worthReporting` 恒 false，低于 crash / ANR / 内存回收）。只看 `OTHER`，其它原因码带这段文字不改判。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：经真 `PreviousExitLog.collect` + `classifyPreviousExit`，`OneKeyClean` / `[UNKNOWN] OneKeyClean` + importance=125 × 标记 `resumed` / `inactive` / `paused` 均判 `vendorStopped` 不上报、摘要保留描述；同一启动另有 `CRASH` 时仍判 crash 上报；`androidExitKind` 单测钉住锚定（后缀夹杂、大小写、小写前缀、非 `OTHER` 原因码均不改判）。原先断言 `OneKeyClean` → null 的两处改成别的非形态串。
- **备注**：真机未复测（需小米设备一键清理后重启）。
