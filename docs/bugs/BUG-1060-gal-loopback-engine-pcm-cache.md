## BUG-1060 · Loopback 制卡误用引擎 PCM 碎片导致音频异常
- **报告**：2026-07-24（用户：`屋上の百合霊さんフルコーラス.exe` 的 `正解` 卡片句子音频像倍速）
- **真实性**：✅ 真 bug。捕获工作台明确显示会话已降级为 `systemLoopback`（48 kHz / 2 ch / 32 bit），但逐行状态却是 `engine_pcm` 且多条不同长度台词都固定约 1.72–1.74 秒；实际 Anki AAC 仅 1.77 秒、基频中位数约 533 Hz。根因是 `hibiki/lib/src/mining/gal_hook_session_controller.dart` 的文本轮询和制卡补抓在 `_audioSource` 已选 Loopback 后，仍无条件调用保活 helper 的 `grabUtterance`，把未通过 PCM readiness 的残留碎片写入 `_lineVoiceCache`，随后又按当前会话来源误标为 `system_loopback`。
- **[x] ① 已修复** — 仅当 `_audioSource` 与 `engine` 是同一实例（readiness 已正式选择 engine PCM）时才允许抓取 engine clip；文本 helper + Loopback 会话直接冻结真实 Loopback，制卡补抓也不再复活不可信 engine PCM。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_hook_session_controller_test.dart` 的 BUG-1060 用例让 text-only helper 故意暴露一段“可读但未就绪”的 engine utterance，断言行到达和制卡阶段均零次调用它、只缓存一次 Loopback。
- **验证**：目标测试 20/20 通过，`flutter analyze --no-pub` 通过，Windows Debug 构建成功；隔离构建实机启动该游戏时也确认失败分支会明确落到 `系统 Loopback（混音）· 48000 Hz · 2 ch · 32 bit`。全量测试跑至 13,304 个通过事件、143 个既有 UI/字体/视频/设置并发失败后停止，未发现 BUG-1060 相关失败。
- **备注**：Windows-only galgame 消费状态机修复；不修改或扩展其它平台的 galgame 实现。
