# P3 Stage 2 实现计划(侦察定稿,2026-08-10)

> 基线 develop@7a3505ca7a(v82)。目标 v83。两个决策点已拍板:
> ① CollectionMemberTombstones.entryKey 冻结 bookKey 域;② shelf_entries 顺带换键 + 删 migrateShelfEntryKey。

四路侦察全部回报完毕。整合输出 P3 Stage 2 实现地图。

---

# P3 Stage 2 实现地图：ShelfEntries / MediaCollectionItems entryKey 换 uid（目标 v83）

基线：develop@7a3505ca7a（v82 已落地）。所有 file:line 以该 commit 为准。

## 0. 范围判定：只改 epub 域的**值**，不改键形，不动其它 kind

| mediaKind | entryKey 当前值语义 | 证据 | Stage 2 是否动 |
|---|---|---|---|
| epub | **bookKey = sanitizeTtuFilename(title)**，标题派生、同名重命名会漂移 | `tables.dart:803-806`、`collection_manifest.dart:270-271` | ✅ 换成 `epub_books.uid` |
| srt | `SrtBooks.uid`（天然稳定） | `tables.dart:914` | ❌ |
| video | `VideoBooks.bookUid`（天然稳定；远端下载直接沿用 `video.id` 作 bookUid，**零漂移**：`home_video_page.dart:1654` + 注释 `:1599-1600`） | `tables.dart:914` | ❌ |
| game | `galgames.id`（微秒戳串，本机局域） | `tables.dart:914-916` | ❌ |
| 远端 epub（本地无行） | `downloadId`（= host 的 bookKey） | `tables.dart:803` | 照抄透传（见 §7 风险 2） |

键形不变：`shelf_entries` PK `(mediaType, entryKey)`（`tables.dart:820`）、`media_collection_items` PK `(collectionId, mediaType, entryKey)`（`tables.dart:924`）、墓碑 PK `(collectionName, collectionType, mediaType, entryKey)`（`tables.dart:965`）。

## 1. 重大侦察结论（改变工作量估计的三件事）

1. **`shelf_entries` 生产侧已是死表**：`upsertShelfOrder`(`database_library.part.dart:339`)/`batchUpsertShelfOrder`(:360)/`setSeriesForEntry`(:383)/`getAllShelfEntries`(:330)/`getShelfEntriesBySeries`(:334)/`getShelfEntry`(:322) 在 lib/ 下**零生产调用**（旧写入方 `shelf_reorder_page` 已删，`docs/specs/2026-07-11-unified-collections-ui-v2.md:102`；`getAllShelfEntries` 被架构守卫列为库页禁止 token：`unified_collections_architecture_guard_test.dart:222-233`）。仅剩 4 条删除路径清行 + `migrateShelfEntryKey` 一个写入点 + backup 裸 SQL 裁剪。
2. **`migrateShelfEntryKey` 今天已恒 no-op**：它只在旧行（entryKey=downloadId）存在时迁移，而已无任何路径能建 downloadId 行（远端占位卡进不了选择集：`shelf_ordering.dart:53-71` 只认 `fushi://book/<bookKey>` 与 `srt_<uid>`）。「远端下载改键路径删除」的正当性不依赖 uid——**它现在就在迁移一张没人写的表**。
3. **`shelf_entries` 不进 backup_merge_engine**（全文件零匹配），只在导出裁剪出现（`backup_service.dart:1885/1923`）；合并引擎工作量集中在 `_mergeMediaCollections`。

## 2. 两表 DAO 全量与生产调用点（盘点结果）

### 2a. ShelfEntries DAO（8 个，全在 `packages/fushi_core/lib/src/database/database_library.part.dart`）
`getShelfEntry`:322 / `getAllShelfEntries`:330 / `getShelfEntriesBySeries`:334 / `upsertShelfOrder`:339 / `batchUpsertShelfOrder`:360 / `setSeriesForEntry`:383 / `deleteShelfEntry`:402 / `migrateShelfEntryKey`:412（insert+delete 搬 sortOrder/seriesId，独立事务）。

