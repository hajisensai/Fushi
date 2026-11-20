## BUG-4943 · Android 后台 ANR：诊断标记在主线程同步 fsync
- **报告**：2026-11-21（应用内反馈 OU6bZvpCd0：3.3.0，Xiaomi 220233L2G，Android 11，armeabi-v7a；`ApplicationExitInfo` reason=ANR「bg anr」，主线程 state=D，栈顶 `libc fsync ← libflutter.so ← base.apk(libapp AOT)`，ANR 前 20 秒 UI_HIDDEN，整段会话持续 RUNNING_CRITICAL）
- **真实性**：✅ 真 bug（AOT 栈无符号，具体调用点按代码路径推定）。`libflutter` 里调 `fsync` 的只有 dart:io 的 `flushSync` / `writeAs*Sync(flush: true)`，异步版 `flush: true` 跑在 IO 线程不会出现在主线程栈上。Flutter 3.29 起 Android 的 UI isolate 就是平台主线程。主线程上**高频**同步 fsync 的只有诊断标记：
  - `fushi/lib/src/diagnostics/previous_exit_log.dart:443`（修前）`SessionMarker._write()`：每 30 秒内存采样（`kMemorySampleInterval`）、每次生命周期变化 / 内存压力都同步 `writeAsStringSync(flush: true)`；进后台（paused/hidden）与后台期间的采样照样触发；
  - `previous_exit_log.dart:1574`（修前）`ActivityBreadcrumb.mark`：查词弹窗、复习同步各阶段、ASR 内存闸调；
  - `fushi/lib/src/utils/misc/error_log_service.dart` 的 `markLookupStackDepth`（每次查词弹窗进出）、`markImportStart`、`markInitStep`、`logFatal` + `_trimLogFileToMaxBytesSync`。
  根因是把「防进程下一刻没了」误当成需要 fsync：原生崩溃 / SIGKILL / 系统回收 / 看门狗强杀都不丢内核页缓存，`write(2)` 返回即足够；fsync 只多防整机掉电 / 内核崩溃，代价是低端机 IO 拥塞时主线程一次卡几秒 → ANR。
- **[x] ① 已修复** — 上述诊断标记全部改为只同步写（进页缓存）、不 fsync；同步语义（崩前留得下）不变。落盘语义写在 `SessionMarker` 文档。启动时一次性 / 罕见路径的原子写（`readAndClearTextFile`、`CrashReportStore.write` 的 tmp+rename 等）不在主线程热路径，未动。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/diagnostic_marker_no_fsync_guard_test.dart`（方法体切片守卫：7 个标记写入方法仍 `writeAsStringSync`、不带 `flush: true` / `flushSync`）；`fushi/test/startup/platform_dispatcher_error_guard_test.dart` 的 logFatal 守卫改为「同步写、不要求 fsync」。
- **备注**：同一反馈里 32 位包缺 `libfushi_torrent_ffi.so` 导致 `EmbeddedTorrentHost.probeAvailable` 每次启动记错误，与本 ANR 无关，未在本条处理。未在真机复现 ANR（需要低端机 IO 拥塞环境）。
