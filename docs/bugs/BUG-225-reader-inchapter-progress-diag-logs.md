## BUG-225 · 章内滚动进度链路三点诊断日志(TODO-151/164)
- **报告**：2026-06-12（用户：章内滚动进度「还是没修好」；TODO-164 要求加错误日志检测）
- **真实性**：✅ 真需求（非新 bug）。BUG-213(`5ef9e28a9`) 的修复（JS scroll reporter →
  `onReaderScroll` → `_handleReaderScroll` 纯函数门控 → `_refreshProgress`）对**连续模式
  架构正确**，但对**分页模式是 no-op**：分页翻页已 `_refreshProgress` + `registerSnapScroll`
  把章内自由滚动 snap 回列边界，章内无净滚动 → 无 scroll 事件 → 无回传。用户仍报没修好，
  可能=用旧版/用分页模式/连续模式某一链断。为下次真机 run 能定位是哪一链断，在链路三点
  加诊断日志（**不改 BUG-213 现有逻辑，只加日志**）。
- **[x] ① 已加诊断日志** — 三点都默认 off、由 `DebugLogService.instance.enabled` 门控
  （ship off；用户在调试日志页打开后才进环形缓冲），文件位置
  `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`：
  - JS `_reportReaderScroll`（setup 脚本内）：`console.log('[ReaderDiag] scroll report
    reanchorPending=… hasBridge=…')`，由 Dart 把 `DebugLogService.instance.enabled` 插值进
    脚本门控（经 `onConsoleMessage` → `debugPrint` → DebugLogService）。在原 `_reanchorPending`
    早返回**之前**记录，便于看清「reanchorPending=true 早返回不回传」「hasBridge=false
    callHandler 不可用」哪一种。
  - Dart `_handleReaderScroll`：记四个门控条件各自真值（`readerContentReady`/`restoreInFlight`/
    `lyricsMode`/`controllerAvailable`）+ `allowed` + 是否实际 `refresh`，定位被哪个门控挡掉。
  - Dart `_refreshProgress`：记重算后 `_progressCurrentChars`/`_progressTotalChars`（+ progress/
    section），确认滚动后章内进度数确实推进/未推进。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_inchapter_progress_diag_log_test.dart`：
  源码扫描守卫断言三点诊断接入存在且都受 `DebugLogService.instance.enabled` 门控、JS 端走
  console.log 输出 reanchorPending/hasBridge、Dart 两点记对应字段；撤掉任一点对应用例转红。
  同时把 `reader_inchapter_progress_scroll_test.dart` 里 `_handleReaderScroll` 源码守卫的扫描
  窗口从 600 放宽到 1100（插入诊断块后函数体加长，旧窗口会漏掉末尾 `_refreshProgress();`
  误转红——属本次必须同步的回归修复，非逻辑变化）。
- **备注**：needsDevice — 三点诊断的运行时输出需真机/模拟器开启调试日志后滚动复测，据日志
  判定用户「没修好」是分页模式(no-op，预期)/旧版/连续模式哪一链断，再决定是否需要为分页
  模式补独立进度回传通道。撞号：取 develop 最高 220→221(本 agent 165 占)→222，遍历 worktree
  分支取并集确认未撞；如 integration 合并撞号请改号。
