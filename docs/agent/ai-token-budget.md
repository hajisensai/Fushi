# AI 层 token 度量与「纯浪费」清单

所有者 2026-11-20：给整个 AI 层省额度，**只做不降效果的**。截断 / 摘要历史、截断工具结果、删提示词里影响判断的内容、降模型都不做。本文件记度量方法、实测数字和已修 / 未修项。

## 怎么量（可重复，不联网）

- AI 助手：`fushi/test/ai/agent/ai_agent_token_budget_test.dart`。真实操作目录（全部描述、常驻清单、技能）+ 真实 `AgentSession` + 真实 `AiChatClient` 拼请求体，假 HTTP 端点按脚本回工具调用，记下每轮请求体。`TOKEN|` 行是每轮构成（system / 工具表四类 / 历史 / 各工具结果）和整场汇总。「未命中估算」= 各轮字符总和减去与上一轮按提供商渲染顺序（tools → system → messages）的公共前缀，即理想前缀缓存下仍要全价算的部分。工具结果是照各路由 `toJson` 形状造的样本。
- 助手型请求与统一调用层：`packages/fushi_engine/test/ai/ai_token_waste_guard_test.dart`。
- 历史基线：本机存档（`ai_agent_sessions` 6 场、`library_organize_runs`），只读统计，不出内容。

## 实测（2026-11-20）

**存档基线**（6 场，都早于 11-16 的 Anthropic 尾部滚动断点）：输入 1,089,044 未命中、147,086 缓存读、67,797 缓存写，命中约 11%；每场 assistant 回合 p50 9、最多 21。工具结果占历史字符的 98%（200,310 / 204,107）。按来源：`ops.search` 42.7k（17 次）、`downloads.job.list` 27.4k（1 次）、`library.item.list` 25.3k（9 次）、`video.work.list` 16.8k（1 次）、`ops.describe` 13.0k（25 次，其中描述 + schema 10.9k）。去掉结果里的 null 值只省 0.5%、再去空串 / 空数组也只到 1.8%，所以**不做**结果瘦身。6 场里 4 场 describe 过 `library.item.list` / `video.work.list` / `downloads.job.list`。

**每轮固定部分**（修后）：system 1,553 字符；工具表 元工具 1,130 + 常驻 3,223 + 技能 2,881。各轮逐字相同，前缀缓存能吃到。

**前缀稳定性**：工具表没变的相邻两轮，后一轮总是以前一轮的全部内容开头（只在末尾追加）。system 不含时间 / 计数这类每轮变化的内容，工具结果在历史里存的是编码后的字符串，重发逐字一致，JSON 键序固定。**唯一打断点是 describe**：新工具接在工具表末尾（不插在中间），但工具表排在 system 和历史前面，表一变，system 与整段历史的缓存全失效。

| 场景 | 修前 | 修后 |
|---|---|---|
| 「我视频库里有哪些作品」 | 4 轮，43,741 字符，未命中估算 19,409，工具表变 1 次 | 2 轮，20,800，未命中估算 11,869，变 0 次 |
| 「整理视频库」（search → describe → 3 读 → 2 写） | 8 轮，257,870，未命中估算 89,908 | 8 轮，253,099，未命中估算 86,370 |
| 第二个场景历史里的 describe 结果 | 3,137 字符 | 848 字符 |

助手型请求（单次）：身份消解（6 候选 + 3 页资料）12,235 → 11,559 字符；没有资料时 3,469 → 2,902（-16%）；系列清单 8,794 → 8,680。整理库一块（200 条目 + 150 合集）：system 3,318、user 36,039，其中条目之前的共享上下文（合集 / 已知键 / 拒绝）14,758。

## 已修

1. **常驻工具 id 写错**（`kAiAgentResidentOps`）：初版 10 个里 6 个在目录中从来不存在，被静默跳过，模型每场都要先 search 再 describe 才能列库，多一轮请求，还让缓存整段失效。改成对应的真实 id（`nav.go`、`library.item.list`、`video.work.list`、`downloads.job.list`），`tasks.*` 没有通用等价物不放。守卫：常驻 id 必须都在目录里。
2. **describe 结果重复工具定义**：原生 tool calling 时，describe 过的工具下一轮起就在工具表里，结果里不再放描述和 schema，只给风险 / 确认 / 可撤销 / 长任务标记和调用名（`agentDescribeResult`）。降级协议照旧给全量（系统提示里只有一行签名）。
3. **助手提示的缩进空白**：身份消解、媒体身份、获取意图、别名、系列清单 5 处用户提示从 `JsonEncoder.withIndent('  ')` 改成紧凑 `jsonEncode`，内容逐项相等。守卫：提示里没有缩进。
4. **重试**：核对过，4xx / 鉴权 / 上下文超长 / 空回复 / 输出被截断都不会触发重发（鉴权和额度类只换下一把 key）。补了防回归测试。

## 没修（记录在案）

- describe 让缓存整段失效是「工具表按需扩展」这个设计本身的代价；要消掉只能改协议（例如通用调用工具），会改变模型看到的工具形态，不在本轮范围。
- 整理库多块时，合集上下文每块重发一次。OpenAI 兼容 / DeepSeek / Gemini 在合集不变时靠前缀自动缓存能吃到；Anthropic 只在 system 上挂了断点，而这段 system 约 830 token，低于 Anthropic 的最小缓存长度，等于没缓存。要在共享上下文后面加断点，得先量各块之间合集上下文有多少是逐字相同的，没量之前不改。
- 字幕校对的 LLM 提示（`asr_proofread/` 下多处 `withIndent(' ')`）按规矩去上游 `fushi-subtitles` 改。
- 列表类读操作缺分页 / 过滤：`downloads.job.list`（存档里一次 27k 字符）、`video.work.list`（一次 16.8k）、`video.discovery.resources`。
- 关系推断里 AI 判成「不相关」的一对不落库（`media_link_inference.dart` 的 `applyMediaLinkCandidates`），全库重跑或手动推断时同一对会再问一次 AI。
