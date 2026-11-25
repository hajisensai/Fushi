## BUG-4491 · 华为改所有文件访问权限后被系统结束报成意外退出
- **报告**：2026-11-15（应用内崩溃报告：反馈 w_dTs9eQ45）
- **真实性**：✅ 真 bug，在 upstream/develop 017cdcf 沿代码路径确认。华为 BLK-AL80 上报「意外退出」，附带日志里同一 pid 的 `ApplicationExitInfo` 是 `reason=OTHER importance=100 description: MANAGE_EXTERNAL_STORAGE changed.`——即用户在系统设置里改「所有文件访问权限」，系统 killUid 结束进程；但华为 `AppExitInfoTracker` 没加 AOSP 的 `[KILL UID]` 子原因前缀。
  - 根因：`fushi/lib/src/diagnostics/previous_exit_log.dart:582`（修复前 :580）`_aospKillUidOpChanged` 正则 `^\[KILL UID\] …` 强制要求前缀 → 匹配失败 → `androidExitKind` 返回 null → 只剩会话标记推断（resumed / importance 100）→ `unexpected` → 上报。BUG-4323 的修复只覆盖了带前缀的 AOSP 原生形态。
- **[x] ① 已修复** — 正则前缀改为可选：`^(?:\[KILL UID\] )?[A-Z][A-Z0-9_]* changed\.?$`，仍整串锚定、只认「全大写 appop 名 + changed」，厂商其它 OTHER 文本不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：经真 `PreviousExitLog.collect` + `classifyPreviousExit`，`OTHER + MANAGE_EXTERNAL_STORAGE changed.`（无前缀）+ 标记 resumed 判 permissionChanged 不上报；`androidExitKind` 单测补无前缀正例与小写 `settings changed.` 反例，原有前缀夹杂反例保留。
- **备注**：纯分类逻辑，无需真机。
