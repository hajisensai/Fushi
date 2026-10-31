# CLI 补齐 + app 内「AI 助手」操作页：共用操作目录（2026-10-26，设计稿）

> 状态：**已实现**（2026-10-26 所有者「完全做完」：§9 其余决策点按推荐执行；实现记录与偏离见 §12）。D1 已拍板（AI 写操作只要求可回滚）；**D9 已拍板（2026-10-26）：装扩展一律先确认**，见 §5.2。
> 相关：[2026-09-22-ai-video-acquisition.md](2026-09-22-ai-video-acquisition.md)、
> [2026-09-28-remote-ai-assistant.md](2026-09-28-remote-ai-assistant.md)、
> [2026-10-20-ai-library-organize-design.md](2026-10-20-ai-library-organize-design.md)、
> `packages/fushi_cli/README.md`、`packages/fushi_server/README.md`。

## 1. 需求

1. **补齐 CLI**：app 里能点的操作，CLI 都要能做。
2. **app 内 AI 操作页**：用户用一句自然语言让 AI 代办，例如下载扩展、视频、字幕，调整设置，处理刮削，处理冲突。
3. **CLI 与 AI 共用代码**：AI 侧应该比 CLI 能做的更多，也应该更好用。

## 2. 现状（2026-10-26，HEAD `d9b9024fc0` 实测）

### 2.1 已有三套「程序化操作面」

| 面 | 位置 | 规模 | 运行在 |
|---|---|---|---|
| 桌面控制通道 + `fushi_cli` | app 侧路由 `fushi/lib/src/platform/desktop/ctl/ctl_*.dart`（约 59 个文件，约 2.9 万行，**317 条 `CtlRoute`**）；CLI 侧命令 `packages/fushi_cli/lib/src/commands/*`（`kCtlCommandGroups`） | 30 个 `/api/admin/*` 域 | 只在桌面开（`main.dart` 的 `_startCtlServer`），手机上没有 |
| 无头服务端 `fushi_server` + `ctl` | `packages/fushi_server/lib/src/{cli.dart,commands/,ctl/,admin/admin_api.dart}` | 约 20 个离线命令；admin API 约 40 条；可经 `/host/*` 代理互联 | 服务器 |
| 互联助手会话 | `packages/fushi_engine/lib/sync/assistant/`（`HostAssistantSession`，`/api/assistant/sessions`） | 只有一个 feature：`videoAcquire` | app 或服务端当 host |

控制通道已经有一条好纪律：每条路由都调用 UI 按钮背后的同一个方法，不另写业务逻辑。另有两条守卫：
- `ctl_cli_route_coverage_guard_test.dart`：双向钉死「路由 ↔ CLI 命令」。
- `settings_cli_action_coverage_test.dart`：设置动作必须声明 CLI 入口。

UI 动作门面守卫 `ctl_ui_action_facade_coverage_guard_test.dart` 目前只登记了一个门面。

### 2.2 CLI 缺口（`fushi_cli` 没覆盖的域）

| 缺口 | app 里的可编程入口（已存在） | 备注 |
|---|---|---|
| 音乐库：列表、刮削、手动指定录音、歌单、播放遥控 | `MusicScrapeService.scrapeTrack(trackUid, {manualRecordingId})` / `scrapeLibrary`（`media/music/metadata/music_scrape_service.dart:333/460`） | `LibraryCtlKind` 没有 music，`ctl_library_routes.dart:933` 把 `SourceLibraryKind.music` 映射成 false |
| SRS 复习：牌组和笔记查询、统计、sync v2 冲突、重复笔记合并 | `SrsDbStore.sync2Conflicts` / `sync2Resolve`、`syncConflicts` / `resolveConflict`、`duplicateNoteGroups` / `mergeNotes`（`fushi_engine/lib/srs/`，无 UI 依赖） | 冲突中心页 `srs_conflicts_page.dart` 直接调 store |
| 同步过程中的冲突弹窗 | `SyncConflictPrompter`（`sync/sync_conflict_prompter.dart`，依赖 `navigatorKey.currentContext`） | 云同步差异已有 `fushi_cli sync compare / compare-apply`（`sync/sync_compare_cli.dart`）；但 `/api/admin/sync/run` 走 `runManualSyncWithFeedback(context:)`，同步中途的冲突只能在弹窗里选 |
| 书的元数据和封面刮削 | `BookMetadataScraper.search/fetchById/searchDlsite`（`media/metadata/book_metadata_scraper.dart`） | 写回逻辑写在对话框 `showBookCoverScrapeDialog` 里，要先抽出来 |
| 人物、跨媒体关联（作品图谱建议的接受和拒绝） | `media/links/`、`media/people/` | 无路由 |
| 碟片（DVD / BD 菜单、光驱交接） | `media/video/disc*` | 无路由 |
| YouTube 等 URL 视频导入 | `youtube_source_resolver.dart`（engine） | `ctl/` 下 `youtube` 零命中 |
| 内置浏览器、广告拦截规则 | `web_browser/`、`web_adblock/` | 无路由 |
| 「发现 → 一键获取」的风险确认框 | `startDiscoveryItemDownload({required BuildContext context})` | 现在借 `navigator.context` 弹框；CLI 场景语义不清 |

