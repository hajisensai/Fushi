## BUG-3993 · 整季生成字幕 AI 校对暂停：AI 回复多次不完整
- **报告**：2026-11-02（用户：整季生成日语字幕，AI 校对开着、提供商 Anthropic claude-opus-5-5，前 14 集已有 .ja.srt 跳过，其余集识别完后暂停在「AI 请求失败（AI 回复多次不完整）」，点「继续」仍一样）
- **真实性**：✅ 真 bug（代码路径确定性复现；用户设备上的任务缓存没拿到，具体是哪一阶段没法从截图确认——失败时所有待做集都停在「识别」，与 S0 专名表阶段吻合）。根因：四个 AI 阶段的重试循环都是「原样重发同一请求、最多 3 次」，而且整段回复要么全收、要么全扔：
  - `packages/fushi_engine/lib/ai/ai_chat_client.dart` `completeWithUsage` 不带回停止原因，调用方看不出回复是撞上 `max_tokens`（8192，`kSubtitleAiMaxOutputTokens`）被截断的；
  - `subtitle_glossary_builder.dart` `_ask`：整季 / 多季作品的专名表很长，输出截断 → JSON 数组不闭合 → `parseSubtitleGlossaryReply` 返回 null → 原样再发，同一处再截断 → 3 次后抛 `reply_incomplete`。每次重跑都是同一个结果，「继续」救不回来；
  - `subtitle_proofreader.dart` `_batch` / `subtitle_consistency_pass.dart` `_askChunk` / `subtitle_clip_classifier.dart` `classify`：同样的结构，回复漏 id 或截断就把已答的部分全部丢掉、整批原样重问。
- **[x] ① 已修复** — 截断成为一等信号：`AiChatCompletion.stopReason` / `truncated`（OpenAI `length`、Anthropic `max_tokens`、Gemini `MAX_TOKENS`）。新增 `salvageTruncatedAiJson`，从不闭合的 JSON 对象 / 数组里抢救写完整的顶层成员。S3 校对 / S4 写法统一 / 短片分类改为「已答的 id 跨次累积，只补问剩下的」（校对补问时已答行原位作只读参考）；S0 专名表截断时留下完整条目、接着发续写请求只要剩下的（`kSubtitleGlossaryContinue`），续写回 `[]` 即结束。失败判据从「3 次没凑齐」改为「连续 3 次一个新 id / 条目都没拿到」。S3 顺带只收本批 id，避免模型顺手改的上下文行盖掉相邻批的修正。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/asr_proofread/subtitle_proofreader_test.dart`（截断后只补问剩下的 id、每次都截断但有进展超过 3 次仍成功、`salvageTruncatedAiJson`）、`subtitle_glossary_builder_test.dart`（截断续写拼整表、续写回 `[]` 结束）、`fushi/test/ai/ai_chat_client_usage_test.dart`（三家停止原因判截断）。
- **备注**：没有在用户设备上用真实 Opus 跑整季复测；用户更新后点「继续」即可从已有缓存续跑（识别稿缓存仍在，不重新识别）。
