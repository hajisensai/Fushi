# AI 管库 v3：从「固定流水线」改成「带专用工具箱的长程 agent」

> 状态：设计稿 + 实现契约，2026-11-22。所有者当日拍板：
> - 「我希望他能和你做到一样甚至更多更好。比如我让你重新整理下我的库，包括调整下合集层级等，重写补充关系网等。你根本性优化一下」
> - **不做嵌套合集**：「层级」指「分合集错误这种」——条目放错合集、该拆的没拆、该并的没并、该单独放的被塞进合集。
> - **用户合集 AI 可以直接改**（合并 / 改名 / 拆散 / 移出，含自动路径）：「开启以后就可以自动改。反正不是能撤销吗」。取代 [库管家](2026-11-18-ai-library-curator-design.md) §8 的「合集级改动出确认卡」。
> - **直接改，完事汇报，可撤销**（不先出计划等确认）。
> 前置：[AI 整理库](2026-10-20-ai-library-organize-design.md)、[库管家](2026-11-18-ai-library-curator-design.md)、[AI 助手](2026-10-26-ai-operations-agent-design.md)。

## 1. 为什么现有的做不到

| 能力 | 库管家（固定流水线） | AI 助手（通用 agent） |
|---|---|---|
| 看到整个库 | 否：默认只看水位之后的新条目，每次请求只看一桶 | 否：没有整库一览的读操作；`library.item.list` 结果不截断，大库直接撑爆上下文 |
| 改合集归属 | 只答「这几个是不是一组」；用户合集的合并 / 改名只出确认卡 | 逐条操作（一个成员一次调用），且走用户写入口——AI 自己的判断被记成「用户亲手定的」并钉住 |
| 改关系网 | 只会加；不改类型 / 方向，不删错连 | `links.add` / `links.remove` 逐条；不能改关系类型 |
| 长程工作 | 不适用 | 单轮硬上限 25 次工具调用；没有上下文压缩；没有计划清单 |

根因：库管家是「代码编排、模型答窄问题」，从结构上就没有全局视角；助手有全局推理能力，但工具粒度、上限与上下文管理都是给「一句话办一件事」设计的。

## 2. 方案

保留库管家作为**自动路径**（便宜、增量、导入后静默跑）。新增**整库整理模式**：用户说「重新整理我的库」时，助手进入长程模式，像 Claude Code 处理代码库一样工作——

1. `library.map summary` 看全貌（各域条目数、散条目数、合集按来源计数、关系按状态计数）；
2. 逐域 `library.map`（紧凑列式、可分页、可按标题过滤）读出合集与成员、散条目；`library.map view=links` 读出作品（关系图连通分量）与每条边；
3. 用 `plan.update` 列计划清单并随进度更新；
4. 每发现一批问题，用 `library.changes.apply` 一次提交一整份变更集（合集：移入 / 移出 / 单独放 / 新建 / 合并 / 改名 / 拆散；关系：连 / 断 / 改类型），一个事务、一条撤销记录；
5. 必要时调已有操作（`video.library.audit`、`video.work.regroup`、`library.curate.*` 刮削认领等）；
6. 最后自查（再读一遍受影响的部分）并汇报改了什么。整个对话的写操作都在「AI 操作记录」里，可按条或整场撤销。

### 2.1 AI 身份

`library.changes.apply` 的全部写入以 **AI 身份**落库：合集走 `userIntent: false`（不转所有权、不钉成员），关系走 `confirmed_by = ai`。用户之后的否决（撤销、手动加回被移出的成员、移除 AI 连接）照旧形成墓碑 / 钉住，AI 不再重复同一个动作。通用操作 `library.collection.*` 仍是用户身份（用户口述「把这本放进 X」时那就是用户意图），系统提示要求整库整理时只用变更集。

### 2.2 用户合集的权限（取代库管家 §8）

