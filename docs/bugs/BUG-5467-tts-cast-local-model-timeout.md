## BUG-5467 · tts-cast-local-model-timeout
- **报告**：2026-11-23（用户：有声书制作台「用 AI 标注说话人」用本地 Unsloth Studio + Qwen3-14B 标《化物語（上）》，转了几分钟后报「网络错误」）
- **真实性**：✅ 真 bug。同一请求直接发给本地端点能正常回 200，只是要几分钟：选角一块回 3–4.5k token，本地 9B 约 50 token/s 已压线，14B 必超。
  - 根因 `packages/fushi_engine/lib/ai/ai_chat_client.dart` `_send`：所有 chat 请求共用 90 秒时限 `kAiChatRequestTimeout`，超时被包成 `network_error`（临时性失败），`_withRetry` 把整块重生成最多 `kAiChatMaxAttempts` 次，每次都在模型还在正常吐字时被掐断，最后界面报「网络错误」。
  - 时限是全局常量，调用方没法按自己的回复长度放宽。
- **[x] ① 已修复** — `AiChatClient` 构造参数 `requestTimeout`（默认仍是 90 秒，其余调用方不变）；`annotateTtsCast` 建客户端时给 10 分钟（输出上限 8192 token 按约 15 token/s 估）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/ai/ai_chat_request_timeout_test.dart`（客户端时限短于生成耗时报 network_error、放宽后同一慢应答正常拿到、默认仍 90 秒）。
- **备注**：云端模型一块几十秒就回，不受影响；用户在 Unsloth Studio 关掉思考（per-load reasoning off / `chat_template_kwargs.enable_thinking=false`）能再快不少，但不是修复的一部分。
