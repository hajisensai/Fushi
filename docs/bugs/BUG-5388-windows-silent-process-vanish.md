## BUG-5388 · Windows 阅读中进程无声消失：无 dump、无 WER、无 exitReason
- **报告**：2026-11-24（用户：「我 fushi 好像自己关掉了」）
- **真实性**：✅ 进程确实非正常消失；根因未定位（各层均无痕迹，见下）。待下次复现时用进程终止审计的退出码定性。
- **[ ] ① 未修复** — 根因未知，无法修。
- **[ ] ② 未加自动化测试** — 同上。
- **备注**：

### 现场（2026-11-24，Windows，3.4.0-debug.32189，pid 25336）

- 13:19:25 启动，**20:14:13～20:14:25 之间消失**。消失前在 `ReaderFushiPage` 读《安達としまむら3》：20:14:09 查词「天下分け目なのだ」（popup 由 warm slot 秒开），20:14:13 `study_diag_log` 还记了 `[ledger] arrive` 与 `+14c`；`session_marker.json` 每 30 秒的内存采样最后一条是 20:13:55，20:14:25 那条没写出来。
- `session_marker.json`：`clean=false`、`exitReason=null`、`terminatedBy=null`、`memoryPressureCount=0`。重启后 `previous_exit_log.dart` 写进 `error_log.txt`：「上次进程没有走正常退出……（停在前台时没了，疑似闪退）」。
- 内存无压力：rss≈1.03 GB、priv≈3.7 GB、系统已提交 108/128 GB。

### 已排除

| 路径 | 若是它应留下的痕迹 | 实际 |
|---|---|---|
| SEH 未处理异常 | `fushi/windows/runner/crash_dump.cpp` 的 filter 写 `%LOCALAPPDATA%\Fushi\crashdumps\hibiki-*.dmp` + `crash_summary.log`，再链回 WER（Application 1000/1001） | 都没有（最新 `hibiki-*.dmp` 是 10-21）；同时段 WER 正常记了别的进程崩溃 |
| CRT `abort` / `__fastfail` | Application 1000，异常码 `0xc0000409` | 没有 |
| 应用主动退出（点 X、重启、更新） | 一律走 `fushi/lib/src/platform/app_exit_coordinator.dart`，先记 `exitReason` 再 `TerminateProcess`（`windows_process_exit.dart`） | `exitReason=null` |
| 自动更新安装器 | 安装目录时间戳变化、Restart Manager 事件 | 安装目录 13:19 后未变，无 RM 事件 |
| 本机 Claude 会话 kill | 20:13～20:15 的会话 transcript 里有 taskkill / Stop-Process | 无 |
| 任意事件日志 | 全部日志 20:13～20:16 按 `fushi` / pid 25336（0x62F8）搜 | 零条 |

**剩下的可能**：外部进程 `TerminateProcess`（任务管理器、杀软等），或某个原生 DLL 绕过 CRT 直接结束进程。现有证据分不出来。

### 下次复现怎么定性

本机已于 2026-11-24 开启「进程终止」审计（`auditpol /set /subcategory:{0CCE922C-69AE-11D9-BED3-505054503030} /success:enable`，已用 `cmd /c exit 7` 实测记到 `退出状态: 0x7`）。再消失时**以管理员身份**查：

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4689; StartTime=(Get-Date).AddHours(-1)} | Where-Object { $_.Message -match 'fushi\.exe' }
```

按退出状态判断：`0x1` 多半是外部 `taskkill /F` / 任务管理器；`0xC0000409` 是 fast-fail；`0xC00000FD` 是栈溢出；其它值再对照 NTSTATUS 查。4689 不记「由谁结束」，判成外部结束后再查杀软日志。

若多次复现都指向自身无痕退出，再考虑在 `fushi_update_launcher` 之类的常驻伴生进程里做进程外退出码记录，写进 `previous_exit_log` 的上次退出报告。
