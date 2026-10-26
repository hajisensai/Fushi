# AI 整理库（把该在一起的条目归进合集）设计

> 状态：设计稿 v2，日期 2026-10-20。
> 所有者已拍板（2026-10-20）：**AI 直接改库**（不经预览确认）；**允许自动运行**；**发送视频文件夹末级名**；书 / 漫画「同系列不同作品」放哪随设计定（本稿：进同一个合集）；**多端冲突要彻底解决**。
> 范围：书架（小说 / 字幕书 / 有声书）、漫画、视频媒体库、游戏库。

## 0. 实现记录（v3，2026-10-21）

已在分支 `worktree-ai-library-organize-spec` 全部实现。下文 §1–§16 是 v2 设计；实现中有以下**有意偏离**，以这里为准：

| 主题 | v2 设计 | 实现 | 为什么 |
|---|---|---|---|
| 收敛放在哪 | 同步纯函数 merge 之后做一步规整 | 同步一轮**推进基线之后**由调用方调 `convergeCollectionsAfterSync`（三个调用方：云同步两条路径、互联 host 的 POST 合并），败方墓碑时刻取 `max(now, 新基线 + 1)` | 多端随机同步的性质测试实测：收敛若在落盘里（基线之前）跑，败方墓碑早于新基线被判成旧闻，对端活副本「重建胜」，两端永远来回；同毫秒同样会来回 |
| 合并去向 | 墓碑上记 `mergedIntoName` | 胜方合集记只增不删的 `organizeAliases`（并集合并）；墓碑只记 `organizeKey` + `organizeMerged`（被整理器并掉 / 用户删的） | 去向只记在败方墓碑上，旧对端把败方复活后去向就丢了；别名在胜方、按并集合并，永远不丢 |
| 部分可见下的丢失 | 未覆盖 | 同步落盘删整理器合集时 `rehomeDissolvedOrganizerCollections`：键被吸收 → 本机成员转给吸收者；同名异组或「并掉但吸收者还没到」→ 按 `disambiguatedOrganizeName`（名字 + 键的 4 位短哈希）重建；用户删的同组 → 才算拒绝 | 200～1000 个随机种子的性质测试找到两种丢成员：A 并 Y 进 X 的同时 B 并 Z 进 Y；两个不同系列碰巧同名、一端删自己那个连带删了另一端那个 |
| 规则归组的键 | — | `BookSeriesGrouper` / 视频系列模式建的合集写 `origin=rule` 与标题键（与 AI 同一个折叠函数 `foldMediaTitle`，下沉到 fushi_core） | 日文作品 AI 给的原名与系列名一致时天然认成一个 |
| 「负责设备」 | 非负责设备只整理负责设备没有的条目 | 自动整理开关本身就是设备本地的、默认关，文案提示只在一台设备打开 | 判断「负责设备有没有这个条目」需要对端整库清单（合集清单只有成员），而正确性已由收敛保证，这只是省钱 |
| 同意 | 弹一次性说明框 | 手动入口弹一次；设置里的自动开关**副标题即完整披露**，亲手打开即记为同意（不弹模态框）；CLI 要 `--yes` | 设置开关弹模态框会挂住设置页的焦点驱动覆盖测试，且披露就在开关旁边更直接 |
| 入口 | 顶栏 `adaptiveOverflow` | 四个库页共用的 `FushiTagFilterBar` 动作区（`onAiOrganize`）+ 书架 / 视频库多选「AI 整理所选」 | 库页实际不用 `FushiFloatingTopBar` |
| 结果提示 | toast 带「查看 / 撤销」 | 结果对话框（撤销 / 查看 / 好） | `FushiToast` 不支持按钮 |
| 自动触发 | 导入后传新条目 | 库页加载 / 来源扫描后去抖 30 秒，只看 `local_added_at`（游戏 `added_at`）晚于「上次自动整理开始 / 打开开关时刻」的条目 | 书架的归组触发点是每次页面加载，不带新条目清单 |
| 用户接手 vs 并掉 | — | 一端用户刚接手（加减成员 / 改名）的合集、另一端整理器按旧状态把它并掉：同步时「并掉」的删除压不过 `origin=user` 的活副本（`_mergeOne` 与多份折叠同一规则）；用户合集与别的合集相连**只认双方主键相同**，吸收者别名里留着它的键也不会被吞 | 独立审查找到：否则用户的增删被静默撤销 |
| 拒绝的粒度 | 只记主键 | 删除哨兵记被删合集的**键集合**（主键 + 吸收过的别名）；自动路径（刮削拆分等）删合集不记键、不算拒绝 | 别名里的键换一台设备照样会被 AI 算出来；自动删除不是用户表态 |
| 允许再次建议 | 清哨兵上的键 | 设备本地放行名单（偏好 `library_organize_allowed_keys`）；放行后再建出的同键合集让拒绝在每台设备上自然解除 | 清键会被对端仍带着键的哨兵在下一轮同步写回 |
| 自动整理的输入与水位 | — | 自动 / 「整理所选」只发被点名的条目（整理器合集的其它成员不发，合集只发名字与样本）；水位只认**跑完**（`done`）的自动整理，被额度截断记 `partial`、不推进 | 否则一本新书就把整域成员发出去、吃光每日额度，被截断的那批永远不再看 |
| 无头服务端 | — | yaml `ai.library_organize: true`（默认关）时扫描后对本轮新入库条目跑一次自动整理；新合集名用作品原语言 | 服务端常驻，正适合当负责自动整理的那台 |

