## BUG-2706 · 同一 Fushi 进程二次启动同款游戏时文本线程记忆恢复到上一次的死线程
- **报告**：2026-09-26（千恋＊万花真机验收时发现）
- **真实性**：✅ 真 bug，真机复现。同一个 Fushi 宿主里先启动一次并选定 `EmbedKrkrZ` 线程，停止后再次启动：会话事件记 `text.thread_selected {threadId: 2697783395901573741}` + `text.thread_memory_restored`，但本次进程的同一 hook 面线程是 3248536043164162368——恢复写进共享内存的是**上一次进程**的 thread id，于是本会话一句台词都不发布（`selected_text_thread_id` ≠ 任何活线程）。根因：`fushi/lib/src/mining/gal_hook_session_controller.dart` `_maybeRestoreTextThread` / `_maybeAutoSelectEngineExactThread` / 选择持久化查找用的是全量目录 `_textService.textThreads`，里面还留着上一次启动的线程（thread id 含进程身份，且累计行数更多，赢下「行数最多」）。服务早有会话级目录 `textThreadsSince(sessionStartedAt)`，控制器对外 getter 也用它，只是这三处内部循环没用。
- **[x] ① 已修复** — 提交 `cd13a810239`：三处改用会话级 `textThreads`。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_capture_audio_integrity_test.dart`「文本线程记忆：二次启动只从本会话线程里恢复，不选上一次的死线程」（每次启动一个新假引擎，建模新进程）。反向验证：把恢复循环改回全量目录时该测试失败（选中 7 而非 8），修复后通过。
- **备注**：真机宿主是修复前构建的 itest runner，二次启动时仍需手选线程；修复的真机复测待下次重建宿主。定向 `flutter test`（会话控制器 / 音频完整性 / 音频源 / launcher 等待 / 转区回退）177 条全绿。