生产调用点仅剩：
- 删除路径 4 处（DAO 事务内）：`database_content_misc.part.dart:560`（deleteEpubBook，手里有整行 → uid 可得）、`database_library.part.dart:1039`（deleteSrtBookByUid）、`database_prefs_media.part.dart:318`（deleteAudiobookByBookKey）、`database_video_domain.part.dart:1857`（deleteVideoBook）。
- `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:416`（migrateShelfEntryKey 唯一调用点，恒 no-op）。
- 裸 SQL：`backup_service.dart:1885/1923`（导出裁剪）；`database.dart:2593/2628/2783/2864`（v38 历史迁移，冻结勿动）。

### 2b. MediaCollectionItems / 墓碑 DAO（同文件）
成员：`getCollectionItems`:616 / `getAllCollectionItems`:631 / `getPrimaryCollectionIdByEntry`:644（返回 `'<mediaType>|<entryKey>'→cid`）/ `addToCollection`:670 → `addToCollectionRaw`:677（清同键成员墓碑）/ `removeFromCollection`:709 → `removeFromCollectionRaw`:715（**写成员墓碑** + 移空自删）/ `reorderCollectionItems`:767 / `reorderCollectionItemsAutomatically`:780 / `removeEntryFromAllCollections`:826 / `upsertCollectionItemAt`:937（sync 专用）/ `deleteCollectionItemRaw`:950（sync 专用）。
墓碑：`getAllCollectionMemberTombstones`:862 / `upsertCollectionMemberTombstone`:879 / `deleteCollectionMemberTombstone`:897 / `replaceCollectionTombstonesFor`:913。

调用点按子系统（调用方手里的身份）：
- **书架/库页(epub+srt)**：`reader_fushi_history_page.dart:2315-2321`（`_addEpubToCollection` 传 **bookKey**，来自 `MediaItem.mediaIdentifier` 解码,非 EpubBookRow）、`:779/787` 读归属；`reader_history/books.part.dart:782/798/850/855`（批量组合,身份 `ShelfEntryRef` 经 `shelfSelectionToEntry`(`shelf_ordering.dart:53`) 解出 **bookKey**/srt uid；`:627-646` 剪枝用 `getAllEpubBooks()`——**此处有整行,bookKey→uid 最省的换算点**）、`:324`（srt uid）。
- **合集组件**：`add_to_collection_dialog.dart:24-65`、`collection_drag.dart:60-70`、`collection_context_dialog.dart`、`collection_one_key_sort.dart:144-148`、`collection_asset_reclaim.dart:76-116`、`media_collection_grid_detail_page.dart:103-215`（身份=**成员行裸串**,raw 操作,未知种类可移——这类无需换算）、`media_collection_detail_page.dart`（video bookUid）。
- **视频域**：`home_video_page.dart` 多处、`video_book_repository.dart:321-667`（含 `:667` removeEntryFromAllCollections）、`video_folder_group_coordinator.dart`、刮削 8 文件——全 video bookUid,不动。
- **galgame**：`games_library_page.dart:479-500`、`galgame_repository.dart:186/213`——game id,不动。
- **制卡**：`reader_fushi/mining.part.dart:212-220`（getPrimaryCollectionIdByEntry 用 `(epub, bookKey)` 组合键取系列名——**必改成 uid**）。
- **dashboard/统计**：`home_dashboard_page.dart:593-614`、`reading_statistics_page.dart:172-175`、`video_statistics_page.dart:87-90`（epub 组合键查询同上必改）。
- **sync 引擎**：`collection_sync_engine.dart:461-657`（见 §5）；host 归属注入 `app_model_library_host_service.dart:258-289`。
- **读取期孤儿过滤**：`collection_grouping.dart:106-110`、`video_fushi_page.dart:2091`、`app_model_library_host_service.dart:275`、`media_tracking_repository.dart:589/777`。

**隐藏 entryKey 载体（易漏）**：`media_collections.coverSource` = `'<mediaType>|<entryKey>'`（`tables.dart:840-842`）——epub 成员被借封面时含 bookKey，v83 迁移与备份合并（`backup_merge_engine.dart:425/498` 直搬 cover_source）都要跟着换，否则合集封面借用断链。

## 3. 远端下载改键路径：删什么、为什么能删

现路径（BUG-414 血统只是「bookKey 会漂移」的论据，改键本体出自 TODO-616 §0🔴2）：`remote.part.dart:378` `_downloadRemoteBook` → `:409-423` 判 `localBookKey != book.downloadId` 调 `migrateShelfEntryKey(epub, downloadId, localBookKey)`（DAO `database_library.part.dart:409-435`）。**media_collection_items / 墓碑从来没有对应改键**（全仓 `UPDATE … SET entry_key` 零命中）。