代码位置：
- 数据层：`packages/fushi_core/lib/src/database/collection_organize.dart`（来源 / 键 / 别名的纯值层）、`tables.dart`、`database_library.part.dart`（`_claimCollectionForUser`、`absorbOrganizeIdentity`、`getRejectedOrganizeKeys`…）、迁移 `database.dart` `from < 124`。
- 同步与收敛：`packages/fushi_engine/lib/sync/collection_sync_engine.dart`、`collection_manifest.dart`、`lib/media/collections/library_organize/organize_convergence.dart`、`lib/media/collections/collection_merge.dart`（合并唯一入口）。
- AI 引擎：`packages/fushi_engine/lib/ai/ai_library_organize_assistant.dart`、`lib/media/collections/library_organize/`（facts / plan / apply（含撤销）/ service）。
- app：`fushi/lib/src/media/collections/library_organize_runner.dart`、`pages/implementations/library_organize_history_page.dart`、`settings/settings_schema_ai.dart`（`ai.library_organize`）、`ops/ctl_library_organize_routes.dart`。
- CLI：`fushi_cli library organize --domain <books|manga|video|games> [--yes]` / `organize-history` / `organize-undo <id>`。
- 服务端：`packages/fushi_server/lib/src/config/server_ai_config.dart`（`serverLibraryOrganizer`）、`library_scanner.dart`。
- 测试：`fushi/test/sync/collection_organize_convergence_test.dart`（多端随机性质测试：逐项一致、每键至多一个合集、不丢任何一次归组）、`fushi/test/database/migration_v124_collection_organize_test.dart`、`fushi/test/media/collections/library_organize_test.dart`、`library_organize_runner_test.dart`、`fushi/test/ops/ctl_library_organize_routes_test.dart`、`packages/fushi_server/test/library_organize_config_test.dart`。

## 1. 要解决什么

规则归组已经有了，但只能认「文件名长得像同一系列」：

- 书 / 漫画：`BookSeriesGrouper`（`packages/fushi_engine/lib/media/collections/book_series_grouper.dart`）按「系列名 + 卷号」解析书名；
- 视频：`VideoFolderGroupCoordinator`（`video_folder_group_coordinator.dart`）按文件名 series/season/episode 或按目录建 playlist；
- 游戏：没有自动归组。

规则认不出来、而用户一眼就知道「这几个是一块的」的情况，正是 AI 的用武之地：

| 场景 | 例子 | 规则为什么认不出 |
|---|---|---|
| 同作不同写法 | 「とある魔術の禁書目録」与「Toaru Majutsu no Index」「魔法禁书目录」 | 跨语言 / 罗马音 / 译名 |
| 卷名不带卷号 | 「涼宮ハルヒの憂鬱」「涼宮ハルヒの溜息」「涼宮ハルヒの退屈」 | 每卷标题都不同 |
| 外传 / 短篇集 / 续作 | 「ソードアート・オンライン プログレッシブ」 | 系列名前缀不一致 |
| 散落的单文件视频 | 下载站命名乱七八糟的几集、OVA、SP | 文件名解析失败，落成 `book:<uid>` 单条 |
| 同品牌同世界观的游戏 | 同一品牌的 fandisk / 续作 | 游戏库根本没有自动归组 |
| 两个本该合并的合集 | 用户手建的「禁书」与自动建的「とある魔術の禁書目録」 | 合并只能靠用户多选 |

## 2. 核心原则

