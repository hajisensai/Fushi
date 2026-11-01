## BUG-3928 · AI 助手降级协议把整份工具 schema 塞进系统提示，小上下文本地模型超长
- **报告**：2026-11-01（用户：反馈 GewyVIt5oo 遗留项，见 BUG-3930 备注（PR #2752 分支 fix/feedback-ai-misc））
- **真实性**：✅ 真问题（代码路径确认）。`packages/fushi_engine/lib/ai/agent/agent_session.dart` 旧 `_jsonTurn`：提供商不支持原生 tool calling 时，每轮把元工具 + 约 10 条常驻工具 + 技能 + 本场 describe 过的工具**逐条连完整 JSON Schema**（属性说明、嵌套 items）写进系统提示，且 describe 过的工具只增不减；上下文 4k 的本地模型（LM Studio 默认）第一轮就可能超长。服务端回的 400「context length …」被 `classifyAiHttpFailure` 归成 `http_400`，界面只显示「HTTP 400」，用户看不出原因。
- **[x] ① 已修复** — 降级协议系统提示分层：元工具（`ops__search` / `ops__describe` / `ui__ask_choice`）保留完整 schema，其余工具只给一行签名 `name(arg: type, opt?: type)` + 截短摘要，完整 schema 由 `ops__describe` 按需取（技能也能 describe）；`classifyAiHttpFailure` 把各家「上下文超长」错误体归成新短码 `context_overflow`（不重试），界面提示调大服务端上下文长度 / 换模型 / 开新对话。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/ai/agent/agent_json_prompt_budget_test.dart`（20 条重工具时提示 < 6000 字且不含完整 schema；7 家超长错误体样本 → `context_overflow`；429 TPM 限流仍是 `rate_limited`）。
- **备注**：原生 tool calling 路径不受影响（工具 schema 走 API 的 tools 字段，常驻集已按 spec 控制在约 15 条）。
