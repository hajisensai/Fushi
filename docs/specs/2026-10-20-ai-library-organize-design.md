# AI 整理库（把该在一起的条目归进合集）设计

> 状态：设计稿，待所有者拍板。日期：2026-10-20。
> 范围：书架（小说 / 字幕书 / 有声书）、漫画、视频媒体库、游戏库。

## 1. 要解决什么

规则归组已经有了，但只能认「文件名长得像同一系列」：

- 书 / 漫画：`BookSeriesGrouper`（`packages/fushi_engine/lib/media/collections/book_series_grouper.dart`）按「系列名 + 卷号」解析书名；
- 视频：`VideoFolderGroupCoordinator`（`video_folder_group_coordinator.dart`）按文件名 series/season/episode 或按目录建 playlist。

规则认不出来、而用户一眼就知道「这几个是一块的」的情况，正是 AI 的用武之地：

| 场景 | 例子 | 规则为什么认不出 |
|---|---|---|
| 同作不同写法 | 「とある魔術の禁書目録」与「Toaru Majutsu no Index」「魔法禁书目录」 | 跨语言 / 罗马音 / 译名 |
| 卷名不带卷号 | 「涼宮ハルヒの憂鬱」「涼宮ハルヒの溜息」「涼宮ハルヒの退屈」 | 每卷标题都不同 |
| 外传 / 短篇集 / 续作 | 「ソードアート・オンライン プログレッシブ」 | 系列名前缀不一致 |
| 散落的单文件视频 | 下载站命名乱七八糟的几集、OVA、SP | 文件名解析失败 → 落成 `book:<uid>` 单条 |
| 同作者同世界观的游戏 | 同一品牌的 fandisk / 续作 | 游戏库根本没有自动归组 |
| 两个本该合并的合集 | 用户手建的「禁书」与自动建的「とある魔術の禁書目録」 | 合并只能靠用户多选 |

**AI 只出建议，不直接改库。** 所有改动走「预览 → 用户勾选 → 应用」，并且可撤销。这与现有 AI 功能的边界一致（`AiFeature` 注释：AI 只产出配置 / 候选）。

## 2. 不做什么（v1 边界）

- 不删条目、不删合集、不把成员移出用户的合集（只做**加法**：新建合集、并入已有合集、合并两个合集）。
- 不在导入 / 扫描后自动跑（按量计费，绝不静默开启）。v1 只有用户手动触发。
- 不动目录自动合集（`sourceFolderPath != null`）的成员归属，它们只能作为「并入目标」的参考，不作合并源。
- 不跨域：书不会和视频进同一个合集（域由 `CollectionShelfDomain` 推导，与 `getMediaCollectionsForEntryDomain` 同口径）。
- 不改合集内顺序；新建合集落盘后交给现成的 `collectionOrder`（AI 排序）自动路径处理（它本来就只在 `orderUpdatedAt == 0` 时动）。
- 不发文件内容、封面、完整路径。

## 3. 整体流程

```
用户点「AI 整理」
   │
   ├─ 0. 门：isAiModuleEnabled && resolve(AiFeature.libraryOrganize) 有提供商 && 一次性同意
   │
   ├─ 1. 本地取事实（引擎）       LibraryOrganizeFacts：散条目 + 已有合集（同域）
   ├─ 2. 本地先归一轮（规则）     硬证据直接成组：同刮削 id / 同系列键 / 同品牌+同系列词
   ├─ 3. 分块（blocking）          只把「规则定不了」的部分发给 AI，按相似度分桶、每桶 ≤ N 条
   ├─ 4. 问 AI（每桶一次请求）    输出结构化 JSON：groups / merges
   ├─ 5. 本地校验 + 裁决           下标合法、不跨域、尊重墓碑、刮削 id 冲突否决 …
   ├─ 6. 预览页                    按建议卡片列出，默认勾选高置信，用户可改名 / 取消某成员
   └─ 7. 应用（一个事务）+ 撤销记录
```

第 1–5 步全部在 `packages/fushi_engine/`（纯 Dart，服务端可复用）；第 0、6、7 步在 app。

## 4. 数据与模块

### 4.1 新增 `AiFeature.libraryOrganize`