1. **AI 直接改库，但每一步都可撤销。** 没有预览确认框；改动写进本地「整理记录」，可以按次、按条撤销。
2. **用户永远赢。** 用户碰过的合集（改名、加减成员、手动排序、手建）归用户所有，AI 再也不改它；用户撤销或删掉的 AI 分组会变成「拒绝」，跨端同步，任何设备上的 AI 都不会再建。
3. **多端结果必须收敛，而不是靠互斥。** 不论几台设备、谁先谁后、离线多久，同步完成后各端的合集逐字节相同（§8）。「只让一台设备跑」只用来省钱，不承担正确性。
4. **规则能定的不花钱。** 只把规则认不出的部分发给 AI。

## 3. 边界

- 不删条目，不删用户合集。
- AI 可以：新建合集、把散条目并入合集、合并合集、把条目从**AI 自己建的**合集里移出（纠正自己上次的错误）。
- 不动目录自动合集（`sourceFolderPath != null`）的成员归属。它们可以作为并入目标，但不能作为合并源。
- 不跨域：书不会和视频进同一个合集。域由 `CollectionShelfDomain` 推导，与 `getMediaCollectionsForEntryDomain` 同口径。
- 不改合集内顺序。新建合集落盘后交给现成的 `collectionOrder`（AI 排序）自动路径处理，它本来就只在 `orderUpdatedAt == 0` 时动。
- 不发文件内容、封面、完整路径、阅读或观看记录。

## 4. 整体流程

```
触发（手动「AI 整理」/ 导入或扫描后自动）
   │
   ├─ 0. 门：isAiModuleEnabled && resolve(AiFeature.libraryOrganize) 有提供商 && 一次性同意
   ├─ 0'. 省钱协调（§8.6）：已连上的对端正在负责整理时，跳过它也有的条目
   │
   ├─ 1. 本地取事实（引擎）       散条目 + 已有合集 + 已知分组键 + 已拒绝分组键
   ├─ 2. 本地先归一轮（规则）     硬证据直接成组：同刮削 id / 同系列键
   ├─ 3. 分块                      只把规则定不了的部分发给 AI，按相似度分桶
   ├─ 4. 问 AI（每桶一次请求）    结构化 JSON：groups / merges / evictions，每组带 organizeKey
   ├─ 5. 本地校验 + 裁决           下标合法、不跨域、尊重墓碑与拒绝、刮削 id 冲突否决、用户所有权
   ├─ 6. 落盘（每批一个事务）      写合集 + 写整理记录
   └─ 7. 收敛规整（§8.4）          与同步后跑的是同一个纯函数
```

第 1–5、7 步全部在 `packages/fushi_engine/`（纯 Dart，无头服务端也能跑）；第 0、6 步的 UI 部分在 app。

## 5. 数据模型（schema v123 → v124）

### 5.1 `MediaCollections` 加两列

| 列 | 类型 | 含义 |
|---|---|---|
| `origin` | TEXT NOT NULL DEFAULT `'user'` | `user` / `rule` / `ai` / `folder`。迁移时 `sourceFolderPath != null` 回填 `folder`，其余保持 `user`（存量里分不出规则建的，宁可当用户的，AI 不碰）。新代码里 `BookSeriesGrouper` / `VideoFolderGroupCoordinator` 建的写 `rule` |
| `organizeKey` | TEXT NULL | 分组身份键（§6）。`ai` / `rule` 合集必有；`user` 合集可以有（从 AI 合集转成用户所有时保留，用于识别「同一系列」） |

**所有权只升不降**：`ai` / `rule` 一旦被用户编辑，就转成 `user`，永不回退。任何一个用户写入口（`renameMediaCollection`、`addToCollection`、`removeFromCollection`、`reorderCollectionItems`、拖拽、合并、详情页拆分）都执行这次转换。自动路径用的 `*Automatically` / AI 内部入口不转。这条单调性是 §8 收敛的前提。

### 5.2 合集级墓碑加两列

合集级删除墓碑是 `CollectionMemberTombstones` 里 `mediaType = entryKey = ''` 的哨兵行。给它加：

| 列 | 含义 |
|---|---|
| `organizeKey` | 被删合集的分组键 |
| `mergedIntoName` | 非空表示这次删除是「被合并进了某合集」，而不是用户拒绝 |

于是一条哨兵行有三种语义：

- `mergedIntoName != null`：**重定向**。这个分组键以后一律指向那个合集。
- `organizeKey != null && mergedIntoName == null`：**拒绝**。用户删了 / 撤销了这个 AI 分组，任何设备都不再建这个键。
- 两者都空：普通删除（现状语义）。

### 5.3 本地整理记录（不同步）

```
library_organize_runs(id, domain, trigger 'manual'|'auto', startedAt, finishedAt,
                      status, providerId, model, inputTokens, outputTokens, error)
library_organize_changes(id, runId, kind 'create'|'add'|'merge'|'evict'|'tag',
                         collectionName, collectionType, organizeKey,
                         mediaType, entryKey, payloadJson, undoneAt)
```