可删清单：
- `database_library.part.dart:409-435`（DAO 本体）；
- `remote.part.dart:409-423`（调用点 + 吞错块）；
- `fushi/test/database/shelf_entries_test.dart:88-144`（5 条 migrateShelfEntryKey 测试）；
- `tables.dart:803-806` entryKey 漂移注释改写。

删除正当性双保险：① 该路径今天恒 no-op（§1.2）；② 换 uid 后 epub 归属键在导入时刻定死、改标题/同名重命名不再漂移，「防漂移迁移」失去存在理由。**注意**：远端书 wire 无 uid（`RemoteBookInfo` 字段 `fushi_library_host_service.dart:250-308` 无 uid,且 `tables.dart:369-379` 明文「uid 不进 wire」+ 两端 uid 互撞）——但 Stage 2 不需要远端 uid：远端条目照抄 wire bookKey 透传（§7 风险 2），下载落地后由 sync 通道的 diff 收敛（见 §5B2 说明），不需要专用改键。

## 4. 备份合并引擎现状与改法

现状（`fushi/lib/src/sync/backup_merge_engine.dart`）：
- `_mergeMediaCollections`:418-539——**Dart 逐行循环**（非 INSERT...SELECT）：合集按自然键 (name,type) 对齐 id(:476-505)，成员 `INSERT OR IGNORE` 改写 collection_id(:527-537)，本地墓碑内存集合防复活(:434-455,成员键四元组直等匹配)。
- Stage 1b 模板：`_srcBookUidRekey`:282-285（src.uid→src.book_key→本库 book_key→uid,COALESCE 回落原值）、`_srcBookKeyForTombstone`:289-291（墓碑 guard 冻结在 book_key 域）。
- shelf_entries 不合并（无需新增——死表，合并零增益）。

改法（照 Stage 1b 形，但因是 Dart 循环，用查表 map 而非 SQL 表达式）：
1. 进成员循环前构建两张 map：`SELECT uid, book_key FROM {src}.epub_books`（srcUid→srcBookKey）与本库 `book_key→uid`。
2. epub 成员换键：`entryKeyForInsert = 本库uid[srcBookKey[srcEntryKey]] ?? srcBookKey[srcEntryKey] ?? srcEntryKey`（三级回落：本库有书→本库 uid;本库无书→回落 **src bookKey**(不是 src uid!保持 wire 域可续接);src 无书行→照抄,即远端透传行/游离行）。
3. 墓碑匹配（:521-525）：src 成员先经 srcUid→srcBookKey 归一到 bookKey 域再与本地墓碑比（本地墓碑域见下）。
4. cover_source 若为 `epub|<key>` 同步换键。
5. 无需 uid 撞库防线追加——成员表无 uid 唯一索引，`epub_books` 的 uid 重生成防线 Stage 1b 已做。

**墓碑 entryKey 面貌判定**：
- `BookTagMembershipTombstones.itemKey`：**冻结**（epub=bookKey）。v82 未动标签域；`tag_assignments` 与其墓碑整个不在 Stage 2 范围（P3 骨架 Stage 2 只列两表；`sync_manager.dart:773-783` / host `:313-350` 的标签 wire 全在 bookKey 域）。留下的表间键形不一致（tag_assignments epub 键仍 bookKey）要在 PR 描述里写明是有意分期。
- `CollectionMemberTombstones.entryKey`：**建议冻结在 bookKey 域（wire 域），不随成员表换 uid**。理由：(a) 墓碑本质是跨端防复活证据，与合集自然键 (name,type) 同律——必须在行消亡后仍可跨端比较；(b) 若切 uid，书被删后 uid→bookKey 反查失败，墓碑无法出 wire（`collection_sync_engine.dart:516-528` 发布需 bookKey）；(c) 合并引擎/发布/落地三处全免换算或单向换算。代价：`removeFromCollectionRaw`(:715) 写墓碑时手里是成员 entry_key(uid)，需反查 `uid→bookKey`（新入口 `resolveEpubBookKeyByUid`，反向对偶 `resolveEpubBookUid`(`database_content_misc.part.dart:131`)），反查不上（透传行）直接用原值——透传行的 entry_key 本来就是 bookKey，自然闭环。

## 5. sync/互联走线与冻结面