| 动作 | 以前 | 现在 |
|---|---|---|
| 合并两个用户合集 | 出确认卡 | 直接执行（自动路径同），撤销按快照重建 |
| 改名用户合集 | 出确认卡 | 直接执行，撤销改回原名 |
| 拆散（移出全部成员） | 不可以 | 直接执行；被移空的合集随之删除，撤销按原来源重建 |
| 移出用户钉住的成员（`pinned_by_user`） | 不可以 | **仍不可以**：钉住 = 用户否决过 AI 的移出 / 亲手放进来，这是撤销能「停下来」的唯一凭据 |
| 目录合集（`sourceFolderPath != null`）的成员 / 名字 | 不动 | 不动（由磁盘目录决定） |

库管家自动路径的「合集级建议」（`OrganizeProposal`）不再产生：`planOrganizeReply` 把合并 / 改名直接产成动作（自动路径照旧只落 high 置信）。存量待确认建议照旧可在记录页接受 / 拒绝。

## 3. 契约

### 3.1 引用格式

- 条目：`<mediaType>:<entryKey>`，与 `media_collection_items` 的两列同值（`library.map` 原样给出）。
- 合集：`C<id>`（`media_collections.id`）。
- 关系端点：`<MediaLinkKind.dbValue>:<key>`（如 `book:<bookKey>`、`video_collection:12`）。`library.map` 对每个条目同时给出它的端点引用（与条目引用不同时）。

### 3.2 `library.map`（只读）

引擎：`packages/fushi_engine/lib/media/library_agent/library_map.dart`，`Future<Map<String, Object?>> loadLibraryMap(FushiDatabase db, LibraryMapQuery q)`。

- `view=summary`：各域（books / manga / video / games）条目数、散条目数、合集数（按 origin）、关系边数（按 user / ai / suggested）、作品（连通分量）数。
- `view=<域>`：列式 `collections{columns, rows}`（ref、名字、origin、成员数、成员引用、钉住的成员引用、是否目录合集）+ `items{columns, rows}`（ref、标题、作者 / 品牌、年份、视频文件夹末级名、所在合集、关系端点引用）。`q` 按折叠标题过滤（命中合集时带出它的全部成员）；`offset` / `limit` 分页（默认 400 行，结果带 `total` 与 `nextOffset`）。
- `view=links`：`works{columns, rows}`（作品编号、名字、成员端点引用）+ `edges{columns, rows}`（from、to、relation、state = user / ai / suggested、source）+ `titles{端点引用: 标题}`。按作品分页。

只给标题级事实，不给完整路径、文件内容、阅读记录（口径同 AI 整理库 §11）。列式输出：键名只出现一次。

### 3.3 `library.changes.apply`（写，可撤销）

引擎：`packages/fushi_engine/lib/media/library_agent/library_changeset.dart`。

```json
{
  "changes": [
    {"op": "move", "items": ["epub:abc"], "to": "C12" | "new:<名字>" | "standalone", "from": "C3", "why": "…"},
    {"op": "merge", "into": "C3", "from": ["C5", "C7"], "why": "…"},
    {"op": "rename", "collection": "C3", "name": "…", "why": "…"},
    {"op": "dissolve", "collection": "C9", "why": "…"},
    {"op": "link", "from": "book:…", "to": "video_collection:12", "relation": "adaptation", "why": "…"},
    {"op": "unlink", "from": "…", "to": "…", "relation": "…", "why": "…"},
    {"op": "relink", "from": "…", "to": "…", "relation": "sequel", "why": "…"}
  ],
  "dryRun": false
}
```

- `move`：`from` 省略 = 从条目当前所在的全部非目录合集移出；`to=standalone` = 只移出；`new:<名字>` = 新建 AI 合集（同名已存在则并入它）。
- `relink`：把一对端点之间 AI 生效 / 建议态的连接换成新的关系或方向（用户确认过的不动）。
- 有方向的关系 `from → to`：`adaptation` 原作 → 改编，`sequel` 前作 → 续作，`side_story` 本篇 → 外传，`theme_song` / `soundtrack` 作品 → 音乐，`cast` 作品 → 人。
- 每条独立校验，不过的进 `skipped`（下标 + 原因码：`unknown_ref` / `cross_domain` / `folder_collection` / `pinned_by_user` / `name_taken` / `vetoed` / `user_confirmed` / `exists` / `invalid`），其余照常执行。不整批作废。
- 合集部分复用 `applyOrganizeActions`（新增 `rename` 动作种类），记一条 `library_organize_runs`（trigger = `agent`）；关系部分用 `applyAiMediaLink` / 新增的 AI 改类型写入，收集回执。
- 结果：`{runId, applied: [{i, op, …}], skipped: [{i, op, reason}], undo: {…}}`；`undo` 是撤销载荷（runId + 关系回执），由路由交给操作记录。
- 撤销：`undoLibraryOrganizeRun(runId)` + 倒序退回关系回执。后续被用户改过的那一处跳过（「已被后续修改覆盖」）。