只记本机这一次做了什么，供撤销和「整理记录」页使用。不进同步也不进备份：别的设备有自己的记录，撤销的结果通过墓碑和拒绝传播。

### 5.4 同步清单

`CollectionManifestEntry` 加可选字段 `origin`、`organizeKey`；合集级删除（`deletedAt`）旁加 `organizeKey`、`mergedIntoName`。旧版对端读不到这些字段时按缺省处理：

- 缺 `origin` 视为 `user`（AI 不碰，最安全）；
- 缺 `organizeKey` 视为「未知」，**不是**「清空」。合并时以有值的一侧为准。

这一点需要单独测：旧对端会用自己的本地库重建清单，丢掉这两个字段；合并逻辑必须不因此把新端的键冲掉。

## 6. 分组身份键 `organizeKey`

收敛的关键在于：**同一个系列在不同设备上要算出同一个键**。按优先级取：

1. **外部 id**（最稳）：
   - 视频 `level=work`：`anilist:<id>` / `tmdb:tv:<id>:s<season>` / `tmdb:movie:<id>`；
   - 游戏：`vndb:<seriesId>`（有刮削时）；
   - 书 / 漫画：暂无可靠的系列级外部 id，跳过。
2. **原语言标题键**：AI 必须给出该系列的「原语言正式名」（日文作品给日文原名，不给译名），本地用 `normalizeMediaSearchText`（全角转半角、片假名转平假名、小写、去空白和标点）归一化，得到 `t:<domain>:<归一化>`。原名比展示名稳定得多：中文用户和日文用户的设备会给出不同的展示名，但原名相同。
3. **已知键复用**：发给 AI 的事实里带上本机已知的全部 `organizeKey`，包括从同步拿到的、重定向表里的、拒绝表里的。prompt 要求：如果是已知系列，**必须原样复用**已知键，不许新造。

合集的**展示名**与键分开。展示名由 AI 按用户的界面语言给，可以不同；身份只看键（§8.4 规整时统一展示名）。

## 7. AI 交互

### 7.1 新增 `AiFeature.libraryOrganize`

在 `packages/fushi_engine/lib/ai/ai_feature.dart` 加枚举值，注释写清边界：直接落盘、可撤销、用户所有的合集不碰、拒绝跨端生效。设置页「AI → 功能指派」自动多一行，默认跟随默认提供商。这个任务对作品知识的依赖比对推理能力大，可以单独指派一个便宜模型。

### 7.2 引擎模块 `packages/fushi_engine/lib/media/collections/library_organize/`

| 文件 | 内容 |
|---|---|
| `library_organize_facts.dart` | `Future<LibraryOrganizeFacts> loadLibraryOrganizeFacts(FushiDatabase db, CollectionShelfDomain domain, {Set<String>? onlyEntryKeys})` |
| `library_organize_rules.dart` | 本地硬归组 + 分块 |
| `ai_library_organize_assistant.dart`（放 `lib/ai/`） | prompt 构造 + `parseAiLibraryOrganizeReply` |
| `library_organize_plan.dart` | `LibraryOrganizePlan` + `validateLibraryOrganizePlan` |
| `library_organize_apply.dart` | `Future<int> applyLibraryOrganizePlan(FushiDatabase db, LibraryOrganizePlan plan)`，返回 runId |
| `library_organize_undo.dart` | `Future<void> undoLibraryOrganizeChanges(FushiDatabase db, Iterable<int> changeIds)` |
| `organize_convergence.dart` | §8.4 的纯函数 `CollectionManifest convergeOrganizedCollections(CollectionManifest m)` |
| `library_organize_service.dart` | 编排、自动触发的去抖、省钱协调、预算 |

请求里每个条目只有一个局部下标（`#17`），每个已有合集只有一个编号（`C2`），不暴露 uid / bookKey。回复也只认下标，本地再映射回 `(mediaType, entryKey)`。这与 `ai_collection_order_assistant` 的做法相同。

### 7.3 发给 AI 的事实（每条一行）

| 字段 | 书 / 漫画 | 视频 | 游戏 |
|---|---|---|---|
| 标题 | 书名 | 刮削标题优先，否则文件名去掉扩展名与发布组标签 | 游戏名 |
| 次要 | 作者 / 出版社 | 年份、季 / 集号解析结果、**文件夹末级名** | 品牌、发售年 |

已有合集每个发一行：编号、展示名、`organizeKey`、成员数、前 5 个成员标题、是否用户所有（用户所有的只能作为 `into` 目标，不能被合并、不能被移出成员）。

