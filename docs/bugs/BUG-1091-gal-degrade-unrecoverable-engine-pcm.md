## BUG-1091 · galgame 刚启动就误报「降级运行 · engine_pcm_unavailable」，且永远回不到引擎 PCM
- **报告**：2026-07-26（用户：「游戏刚起来、一句语音都还没播，状态卡就写降级运行 · 系统 Loopback（混音）· engine_pcm_unavailable / 已降级，后面一直是这样」）
- **真实性**：✅ 真 bug（三处叠加，均沿真实代码路径验证）
  1. `galgame_audio_source.dart:946`（改前）：`start()` 的 readiness 循环只要 `_textHookReady && _audioHooksReady`（= hook **装上了**，`:163-170`）就立刻 `return null`，**不等第一句语音**。而真正的就绪门是 `parseEngineHookReadyFormat`（`:142-159`，要求 native `ready` + 有效 PCM 格式），游戏没播过语音时必然为空 → 第一个 200ms poll tick 就判死，30s 的 `_readyTimeout` 形同虚设。
  2. 无恢复路径：`gal_hook_session_controller.dart:1837-1900` 的 `_activateTextWithLoopback`（写 `engine_pcm_unavailable` 的唯一位置）没有接任何升格；`_scheduleEngineRecovery` 只挂在两个**注入失败**点（`:617` engine_attach_failed / `:738` launch_injection_failed），唯一的在线升格 `_promoteLateResourceAudio` 只看 `rawVoiceReady`。`EngineHookGalAudioSource.pcmReady` 在整个 lib 里零消费者，是死 getter。→ 降级是终态。
  3. 文案裸奔：`_activateTextWithLoopback` 显式把 `injectorFailure` 置 `none` → `galGalHookFailureLabel(none)` 返回 null（`gal_hook_failure_text.dart:14`）→ `texthooker_page.dart:1420` 把内部代码 `engine_pcm_unavailable` 原样甩给用户。
- **[x] ① 已修复** — 提交 `77486f1c7`：
  - `galgame_audio_source.dart`：`_pcmReady` 换成 `_readyFormat`（由 `_pollFormat` 用**与 `start()` 完全相同**的 `parseEngineHookReadyFormat` 写入），新增 `readyPcmFormat` getter。判据必须是这道门——直接看 `parseGalPcmFormat` 会把未过门的残留碎片当可用 PCM，正是 BUG-1060 修掉的回归。`start()` 早退分支与 `refreshReadiness()` 的注释改写成「此刻还没有 PCM」而不是「这局没有 PCM」。
  - `gal_hook_session_controller.dart`：`_refreshReadinessThrottled` 加上与资源侧**对称**的 PCM 升格分支 `_promoteLateEnginePcm`。它复用存活的 engine 实例（不重新注入），刻意**不**走 `_activateEngine` / `_startEngineTextPolling`——那会把文本轮询游标归零、清掉逐行缓存与用户裁决，导致整段历史台词被重放。升格前先 `_flushAllLoopbackFreezes()` 把待冻结行按真实已等待时长冻好，再停旧 Loopback；补录进行中则跳过本轮（用户裁决优先）。
  - `gal_hook_failure_text.dart`：新增 `galHookFallbackLabel(String)`——降级原因和注入失败原因是两套独立事实，各有自己的翻译表。`texthooker_page.dart` 状态卡改为 `galHookFailureLabel(injectorFailure) ?? galHookFallbackLabel(fallbackReason) ?? fallbackReason`。新增 5 个 i18n key（经 `tool/i18n_sync.dart` + `dart run slang`）。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_audio_degrade_track_test.dart`：
  - 「BUG-1091 引擎 PCM 晚到时把降级的 Loopback 升格回引擎，且不重放台词」：`_FakeEngine.start()` 返回 null + textHookReady → 断言临时降级；随后 `readyFormat` 置位 → 断言 backend 变 enginePcm、fallbackReason 清空、Loopback 被停、engine **未**重启、`service.entries` 仍只有 1 条（游标未重置）。
  - 「BUG-1091 降级原因必须有人话文案」：`galHookFallbackLabel` 七个已知代码非空、未知代码返回 null（不编造），+ 源码守卫状态卡确实调用它。
- **备注**：`engine_pcm_unavailable` 这个内部代码字符串保留（旧诊断/事件日志沿用），语义由文案与升格路径纠正。真机验收未做：需在 Windows 上按原始启动路径确认「开局显示临时降级 → 第一句语音后自动切回引擎 PCM」。
