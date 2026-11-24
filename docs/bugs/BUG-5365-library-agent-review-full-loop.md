## BUG-5365 · AI 助手自动全库复查把整库灌进一场对话爆上下文、失败不记进度无限重跑
- **报告**：2026-11-24（用户：本机库 `fushi.db` 里 AI 操作记录全是「自动全库复查」、一次也没改动）
- **真实性**：✅ 真 bug。根因（修复前 HEAD `21a3dd14ac`）：
  - `fushi/lib/src/media/library_curate/library_agent_review.dart:194` `review()` 只在会话「跑完」时写 `library_agent_review_state`，`llm_error` 直接 `return`，失败什么都不记；于是 `decideLibraryAgentReview`（同文件 `:93`）每次仍判「首次 → 全库」，库管家自动路径（`library_curate_auto.dart` `runAutomaticLibraryCurate`，入库 / 扫描 / 库页加载去抖触发）每次都从头再跑全库，无退避、无熔断。
  - 同文件 `:187` 全库复查是一场无界会话：提示词 `library_agent_review_full_prompt` 让模型把整库 `library.map` 全部读进同一上下文，大库必然撑爆；`packages/fushi_engine/lib/ai/agent/agent_session.dart:15` 会话 token 不设上限，无人值守时也没人能按停止。
- **[x] ① 已修复** — `79c2d52283`：全库复查按 `library.map` 视图分段（一段一场有界会话，游标逐段落盘、下次续跑）；每次尝试都记账（失败指数退避 1h→24h，连败 5 次熔断，换提供商 / 模型 / 地址或重新打开开关解除）；`AgentLimits.maxSessionTokens` 给无人值守会话 25 万 token 上限，单趟复查 75 万。
- **[x] ② 已加自动化测试** — `fushi/test/media/library_curate/library_agent_review_test.dart`（失败后退避期内的触发不发请求、到点从同一段重来；连败熔断与换提供商恢复；分段推进 + 单趟 token 用满停下 + 下次续跑 + 收尾推水位；会话抛异常按失败记；旧版 / 空 / 坏状态解析），`packages/fushi_engine/test/ai/agent/agent_long_task_test.dart`「会话 token 上限 maxSessionTokens」。
- **备注**：没在真实库 / 真实模型上跑过分段复查；真机复测待补（看「AI 操作记录」里 `library_review` 场景每场只读一个窗口、失败后不再一两小时一趟）。

### 实测数据（用户本机库，只读）

`ai_agent_sessions` 里 scene=`library_review` 的会话：11-22 23:16 ～ 11-24 10:30 共 40 趟、合计 2250 万 token、`ai_agent_actions` 0 条。每趟都是自动全库复查：先 `skill.library.reorganize`，然后连续调 `library.map`（view=video 分页到 offset 1200，总 1308 条；games；links ……），单场累计 45～68 万 token 后提供商返回 `empty_response` → notice `llm_error`。`library_agent_review_state` 偏好始终为空。

### 修复

设计写进 spec `docs/specs/2026-11-22-ai-library-agent-design.md` §7.1。

- **分段**（`library_agent_review_state.dart`）：视图顺序 books → manga → video → games → links，窗口库页 100 行、links 50 个作品；每段提示词 `library_agent_review_segment_prompt` 只给一个窗口（`view` / `offset` / `limit`，不顺着 `nextOffset` 翻页）。状态新增 `fullStartedAt` / `fullView` / `fullOffset`，空视图跳过不开会话；全部走完时水位推到这趟全库复查开始的时刻。全库进行中不另做增量。
- **失败记账**：状态新增 `failures` / `retryAt` / `pausedFor`。请求失败 / 取消 / 中断 / 会话抛异常 = 失败，退避 `1h × 2^(n-1)`、封顶 24h；连续 5 次熔断（从首败约 15 小时），记下提供商指纹，换了提供商 / 模型 / 地址或在设置里重新打开开关（`settings_schema_ai.dart`）才恢复。游标与水位失败时不动。
- **token 上限**：引擎 `AgentLimits.maxSessionTokens`（每次请求模型前检查，用满记 `token_budget` 停下；只给无人值守的会话设）；复查会话 25 万（低于实测出错的 45～68 万），单趟复查 75 万（约三段）。撞上限算这一段做完，往下走。
- 旧版只有 `lastReviewAt` / `lastFullAt` / `itemsSinceFull` 的状态、空串、坏 JSON 都照常解析。