刮削 id 不发给 AI，只在本地用于否决。

### 7.4 本地硬归组（不花钱）

1. 视频：散条目刮到**同一个**作品 id（同 AniList / 同 TMDB 季）→ 成组，键取外部 id；
2. 书 / 漫画：`parseBookSeriesKey` 同键但没被 `BookSeriesGrouper` 处理的；
3. 游戏：同 VNDB 系列。

结果 `origin=rule`，同样写整理记录、同样可撤销。

### 7.5 分块

- 散条目和已有合集一起，按归一化标题做 bigram Dice 粗聚类（阈值放低，宁多勿漏）；同作者 / 同品牌强制同桶。复用 `packages/fushi_audio/lib/src/matching/epub_srt_matcher.dart` 的 Dice 实现，包一层标题版本；
- 每桶 ≤ 150 条；没进任何桶的孤儿条目按标题排序后切成 ≤ 300 条的大桶，专门让 AI 找跨语言别名（bigram 认不出这种）；
- 一行约 20–40 token，千条量级约 3 万 token。

### 7.6 回复格式

只要一个 JSON 对象。现有 `AiChatClient` 不支持 tool call / json_schema，所以用 `decodeAiJsonObject` 从回复里抠：

```json
{
  "groups": [
    {
      "key": "t:books:すずみやはるひ",
      "originalTitle": "涼宮ハルヒシリーズ",
      "name": "凉宫春日系列",
      "members": [3, 17, 21],
      "into": null,
      "level": "work",
      "confidence": "high"
    }
  ],
  "merges": [
    { "collections": ["C2", "C5"], "key": "t:books:とあるまじゅつのいんでっくす", "confidence": "high" }
  ],
  "evictions": [
    { "collection": "C7", "members": [40], "confidence": "high" }
  ]
}
```

- `key` 可以是已知键（必须原样复用），也可以留空，由本地从 `originalTitle` 生成；本地**一律重算**一次并以本地结果为准，AI 给的 `key` 只用来匹配已知键；
- `level`：`work`（同一部作品的卷 / 集）或 `franchise`（同系列的不同作品，见 §9）；
- `evictions` 只允许针对 `origin=ai` 的合集；
- 不确定就不要列，空数组是合法回复。

### 7.7 直接改库下的置信度门槛

没有人工确认，所以门槛要比预览模式高：

| confidence | 手动触发 | 自动触发 |
|---|---|---|
| high | 落盘 | 落盘 |
| medium | 落盘 | 不落，留到下次手动整理 |
| low | 不落 | 不落 |

`merges`（合并两个已有合集）在自动触发下只接受 high。

### 7.8 本地校验与裁决

任一条不过，就丢弃该条建议（不是整批作废），原因写进整理记录的 `error`：

1. 下标 / 编号越界、重复，或新建组成员 < 2；
2. 同一条目出现在两个建议里：两个都丢弃；
3. 跨域；
4. **拒绝**：键在拒绝表里，丢弃；键在重定向表里，改写成重定向目标；
5. **墓碑**：用户把某条目从同键合集里移出过（成员墓碑），那个条目从建议中剔除；
6. **刮削 id 冲突（视频）**：`level=work` 组里成员刮到不同作品 id，降为 `franchise`（§9）；
7. **用户所有权**：用户合集不能作合并源，不能被移出成员，只能作 `into` 目标；目录合集不能作合并源；
8. 名字为空或超过 80 字符：用 `originalTitle`，再不行就丢弃；
9. 同键的合集已经存在：改成 `into` 那个合集，不新建。

## 8. 多端一致性（彻底解决）

### 8.1 为什么互斥（锁）解决不了

- **离线**：笔记本断网时导入了书，自动整理要不要跑？跑就和其它端并发，不跑就永远等。锁要求一个永远在线的仲裁者，而互联是可选的点对点 host / client，云同步是读-合并-写的文件，两者都没有在线仲裁者。
- **库本来就不同**：每台设备扫的是自己的本地文件。手机上的 3 本和电脑上的 5 本是同一个系列，各自都应该被整理，这本身就是「两边同时操作」，不能禁止。
- **三台以上设备**：A 与 B 同步、B 与 C 同步，顺序任意，锁不能跨这种传递关系生效。

规则归组从来不冲突，并不是因为它加了锁，而是因为**同样的输入在每台设备上都算出同一个合集名**。所以正确的方向是：让 AI 的结果也具备这种性质，即使两边各算各的，同步后也合成一个。

### 8.2 身份：用 `organizeKey` 代替展示名

