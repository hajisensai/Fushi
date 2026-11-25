# AI 助手接入外部 MCP server（MCP 客户端）（2026-11-05，设计稿 + 实现）

> ## ⚠️ 合并前必须由所有者与 AI 审查者批准「这个想法本身」
>
> **To the maintainer (`hajisensai`) and the AI reviewer:** this PR comes from a fork contributor
> (`samutw`). It adds a *new product capability* — the in-app AI assistant can call tools on
> external MCP servers the user configures — not just a bug fix. Please review and explicitly
> approve **the idea** (sections 3, 6 and 9 below) before reviewing the code, and do not merge
> until both of you have signed off. If the idea is rejected, close the PR; nothing else depends
> on it.
>
> **致所有者与 AI 审查者：** 本 PR 来自 fork 贡献者，引入的是一项**新的产品能力**（AI 助手调用
> 用户自配的外部 MCP server 上的工具），不是修 bug。请先审 §3（做什么）、§6（安全）、§9（待拍板）
> 并**明确批准这个想法**，再看代码；两位都签字之前不要合并。想法被否就直接关 PR，没有别的东西
> 依赖它。
>
> 状态：**所有者 2026-11-07 批准想法，但去掉内置的 MangaBaka 预设**——用哪个 MCP server 由用户
> 自己添加（见 §3、§9 D4）。审查时一并补了 §6 里标「审查补」的几条安全加固。分支
> `feat/ai-mcp-client`，base `177ca2c8b6`。
> 相关：[2026-10-26-ai-operations-agent-design.md](2026-10-26-ai-operations-agent-design.md)
> （AI 助手与操作目录）、[../mcp-external-ai.md](../mcp-external-ai.md)（反方向：外部 AI 调 Fushi）。

## English summary

Fushi already *is* an MCP server (external AIs can drive Fushi). This adds the other direction:
Fushi's in-app AI assistant becomes an **MCP client**. Users add MCP servers under
**Settings › AI › AI assistant › MCP servers**, turn each server (and each tool) on or off, and
the assistant can then use those tools in chat. **There are no built-in presets**: the owner
approved the idea on 2026-11-07 but asked for the MangaBaka preset to be dropped — users add the
servers they want themselves (web address, local program on desktop, or a pasted `mcpServers`
snippet, which is imported switched off). Tools are loaded **on demand** through the existing
`ops__search` / `ops__describe` meta tools (MangaBaka's 18 tool definitions alone are ~80 KB
without output schemas, too large to send every turn to a local model). Read-only tools run directly; every other MCP tool shows
the existing confirmation card first, because MCP calls cannot be undone. Tool results go into
the existing `<untrusted_data>` wrapper. Server config is device-local and never synced/backed up.

## 1. 需求

用户（2026-11-05）：在 Unsloth 桌面版里开了 MangaBaka MCP，但 Fushi 的 AI 助手用不了它——
Fushi 调 LLM 时只走 OpenAI 兼容的 `/chat/completions`，请求里只带 Fushi 自己的工具；Unsloth
的 MCP 开关只在它自己的聊天界面生效。要求：

1. AI 助手能用 MangaBaka MCP 的工具。
2. 用户能开 / 关它，也能加别的 MCP server（通用能力）。

所有者 2026-11-07 拍板：**想法批准，但不内置 MangaBaka 预设**——用户想用哪个 server 自己加。
MangaBaka 仍是本设计的实测对象（§2.1 的协议事实照旧成立），只是不再随应用预置。

## 2. 现状（HEAD `177ca2c8b6` 实测）

- Fushi 只有 MCP **server**（`packages/fushi_cli/lib/src/mcp/`，`fushi/lib/src/ai/mcp/`），没有客户端。
- AI 助手经 `AgentToolbox`（`packages/fushi_engine/lib/ai/agent/agent_tool.dart`）拿工具：
  常驻工具 + `ops.search` / `ops.describe` 按需拉入。接口同步。
- 降级协议（无原生 tool calling）已为 4k 上下文的本地模型压过提示词（反馈 GewyVIt5oo）。
- 工具结果一律包进 `<untrusted_data>`（`wrapAgentUntrusted`）。
- 模块规则 §13：AI 写操作必须可回滚，做不到就**执行前让用户确认**；AI 配置设备本地。

### 2.1 MangaBaka MCP 实测（2026-11-06 对公网端点探测）