### 3.4 助手运行时

`packages/fushi_engine/lib/ai/agent/agent_session.dart`：

- **长程任务**：`AgentSkillContext.beginLongTask({required Iterable<String> tools, int? maxToolCalls})`——把整理要用的工具直接装进本场（等同 describe 过），本轮工具调用上限提到 `AgentLimits.longTaskMaxToolCalls`（默认 400）。连错熔断（同一工具同一参数连错 2 次）照旧。
- **上下文压缩**：每次请求前估算历史字符数，超过 `AgentLimits.historyCharBudget` 时把较早的工具结果替换成占位（保留头部摘录与原长度，提示需要时重新读取），最近若干条完整保留；tool_use / tool_result 配对不破坏。对所有会话生效（长对话一样受益）。
- **计划清单**：元工具 `plan.update`（`items: [{text, status: pending|active|done}]`），清单存在会话状态里、随存档走，在对话里显示为一条带勾选状态的记录。

### 3.5 入口

- 助手技能 `skill.library.reorganize`：调 `beginLongTask` 装上 `library.map` / `library.changes.apply` / `plan.update` 及相关已有操作，返回工作方法说明（先看全貌、按域推进、成批提交、最后自查汇报、不确定的列给用户）。`skill.curate_library` 的描述改成「增量、便宜的自动整理」。
- 设置 → AI 的「立即整理整个库」改为打开助手并发出「重新整理整个库」（长程模式）；自动开关仍驱动库管家流水线。

## 4. 不做

- 嵌套合集（所有者 2026-11-22 明确不要）。
- ~~让自动路径跑长程 agent~~：所有者 2026-11-22 当日改口（「我希望他能自动呢……我希望效果最好的」），见 §7。
- AI 改磁盘文件——那是视频整理操作（库管家 §15）的范围，长程模式可以调用它们，但不新增。

## 5. 已知风险

- 关系改类型（`relink`）留下的旧行墓碑要和「用户否决」区分开，否则会触发「一对端点有墓碑就不许 AI 生效」的不变量把新行也收掉；旧版对端不认识这个区分，会把它当否决（见实现记录）。
- 长程模式一场可能几百次调用，费用随库大小线性增长；界面显示累计费用（已有），不设本地上限（口径同 AI 整理库 §10.2）。

## 6. 实现记录（2026-11-22）

### 6.1 与正文的偏离

- **主题曲 / 原声的方向**：库里的约定是「音乐 → 作品」（`MediaLinkRelation`），与 §3.3 写的相反。变更集按端点种类自动摆正，模型写哪个方向都行；操作描述已改成「两端顺序不限」。
- **relink 的旧行**：新增墓碑专用来源 `MediaLinkSource.superseded` 与判据 `mediaLinkIsVetoTombstone`。「一对端点有墓碑就不许 AI 生效」的不变量（`mediaLinkPairVetoed` / `enforceMediaLinkVetoes`）只认否决墓碑，不认被取代的旧行。新 db 方法 `setAiMediaLinkRelation` / `revertAiMediaLinkRelation` 单事务完成改类型与撤销。**旧版对端**不认识 `superseded`，会照否决处理，把新关系也写成墓碑，同步回来后这次改类型在全网退化成「断开」（宁可少连）。
- **改名带走成员墓碑**：`renameMediaCollection` 原来改名时把旧名下的成员墓碑全删了，于是「用户移出过 X」在改名后被遗忘，AI 整理和同步并集都会把成员放回来。现在把成员墓碑搬到新名下（同成员取较新的 `deletedAt`），合集级哨兵照旧留在旧名。用户手动改名同样受益。
- **`OrganizePlan.proposals` 删除**：整理器不再产出合集级建议，合并 / 改名直接成动作（自动路径只收 high）。`LibraryOrganizeResult.proposals` 字段保留但恒为 0（路由 / CLI / 汇报还在读它）；已存的建议照旧能接受 / 拒绝。
- **`beginLongTask` 只升不降**：传入的上限低于当前上限时不调低，免得两个技能先后调用把正在跑的长任务卡住。
- **地图隐藏上锁作品**：`loadLibraryMap` 默认自己读 `MediaLockSnapshot`，上锁的条目、成员与端点一律不出现（不看本会话是否已解锁——没必要把上锁作品交给模型）。
- **撤销不另设路由**：`library.changes.apply` 的撤销回调直接调引擎 `undoLibraryChangeset`，操作目录棘轮（每条路由都要有描述）因此不变。