同步的自然键仍然是 `(name, collectionType)`，不动现有 wire 契约。在它之上，`ai` / `rule` 合集再按 `organizeKey` 认亲：键相同，就是同一个系列，必须合成一个合集。

### 8.3 三层兜底，保证键相同

1. 外部 id 键（§6.1）：两端独立算，必然相同。
2. 原语言标题键（§6.2）：AI 给的原名经归一化，绝大多数情况相同。
3. **已知键复用 + 重定向**：如果两端还是算出了不同的键（例如一端是 `t:すずみやはるひ`，另一端是 `t:すずみやはるひのゆううつ`），同步后任何一台设备下一次整理时都会同时看到两个 AI 合集。AI 被要求合并同系列合集（`merges`），合并会留下一条重定向墓碑（失败方的键 → 胜方合集）。重定向随同步传播，以后任何设备再算出失败方的键，都会被改写成胜方。这一层让两种键**最终一定合流**，代价是中间可能有一段时间两个合集并存。

此外加一条**不依赖 AI 的重叠规则**：同域两个 `ai` / `rule` 合集共享的成员（按 wire 成员键比较）≥ 较小一方成员数的一半，直接按 §8.4 合并。这条覆盖两端用同一批书、只是键不同的常见情况，不需要等下一次 AI 运行。

### 8.4 收敛规整：一个确定性纯函数

`convergeOrganizedCollections(CollectionManifest m)` 在两处运行：每次 `CollectionSyncEngine.merge` / `combinePeers` 之后，以及每次本地整理落盘之后。它只读清单里的 wire 字段，不读墙钟、不读本地库、不问 AI。

1. 应用重定向：`organizeKey` 命中重定向的 `ai` / `rule` 合集，改写成目标键。
2. 按 `(domain, organizeKey)` 分组。只考虑活着的 `ai` / `rule` 合集；`user` 合集不参与被合并，但同键的 `user` 合集存在时它就是胜方。
3. 再按 §8.3 的重叠规则把组连通（并查集）。
4. 每组选**胜方**：有 `user` 合集取 `user`（多个取名字字典序最小）；否则取外部 id 键优先、再按名字字典序最小。
5. 胜方成员 = 组内全部成员的并集，减去任何一方的成员墓碑。墓碑在并集之后生效，所以用户在任何一端移出的成员都不会被并回来。
6. 失败方变成合集级删除墓碑：`mergedIntoName = 胜方名`、`organizeKey = 失败方原键`、`deletedAt = 组内各合集已知时间戳的最大值`（不用 now）。
7. 胜方的展示名不改。名字是 wire 自然键的一部分，改名等于删了重建，会制造新的分叉。

第 6 步的时间戳可能早于某个对端的同步基线，按现有「早于基线且对端活着 ⇒ 复活」规则，失败方会在那一端被救回来。这没关系：规整在每次合并后都会重跑，失败方仍然同键或仍然重叠，会被立刻再并一次。复活不会造成永久分叉，最多多一轮同步。PR 2 的性质测试要专门覆盖这条路径。

这几步只用到并集、取最小值、取最大值，都满足交换律、结合律和幂等，因此不论同步顺序如何、跑多少次，各端最终结果逐字节相同。这与 BUG-2941「下载合集按季 / 集重排」是同一种写法（合并后做一步只依赖 wire 字段的确定性规整）。

### 8.5 拒绝的传播

用户在任一设备上撤销某个 AI 分组，或删掉一个 `ai` 合集，写一条「拒绝」墓碑（`organizeKey` 非空、`mergedIntoName` 为空）。它与现有的合集删除墓碑走同一套基线判新闻规则：

- 晚于对端基线：对端删除同键的 `ai` 合集，并把键加进拒绝表；
- 对端那时已经把该合集转成了 `user`（用户在那边编辑过）：**用户合集不删**，只记拒绝，不再让 AI 往里加东西。这是唯一一处「两端用户意图冲突」，按「编辑胜于删除」处理，与现有成员「重新加入胜」的语义一致。

拒绝**没有过期**。用户确实想要时可以在「整理记录」里点「允许再次建议」，这会清掉拒绝墓碑，同样跨端同步。

### 8.6 省钱协调（不承担正确性）

两端各自整理同一批书，结果会收敛，但会花两次钱。所以加一个轻量协调：

- 设置项「自动整理由这台设备负责」，默认只在互联 host（或无头服务端）上开，其余设备默认关；只有一台设备时它就是负责者。
- 非负责设备的自动整理只处理**负责设备没有的条目**（按 wire 成员键判断，看最近一次同步拿到的对端清单）。共享条目等负责设备整理好，同步过来即可。
- 负责设备离线超过 7 天，非负责设备自动接手（只是多花钱，结果照样收敛）。
- 手动触发不受限制，用户点了就跑。