### 2.3 现有 AI 层的限制

LLM 层是 `packages/fushi_engine/lib/ai/ai_chat_client.dart`（`AiChatClient`），支持三种协议、18 个预设。限制如下：
- **不支持 tool calling，不支持流式**：三个 payload 构造器里都没有 `tools` 字段。
- 消息角色只有 system、user、assistant 三种。
- 结构化输出只能靠提示词要求 JSON，再用 `decodeAiJsonObject` 从回复里抠。

AI 规则（`fushi/CLAUDE.md` §13，所有者 2026-10-26 拍板改写）：**AI 的写操作必须可回滚。** 旧写法「AI 只在候选里选、产物先进草稿 / 待确认」不是所有者的规定，已从规则里删掉。所以 AI 可以直接执行、直接落库，前提是能撤销，见 §5。

## 3. 总体方案：一份「操作目录」，三个前端

```
                   ┌───────────────────── OpCatalog（操作目录） ─────────────────────┐
                   │  每条 FushiOp = id + 说明 + 参数 schema + 风险级 + 可用性 + handler │
                   │  handler = 今天 CtlRoute 的处理器（调 UI 按钮背后的同一方法）        │
                   └──────────────┬──────────────────┬──────────────────┬───────────┘
                                  │                  │                  │
                     HTTP 适配（桌面）        进程内调用（五平台）     互联会话（远端）
                        /api/admin/*            OpInvoker            /api/assistant
                                  │                  │                  │
                             fushi_cli          AI 助手页         手机 → 电脑/服务端
                   （手写命令 + 通用 op 命令）  （agent loop）       的 AI 助手
```

要点如下：

1. **路由升级为带描述的操作（`FushiOp`）**：
   - 在现有 `CtlRoute` 上加描述信息：稳定 id、给模型看的英文说明、参数 JSON Schema、风险级、可用性谓词。
   - handler 原样复用，**不另写业务逻辑**。
   - HTTP 路径由操作派生，CLI 线协议不变。
2. **控制通道搬出 `platform/desktop/`**：
   - 路由本质上是「app 进程内调用 AppModel」，并不依赖桌面。
   - 目录改为 `fushi/lib/src/ops/`，`DesktopCtlContext` 改为 `OpContext`（`focusMainWindow` 变成可选）。
   - 桌面照旧在上面挂 HTTP 服务；手机只用进程内 `OpInvoker`。
3. **AI 助手 = 操作目录 + agent loop + 操作记录与撤销**：
   - AI 能调用的就是这份目录，CLI 能做的 AI 都能做。
   - AI 额外多出三类能力：只在进程内有意义的操作（§6.2）、组合技能、界面上下文。
4. **CLI 补齐分两路**：
   - 手写命令按 §2.2 补齐缺失的域，保留人类可读的好用参数。
   - 新增通用命令 `fushi_cli op ls|describe|call`：只要操作有描述，CLI 就自动可用。这一条把「补齐」从一次性的工作变成结构保证。

### 3.1 为什么不另起一套「AI 工具层」

- 317 条路由已经做过一遍「UI 动作 → 可编程入口」的抽取，也有门禁守着。再写一套 AI 工具，就是第二份业务入口，迟早与 UI 分叉。
- 同一份目录还让三个前端的权限判断一致：AI 被拒、CLI 被拒、UI 置灰，判据只写一处（如 `StoreRestrictedCapability`、模块开关）。

### 3.2 为什么不直接让 AI 调 `fushi_cli`（子进程 / HTTP 回环）

- 手机上没有控制通道，也没有 CLI。
- 走 HTTP 回环会丢掉进程内才有的能力：当前页面上下文、在 UI 上弹候选让用户点、导航高亮。
- 路由本来就跑在 UI isolate 上，进程内直接调用的成本更低。

## 4. 操作目录（`FushiOp`）

### 4.1 描述结构（放在 `packages/fushi_cli`：纯 Dart，app、CLI、将来的服务端都能依赖）