在 `packages/fushi_engine/lib/ai/ai_feature.dart` 加一个枚举值，注释写清边界（只出建议、只做加法、用户确认后落盘）。设置页「AI → 功能指派」自动多一行，默认跟随默认提供商；用户可单独指派一个便宜模型（这个任务对模型能力要求不高，标题知识比推理重要）。

### 4.2 引擎侧：`packages/fushi_engine/lib/media/collections/library_organize/`

| 文件 | 内容 |
|---|---|
| `library_organize_facts.dart` | `LibraryOrganizeFacts loadLibraryOrganizeFacts(FushiDatabase db, CollectionShelfDomain domain)`：散条目（不在任何合集）+ 已有合集（名字、类型、成员标题前 5 个、成员数、是否目录合集、`orderUpdatedAt`） |
| `library_organize_rules.dart` | 第 2 步本地硬归组 + 第 3 步分块 |
| `ai_library_organize_assistant.dart`（放 `lib/ai/`） | system / user prompt 构造、回复解析 `parseAiLibraryOrganizeReply` |
| `library_organize_plan.dart` | `LibraryOrganizePlan`（建议列表）+ 校验裁决 `validateLibraryOrganizePlan` |
| `library_organize_apply.dart` | `Future<LibraryOrganizeUndo> applyLibraryOrganizePlan(FushiDatabase db, LibraryOrganizePlan plan, Set<String> acceptedIds)` |

每个条目在请求里只有一个**局部下标**（`#17`），不暴露 uid / bookKey；回复里也只认下标，本地映射回 `(mediaType, entryKey)`。这和 `ai_collection_order_assistant` 的「模型只给下标，本地校验」是同一范式。

### 4.3 发给 AI 的事实（每条一行，紧凑）

| 字段 | 书 / 漫画 | 视频 | 游戏 |
|---|---|---|---|
| 标题 | 书名 | 刮削标题优先，否则文件名去掉扩展名与发布组标签 | 游戏名 |
| 次要信息 | 作者 / 出版社 | 年份、季 / 集号解析结果、文件夹**末级**名 | 品牌（maker）、发售年 |
| 外部身份 | — | 已刮到的 AniList / TMDB id（只用于本地否决，不发给 AI） | VNDB id（同左） |

单行约 20–40 token。千条量级约 3 万 token，用便宜模型一次几分钱；仍按第 3 步分块控制上限。

### 4.4 第 2 步：本地硬归组（不花钱）

以下情况不问 AI，直接产出「规则建议」（预览里标「规则」徽章）：

1. 视频：两个散条目刮到**同一个**作品 id（同 AniList / 同 TMDB 季）；
2. 书 / 漫画：`parseBookSeriesKey` 同键，但当前因为「已有合集挡住」等原因没被 `BookSeriesGrouper` 处理的；
3. 游戏：同 VNDB 系列（有刮削时）。

### 4.5 第 3 步：分块

- 散条目 + 已有合集一起，按 `normalizeMediaSearchText`（`fushi/lib/src/media/media_search_text.dart`，需下沉到引擎或在引擎写同口径版本）归一化后的标题做 bigram Dice 粗聚类（阈值放低，宁多勿漏），同作者 / 同品牌强制同桶；
- 每桶 ≤ 150 条；剩下没进任何桶的「孤儿」条目按标题排序再切成 ≤ 300 条的大桶（专门让 AI 找跨语言别名，这是 bigram 认不出的）；
- 域内总量 > 3000 条时，预览前先给出「将发送 N 次请求、约 X token」的确认。

### 4.6 AI 回复格式

只要一个 JSON 对象（不依赖 tool call / json_schema，现有 `AiChatClient` 不支持；用 `decodeAiJsonObject` 抠）：

```json
{
  "groups": [
    {
      "name": "涼宮ハルヒシリーズ",
      "members": [3, 17, 21],
      "into": null,
      "level": "work",
      "confidence": "high",
      "reason": "同一轻小说系列的第 1–3 卷"
    }
  ],
  "merges": [
    { "collections": ["C2", "C5"], "name": "とある魔術の禁書目録", "confidence": "medium", "reason": "同作的中文名与日文名" }
  ]
}
```

- `members` 是条目下标，`into` 是已有合集编号（`"C2"`）或 null（新建）；
- `level`：`work`（同一部作品的卷 / 集）或 `franchise`（同系列的不同作品，见 §5）；
- `confidence` 只有 `high` / `medium` / `low` 三档；`low` 不进预览（只在「显示更多」里）；
- 不认识就别编：prompt 明确要求「不确定就不要列」，空数组是合法回复。