### 8.7 合集名就是自然键带来的一个坑

`(name, collectionType)` 是 wire 自然键，所以两个不同系列的 AI 合集**不能同名**（例如两部都叫「短篇集」）。落盘前如果检测到同名但不同键，展示名加区分后缀（作者 / 品牌 / 年份）。这个后缀必须从 wire 可见的成员信息确定性地算出来，两端才能得到同一个名字。

## 9. 视频的「作品」与「系列」两层

视频合集不只是展示分组。刮削计划器把「≥2 成员、能解析出集号」的合集当作**一部作品**（`video_source_work_planner.dart` 的 `collection:<id>` 工作单元）。如果把《物语》系列的第一季、第二季和剧场版塞进一个合集，刮削会把它们当成一部作品去搜，元数据全错。

所以视频分两层落地：

- `level=work`（同一部作品、同一季的散集）：进合集，与规则归组的结果同构；
- `level=franchise`（同系列的不同作品）：**不建合集**，给相关合集 / 条目打同一个标签 `系列:<名字>`（`TagAssignments`），库页按标签筛选即可看到整个系列。标签名同样由 `organizeKey` 确定，写整理记录、可撤销。已有的刮削关系边 `CollectionRelations` 是可重建的缓存，不写 AI 结论。

书 / 漫画 / 游戏没有「一个合集 = 一部作品」的刮削判据，`franchise` 级直接进合集，例如「物语系列」一个合集装全部卷。

## 10. 触发

### 10.1 手动

- 书架 / 漫画库 / 视频库 / 游戏库顶栏加动作「AI 整理」（图标 `auto_awesome`），走 `FushiFloatingTopBar.adaptiveOverflow`，宽度不够时收进「⋯」（优先级低于搜索、排序、导入）；
- 多选模式下加「AI 整理所选」；
- 桌面 CLI：`fushi_cli library organize --domain video [--dry-run]`；
- 手动触发处理全域，或所选范围。

### 10.2 自动

- 设置项「导入后自动 AI 整理」，默认关（按量计费，必须显式开启），开启前要先过 §11 的同意框；
- 触发点挂在规则归组之后：`source_library_scanner.dart` 扫描完成、各导入对话框完成、无头服务端 `library_scanner.dart` 扫描完成；
- **只处理本次新增、且规则没归进合集的散条目**，加上它们可能并入的已有合集作为候选目标。不全库重跑；
- 去抖 30 秒，连续导入合并成一次；
- 每日预算：默认每域每天 ≤ 5 次请求，超了顺延到第二天，「整理记录」里显示原因；
- 置信度门槛按 §7.7 的自动列。

### 10.3 进度与结果

- 手动：底部 sheet 显示「正在分析 … 第 2/5 批」，可取消。每批落盘一次，取消不回滚已完成的批；
- 结束后 toast「已整理 9 处」，带「查看」和「撤销」两个按钮；
- 自动：静默运行，库页顶栏的 AI 图标上出现小红点，点开就是「整理记录」。

## 11. 门与隐私

- 入口一律经 `isAiModuleEnabled`（守卫 `ai_module_gate_guard_test.dart` 钉住）；
- 第一次运行（手动或开启自动时）弹一次性说明：会把标题、作者 / 品牌、年份、**视频文件夹末级名**发送给所选 AI 提供商，可能计费；点「开始」才记住，关掉弹窗不算同意。写法参照 `ocr_llm_default_consent.dart`；
- 不发完整路径、文件内容、封面、阅读或观看记录。

## 12. 「整理记录」页

设置 → AI → 整理记录，库页的 AI 图标也能进入。页面按次列出，进场动效走 `FushiEntranceScope` + `fushiStaggeredItemBuilder`：

```
10-20 14:03  书架 · 自动 · 3 处 · 1.2k token                    [撤销本次]
   + 新建「凉宫春日系列」(3 本)                       AI · 高   [撤销]
   + 「魔法禁书目录 22」并入「とある魔術の禁書目録」  AI · 高   [撤销]
   ⇄ 合并「禁书」→「とある魔術の禁書目録」            AI · 高   [撤销]
10-20 09:41  视频 · 手动 · 2 处
   + 新建「葬送のフリーレン」(28 集)                  规则      [撤销]
   # 标签「系列:物語」→ 4 个合集                      AI · 中   [撤销]
```

撤销语义：