```dart
enum OpRisk {
  read,          // 只读：列表、查询、状态
  write,         // 写，且有 undo：改设置、启停扩展、入下载队列、建合集、软删条目
                 // （可另加 confirm: true 强制先确认，见 §5.2「装扩展」）
  irreversible,  // 写，但撤销不了：删用户磁盘文件、清扩展数据、运行未签名 / 明文 http 来源的扩展、
                 // 把数据发给已指派 LLM 以外的第三方（云 OCR 等）
}

class OpParam {            // 生成 JSON Schema 子集：string/int/bool/enum/list/object
  const OpParam.string(this.name, {required this.description, this.required = false, ...});
  // ...
  final bool userGate;      // true = 只能由用户确认界面填（confirm / yes / trustSigner / consentUpload）
}

class FushiOp {
  final String id;                // 'video.subtitle.search'，点分域名，稳定、可做持久化 key
  final String summary;           // 给模型和 `op ls` 用的英文一句话
  final List<OpParam> params;
  final OpRisk risk;
  final bool longRunning;         // 返回 taskId，进度经 task.get/wait
  final bool needsUi;             // 要弹 app 内对话框或候选（AI 页可满足，CLI 需显式参数）
  final OpAvailability Function(OpContext)? availability;  // 平台、合规、模块、前置条件 → 可用 / 不可用 + 短码
  final OpUndo? undo;             // 可撤销的写：在执行前抓快照，返回撤销句柄
  final bool confirm;             // 即使可撤销也必须先出确认卡片（装扩展，§5.2）
  final CtlRoute route;           // 现有路由，handler 不变
}
```

- **`userGate` 参数是安全关键**：今天的路由靠 `confirm=true`、`yes`、`trustSigner`、`allowInsecure`、`consentUpload`、`consentLlm` 表态。AI 前端把这些参数**从给模型看的 schema 里删掉**，由运行时按 §5.2 填：
  - 有 `undo` 的可逆操作，运行时直接注入，不打扰用户。
  - 不可逆操作，只在用户点了确认卡片后才注入。

  模型无论被什么内容诱导，都没法自己把不可逆操作填成「已确认」。CLI 保持现状，这些参数照旧是用户自己敲的 flag。
- id 命名沿用 CLI 的域、命令结构（`fushi_cli video sub-search` 对应 `video.subtitle.search`），i18n 不进描述：模型看英文，UI 卡片用 i18n key 渲染。

### 4.2 迁移策略：棘轮，而不是一次性改 317 条

1. 加 `FushiOp` 结构与 `OpCatalog`。`CtlRoute` 加可选的 `op` 字段；**只有带描述的路由才对 AI 可见**，没描述的照旧只给 CLI 用。
2. 新守卫 `op_catalog_ratchet_guard_test.dart`：
   - 没有描述的路由数只许减不许增，新增路由必须带描述。
   - 每条带描述的操作，其 `userGate` 参数必须真被 handler 读取（防止描述与实现漂移）。
     - **非 `read` 操作必须二选一**：声明 `undo`；或标成 `irreversible` 并至少有一个 `userGate` 参数。这条把「AI 写操作必须可回滚」钉成结构约束。
   - 扩展安装类操作（`online.extension.install*` / `online.repo.add`）必须 `confirm: true`（D9）。
3. 按 §8 的阶段优先描述高频域：设置、下载、字幕、扩展、刮削、冲突、库查询、导航。

### 4.3 设置：不逐项写操作，走 schema

设置项有声明式 schema。`buildSettingsSchema`、`flattenVisibleSettings`、`SettingsSearchEntry` 自带标题、面包屑、选项标签和同义词表 `settings_search_synonyms.dart`，并且已经有 `cliValue`。所以设置只需要四个通用操作：

| 操作 | 风险 | 说明 |
|---|---|---|
| `settings.search(query)` | read | 复用设置搜索的匹配和同义词；返回 id、标题、面包屑、类型、当前值、可选值 |
| `settings.get(id)` | read | |
| `settings.set(id, value)` | write | 走设置项自己的 onChanged，与在设置页操作等价；执行前记录旧值，撤销 = 写回旧值 |
| `settings.run(id)` | 按动作声明 | 动作项（清缓存、测试连接…）复用 `SettingsActionItem.cli` |

密钥类设置沿用 `isCtlSecretSetting`：对 AI **不可读不可写**。API key、密码只能用户自己在设置页填。

## 5. AI 助手：执行模型

### 5.1 规则：写操作必须可回滚（所有者 2026-10-26 拍板）

AI 直接执行，不先进草稿，也不逐条审批。唯一的硬要求是能撤销。落到实现上是三条：

- AI 只能调用**操作目录**里的操作。参数过 schema 和 handler 自己的校验，越界或不存在一律 400 / 404 回给模型。
- 执行的全部是现有 handler，与按钮背后同一个方法。
- 新增 `AiFeature.agent`（「AI 助手」）。没指派提供商时入口可见，点击引导去「设置 › 模型 › LLM」，不发任何请求。

### 5.2 执行方式按「能不能撤销」分

| 风险 | 行为 |
|---|---|
| `read` | 直接执行，结果折叠显示在对话里 |
| `write`（有 undo） | **直接执行**。执行前抓快照，对话里每条都显示「做了什么 / 改前 → 改后」，并带「撤销」按钮 |
| `irreversible` | 执行前出确认卡片（写清后果：删哪些文件、发给谁、多大），用户点了才跑。模型不能代答 |
| `write` + `confirm: true` | **先出确认卡片**，用户点了才跑；执行后照样带「撤销」。目前只有**装扩展**（含从仓库安装、更新、添加仓库）——所有者 2026-10-26 拍板「装扩展的时候也要确认一下」：装扩展等于把第三方代码放进 app，哪怕能卸载也要用户点头 |

