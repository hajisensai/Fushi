## BUG-5571 · diag-log-trim-on-every-append-freezes-ui
- **报告**：2026-11-27（用户：视频播放中「画面冻结了，然后未响应」，截图为 Windows 未响应白化窗口）
- **真实性**：✅ 真 bug。本机 3.4.0-debug.32862（develop 06de0be）进程 97936 的 4 份 hang dump，用补丁引擎 pdb + 同提交本机重编另存的 Dart 调试信息（按代码字节对齐到安装包，BUG-5568）还原：
  - 10:31 卡 20.8 s：主线程 `_startMicrotaskLoop` → … → `VideoDiagLog._trimFile`（`fushi/lib/src/diagnostics/video_diag_log.dart:325`，旧行号）→ `String.substring` → `TwoByteString::New` → `Heap::AllocateOld` → `GCMarker::IncrementalMarkWithSizeBudget`；
  - 10:25:55 卡 4.3 s：同一条链 → `_File.writeAsString` → `Utf8Encoder.convert` → `AllocateUint8Array` → GC 标记。
  - 根因：`VideoDiagLog._append`（旧 `video_diag_log.dart:315-318`）每行 `length()`，超 4 MB 就 `_trimFile` 整文件读回、UTF-8 解码、`trimTail` 保尾到**正好** 4 MB、再编码写回。保尾落在上限下方一行以内，文件长满后**下一行又超限**——稳态下每一行日志都是一次 4 MB 读 + 解码（8 MB 双字节串）+ substring + 编码 + 重写，全在 UI isolate。诊断开着每秒几十行，大块分配把 ~2 GB 堆的增量标记一次次拖进主线程。当时 `video_diag_log.txt` 正是 4194297 字节（贴着上限）。
  - 同一写法：`StudyDiagLog._append/_trimFile`（`fushi/lib/src/stats/study_diag_log.dart`，`study_diag_log.txt` 1048560 字节贴 1 MB 上限）；`ErrorLogService._trimLogBytes`（`fushi/lib/src/utils/misc/error_log_service.dart`，保尾到正好 512 KB，`_trimToMaxUtf8Bytes` 每 rune 一次 `utf8.encode`，`error_log.txt` 524287 字节贴上限）。
- **[x] ① 已修复** — 新增 `CappedLogFile`（`fushi/lib/src/utils/misc/capped_log_file.dart`）：大小记在内存、超上限才裁、一裁裁到 3/4 上限；裁剪全在字节层（RandomAccessFile 定位读保留的尾部，从第一个 `\n` 之后起写回，不解码不建串）。`VideoDiagLog` / `StudyDiagLog` 改用它（删掉各自的 `_append` / `_trimFile` 抄本，`clear()` 后 `forgetSize()`）。`ErrorLogService` 的保尾目标改为 3/4 上限（`_trimTargetBytes`），`_trimToMaxUtf8Bytes` 在内容本就未超限时直接返回。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/capped_log_file_test.dart`：1 KB 上限灌 10 KB 行日志，裁剪次数 ≤ 41（旧写法约 900 次）且文件始终 ≤ 上限、最新行在、对齐行首；不切多字节 UTF-8；未超限不重写；外部清空后 `forgetSize` 重新量。`fushi/test/stats/study_diag_log_test.dart` 换成「init 接住超限旧文件裁到 3/4」。
- **备注**：同一次冻结里 2026-11-27 10:23:48 → 10:25:55 那 130 s 看门狗一行没记，dump 与日志都解释不了——已由 BUG-5568 加「看门狗线程没被调度」记录，下次能分清是主线程忙还是整个进程没跑。