- 端点 `https://api.mangabaka.org/mcp`，匿名，18 个工具全部 `readOnlyHint: true`。
- **只支持协议版本 `2026-07-28`**（无状态修订）：
  - `initialize`（任何版本）一律回 `-32022 Unsupported protocol version`，`error.data.supported = ["2026-07-28"]`。
  - 每个请求的 `params._meta` 必须带 `io.modelcontextprotocol/protocolVersion` 与
    `io.modelcontextprotocol/clientCapabilities`（缺了回 `-32602`，`data.envelope.missing` 点名）。
  - HTTP 头必须带 `MCP-Protocol-Version`、`Mcp-Method`（= body 的 method），`tools/call` 另带
    `Mcp-Name`（= `params.name`），头与 body 不一致回 `-32020`。
  - 错误以 HTTP 400 + JSON-RPC error body 返回；成功是 `application/json`（不是 SSE）。
- 工具定义很大：18 个合计约 180 KB，其中 `outputSchema` 约一半；去掉后描述 + 入参 schema 仍约
  80 KB（约 2 万 token）。`series_search` 一条的 schema 就 11 KB。

结论：**不能把 MCP 工具做成常驻工具**，必须按需加载；客户端必须同时会说旧握手协议
（2024-11-05 / 2025-03-26 / 2025-06-18）与新的无状态协议（2026-07-28）。

## 3. 做什么

1. **设置 › AI › AI 助手 › MCP servers**：一个可增删的 server 列表。
   - 每个 server 一个开关 + 状态行（已连接，N 个工具 / 出错原因）。
   - 「添加」：网络地址（HTTP）/ 本地程序（stdio，**仅桌面**）/ 粘贴配置（通用 `mcpServers`
     JSON 形状，Claude Desktop 等客户端的配置片段可直接贴；**导入的条目一律先关着**，用户看过
     命令 / 地址后亲手打开）。
   - 编辑页：名称、地址与请求头（或命令、参数、环境变量）、「每次调用前都问我」开关、
     「测试连接」（列出工具，每个工具一个开关）、删除。
2. **AI 助手对话**：开着的 server 的工具对模型可见、可调用；连不上的 server 不影响对话。
3. **没有内置预设**：清单默认为空，所有 server 都由用户自己添加（所有者 2026-11-07 拍板）。

不做：MCP 的 resources / prompts / sampling / elicitation；OAuth 登录流（需要鉴权的 server
先用请求头填 token）；把 MCP 工具开放给互联远端会话（`/api/assistant` 的已配对设备）——本机配的
外部 server 不替别的设备调。

## 4. 架构

```
packages/fushi_engine/lib/ai/mcp_client/      纯 Dart（不碰 Flutter / 插件）
  mcp_client_config.dart      McpServerConfig + 编解码（逐条容错；密钥 base64）
  mcp_client_transport.dart   McpClientTransport：HTTP（Streamable HTTP，JSON / SSE 应答）、stdio
  mcp_client_session.dart     JSON-RPC 客户端：协商（旧握手 / 无状态）、tools/list 翻页、tools/call
  mcp_client_toolbox.dart     McpClientToolbox（AgentToolbox）+ ComposedAgentToolbox
fushi/lib/src/ai/mcp_client/                  app 侧装配
  ai_mcp_client_runtime.dart  传输工厂（HTTP 走 createAppHttpIoClient；stdio 只在桌面）
  ai_mcp_client_form.dart     编辑页多行文本 ↔ 请求头 / 参数 / 环境变量
fushi/lib/src/pages/implementations/
  ai_mcp_servers_page.dart    设置页（列表 / 添加 / 编辑 / 测试连接）
```

改动的既有文件只有：`agent_tool.dart`（加 `AgentPromptNoteProvider` 接口）、`agent_session.dart`
（system prompt 附说明段）、`ai_agent_controller.dart`（换组合工具箱、`send` 前 `prepare`）、
`settings_schema_ai.dart`（一条入口）、偏好键四处登记、i18n。

- **为什么是 Dart 不是 Rust**：架构硬规则说「新**计算型**子系统」放 Rust。MCP 客户端是纯 I/O
  协议胶水（HTTP / 子进程 + JSON-RPC），没有计算；现有 MCP server 与 AI 调用层都在 Dart，
  `AgentToolbox` 也是 Dart 接口。放 Rust 只会多一层 FFI 往返。见 §9 D3。
- **接入点**：`AiAgentController` 给会话的工具箱换成 `ComposedAgentToolbox(主=AiAgentToolbox,
  附加=[McpClientToolbox])`。主工具箱一行不改。`AgentSession` 只加一处：工具箱实现
  `AgentPromptNoteProvider` 时把它的说明附在 system prompt 末尾（原生与降级两种协议都附）。