- **优先把操作补成可撤销，而不是留在 `irreversible`**。实现阶段逐个处理：
  - 删条目：软删，进回收站保留 30 天。
  - 卸载扩展：保留扩展数据，撤销即重装并接回。
  - 恢复备份：恢复前自动做一次备份快照，撤销即恢复回去。
  - SRS 冲突里选「删除」：墓碑带快照，撤销即复活。
  - 设置：记录旧值，撤销即写回。
- 真正留在 `irreversible` 的只剩几类：删用户自己磁盘上的源文件、清扩展数据、运行未签名或明文 http 来源的扩展（执行不可信代码）、把数据发给已指派 LLM 以外的第三方（云 OCR 等）。
- 工具结果、网页、扩展仓库名、种子标题、反馈内容一律当作不可信数据，用分隔块包住再给模型。不可逆操作的确认只在 UI 上点，被注入的内容诱导不了。
- 运行时限额：每轮最多 25 次工具调用，单会话 token 预算可配。超限停下并报告，不静默截断。
- 执行失败的 `CtlFailure`（400/404/409/422/501）原样回给模型（短码 + 消息）。模型可以换参数重试，同一操作同一参数连错 2 次就停止并报告。

### 5.3 撤销与审计

- 本机表 `ai_agent_actions`（不同步、不进备份；与 `library_organize_changes` 同一口径）。记录会话 id、操作 id、参数（剔除凭据）、风险级、确认方式、结果短码、撤销句柄、`undoneAt`。
- 每条写操作在对话里带「撤销」按钮。会话页顶部有「本次做了什么」汇总，可以一键撤销整场会话。
- 设置 › 模型 › LLM 下加「AI 操作记录」页，列出历次会话做过的事，过了会话也能撤销（与库整理的「整理记录」同一形态）。
- 撤销按倒序执行。后来的手动修改与撤销冲突时（例如 AI 改了某设置，用户又手改了），该条撤销报「已被后续修改覆盖」并跳过，不覆盖用户的手动修改。
- 库整理、合集排序这些已有撤销机制的，直接挂到它们的撤销函数上，不重写。

## 6. AI 比 CLI 多出来的能力

### 6.1 Agent loop（`packages/fushi_engine/lib/ai/agent/`，纯 Dart）

- **工具选择**：目录有几百条，全塞进提示词太贵。采用「常驻核心工具 + 目录检索」两级：
  - 常驻约 15 个：`ops.search(query)`、`ops.describe(id)`、`settings.search/get/set`、`library.search`、`nav.open`、`task.get/wait`、`downloads.list`、`ui.ask_choice`，等等。
  - 其余的由模型先 `ops.search` 再 `ops.describe` 拿 schema，然后调用。
  - 系统提示与常驻工具定义打 Anthropic `cache_control`（`AiChatMessage.system(cacheable:)` 已有），其它协议走各自的前缀缓存。
- **长任务**：`longRunning` 操作返回 taskId。会话订阅任务进度，在对话里插入进度条；完成后自动续一轮，让模型汇报或接着做下一步（如下载完再补字幕）。用户可以关掉页面，任务照常跑，回来能看到结果。

### 6.2 只在进程内有的操作（不进 CLI）

| 能力 | 例子 |
|---|---|
| 界面上下文 | 「这个视频」「这本书」= 当前打开的条目或选中项。进入页面时把当前页面、条目 id、播放或阅读位置作为上下文注入 |
| 候选交给用户点（`ui.ask_choice`） | 刮削候选、字幕候选、扩展搜索结果、冲突两侧，**渲染成可点的卡片**，用户点选比模型猜更可靠。这正是现有边界「在候选里选」的自然延伸 |
| 导航与高亮（`nav.open`） | 打开到某个设置项并高亮（复用 `SettingsSearchReveal`），打开某条目、某页签，让用户自己看或改 |
| 内嵌现有专门助手 | 「AI 下视频」会话、库整理、合集排序、视频 AI 识别，作为子流程嵌进对话（复用 `VideoAcquisitionSession` 的视图），不重写 |

### 6.3 组合技能（skills）

技能是确定性的多步配方，模型只负责选择技能和填参数，步骤由代码编排：
- **补字幕**：对某作品或合集逐集 `video.subtitle.search`。命中唯一的直接装，多候选的汇总成一张选择卡，都查不到的直接用 ASR 生成（撤销 = 删掉生成的字幕）。要走 LLM 校对的，先在对话里报一句费用估算（`estimateCost`）。
- **处理刮削**：拉待确认队列。高置信的直接认领（撤销 = 退回待确认），歧义的出候选卡让用户点，查无的自动改名重搜或用 AI 识别，仍不行就留在队列里报告。
- **处理冲突**：汇总 SRS sync v2 冲突、云同步差异、重复笔记，按规则直接裁决（如「两侧相同只是时间戳不同 → 取新」），删除侧走带快照的墓碑，整批可撤销；规则判不了的出候选卡。
- **扩展**：「装一个能看 X 的源」= 搜仓库、列候选扩展、安装（撤销 = 卸载）、试搜 X 验证可用。**安装一律先出确认卡片**（§5.2，D9），卡片写明扩展名、来源仓库、签名状态；未签名或明文 http 的扩展在卡片上额外标红警告。