### 4.7 第 5 步：本地校验与裁决

任何一条不过，该建议丢弃（不是整批作废），并在调试日志记原因：

1. 下标 / 合集编号越界、重复、组成员 < 2（新建时）；
2. 一个条目出现在两个建议里 → 两个都降为 `low`；
3. 跨域；
4. **墓碑**：用户以前把条目从同名合集里移出过（`CollectionMemberTombstones`），或删过同名合集（合集级墓碑）→ 丢弃。用户删过的不让 AI 复活，与 `BookSeriesGrouper` 同口径；
5. **刮削 id 冲突否决（视频）**：`level=work` 组里成员已刮到**不同**作品 id → 自动降成 `franchise`（见 §5）；
6. 合并源是目录合集 → 丢弃该合并；
7. 名字为空 / 超 80 字符 / 与域内另一个现有合集同名但不是 `into` 目标 → 改用 `into` 指向那个合集（复用 `createMediaCollection` 的自然键查重语义）。

## 5. 视频的特殊约束：「作品」与「系列」两层

视频合集不只是展示分组：刮削计划器把「≥2 成员、能解析出集号」的合集当作**一部作品**（`video_source_work_planner.dart` 的 `collection:<id>` 工作单元）。如果 AI 把《物语》系列的第一季、第二季、剧场版塞进一个合集，刮削会把它们当一部作品去搜，元数据全错。

所以视频分两层落地：

- `level=work`（同一部作品、同一季的散集）→ 进合集，和规则归组的结果同构；
- `level=franchise`（同系列的不同作品）→ **不建合集**，改为给相关合集 / 条目打同一个标签 `系列:<名字>`（`TagAssignments`），库页按标签筛选即可看到整个系列。已有的刮削关系边 `CollectionRelations` 是可重建缓存，不写 AI 结论。

书 / 漫画 / 游戏的合集不参与这种「一个合集 = 一部作品」的刮削判据，`franchise` 级直接进合集即可（如「物语系列」一个合集装全部卷）。

> 待拍板：书 / 漫画的 `franchise` 级是否也改走标签，让「一个合集 = 一部作品」在全域一致？我倾向于**不改**：书架用户的心智就是「一个系列一摞书」，强行拆成标签会更难用。

## 6. 门与隐私

- 入口一律经 `isAiModuleEnabled`（守卫 `ai_module_gate_guard_test.dart` 会钉住）；
- 第一次运行弹一次性说明：会把**标题、作者 / 品牌、年份、文件夹末级名**发送给所选 AI 提供商，可能计费；「开始」才记住，关弹窗不算同意。范式照抄 `ocr_llm_default_consent.dart`；
- 不发完整路径、文件内容、封面、阅读 / 观看记录。

## 7. UI

### 7.1 入口

- 书架 / 漫画库 / 视频库 / 游戏库顶栏加一个动作「AI 整理」（图标 `auto_awesome`），走 `FushiFloatingTopBar.adaptiveOverflow`，宽度不够时进「⋯」（优先级低于搜索、排序、导入）；
- 多选模式下额外一项「AI 整理所选」：只对选中的条目和合集跑，适合大库里局部整理；
- 桌面 CLI：`fushi_cli library organize --domain video [--dry-run] [--apply-high]`，经 `ctl_library_shelf.dart` 同一服务。

### 7.2 进度

一个底部 sheet：「正在分析 … 第 2/5 批」，可取消（`AiChatFailure('cancelled')`）。已完成的批次的建议先放进列表，不等全部跑完。

### 7.3 预览页（核心）

全屏页，按建议卡片列出，进场走 `FushiEntranceScope` + `fushiStaggeredItemBuilder`：

```
┌ 建议 12 条 · 已选 9 ─────────────────── [全选高置信] [应用] ┐
│ ☑ 新建合集「涼宮ハルヒシリーズ」         高 · AI          │
│    [封面][封面][封面]  3 本                                 │
│    同一轻小说系列的第 1–3 卷                  [改名] [展开] │
│ ☑ 并入「とある魔術の禁書目録」(已有 8 本)  中 · AI          │
│    + 魔法禁书目录 22、+ 新约 1                              │
│ ☐ 合并「禁书」与「とある魔術の禁書目録」    中 · AI          │
│ ☑ 新建合集「葬送のフリーレン」             规则             │
└─────────────────────────────────────────────────────────────┘
```

