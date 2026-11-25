## BUG-5183 · ColorOS 改应用权限时系统按 uid 结束进程，下次启动误报「意外退出」
- **报告**：2026-11-22（应用内反馈 4u4HnlOcv2：OnePlus ColorOS 15 / Android 15，启动约 0.5 秒后进程没了，下次启动弹闪退报告）
- **真实性**：✅ 真 bug（误报）。日志里 `Process.androidExitInfo reason=OTHER status=0 importance=100`，描述 `[KILL UID] Permission related app op changed`，没有任何 Dart / Java / 原生栈。`fushi/lib/src/diagnostics/previous_exit_log.dart:656` 的 `_aospKillUidOpChanged` 只认「全大写 appop 名 + changed」，这串匹配不上，`androidExitKind`（同文件 `OTHER` 分支）返回 null，退回会话标记（前台 resumed）→ `PreviousExitKind.unexpected`。AOSP 源码里没查到这串描述，按观测到的厂商形态收。
- **[x] ① 已修复** — `_aospKillUidOpChanged` 收进整串 `Permission related app op changed`（整串锚定、区分大小写、子原因前缀可缺），归 `PreviousExitKind.permissionChanged`；不放宽成任意 `[KILL UID] …`，`malware` 等其它子原因照旧分开判。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`「androidExitKind：OTHER 只认锚定的 AOSP「[KILL UID] <OP> changed」形态」：这串 → `permissionChanged`；小写变体、带后缀、带前缀、`Other related app op changed` 都不认；`[KILL UID] malware` 仍是 `securityKilled`。变异实测：还原正则后该用例红，恢复后绿。
- **备注**：反馈 4u4HnlOcv2。
