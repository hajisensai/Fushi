## BUG-3750 · TTS 朗读用微软 / 谷歌在线语音经常中断
- **报告**：2026-10-24（用户：「Fushi TTS 朗读用微软、谷歌的语音经常会断」，要求全平台修）
- **真实性**：✅ 真 bug（沿代码路径确认，未做真机 / 真网络复现）。四处叠加：
  1. `fushi/lib/src/media/audiobook/tts/tts_read_along.dart:542`（修前）`_onSegmentEvent` 收到任何 `TtsSegmentFailed` 都 `pause()` + 提示，不分是当前句还是后台预取句；预取窗口按 60 秒播放时长算、可达 60 句，窗口里任一句抖一下就打断正在读的句子。
  2. `packages/fushi_engine/lib/tts/tts_synthesis_scheduler.dart:211` / `:220` / `:180`（修前）任一句失败即置 `_failure`，`_pump` 整体停发，预取失败也会让后面的句子永远等着。
  3. 所有在线引擎（`edge_tts_provider.dart` / `azure_tts_provider.dart` / `google_cloud_tts_provider.dart` / `translate_tts_providers.dart` / 共用 `tts_http.dart`）对连接重置、超时、429、5xx、空音频零重试；Edge 每句新开 websocket，`edge_tts_provider.dart:279`（修前）只有 3 分钟整体超时、无空闲超时，连接半开时播放器缓冲 3 分钟。
  4. `fushi/lib/src/media/audiobook/tts/tts_book_plan.dart:152`（修前）发音词典在按引擎上限切句**之后**才替换，替换会把句子撑过上限（谷歌翻译朗读 180 字，超了回 400 拒收），该句必然失败。
- **[x] ① 已修复** — 提交见 PR（`fix(tts): ...`）：
  - 调度器：播放器 `ensure` 过的句子失败才停（`TtsSegmentFailed.blocking`）；后台预取失败只记下并暂停继续预取，播放器要到该句时重新请求，再失败才停——不跳句。
  - 朗读层：`TtsFailureReportGate`，只有播放器停在失败句上才暂停 + 提示一次（播放器预读的下一句失败时当前句照常读完）。
  - 新增 `packages/fushi_engine/lib/tts/tts_retry.dart`（`ttsWithRetry` / `TtsRetryPolicy`）：唯一的退避重试层，只重试 `TtsFailure.isTransient`（network / timeout / 429 / 5xx / 409 busy / 显式标记的空音频），最多 3 次、指数退避 + equal jitter、尊重 `Retry-After`（超过 30 秒不等直接上报）、取消令牌可中断等待；朗读调度器与制作有声书渲染共用。
  - Edge：收帧抽成 `collectEdgeTurn`，30 秒无帧判 network `idle`（交给重试）；提前关闭改判 network、无音频标临时；握手 HTTP 拒绝按状态码归类；补接 `TlsException`。
  - 切句：`splitTtsTextWithPronunciation` 按超出量收紧上限重切本章直到套用词典后放得下，收紧到 1/4 仍放不下时超长句退回不套用词典的写法。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/tts/tts_retry_test.dart`、`packages/fushi_engine/test/tts/edge_tts_turn_test.dart`、`packages/fushi_engine/test/tts/tts_synthesis_scheduler_test.dart`（预取失败不停 / 回到失败句重新请求 / 仍失败才阻塞 / 重试有界 / 不重试非临时失败）、`fushi/test/media/audiobook/tts/tts_read_along_failure_gate_test.dart`、`fushi/test/media/audiobook/tts/tts_book_plan_test.dart`（发音词典不撑破上限）。
- **备注**：未做真机 / 真实在线服务验证（断网、限流、半开连接只在假引擎 / 假 socket 上验证）。朗读层的暂停时机测的是 `TtsFailureReportGate` + 真调度器，没有挂真 `AudiobookPlayerController` / just_audio。系统语音（`desktop_tts.dart` 等）不在本修复范围。