- 撤销「新建」：删合集并写**拒绝**（§8.5）；
- 撤销「并入」：移出成员并写成员墓碑（与用户手动移出相同）；
- 撤销「合并」：从记录的 `payloadJson` 快照重建被合并的合集和成员，删掉重定向墓碑，并把原来两个键都记为「不得再合并」（拒绝表里存成键对）；
- 合集已经转成 `user` 后，对它的撤销只撤成员级改动，不删合集，并说明原因；
- 撤销本身就是一次用户写入，同步传播。

## 13. 顺带要还的债

书架与视频库各有一份几乎相同的 `_combineMergeCollections`（`home_video_page.dart` 与 `reader_history/books.part.dart`），AI 整理会是第三个调用方。先把它抽到 `database_library.part.dart`，签名 `Future<void> mergeMediaCollections(List<int> collectionIds, {required String name, required bool userIntent})`，两处 UI 改调它。`userIntent` 决定是否把胜方转成 `user`。

## 14. 测试

| 层 | 测试 |
|---|---|
| 收敛纯函数（重点） | 性质测试：随机生成 3–5 个设备的清单（随机键、成员、墓碑、所有权），对任意合并顺序 + 任意次数的 `converge`，结果逐字节相同（交换律、结合律、幂等）；用户合集永不被删；成员墓碑永不被并回 |
| 同步兼容 | 旧对端丢掉 `origin` / `organizeKey` 后回传清单，新端不丢键、不把 `ai` 降成未知 |
| 拒绝传播 | A 撤销，B 同步后同键 `ai` 合集被删；B 那边已转成 `user` 时不删只记拒绝 |
| 引擎纯函数 | prompt 构造快照；回复解析（围栏、多余散文、越界下标、重复成员、空数组）；校验裁决逐条一个用例；键归一化（全角、片假名、空白） |
| 引擎 + 内存库 | 刮削 id 冲突降级、目录合集不作合并源、同键复用、跨域拒绝、置信度门槛按触发方式区分 |
| 所有权 | 每个用户写入口都会把 `ai` 转成 `user`（源码扫描守卫枚举 `database_library.part.dart` 的写方法，新增写方法必须声明是否转所有权） |
| 撤销 | 撤销后库与整理前逐行一致（除新增的墓碑和拒绝） |
| 门 | AI 模块关闭 / 无提供商 / 未同意时不发请求 |
| 迁移 | v123 → v124：`sourceFolderPath` 非空回填 `folder`，其余 `user` |
| 真实模型（手动基线） | 用一份脱敏的真实书架标题清单跑一次，人工记录准确率与原名键一致率，作为调 prompt 的基线 |

测试里的 AI 调用用 `AiClientFactory` 注入假 completer，不联网。

## 15. 分期

1. **PR 1（重构）**：抽出 `mergeMediaCollections`，两处 UI 改调它，无行为变化。
2. **PR 2（schema + 所有权 + 同步）**：v124 两表加列、所有权单调转换、清单字段、`convergeOrganizedCollections` 与性质测试、拒绝传播。这一步不依赖 AI，规则归组也开始写 `rule` / `organizeKey`，可以先合入，先验证收敛。
3. **PR 3（AI 引擎）**：`AiFeature.libraryOrganize`、取事实、分块、prompt、解析、校验、落盘、整理记录、撤销。
4. **PR 4（书 / 漫画 UI + 自动触发）**：顶栏入口、同意框、进度、整理记录页、自动设置项与预算、i18n（`i18n_sync --add`）。
5. **PR 5（视频 + 游戏）**：视频两层（合集 + `系列:` 标签）、游戏事实接入。
6. **PR 6（省钱协调 + CLI）**：负责设备设置、接手逻辑、`fushi_cli library organize`。

PR 2 是风险最集中的一步（schema、同步 wire、所有写入口），按规则走 reviewer 审查，合入后跑目录枚举型守卫整批。

## 16. 已知代价

- 键不一致时（§8.3 第 3 层），最坏会有一段时间两端各有一个同系列合集，要等到任一设备下次整理或重叠规则命中才会合流。重叠规则覆盖了「同一批书」的情况；完全不重叠的两批书（手机 3 本、电脑另外 5 本）要等下一次 AI 运行才合流。
- 合集名是 wire 自然键，所以胜方定下后**不改名**。用户觉得名字不好可以手动改，改完转成 `user` 合集，之后 AI 不再碰它。
- 旧版本设备看不到 `origin`，会把 AI 合集当普通合集显示，在旧版上手动编辑也不会转所有权。等它升级后，下一次同步会从对端拿到正确的 `origin`。在旧版上做的编辑，新端只能当作成员增减来合并。