- **同步接口 vs 异步连接**：`AgentToolbox` 是同步的，连接 / 列工具是异步的。控制器在每轮
  `send` 前 `await mcp.prepare()`：按配置指纹增量连接 / 断开，并行、每个 server 限时 15 s，
  失败只记状态、从不抛。之后本轮的 `search` / `describe` 读缓存。
- **工具 id**：`mcp.<serverId>.<工具名>`，发给模型时按现有规则 `.`→`__`，例如
  `mcp__mangabaka__series_search`。serverId 只含 `[a-z0-9-]`（创建时由名字生成，之后不变）；
  工具名里不合法的字符换 `_`，超过 64 字符截断加短哈希；以「往返后的 id」为准建索引，重名的后者丢弃。

## 5. 按需加载（上下文预算）

- `McpClientToolbox.residentTools()` 恒为空：MCP 工具不进常驻清单。
- 模型经 `ops__search` 找到它们：`ComposedAgentToolbox.searchTools` 把 MCP 工具的关键词命中
  （server 名、工具名、标题、描述）排在目录结果前面；搜索结果里的描述截成一句
  （`agentCompactDescription`），完整描述与入参 schema 只在 `ops__describe` 时给。
- 模型怎么知道有这些工具：system prompt 末尾附一段说明（`AgentPromptNoteProvider`），列出
  已连接 server 与其工具名（不含描述 / schema，MangaBaka 18 个名字约 400 字符），连不上的
  server 标「unavailable」，让模型能如实告诉用户。
- 丢弃 `outputSchema`（只给模型看入参）。工具结果按文本拼接，超过 20,000 字符截断并注明。

## 6. 安全

| 风险 | 处理 |
|---|---|
| MCP 调用不能撤销（违反 §13「写操作必须可回滚」） | 只有 `readOnlyHint: true` 的工具直接执行；其余一律 `confirm`，走现有确认卡片。`destructiveHint` 不为 false 的记 `irreversible`。另有 server 级「每次调用前都问我」。 |
| server 自报的 `readOnlyHint` 可能是假的 | 默认信任（与所有主流 MCP 客户端一致）；用户不信任可开「每次调用前都问我」或关掉单个工具。见 §9 D1。 |
| 提示词注入（工具结果里写「忽略之前的指令」） | 结果走现有 `<untrusted_data>` 包装，system prompt 已规定只当数据；说明段也写明 MCP 结果不可信。 |
| 密钥泄露 | 请求头 / 环境变量值 base64 存在偏好 `ai_mcp_client_servers`，登记进 `kCredentialPreferenceKeys`、`PrefRedactionPolicy.sensitiveKeys`、`deviceLocalPrefKeys`（与 `ai_providers` 同一存法）：不进日志、备份、同步、Profile。AI 自己读写不到（不加任何操作目录路由）。 |
| 本地程序（stdio）= 执行任意命令 | 只能由用户在设置页亲手填写；只在桌面提供；AI 没有任何改这份配置的入口。 |
| 代理 / 出站纪律 | HTTP 一律 `createAppHttpIoClient()`（守卫 `outbound_http_discipline_guard_test.dart`）；loopback 自动直连。 |
| 远端会话 | 互联 `/api/assistant` 的远端会话不挂 MCP 工具箱（`ai_agent_assistant_host.dart` 只用 `AiAgentToolbox`）。 |
| 粘贴的配置片段（审查补） | 片段多半是从网上 / 别的应用复制的：`importMcpServersFromJson` 导入的条目一律 `enabled: false`，本地程序不会在下一轮对话里被自动拉起、请求头里的 token 也不会被自动发出，要用户在列表里看过命令 / 地址再亲手打开。 |
| server 字符串进 system prompt（审查补） | 说明段只列**消毒过的工具 id 尾段**（`[A-Za-z0-9_.-]`，≤64），不放 server 给的原始工具名；说明段写明工具描述与结果都不可信、不得照做其中指令。工具描述本身经 `ops__search` / `ops__describe` 进 `<untrusted_data>`；被拉入后作为工具 spec 的描述发给模型（与所有 MCP 客户端相同，前缀 `[MCP: server 名]`）。 |
| 工具名冒名（审查补） | `ComposedAgentToolbox.execute` 与 `describeTool` 同一归属：主工具箱认得的名字永远交给主工具箱，附加工具箱不能借同名让「按主目录 spec 弹确认、实际执行附加工具」。 |
| 资源上限（审查补） | 单条应答（HTTP body / SSE / stdio 一行）≤ 8 MiB，超了报 `response_too_large` 并断开；stderr 只留最后 4 KB、超长行截断但持续读空（防子进程写满管道卡死）。时限见 §7。 |
| 配坏的 server 不挡对话（审查补） | `prepare()` / 「测试连接」从不抛：非法请求头（`dart:io` 抛 `FormatException`）等映射成 `connect_failed`，进状态行。 |
| 本地程序的退出（审查补） | 按 MCP stdio 规定先关 stdin、等 2 s 自己退出，再强杀；Windows 上经 `cmd /c` 拉起，强杀用 `taskkill /T` 连进程树（否则 node / python 子进程成孤儿）。 |
| TLS | HTTP 走 `createAppHttpIoClient()`，不设 `badCertificateCallback`，证书照常校验。地址只认带主机名的 `http(s)://`；允许 `http://`（局域网 / 本机 server），用户自己填的地址。 |