### 6.2 没做 / 没验证

- **没有对真实库、真实模型跑过整库重排**：模型能否在几百次调用里稳定地读库、分批、自查，判得准不准，没有数。测试只验地图 / 变更集 / 撤销 / 长程模式的机制。
- **计划清单没有专门界面**：`plan.update` 在对话里显示成普通工具卡（卡里是 `[x] / [>] / [ ]` 清单）；互联远端会话视图没有暴露 `plan`。
- **CLI 没有专门命令**：可以用通用的操作调用跑 `library.map` / `library.changes.apply`，整库重排本身是助手对话任务。
- **服务端**：`fushi_server` 没有这两条操作（同库管家 §14.2 的服务端缺口）。
- **压缩让提供商前缀缓存失效一次**：每次压到预算的 60%，降低压缩频率，没另设缓存策略。
- 没有真机 / 像素验证（设置页新增一行动作、整理记录页的触发文案）。

## 7. 自动复查：流水线打底 + agent 复查（所有者 2026-11-22 拍板）

起因：所有者问「库管家是一条写死步骤的流水线，确定不会有问题吗……我希望效果最好的」。流水线有结构性盲区：只看新条目、每次只看一桶、关系只加不改，它从不回头纠正已有的错。所以自动路径改成两段：

1. **流水线**（不变）：规则归组、共享外部 id 的连接、声纹主题曲、唯一候选认领——便宜、证据硬、没有判断空间的部分。
2. **AI 助手复查**（新，设置 › AI「导入后让 AI 助手复查整个库」，**默认开**，偏好 `library_agent_review_auto`）：流水线跑完后起一场无人值守的助手会话（`AiAgentController.unattended`），提示词让它先调 `skill.library.reorganize`：
   - **增量**：把上次复查以来新入库的条目交给它——`library.map` 新增 `addedSince`（毫秒时间戳）过滤，只给这些条目连同它们所在合集的全部成员；再用 `q` 查它们的系列。检查流水线做得对不对、补上漏的。
   - **全库**：第一次、自上次全库复查累积 100 个新条目、或距上次全库复查满 30 天且期间有新条目时，整库过一遍。
   - 无人值守：确认卡一律拒绝、候选卡一律取消（`AiAgentUnattendedHost`，不替用户表态、不挂起）；提示词要求不提问，拿不准的写进汇报。对话存档在「AI 操作记录」（场景 `library_review`），能看汇报、能整场撤销。
   - 水位（偏好 `library_agent_review_state`）只在会话跑完时推进：模型请求失败 / 取消 / 中断不推进（下次重来）；撞调用上限或连错熔断算跑完（重来只会再撞）。
   - 门：开关开、AI 模块开、「AI 助手」指派了提供商；任一不满足不发请求。库管家自动开关关着时复查照样按自己的开关排程。
   - 实现：`fushi/lib/src/media/library_curate/library_agent_review.dart`（大环外，经 `registerLibraryAgentAutoReviewer` 注入叶子 `library_curate_auto.dart`）。

代价：每次导入后多一场助手会话；全库复查一次的 token 随库大小线性增长。不设本地上限（口径同 AI 整理库 §10.2）。

没验证：没有在真实库 / 真实模型上跑过自动复查；没有真机验证设置开关。
