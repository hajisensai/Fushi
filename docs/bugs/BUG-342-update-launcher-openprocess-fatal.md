## BUG-342 · 自更新 launcher OpenProcess(parent) 非 INVALID_PARAMETER 失败被当致命错误放弃安装
- **报告**：2026-06-20（board TODO-600；551 审计·低危；归 549 自更新链路）
- **真实性**：✅ 真 bug（沿真实代码路径确认），根因 `hibiki/windows/runner/update_launcher.cpp:307-321`（修前）
- **[x] ① 已修复** — commit 4e6026da3
- **[x] ② 已加自动化测试** — commit 4e6026da3（`hibiki/test/utils/misc/platform_updater_test.dart` 源码守卫）

### 根因
应用内自更新（Windows）：旧 app 下载新 Inno 安装器后，spawn 一个**分离进程** `hibiki_update_launcher.exe`
（`hibiki/lib/src/utils/misc/platform_updater.dart:400` `WindowsInstaller.runAndExit`），launcher 等当前 PID
退出后再启动 Inno，让安装器看到 AppMutex 已释放。launcher 是 detached 进程，父 app 启动它后立刻 `exit(0)`，
**从不读取 launcher 的退出码**——launcher 的唯一产物是写进 marker JSON 的字段，下次 app 启动 `reconcile()` 读出来判断更新成败。

`WaitForParentExit`（修前 `update_launcher.cpp:307-321`）用 `OpenProcess(SYNCHRONIZE, FALSE, parent_pid)` 拿一个
wait 句柄以 `WaitForSingleObject` 等旧进程退出。但失败处理只对 `ERROR_INVALID_PARAMETER`（87，PID 已不映射到活进程
= 旧进程已退出）容错继续；**其它任何 OpenProcess 失败（`ERROR_ACCESS_DENIED` 5 / 瞬时错误等）都走
`MarkLaunchFailed` + `return false` → `wWinMain` `return 3`，根本不启动 Inno，整条更新被无故放弃**。

OpenProcess 失败从来不能证明旧进程仍在运行；而 launcher 是分离进程退出码无人消费，这样静默丢弃一个已下载好的更新且无任何恢复路径。
属自更新链路的健壮性缺陷。

### 修复
`hibiki/windows/runner/update_launcher.cpp`：
- 抽纯函数 `ParentOpenFailureProvesExit(DWORD error)`（经 `ClassifyParentOpenFailure` 返回 `ParentOpenFailureOutcome`），
  把「错误码 → 是否证明已退出」的判定单列、可读可守卫。**只有 `ERROR_INVALID_PARAMETER` 证明旧进程已退出**
  （记 `parentExitObserved=true`）；其它错误码记 `parentExitObserved=false` + `parentOpenFailed` + `parentOpenError` 诊断。
- `WaitForParentExit` 改为 `void`，**任何 OpenProcess 失败都不再放弃安装**：落 marker 诊断后继续，
  让下游 `WaitForMutexReleased`（有界 mutex 释放轮询）+ Inno 自身的 AppMutex 守卫做真正的闸门。
- 真正的 wait 超时（旧进程满超时仍活）也只记 `parentExitTimedOut` 诊断后继续，不再 `MarkLaunchFailed`——
  放弃只会白白搁置已下载的更新；mutex 轮询与 AppMutex 仍是闸门。
- `wWinMain` 删掉 `if (!WaitForParentExit) return 3;` 死分支（`WaitForParentExit` 不再有致命出口）。
- `MarkLaunchFailed`/`LastErrorMessage` 仅保留给唯一真致命路径：`CreateProcess Inno` 连安装器进程都拉不起来（`return 4`）。
- 重构 `LastErrorMessage` 抽出 `FormatErrorMessage(DWORD error, action)`，使能用显式错误码（避免 `GetLastError()` 被覆盖）。

### 测试（最强可落地层 = Dart 源码扫描守卫）
`hibiki/test/utils/misc/platform_updater_test.dart` 新增守卫
「update launcher never abandons the install on an OpenProcess(parent) failure (TODO-600)」：
断言存在 `ParentOpenFailureProvesExit`/`ClassifyParentOpenFailure` + `ERROR_INVALID_PARAMETER`、`void WaitForParentExit`、
不再含 `return 3;` 与 `if (!WaitForParentExit`、`OpenProcess parent` 不再走 `MarkLaunchFailed`（仅 `CreateProcess Inno` 走）、
落 `parentOpenFailed`/`parentExitTimedOut` 诊断。本机 32 测试全绿（含本守卫），`update_handoff_test.dart` 19 绿无回归。
（C++ 涉 Windows 进程，无 native test 框架，沿用 549 的 Dart 源码守卫范式。）

### 仅真机/构建可验
ISCC + 真实 Windows 自更新端到端（无 ISCC/Win 构建于本机）：构造非标准安装目录、故意让 OpenProcess 返回
`ERROR_ACCESS_DENIED`/瞬时失败（如父进程已退出竞态），断言安装器仍被启动、更新装上。C++ 改动仅人工审 + Dart 守卫断言，
未经 MSVC 编译。