- 默认只勾 `high` 与「规则」；
- 「展开」显示成员列表，每个成员可单独取消勾选（取消后成员 < 2 的新建建议自动失效）；
- 改名用现成的 `showCollectionNameDialog`；
- 视频 `franchise` 建议显示为「打标签 系列:物语」，和合集建议放在两个分区。

### 7.4 应用与撤销

- 一次 Drift 事务内执行：`createMediaCollection` → `addToCollection` → 合并（**先把两份 `_combineMergeCollections` 抽到 `fushi_core` 的 `mergeMediaCollections`**，见 §9）→ 打标签；
- 合并沿用 `chooseMergeTarget`（成员最多者为目标）；
- 应用后 toast「已整理 9 处」带「撤销」，撤销记录 `LibraryOrganizeUndo` 只存本次新建的合集 id、本次加入的成员、被合并掉的合集快照；撤销只回退本次改动，并且不写墓碑（撤销不是「用户不想要这个分组」，以后再跑 AI 可以再建议）；
- 撤销记录只在内存里保留到下一次整理或离开页面；需要持久撤销再加表，v1 不加 schema。

## 8. 同步

不新增 wire 字段：结果就是普通的合集、成员和标签，走现有 `CollectionSyncEngine` 的「成员并集 + 墓碑」。

**已知风险**：A、B 两台设备各自跑一次 AI 整理，可能给同一批书建出不同名字的合集（「涼宮ハルヒ」与「涼宮ハルヒシリーズ」），同步后两个合集同时存在。v1 的缓解：第 5 步第 7 条（同名复用）+ 跑之前先同步一次（互联已连接时预览页顶部提示「先同步」）；彻底解决要有跨端稳定的分组身份，v1 不做。

## 9. 顺带要还的债

- 书架与视频库各有一份几乎相同的 `_combineMergeCollections`（`home_video_page.dart` 与 `reader_history/books.part.dart`），AI 整理是第三个调用方，先抽到 `database_library.part.dart` 的 `Future<void> mergeMediaCollections(List<int> collectionIds, {required String name})`，两处 UI 改调它。这一步可以独立先做一个 PR。

## 10. 测试

| 层 | 测试 |
|---|---|
| 引擎纯函数 | prompt 构造快照；回复解析（围栏、多余散文、越界下标、重复成员、空数组）；校验裁决逐条一个用例 |
| 引擎 + 内存库 | 墓碑否决、刮削 id 冲突降级、目录合集不作合并源、同名复用、跨域拒绝 |
| 应用 / 撤销 | 应用后合集与成员正确；撤销后库与应用前逐行一致；撤销不留墓碑 |
| 门 | AI 模块关闭 / 无提供商时入口不显示、不发请求（并入 `ai_module_gate_guard_test`） |
| widget | 预览页默认勾选、取消成员后建议失效、进场动效接线（`fushi_entrance_wiring_guard_test` 自动覆盖） |
| 真实模型（手动） | 用一份脱敏的真实书架标题清单跑一次，人工记录准确率，作为 prompt 调整的基线 |

AI 调用在测试里用 `AiClientFactory` 注入假 completer，不联网。

## 11. 分期

1. **PR 1（重构）**：抽 `mergeMediaCollections`，两处 UI 改调用。无行为变化。
2. **PR 2（引擎）**：`AiFeature.libraryOrganize` + facts / 规则 / 分块 / prompt / 解析 / 校验 / 应用 + 撤销，全部单测。
3. **PR 3（UI：书 / 漫画）**：顶栏入口、同意框、进度、预览页、i18n（`i18n_sync --add`）。
4. **PR 4（视频 + 游戏）**：视频两层（合集 + `系列:` 标签）、游戏事实接入。
5. **PR 5（CLI）**：`fushi_cli library organize`。

## 12. 待所有者拍板

1. 书 / 漫画的 `franchise` 级进合集（我的倾向），还是和视频一样走标签？
2. v1 是否只做手动触发（我的倾向），还是给「导入后自动建议、不自动应用」留一个开关？
3. 发送字段里是否包含视频的文件夹末级名（对识别散集帮助很大，但可能带用户自己的命名习惯）？我的倾向是包含，并在同意框里写明。
