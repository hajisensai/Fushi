## BUG-1063 · galgame hook 台词显示慢：文本推进被逐行语音抓取阻塞
- **报告**：2026-07-25（用户：hook 文字的显示有点慢）
- **真实性**：✅ 真 bug。三处叠加，均在 `hibiki/lib/src/mining/gal_hook_session_controller.dart`：
  1. `textPollInterval` 原为 400ms。native `pollText`（`hibiki/windows/runner/flutter_window.cpp:1763`）只读共享内存环并拷贝新行，无 IO、无锁等待，400ms 是纯人为延迟：平均 +200ms、最坏 +400ms。
  2. 每个 tick 先 `await engine.refreshReadiness()` 再 `pollText`（旧 `_pollHookedText` 开头），文本链路白白串上一次 IPC 往返。
  3. 最重的一条：旧 `_pollHookedText` 的 for 循环里对每一行 `await engine.grabUtterance() ?? grabClipNear()` / `_cacheLoopbackForLine()`。同一批的第二句台词要排在第一句的语音抓取之后，抓取期间 `_pollInFlight` 还会让下一个 tick 整轮跳过——台词显示被自己的语音配对拖慢。
- **[x] ① 已修复** — `textPollInterval` 400ms → 80ms；readiness 改走 `_refreshReadinessThrottled`（≥500ms 一次，晚到资源 hook 的升格路径不变）；语音抓取整体移出文本主循环，改由 `_scheduleLineAudioAttach` 入串行音频队列（与制卡采集共用同一队列，native 语音缓冲同一时刻仍只有一个读取者），BUG-950 的 engine generation 复检随抓取一起搬进 `_attachLineAudio`。提交见分支 `worktree-gal-overlay-replay-latency`。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_hook_line_latency_recapture_test.dart`：语音抓取挂起（未完成的 Completer）时后续台词仍照常进文本服务（已反向验证：临时改回内联 await 后该断言变红，只剩第一句）；readiness 被降频且时钟推过窗口后仍会重查。`hibiki/test/mining/gal_hook_session_controller_test.dart` 的源码守卫改成钉「文本主路径只许 await `_refreshReadinessThrottled` 与 `engine.pollText`」+「`_attachLineAudio` 内保留 BUG-950 复检」。
- **备注**：同轮给浮窗加了「重播」「重播并录音」两个语音按钮（功能新增，不属本条）。真机验收仍需在 Windows 跑原始 galgame 路径确认观感。
