## BUG-4243 · Android 死时重要度 125（前台服务）被当成界面在前台，后台被杀判成闪退
- **报告**：2026-11-07（用户：应用内自动闪退报告 vJrUPZW9I8，Android 16 Samsung SM-A346E，3.3.0）
- **真实性**：✅ 真 bug。证据：`started=12:53:48 lastLifecycle=paused@12:54:10 androidImportanceAtDeath=125`，内存采样一直到 13:40 都在 `HomeDashboardPage` 且标记停在 `paused`；`ApplicationExitInfo` 记 `reason=SIGNALED status=9 importance=125 at=13:42:29`——界面退到后台约 48 分钟后被系统信号杀掉，却判成「停在前台时没了，疑似闪退」。
  - 语义核对（developer.android.com `ActivityManager.RunningAppProcessInfo`）：`IMPORTANCE_FOREGROUND=100`「running the foreground UI … at the top of the screen」；`IMPORTANCE_FOREGROUND_SERVICE=125`「running a foreground service, for example to perform music playback even while the user is not immediately in the app」。本仓前台服务：`AudioService`（mediaPlayback）、`DownloadKeepAliveService`（dataSync）、悬浮词典 / 歌词 / 悬浮球（specialUse）、`ScreenOcrService`——这些都能在界面退后台时把进程维持在 125。
  - 根因：`fushi/lib/src/diagnostics/previous_exit_log.dart:428`（修前）`androidImportanceAtDeath <= kAndroidForegroundImportance` 直判前台，常量 `:559` 取 125 并注释成「用户看得见」，把前台服务当成界面在前台，压过了标记的 `paused`。
- **[x] ① 已修复** — 拆成 `kAndroidForegroundUiImportance=100` 与 `kAndroidForegroundServiceImportance=125`：`<=100` 直判前台；`101..125` 交给会话标记的生命周期；`>125` 判后台。`formatAndroidExitReports` 的 `foreground`（决定 `memoryKill` 值不值得报）仍按 `<=125`：前台服务在放歌 / 下载时被 LMK 杀用户感知得到，保持 UeCVNnw7Jx 的既有判定。提交 22a6de2244。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：「importance=125（前台服务）+ 标记停在 paused → 后台回收，不弹闪退报告」（去掉修复红）、「importance=125（前台服务）+ 标记停在 resumed → 仍是疑似闪退」。
- **备注**：