合集**不进 aggregate**（`aggregate_snapshot.dart:46-67` 无合集字段），走独立 `__collections__` 清单通道（`sync_orchestrator.dart:102/112`,云 `:720-833`,互联 live `:849-894`）；互联端点 `POST|GET /api/library/collections`（`fushi_sync_server.dart:604, 2192-2231`），DTO 就是 `CollectionManifest`。`shelf_entries.sortOrder/seriesId` **不进任何 wire**。

**冻结面（一行不动）**：`collection_manifest.dart` 全部键——成员 `mediaType/entryKey/sortIndex`(:302-306)、墓碑 `mediaType/entryKey/removedAt/publishedAt`(:361-366,`removedAt` 由 `tables.dart:943` 明文冻结)、合集自然键 `name/collectionType`(:236-241)；per-item 归属 DTO `fushi_library_host_service.dart:199-203`；端点路径与命名空间;wire 里 epub 的 entryKey **恒为 bookKey**。引擎纯函数 `CollectionSyncEngine.merge/combinePeers` 与 codec 保持纯 wire 域不动。

**换算落地点（只许出现在四个口）**：
| 口 | file:line | 方向 |
|---|---|---|
| 发布 `loadLocalCollectionManifest` | `collection_sync_engine.dart:509-514`(成员)/:516-528(墓碑) | 成员 uid→bookKey（`resolveEpubBookKeyByUid`,查不上照抄）;墓碑若按 §4 冻结则零换算 |
| 落地 `applyCollectionLocalChanges` | `:626-638`(desiredKeys/delete/upsert)/:647-657(墓碑镜像,哨兵''不换算) | bookKey→uid,**查不上照抄透传**（不得丢弃!union 语义要求转发本机没有的书的归属;这也是下载落地后归属自动收敛的机制：下轮 apply 时 bookKey 可解析→diff 删 bookKey 行插 uid 行） |
| host 归属注入 | `app_model_library_host_service.dart:278`(组键)与 `:354-358`(书侧按 r.bookKey 查) | map 键变 uid 后此处先 bookKey→uid |
| 远端卡展示回查 | `reader_fushi_history_page.dart:1383-1389`(云盘用 sanitize(title) 组 bookKey 回查) | bookKey→uid |

`deletion_disclosure`/`SyncDeletionTombstones.itemKey`（epub=bookKey）不动（Stage 1b 已冻结）。

## 6. 测试盘点

**范式参考（Stage 1b）**：`fushi/test/database/migration_v82_subtable_uid_test.dart`（手写旧库 DDL + `PRAGMA user_version` + 变异实测记录体例）、`delete_epub_book_cascade_v82_test.dart`（显式 `PRAGMA foreign_keys=ON` + 自证）、`backup_merge_import_test.dart:732/838/1037`（双库互异 uid 经 `resolveEpubBookUid` 造数）。

**必须跟改**：
- `fushi/test/utils/shelf_ordering_test.dart:9-18`（选区→entryKey 编码真相源,首要跟改点）
- `fushi/test/pages/booklongpress_floating_lyric_toggle_test.dart:133-144`（源码守卫 grep `entryKey: bookKey`/`entryKey: book.uid` 字面量,**必转红**）
- `fushi/test/pages/reader_shelf_batch_collection_ops_test.dart:220-258`、`stat_collection_name_test.dart`
- `fushi/test/database/epub_book_format_convert_test.dart:99-116`、`fushi/test/media/manga/book_format_rebuild_test.dart:223/248`（断言 `entryKey == bookKey` 的定点测试）
- `fushi/test/database/shelf_entries_test.dart:146-198`（删书清行组）；`:88-144` 随 migrateShelfEntryKey 一起删
- `fushi/test/sync/fushi_library_collections_test.dart:41/81`（listBooks 归属 JOIN）
- `fushi/test/database/package_schema_version_literal_guard_test.dart`（82→83）

**关键缺口（多数测试用裸串键,换 uid 不会自动转红,必须主动新增）**：
1. v83 迁移测试（照 v82 形）：epub 成员/墓碑按拍板域换键、srt/video/game 照抄、透传行保留（**不清 epub 无主行**——它可能是远端透传行,与 v82 INNER JOIN 清孤儿刻意不同,理由入注释）、cover_source 换键、行数不丢。
2. backup merge：合集用例 `:1171-1268` 现**无真 epub 行**——新增「两库同 book_key、uid 互异,成员 remap 到本机 uid;本机无书回落 src bookKey」。
3. `collection_sync_engine`：发布 uid→bookKey / 落地 bookKey→uid / 透传不丢 / 下载落地后 diff 收敛。
4. deleteEpubBook 清成员行守卫（若采纳 §7 缺口修复）。
5. 守卫复核：`media_kind_persistence_guard_test.dart:90`（禁手拼复合键,新代码必走 `MediaKind.compositeKey`）、`unified_collections_architecture_guard_test.dart` 15 条高概率牵动。