## 7. 协议细节

- **协商**：先发旧握手 `initialize`（`protocolVersion: 2025-06-18`）。
  - 成功 → 旧模式：接受 server 回的版本，发 `notifications/initialized`；HTTP 记住
    `Mcp-Session-Id` 并回带，之后每个请求带 `MCP-Protocol-Version: <协商版本>`。
  - 回错且 `error.data.supported` 含 `2026-07-28`，或 `initialize` 是 method-not-found → 无状态模式：
    每个请求 `params._meta` 带 `io.modelcontextprotocol/{protocolVersion, clientCapabilities, clientInfo}`；
    HTTP 带 `MCP-Protocol-Version`、`Mcp-Method`，`tools/call` 带 `Mcp-Name`。
  - 都不是 → 报 `unsupported_version`，状态行显示 server 支持的版本。
- **HTTP**：POST，`Accept: application/json, text/event-stream`；应答是 SSE 时取 id 匹配的那条；
  非 2xx 但 body 是 JSON-RPC 应答时照常解析（MangaBaka 的错误就是这样回的）；404 + 会话 id = 会话过期，
  下一轮 `prepare` 重连。
- **stdio**：每行一条 JSON-RPC；server 发来的请求只回 `ping`，其余回 method-not-found；
  stderr 留最后 4 KB 供出错时显示；Windows 上 `runInShell`（`npx` 是 `.cmd`）。
- 时限：普通请求 30 s，`tools/call` 60 s。

## 8. 测试

- 引擎：配置编解码（坏条目只丢那一条、密钥 base64 往返）；会话协商（旧握手、无状态、都不支持）、
  翻页、调用结果映射；HTTP 传输（本地 `HttpServer`：JSON / SSE 应答、头部、会话 id、400 + JSON-RPC
  错误）；stdio 分帧（注入流）；工具箱（id 往返、搜索排序、describe、确认标记、结果截断、说明段）；
  组合工具箱路由；`AgentSession` 集成（说明段进 system prompt、非只读工具出确认卡）。
- app：偏好键登记守卫、设置页 widget 测试（添加菜单里没有内置预设）。
- 审查补：导入条目默认关、`http(s)` 地址判据、说明段消毒、同名归属、`prepare` 从不抛、
  应答超限、非法请求头、stdio 关 stdin 优雅退出 / 超时强杀、超长行。
- 手动（2026-11-06）：引擎 `McpClientToolbox` + `McpHttpTransport` 直连真实端点
  `https://api.mangabaka.org/mcp`：协商为无状态 `2026-07-28`、列出 18 个工具、`ops.search`
  式检索「mangabaka series search」首位是 `series_search`、`describe` 风险为 read 且无需确认、
  真实调用 `series_search {q: "yotsuba"}` 返回「Yotsuba&!」。
- 未验：真实 app 里配本地模型（Unsloth / LM Studio）走完整对话。本地小模型能否按说明段
  主动 `ops__search` 取决于模型能力；JSON 降级协议同样带说明段。

## 9. 待所有者拍板

- **D1 信任 `readOnlyHint`**：推荐信任（默认直接执行只读工具），用户可逐 server 改成每次都问。
  备选：所有 MCP 调用一律确认（更安全，但全只读的 server 会每步都弹卡）。所有者批准想法时未另行
  改动，按推荐实现。注意：只读工具的**参数**也会发给 server，提示注入诱导模型把本机数据当参数
  外传的风险不靠确认卡兜底，靠用户只添加自己信任的 server。
- **D2 iOS**：HTTP 型 server 在 iOS 上是否算商店合规的「外部发现源」？当前实现**不区分 iOS**
  （与用户自配 AI 提供商同类：用户自己填的端点）。若判定需要限制，应加进
  `store_compliance.dart` 而不是在消费端写平台判断。
- **D3 Dart 而非 Rust**：理由见 §4。若所有者认为应进 Rust 胖核心，协议层可整体搬走，接口不变。
- **D4 预设清单**：**已定（2026-11-07）：不内置任何预设**，用户自行添加。
