## BUG-3930 · 本地 LLM 回 200 错误体时 AI 助手只报「没有返回内容」
- **报告**：2026-11-01（用户：反馈 GewyVIt5oo（Windows，LM Studio 日志截图））
- **真实性**：部分确认。LM Studio 日志显示 `POST /chat/completions` 被回 `Unexpected endpoint or method ... Returning 200 anyway`——请求路径缺 `/v1`（地址只填到端口）。`packages/fushi_engine/lib/ai/ai_chat_client.dart:960` `_postChat` 把 200 错误体当成功应答，最终报 `empty_response`（「AI 没有返回内容」），看不出是地址问题。SRS 翻译与 AI 助手走同一个 `_postChat` / 同一 URL 拼法，若两者指派同一家提供商，路径相同；用户说 SRS 能用，推测两功能指派了不同提供商 / 地址，待反馈人确认。
- **[x] ① 已修复（诊断部分）** — 2xx 应答只有 `error`、没有应答本体时报新短码 `endpoint_error`，界面提示检查接口地址（OpenAI 兼容服务通常以 /v1 结尾）；测试连接同样报这一条。提交 0a565b8f54。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/ai/ai_chat_endpoint_error_test.dart`。
- **备注**：AI 助手在提供商不支持原生 tool calling 时走 JSON 降级协议，系统提示里带整份操作目录，本地小上下文模型可能超长；未在本次处理。