## 7. 风险点

1. **混合 kind 键空间**：所有换算必须 `mediaType=='epub'` 门控;video/srt/game 值一旦被误换算即数据损坏。合并引擎与迁移 SQL 的 WHERE 子句是第一道防线,测试 ① 必须含四 kind 混排造数。
2. **远端条目 entryKey(本地无行)**：apply 侧**不能**用 Stage 1b 的「查不到=no-op 丢弃」——合集清单是跨端 union,丢弃会砍掉「替对端转发本机没有的书的归属」;必须照抄透传（本列语义变为「epub 本地书=uid;远端-only=对端 bookKey 照抄」,与 v82 reader_positions COALESCE 先例同形）。透传行与真孤儿在库内不可区分——这正是 v83 迁移不能清孤儿的原因。
3. **迁移回填 JOIN 形**：`COALESCE((SELECT uid FROM epub_books WHERE book_key=entry_key AND uid!=''), entry_key) WHERE media_type='epub'`;成员表 PK 含 entry_key,直 UPDATE 可能撞 PK（脏数据同 cid 下 bookKey 行与 uid 行并存）——用 v82 式 create-copy-drop-rename + `INSERT OR IGNORE` 顺带去重。
4. **v83 重入守卫**：v82 靠 `_columnExists(表,'book_key')` 列级守卫,但 Stage 2 **不改列名**（entry_key 本就是多态键,语义注释改即可）,没有 schema 形状可探——重入守卫只剩 `from < 83` + 迁移体自身幂等（uid 不落在 book_key 值域,重跑 COALESCE 不再命中;病态标题恰为 `book_<n>_<n>` 形的碰撞概率忽略但要在注释记一笔）。合成/partial 测试库防炸仍需 `_tableExists` 守卫。
5. **coverSource 隐藏载体**（§2b 末）：迁移、备份合并、`updateMediaCollectionCover` 调用方三处都要对齐,漏一处合集封面静默回退占位。
6. **表间键形不一致（有意分期）**：`tag_assignments`/`BookTagMembershipTombstones`/`book_profiles`/`media_open_history` epub 键仍 bookKey——PR 里写明边界,防后人当 bug 修。
7. **正交活缺口（建议随 Stage 2 顺手修或另立 bug,勿混）**：epub/srt 删除**不清** media_collection_items（`removeEntryFromAllCollections` 全仓仅 video/game 3 处调用）→ 成员计数虚高、移空自删失效、孤儿被 sync 原样发布;远端 epub 成员若未来开放入合集,无任何 rekey 保护（`books.part.dart:782` 等入口现被选择集剪枝挡住）。修法：`deleteEpubBook`/`deleteSrtBookByUid` 补 `removeEntryFromAllCollections`——这同时消灭「孤儿 uid 出 wire」的垃圾传播路径,让 §4/§5 的反查闭环成立。

## 8. 建议执行顺序

1) fushi_core：tables.dart 注释 + v83 迁移（两表+coverSource,rebuild 形）+ `resolveEpubBookKeyByUid` + 删 `migrateShelfEntryKey` + deleteEpubBook/deleteSrtBookByUid 补成员清理
2) 页面消费点：`shelf_ordering` 解码后换算、`_addEpubToCollection`、mining.part、dashboard/统计组合键
3) collection_sync_engine 两口换算 + host service 两处
4) backup_merge_engine `_mergeMediaCollections` 查表换键 + 墓碑归一
5) 测试跟改 + 新增;analyze;`dart run tool/flutter_test_failures.dart --no-pub` 全量门

**待用户拍板的两个决策点**：① `CollectionMemberTombstones.entryKey` 冻结 bookKey 域（本报告推荐）还是随成员切 uid;② `shelf_entries` 是零成本顺带换键（保持与成员表语义一致）还是整表冻结在 bookKey 域（反正无人读）——推荐前者,同 PR 删 migrateShelfEntryKey。