### 6.4 悬浮球入口（所有者 2026-10-26 要求）

悬浮球加一个「AI」按钮：`FloatingBallGlobalAction.ai('ai')`，任何场景都能放，也可以设成单击直达（`FloatingBallTapAction.ai`）。默认放进 `general` / `reader` / `manga` / `video` 四个应用内场景的按钮组；应用外球默认不勾，由用户自己加。

| 球 | 点「AI」之后 |
|---|---|
| 应用内球（全平台） | 在当前页上方弹出 **AI 浮层**：手机是半屏底部面板，桌面是靠边的侧栏；不离开当前页。按球的场景自动带上下文：阅读器 / 漫画 = 当前书和位置、视频 = 当前作品、集数和播放时间、其它页 = 当前页签。例如在视频页说「这集没字幕，找一个」，「这集」自动解析成当前集。浮层右上角可以「展开成整页」 |
| Android 应用外球 | 与 `popupLookup` 同一形态：弹出独立的小 AI 窗（同 `PopupDictFlutterActivity` 的独立 Flutter Activity），盖在当前 app 上，不把 Fushi 拉到前台。另带一个「附上屏幕文字」开关：打开时先走截屏 OCR，把识别出的文字作为上下文（如「这是什么番，帮我下下来」） |
| Windows / macOS 应用外球 | 把主窗唤到前台并打开 AI 浮层（与 `sync` / `switchProfile` 的应用外语义一致）；同样可附截屏 OCR 文字 |

- 浮层和整页是同一个会话对象：从浮层展开成整页、或从整页收回浮层，都不丢对话。
- 浮层同样遵守「新模块必须带动效」：面板进出走 `fushiMotionDuration`，消息列表走 `FushiStaggeredEntrance`。MD3 与 Apple 两套都接。
- 球上的按钮文字、tooltip 与无障碍名称用 i18n key `floating_ball_action_ai`。
- AI 模块被关掉（`ModuleId.ai`）或 iOS 合规门不过时，球上不出这个按钮。没指派提供商时按钮照常出，点了引导去「设置 › 模型 › LLM」，不发任何请求。

### 6.5 远端执行

手机没配 AI 或没有下载后端时，沿用「下载执行设备」的思路：整场 AI 助手会话交给已配对电脑或服务端跑（`/api/assistant` 加 feature `agent`）。手机只渲染与语言无关的视图快照。现有 `HostAssistantSessions` 会话表、长轮询、闲置回收直接复用。服务端只描述了它自己那部分操作，所以远端可用的工具集按 host 能力位报。

## 7. LLM 层改造（`AiChatClient`）

1. **tool calling 三协议**：
   - OpenAI 兼容：`tools` / `tool_choice` / `tool_calls` / `role: tool`。
   - Anthropic：`tools` / `tool_use` / `tool_result`。
   - Gemini：`functionDeclarations` / `functionCall` / `functionResponse`。
   - 消息模型加 `AiChatToolCall`、`AiChatToolResult`。现有 `complete()` 签名不动，新加 `chat(messages, tools:)`。
2. **能力位**：预设加 `supportsTools`。本地模型（Ollama、LM Studio）和部分国产兼容端点不稳定，用户可在提供商上覆盖。**不支持时的降级**：提示词约束「只回一个 JSON 动作」，用现有 `decodeAiJsonObject` 解析，走同一个执行和确认管线（D2）。
3. **流式**（第二阶段）：只为对话页「打字效果」和早取消服务，不影响执行语义；先不做也不阻塞功能。
4. 错误短码、限频、key 轮换、`reasoningEffort` 全部沿用。测试用录制的三协议 fixture 做往返单测，不打真网。

## 8. 分阶段

