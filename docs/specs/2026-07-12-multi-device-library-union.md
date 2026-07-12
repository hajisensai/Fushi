# 多端库联合视图（完整方案：远端混排 + 合集同步 + 手动序跨端）

> 状态：**已拍板**（2026-07-12 用户挨个决策：①混排+撤独立分区+开关默认开
> ②离线=目录快照缓存（灰占位+上次同步时间）③云视频也可下载 ④手动序整合集
> LWW）。本稿为一次交付的完整范围，无分期。
> 源头：用户群聊——书架跨客户端显示一致；缺的书占位可下载；没网保持现状；
> 客户端专有书照常；「参照 git 那样搞？我想让他远端书籍/视频混合进正常里面」。
> 分支：`worktree-unified-collections-plan`。

## 0. Linus 三问

1. **真问题吗？** 真。远端书/视频现在挤在独立分区，和本地库割裂；合集与
   手动序完全不跨端。用户要的是「一个库 = 本地 ∪ 远端」。
2. **「书架摆放位置同步」是伪需求。** 排序重设计后，显示顺序 =
   f(排序模式, 条目元数据)。要同步的是**目录、合集、手动序（sortIndex）**
   这三样数据，不是「位置」。
3. **「参照 git」对一半。** 对的：本地永远可用、离线照改、联网合并——现有
   同步已是这个模型（newer-wins + 墓碑 + bookKey 跨端身份）。错的：全历史/
   分支/三方合并不引入；排列（手动序）上的逐项合并是灾难，整表 LWW。

## 1. 现有地基（已核实，别重造）

| 能力 | 现状 |
|---|---|
| 跨端书身份 | `bookKey = sanitizeTtuFilename(title)`（EpubBooks 主键） |
| 远端书目录 | `RemoteBookInfo`（title/bookKey/封面/有声书徽章/tags），互联 host + 云后端两路 |
| 远端视频目录 | `RemoteVideoInfo`（title/封面/进度/分集/tags），互联可直接流播 |
| 内容下载 | 远端书区已有点击下载→入库全链（含进度徽章） |
| 进度双向同步 | SyncManager newer-wins；BUG-686 修过书架刷新 |
| 删除防复活 | 书墓碑（TODO-1195），重导入清墓碑 |
| 合集 | **设备间同步零覆盖**；仅备份导入合并（`_mergeMediaCollections`：(name, collection_type) 自然键幂等对齐 + 成员 INSERT OR IGNORE） |

## 2. 完整方案

### 2.1 联合目录视图：远端条目混排主网格

- remote-only 条目（远端有、本地无）渲染成**主网格占位卡**：正常卡尺寸 +
  远端封面（RemoteCoverImage 已有）+ 云角标 ☁；两端都有的条目只显示本地卡。
- 排序键：占位卡用远端进度时间戳（`positionUpdatedAtMs`）/远端目录序退化，
  参与当前排序模式；散卡与合集行的既有布局规则不变。
- 独立远端分区去留、「显示远端条目」开关 → 决策点 ①。

### 2.2 内容获取

- **书占位卡**：点击 → 走现有下载链（进度徽章原样），完成后原地变正常卡。
- **视频占位卡（已拍板：云视频也可下载）**：互联在线 → 直接远端流播（现有
  能力接进主网格卡）；云后端视频 → 点击下载整文件入库（进度徽章同书），
  下载完成原地变正常卡。

### 2.3 合集联合（唯一含 schema/接口改动的部分）

1. **目录归属**：host API / 云目录清单携带每条目的合集归属（合集名 + 类型 +
   该条目的 sortIndex），远端占位卡归进对应合集行（合集行内成员占位卡）。
2. **合集双向同步**（自动/手动同步管线新增阶段，云后端走 sync 根下
   `__collections__` JSON 清单，互联走 host API）：
   - 合集按 (name, collection_type) 自然键对齐（复用备份合并的成熟语义）；
   - 成员**并集 + 成员移出墓碑**（新表 `collection_member_tombstones`，
     复合键 collection自然键+media_type+entry_key+removed_at；无墓碑则 A 端
     移出的成员被 B 端并集复活——与书删除墓碑同一律）；重新加入清墓碑。
   - 合集删除：合集级墓碑（同一张表，entry_key 空哨兵或独立列），防复活。
3. **手动序跨端**：`MediaCollections` 加列 `order_updated_at`（schema v40，
   `reorderCollectionItems` 落盘时 bump）；同步比时间戳，**新者整表覆盖**
   （成员 sortIndex 全表跟随）。不做逐成员位置合并——两个排列不存在有意义
   的「合并」。A 端拖完序，B 端同步后详情页/合集行/播放器换集三处跨端同序。
   是否同步手动序 → 决策点 ④。

