## BUG-2166 · 应用内更新静默失败：安装器被自己的 taskkill /T 连同祖先树一起杀掉，且被误诊为 app_mutex_running
- **报告**：2026-09-06（用户：应用内更新后仍是旧版，Fushi 报「Inno Setup reported that Fushi was still running」）
- **真实性**：✅ 真 bug。两处根因：
  - `fushi/windows/installer/fushi.iss:239` / `:251`（修复前的 `KillGracefully` / `KillImage`）—— `taskkill /IM <exe> /T`
  - `fushi/lib/src/utils/misc/update_handoff.dart:906`（修复前的 `summarizeWindowsInstallerFailure`）—— `lower.contains('mutex')`
  - `fushi/lib/src/utils/misc/update_handoff.dart` 的 `fromJson`/`toJson` —— 丢弃 C++ launcher 写入的键

### 现场证据（用户机，2026-09-06）

marker `%APPDATA%\Fushi\Fushi\updates\update-handoff.json`：

| 时刻 (UTC) | 事实 |
|---|---|
| 01:32:53.434 | app 写下交接标记，启动 `fushi_update_launcher.exe`（pid 7028，父 = fushi.exe 97348） |
| 01:34:53.517 | `parentExitObserved:false` —— 恰好 startedAt + 120.001s，即 `WaitForSingleObject` 跑满 `kParentExitTimeoutMs` |
| 01:35:03.752 | 又过 10.2s（= `kMutexReleaseTimeoutMs`）后仍启动安装器（pid 12024） |
| 01:35:04.039 | Inno 日志**戛然而止** |

Inno 日志 `fushi-2.2.4-debug.13582-windows-setup.install.log` 全长 25 行，最后一行是
`Successfully imported the DLL function. Delay loaded? No`。**没有**任何 abort / exception /
`Deinitializing Setup` —— 这是被外部结束的形状，不是自行中止的形状。

app 在 09:35:59 由 **explorer.exe** 重新拉起（`Win32_Process` 实测 `ParentProcessId=16968`
= explorer），即用户自己去开始菜单点的：launcher 的 BUG-1708 兜底当时已经不在了。

### 根因 ①：安装器杀掉了自己所在的进程树

应用内静默更新时进程链是

```text
fushi.exe → fushi_update_launcher.exe → setup.exe（本安装器）
```

`InitializeSetup()` 检测到互斥量仍被持有后跑 `taskkill /IM fushi.exe /T`。`/T` 是**递归**
杀整条后代树，本机实测（三层 cmd 副本）：

```text
taskkill /F /IM fk_parent.exe /T
成功: 已终止 PID 88128 (属于 PID 47184 子进程)   ← 孙进程也被带走
```

于是安装器把 launcher 和自己一并杀掉。`/T` 原本是为了带走 WebView2 子进程，但它们的
image 名就是 `msedgewebview2.exe`，`InitializeSetup` 已经单独扫了一遍 —— `/T` 不提供任何
额外覆盖，只提供自杀能力。

### 根因 ②：诊断把每一份日志都误判成 app_mutex_running

`summarizeWindowsInstallerFailure` 用 `lower.contains('mutex')` 判「Fushi 仍在运行」。而
Inno 会把 `[Code]` 段的外部函数导入逐个写进日志，其中就有

```text
Function and DLL name: OpenMutexW@kernel32.dll
```

这一行**每一份**日志里都有，无论成败。于是这条判据对任何一次失败都恒真，把真正的原因
（安装器被杀）盖成了「Fushi 仍在运行」，用户和 agent 都被指向错误方向。

### 根因 ③：launcher 的观测被 Dart 读写一轮抹掉

marker 有两个写者：Dart 和 C++ `update_launcher.cpp`（`AppendMarkerFields`）。app 下次启动
读回 marker、补诊断再写回，走 `fromJson → copyWith → toJson`，而模型不认识的键在这一步被
静默丢弃。现场因此只剩一个 `parentExitObserved:false`，`launcherMutexReleased` /
`parentExitTimedOut` / `appAliveAfterInstaller` 全没了 —— 连「是 OpenProcess 失败还是真的
等超时」都分不出来。

> 触发这整条链的**上游**是 BUG-2167：app 每次退出都 fail-fast 崩在 `ucrtbase!abort`，
> 崩溃进程被 WER 冻住不死，于是互斥量一直被持有。两条 bug 各自独立可修：修好 ① 之后，
> 即使 app 仍崩在退出路径，安装器也能杀掉那个僵住的进程并把这一版装完。

- **[x] ① 已修复** — `fushi.iss` 的 `KillGracefully` / `KillImage` 去掉 `/T`，改为纯按
  image 名杀（WebView2 由 `KillImage('msedgewebview2.exe')` 单独覆盖）；
  `update_handoff.dart` 的分类器改为结构判据（`windowsInnoLogStoppedDuringStartup`）+
  launcher 实测事实（新字段 `launcherMutexReleased`），删掉裸 `mutex` / `is running` 子串；
  未识别的 marker 键进 `extraFields` 原样写回。
- **[x] ② 已加自动化测试** —
  `fushi/test/utils/misc/platform_updater_test.dart`（taskkill 实参不得含 `/T`，断言落在整个
  实参列表上而非首个字面量）、
  `fushi/test/utils/misc/update_handoff_test.dart`（用户机那份真实 25 行日志作回归样本 +
  marker 未知键往返 + 模型自认键闭合）。
  三条变异实测均被抓到（加回 `/T`、加回 `contains('mutex')`、删掉 `~Gamepads()`）。
### 本轮验证（2026-09-06，本机）

1. **进程树语义两个方向都实测**（三层 `cmd.exe` 副本夹具，父→子→孙）：

   | 命令 | 结果 |
   |---|---|
   | `taskkill /F /IM fk_parent.exe /T` | 父、子、**孙**全部终止（= 安装器自杀） |
   | `taskkill /F /IM fk_parent.exe` | 只终止父进程，子与孙存活（= launcher 与安装器活下来） |

2. **`.iss` 真编译**：`ISCC.exe /DAppVersion=0.0.0-test /DSourceDir=<Debug 构建> ...` →
   `Successful compile (70.610 sec)`，退出码 0。（`.iss` 只在 release workflow 里编译，
   PR CI 抓不到它的语法错，所以本地补了这一步。）

3. Dart 侧 `flutter analyze` 干净；定向测试 99 条绿；`test/platform` + `test/startup` +
   `test/utils/misc` 三个目录 1051 条绿；三条变异（加回 `/T`、加回 `contains('mutex')`、
   删掉 `~Gamepads()`）全部被守卫抓红。

4. 全量套件：`FLUTTER TEST VERDICT: PASSED - 23074 tests ran, all tests passed`。
   注意前两次全量是**环境红**，判据三条：失败的是**不同文件**（`galgame_path_match` →
   `position_pref_keys_guard`）；错误都在传输层而非断言（`Connection closed before test
   suite loaded` / `Unable to connect to flutter_tester process: WebSocketException:
   Invalid WebSocket upgrade request`，全程无 `Expected:`）；两文件单跑 17 条全绿且与本
   改动无交集。**把 `HTTP(S)_PROXY` 整个摘掉后一次就绿** —— 只设 `NO_PROXY` 含 `::1`
   并不足以挡住劫持。

- **备注**：**端到端的一次真实应用内更新没有跑**——本机运行编译出的安装器会执行
  `taskkill /F /IM fushi.exe`，那会关掉用户当前正开着的生产 Fushi。所以这一层留给下一次
  真实更新验证；上面 1 与 2 已把「/T 会不会连坐」和「脚本能不能编译」两个关键点各自钉死。