| 阶段 | 内容 | 产出可验证点 |
|---|---|---|
| **P0 地基** | ① `FushiOp` / `OpCatalog` / `OpInvoker` + 棘轮守卫 ② `ctl/` 搬到 `ops/`，`OpContext` 去桌面化 ③ `AiChatClient` 三协议 tool calling + 降级 JSON 协议 ④ `AiFeature.agent` | 单测：三协议 fixture 往返；`OpInvoker` 进程内调通现有路由测试；`fushi_cli` 全部既有测试不变 |
| **P1 AI 助手页 v1 + 悬浮球** | agent loop、操作记录与撤销（含「AI 操作记录」页）、不可逆操作的确认卡片、`ui.ask_choice`、`nav.open`；AI 整页 + 应用内悬浮球 AI 浮层（带场景上下文）；描述第一批操作：设置（§4.3）、下载中心、在线字幕、扩展仓库和安装、视频刮削确认、库查询、导航 | 集成测试（焦点驱动）跑「把字幕字号调大 → 撤销」「装 X 扩展 → 撤销」「在视频页经悬浮球说『这集补字幕』」三条脚本；用 stub LLM 回放固定工具调用序列 |
| **P2 CLI 补齐** | §2.2 各缺口：music、srs、sync 冲突、书刮削（先把写回从对话框抽成门面）、links / people、disc、URL 导入、web；`fushi_cli op ls/describe/call`；`fushi_cli ai ask "<一句话>"`（终端版 AI 助手；`ai` 组已被 AI 提供商命令占用，做成同组子命令：可逆操作直接执行并打印撤销命令 `fushi_cli ai undo <id>`，不可逆操作在终端里 y/N 确认） | 路由覆盖守卫 + 新门面登记进 `_facades`；每个新域一份命令测试 |
| **P3 技能、应用外球与远端** | §6.3 四个技能；Android 应用外球的独立 AI 小窗与桌面应用外球入口（含附截屏 OCR 文字）；`/api/assistant` feature `agent`；服务端描述自己的 admin 操作并接入 | 技能用 stub LLM 端到端测试；互联会话测试沿用 assistant 测试结构 |

AI 助手是 IO 和编排代码，按「Rust 胖核心」规则留在 Dart（不是计算型子系统）。

## 9. 需要所有者拍板

| # | 决策 | 状态 / 推荐 |
|---|---|---|
| D1 | AI 能否直接执行操作 | **已拍板（2026-10-26）**：能，唯一要求是写操作可回滚；旧「只在候选里选、先进草稿」规则已从 `fushi/CLAUDE.md` 删除 |
| D2 | 提供商不支持 tool calling 时 | 降级成「只回一个 JSON 动作」协议，同一管线；不拒用 |
| D3 | 撤销记录保留多久 | 推荐 30 天（与软删回收站同期），过期只删记录和快照，不动已生效的改动 |
| D4 | 入口放哪 | **悬浮球已拍板**（§6.4）。其余推荐：① 首页 dashboard 一张「AI 助手」卡 ② 桌面全局快捷键（如 Ctrl+K）呼出同一个浮层 ③ 各页顶栏「问 AI」（带当前页面上下文，走 `adaptiveOverflow`）。不新增主导航页签。**2026-10-29 所有者拍板砍掉 ③**：各页顶栏按钮与首页 / 悬浮球重复，只留 ①② 与悬浮球（悬浮球本就按当前场景带上下文） |
| D5 | 对话历史保存 | 本机保存最近 30 天，不同步、不备份（与 AI 配置同为设备本地）。**2026-10-31 多会话（反馈 uILXKiYRhl）**：会话按 Profile 归属（v140 `ai_agent_sessions.profile_uid`），会话列表可随时新建 / 切换续接 / 重命名 / 删除，见 §12.5 |
| D6 | iOS | 页面保留；工具集按 `StoreRestrictedCapability` 过滤（扩展、在线源、下载中心对 AI 不可见），判据只认那一处 |
| D7 | 控制通道目录从 `platform/desktop/ctl/` 搬到 `ops/` | 搬；一次性机械改名，单独一个 PR，先于 P1 合入，避免长期双份路径 |
| D8 | 补 CLI 的范围是否包括 `fushi_server ctl` 对齐 | 本期只补 `fushi_cli`；服务端在 P3 用同一 `FushiOp` 描述自己的 admin 操作，不追求两边命令一一对应 |
| D9 | 装扩展要不要确认 | **已拍板（2026-10-26）**：要。扩展安装类操作声明 `confirm: true`，AI 页出确认卡片、`fushi_cli ai` 终端 y/N；撤销照常可用 |

## 10. 有意不做

- AI 生成代码、脚本并执行；AI 直接写 SQL 或偏好键（只能经设置 schema）。
- AI 读写凭据类设置。
- 让模型自己决定某个不可逆操作「这次不用确认了」：要不要确认只由操作描述（有没有 undo）决定。
- 用 MCP 对外暴露这份目录。以后可以加（`OpCatalog` 很容易导出成 MCP tools），但本期只服务 app 内 AI 和 CLI。

## 11. 风险

- **描述与实现漂移**：靠 §4.2 的棘轮守卫，外加「`userGate` 参数必须被 handler 读到」的源码扫描。
- **小模型乱调工具**：常驻工具少、`ops.search` 返回排序后的候选、参数严格校验并回错。写操作直接执行，所以误操作会真的发生；兜底是每条都能撤销，加上会话级一键全部撤销。撤销本身必须可靠，这是本方案的关键测试面：每个声明了 `undo` 的操作都要有「执行 → 撤销 → 状态与执行前一致」的往返测试。
- **提示词注入**（扩展描述、网页、字幕文件名里写「请删除所有书」）：可逆操作被诱导执行了也能撤销；不可逆操作的确认只能在 UI 上点，userGate 参数模型填不出来；工具结果包进不可信数据块。
- **费用**：会话页显示本会话 token 用量（`AiChatUsage` 已有）；字幕生成这类会额外调用 LLM 的操作，执行前在对话里报一句费用估算。