### 2.4 离线语义（已拍板：目录快照缓存）

新表 `remote_catalog_cache` 缓存上次成功拉取的远端目录（书+视频+合集归属，
含拉取时间戳）；离线/后端不可达时占位卡照常渲染但**置灰 + 「上次同步于 x」**
角标，点击提示不可用。在线成功拉取即整表覆盖快照。

### 2.5 客户端专有内容

本地有、远端无 → 照常显示（同步是并集，不删本地）；是否上传由既有
`syncContent` 等开关决定，不改语义。

## 3. 不做的事

- git 式历史/分支/逐项三方合并（LWW + 墓碑覆盖全部需求）。
- 「摆放位置」同步（不存在该状态）；排序模式偏好保持每端本地。
- 库级手动摆位复活（已拍板砍掉，手动序只活在合集详情页）。

## 4. 改动清单

| 面 | 改动 |
|---|---|
| schema v40 | `media_collections.order_updated_at`；新表 `collection_member_tombstones`；新表 `remote_catalog_cache`（离线快照，含拉取时间戳） |
| host API | 目录接口带合集归属；合集清单 endpoint（读+写） |
| 云后端 | sync 根 `__collections__/collections.json` 清单（LWW 按 order_updated_at/updatedAt） |
| 同步管线 | SyncOrchestrator 新增合集阶段（对齐/并集/墓碑/序 LWW）；SyncRunReport 计数 |
| UI | 两页主网格占位卡（云角标/下载/流播）+ 合集行成员占位卡 + 设置开关；独立远端分区按决策处理 |
| 备份合并 | `_mergeMediaCollections` 尊重成员墓碑（导备份也不复活移出成员） |
| 测试 | 墓碑防复活/序 LWW 整表覆盖/自然键对齐单测；占位卡+下载/流播 widget 测试；守卫更新 |

## 5. 决策点（2026-07-12 已全部拍板）

1. **远端混排形态 = 混排 + 撤独立分区**，设置「显示远端条目」开关默认开。
2. **离线语义 = 目录快照缓存**（灰占位 + 「上次同步于 x」，新表
   `remote_catalog_cache`）。
3. **云视频 = 也可下载**（整文件入库，进度徽章同书）。
4. **合集手动序 = 整合集 LWW**（`order_updated_at`，最后改序设备赢整个顺序）。

## 6. 实现任务表（完整，一次交付；拍板后按决策定稿）

| # | 任务 | 文件 | 验证 |
|---|---|---|---|
| 1 | schema v40：order_updated_at 列 + 成员/合集墓碑表 + remote_catalog_cache 快照表 + 迁移 | hibiki_core database/tables | 迁移单测 |
| 2 | reorderCollectionItems bump order_updated_at | database.dart | DAO 单测 |
| 3 | 合集清单编解码（JSON schema：自然键/成员/序/墓碑/时间戳） | 新 sync/collection_manifest.dart | 纯函数单测 |
| 4 | 合集同步阶段（对齐/并集/墓碑/整表 LWW）接进 SyncOrchestrator | sync_orchestrator.dart | 引擎级单测（双库互推收敛） |
| 5 | 互联 host：目录带合集归属 + 合集清单 endpoint | hibiki_library_host_service.dart | host 单测 |
| 6 | 云后端：__collections__ 清单读写 | sync backends | 同上 |
| 7 | 备份合并尊重成员墓碑 | backup_merge_engine.dart | merge 单测 |
| 8 | 远端目录快照：成功拉取整表覆盖 remote_catalog_cache；离线读快照 | 新 sync/remote_catalog_cache 层 + 两页 | DAO+widget 测试 |
| 9 | 书架/视频页占位卡混排（云角标/在线点击下载/流播、离线灰卡+上次同步时间）+ 开关 + 撤独立分区 | 两库页 + 设置 schema | widget 测试 |
| 10 | 云视频下载链（整文件入库，进度徽章复用书下载） | 视频占位卡 + 下载服务 | widget/服务测试 |
| 11 | 合集行成员占位卡 | collection_shelf_row 调用方 | widget 测试 |
| 12 | 守卫：合集同步不变量（墓碑必查/LWW 必比时间戳/占位不入库/离线只读快照） | 守卫测试 | 全量 analyze+test |

铁律边界：占位卡视觉/下载流播体验/双机真同步需真机（两台设备）复测；
离屏能验到引擎收敛性 + widget 行为层。