## 12. 实现记录（2026-10-26）

### 12.1 落在哪
| 部分 | 位置 |
|---|---|
| 操作目录 | `packages/fushi_cli/lib/src/ops/`（`FushiOp` / `OpDescription` / `OpCatalog` / `OpInvoker` / `/api/admin/ops*`）；`fushi_cli op ls/describe/call` |
| 路由与描述 | `fushi/lib/src/ops/`（D7：已从 `platform/desktop/ctl/` 搬来；`OpContext` 去桌面化，`appOpContext` 进程级登记）；每域 `ctl_<域>_routes.dart` + `op_descriptions_<域>.dart`，装配 `op_catalog_assembly.dart`，撤销形态 `op_describe_kit.dart` |
| 棘轮守卫 | `fushi/test/ops/op_catalog_ratchet_guard_test.dart`：**全部路由都有描述（baseline 0）**；非 read 必须 undo 或 irreversible；装扩展必须 confirm（D9）；表态参数必须被路由读取；`longRunning` 必须有 `taskStatus` |
| LLM 层 | `AiChatClient.chat(messages, tools:)` 三协议 tool calling；提供商 `toolCallingOverride` 覆盖（设置页「工具调用」）；不支持时走「只回一个 JSON 动作」降级（D2） |
| agent loop | `packages/fushi_engine/lib/ai/agent/`：确认 / 记账 / 撤销策略、元工具（`ops.search` / `ops.describe` / `ui.ask_choice`）、限额、不可信数据块、长任务续轮、技能执行、存档 |
| app 侧 | `fushi/lib/src/ai/agent/`：`AiAgentToolbox`（记账进 v136 `ai_agent_actions`、结果凭据脱敏、长任务轮询）、`AiAgentController`、4 个技能、远端会话适配；界面 `ai_agent_page.dart`（整页 / 半屏 / 侧栏）与 `ai_agent_history_page.dart`（AI 操作记录） |
| 入口 | 悬浮球「AI」（应用内 / 桌面应用外 / Android 应用外 + 单击直达）、首页「AI 助手」条、全局快捷键 Ctrl+J、设置 › 模型 › LLM（各页顶栏「问 AI」已于 2026-10-29 删除） |
| 终端 | `fushi_cli ai ask / undo / log`（`/api/admin/ai/agent/*`，不进操作目录） |
| 远端 | `/api/assistant` feature `agent`（引擎 `agent_assistant_host.dart`）；app 当 host 用本机目录；服务端用 `fushi_server/lib/src/admin/admin_ops.dart` 描述的 admin 操作 |

### 12.2 与设计稿的偏离（及原因）
- **终端命令名**：`fushi_cli ai ask "<一句话>"`，不是 `fushi_cli ai "<一句话>"`——`ai` 组已是 AI 提供商命令组。
- **Android 应用外球「AI」**：把 Fushi 拉到前台再开 AI 浮层（与「同步」同一语义），**不是**独立小窗。AI 助手要主进程的完整 AppModel（操作目录、数据库、导航）；`:popup` 进程只有精简初始化，在那里跑目录要跨进程开库，风险大于收益。
- **附上屏幕文字**：截的是 Fushi 自己的窗口（复用反馈截图）再走系统 OCR；Android 应用外截屏 OCR 的结果只留在原生侧做点字，拿不到全文。macOS 上 WKWebView 正文截不到；Linux 没有系统 OCR，不出按钮。
- **刮削技能**：没有「清除作品身份、退回待确认」的路由，认领撤销不了，所以每部作品都出候选卡由用户点（卡片即确认），不自动认领高置信候选。
- **不可逆操作不强制带表态参数**：路由本身没有 `confirm` 的不可逆操作照样只出确认卡片；确认由 AI 运行时按描述强制，模型改不了。
- **SRS 冲突「保留」**：撤销需要 Rust 胖核心的「重开冲突」命令，暂为不可逆（选「删除」可撤销）。
- **恢复备份**：路由不在恢复前自动快照，仍为不可逆。
- **远端执行默认关（服务端与 app 同一判据）**：已配对设备经 AI 能调到 host 的操作，比配对本来给的权限多，所以服务端要在 `ai.agent_for_peers` 显式打开；app 当 host 时同样默认关，用户在「设置 › 模型 › LLM › AI 助手」打开「允许已配对设备使用 AI 助手」（设备本地偏好 `ai_agent_for_peers`）。这是授权开关，`SettingsSwitchItem.userOnly`：AI 自己的 `settings.set` 写不进去，设置页与 `fushi_cli` 照常（2026-10-27 审查修正：原先 app 侧默认放行）。
- **向模型给的地址发请求 = 不可撤销的出站**（2026-10-27 审查）：路径 / query 能夹带模型看到的任何数据，撤销收不回，按 §5.2「把数据发给第三方」处理。`web.open` 定为 `irreversible`；`url.import`（直链会让 ffmpeg 请求该地址抽封面帧）与 `settings.ai.provider.add`（新提供商的地址随后会收到探测与对话）加 `confirm: true`、仍可撤销。`url.probe` 保持 read：只对 YouTube 地址联网且只发往 YouTube（youtube_explode 只取 videoId），直链不联网。棘轮守卫按参数名扫地址类参数，新操作带地址参数却不先确认会变红（豁免表写明理由）。
- **带凭据服务的地址模型不可写**（2026-10-27 审查）：qBittorrent / AnkiConnect / OpenSubtitles / 网络代理 / OPDS / AList / Audiobookshelf / Jellyfin / Plex / Torznab 等，改地址会把已存的密码 / token 发去新地址。判据按结构自动枚举（`fushi/lib/src/ops/ctl_settings_credential_endpoints.dart`：同一配置里有凭据项 + 名字像地址或 URL 键盘的项；记录列表的地址字段；带凭据配置里动作的地址参数），路由按 `CtlCall.fromModel`（只由 `OpInvoker` 以 `OpCaller.model` 调用时置位，模型填不出来）拒；设置页、`fushi_cli`、撤销照常。守卫 `fushi/test/ops/ctl_settings_credential_endpoint_guard_test.dart` 对枚举出的每一项实调路由。机密值本身同样按 `fromModel` 兜底拒写。
- **服务端磁力链接的地址参数**（2026-10-27 审查）：`server.download.add` 拒绝带 `tr=` / `ws=` / `xs=` / `as=` / `x.pe=`（含 `tr.1` 编号写法）的磁力，带地址的走 `server.download.add-with-trackers`（`confirm: true`、仍可撤销，确认卡片显示完整链接）。不做「已知 tracker」白名单：服务端这层没有可信列表，按主机放行也挡不住 `udp://known:1337/announce?<数据>`；纯 DHT 磁力照常直接执行。
- **歌单**：只读（仓储没有写方法，UI 也没有）。

### 12.3 顺带修掉的问题
BUG-3783（字幕补全把已存在的同名字幕报成「已安装」）、BUG-3784（并发 `ensureDefaultProfile` 撞唯一约束；`_copyProfile` 找不到时回退成源 Profile）、BUG-3785（删音乐扫描根留下孤儿曲目）、BUG-3786（LNReader 卸载静默删除插件登录态）；`PUT /api/admin/ai/providers/:id` 现在认显式空串。

### 12.5 多会话（2026-10-31，反馈 uILXKiYRhl）

- **数据结构**：一行 `ai_agent_sessions` = 一场会话，消息（条目 + 模型历史 + 用量）整场序列化在 `payload_json` 里随会话存取——本来就撑得起多会话，缺的是归属与标题语义。v140 加 `profile_uid`（所属 Profile 的全局身份；用 uid 不用自增 id，因为本表设备本地、覆盖恢复后原样回灌而 `profiles` 随备份恢复），存量存档按迁移时的激活 Profile 回填，解析不出 uid 的留空串（对所有 Profile 可见）。操作记录仍不分 Profile。
- **写入口唯一**：本机 AI 页与互联 host 替远端跑的会话都走 `saveAiAgentSessionArchive` → `FushiDatabase.saveAiAgentSessionSnapshot`。首次落库定标题（首条用户消息摘要，空白折叠、60 码点截断）、归属与创建时刻；之后整场重存只更新场景 / 内容 / 用量 / `updated_at`，用户重命名的标题不会被下一轮对话冲掉，中途切 Profile 也不改换门庭。
- **会话库**：`AiAgentController` 实现 `AiAgentSessionLibrary`（`ai_agent_conversation_controller.dart`）：列表只投影元数据列（不读 `payload_json`），切换前先存好当前这场，删除当前这场换成新对话、在途一轮的收尾存档不写回已删会话；切过 Profile 后再打开 AI 助手，手上属于别的 Profile 的那场换成新对话。远端会话（`RemoteAiAgentSession`）没有本机存档，`sessionLibrary` 为 null，不出会话入口。
- **界面**：`ai_agent_sessions.dart` 的 `AiAgentSessionList`：宽屏整页常驻对话左侧，窄屏整页与浮层 / 侧栏顶栏点「会话」按钮弹出；删除先确认，确认文案说明操作记录保留、仍可在「AI 操作记录」撤销。

### 12.4 已知缺口
- 没有真机 / 模拟器端到端验证（焦点驱动集成测试的三条脚本未跑）；验证靠单测、路由测试与撤销往返测试。
- 设置里的字体下载、应用更新下载等也返回任务 id（`/api/admin/tasks/:id`），但没标 `longRunning`，AI 不会自动盯它们（`downloads.job.add` 已标）。
- 撤销载荷里存的是旧值快照：换存储位置后撤销一个「路径类」设置会写回旧路径。
